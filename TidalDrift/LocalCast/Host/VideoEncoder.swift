import Foundation
import VideoToolbox
import OSLog

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didOutput packet: Data, isKeyFrame: Bool, timestamp: CMTime)
}

class VideoEncoder {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "VideoEncoder")
    
    weak var delegate: VideoEncoderDelegate?
    
    private var session: VTCompressionSession?
    private let callbackQueue = DispatchQueue(label: "com.tidaldrift.localcast.encoder.callback", qos: .userInteractive)

    /// Serializes every VTCompressionSession call (create, encode, property
    /// updates, invalidate). VideoToolbox sessions are not safe for concurrent
    /// use: per-frame `encode` (capture queue), live tuning (UI), and adaptive
    /// bitrate (adaptive queue) all hit the same session, and concurrent
    /// VTSessionSetProperty + VTCompressionSessionEncodeFrame wedge the
    /// encoder's XPC service. Every caller then blocks forever in
    /// xpc_connection_send_message_with_reply_sync (observed as a main-thread
    /// hang and system-wide encoder instability that persists after the stream
    /// disconnects). Recursive because `encode` re-enters `setup` when the
    /// incoming frame size changes.
    private let sessionLock = NSRecursiveLock()

    // Flag to force next frame as keyframe
    private var forceNextKeyFrame = false
    private let keyframeLock = NSLock()
    
    // Current configuration (stored so the encoder can auto-reconfigure
    // when ScreenCaptureKit delivers frames at a different resolution than
    // the initial placeholder, e.g. after switching from full display to
    // a specific app).
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var currentCodec: LocalCastConfiguration.Codec = .h264
    private var currentBitrateMbps: Int = 50
    private var currentFps: Int = 60
    private var currentQuality: Float = 0.8

    /// When non-nil, Fast LAN is active and keyframe DataRateLimits are bounded
    /// to this many bytes per 0.1s window so a keyframe cannot exceed the
    /// receiver's fragment cap. Nil means resilient mode (the 1.5x/0.1s formula).
    /// Guarded by sessionLock (read in setup, updateLiveParameters, and
    /// dataRateLimits, all of which hold it).
    private var keyframeCeilingBytes: Int?

    /// A (width, height) that failed VTCompressionSessionCreate even after the
    /// dimension fallback, so the encoder is running at a reduced size while
    /// capture still delivers the larger frames. `encode()` checks this before
    /// auto-reconfiguring so it does not tear down and rebuild the working
    /// reduced-size session (with a forced keyframe) on every captured frame.
    /// Guarded by sessionLock.
    private var failedSetupDimension: (width: Int, height: Int)?

    deinit {
        // SAFETY: The VTCompressionSession callback holds an unretained pointer to
        // self (passUnretained). We MUST invalidate the session before deallocation
        // to prevent the callback from dereferencing freed memory.
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
    
    func setup(width: Int, height: Int, codec: LocalCastConfiguration.Codec, bitrateMbps: Int, fps: Int, quality: Float = 0.8, allowDimensionFallback: Bool = true) {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        // Tear down any existing session first
        if let old = session {
            VTCompressionSessionInvalidate(old)
            session = nil
        }
        
        // Store for auto-reconfigure
        currentWidth = width
        currentHeight = height
        currentCodec = codec
        currentBitrateMbps = bitrateMbps
        currentFps = fps
        currentQuality = quality
        
        let vtCodec: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var createdSession: VTCompressionSession?

        // Enable Apple's low-latency rate controller (Apple Silicon, macOS 11.3+).
        // This is the encoder mode built for real-time/conferencing: it reacts to
        // bitrate changes within a frame or two and holds latency far better than
        // the default rate controller under motion and loss. Falls back silently
        // to the default controller on hardware that doesn't support it.
        var encoderSpec: [CFString: Any] = [:]
        if #available(macOS 11.3, *) {
            encoderSpec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = kCFBooleanTrue as Any
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: vtCodec,
            encoderSpecification: encoderSpec.isEmpty ? nil : encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &createdSession
        )

        guard status == noErr, let session = createdSession else {
            logger.error("Failed to create \(codec == .hevc ? "HEVC" : "H.264") compression session: \(status)")
            if codec == .hevc {
                logger.warning("Falling back to H.264 encoder")
                setup(width: width, height: height, codec: .h264, bitrateMbps: bitrateMbps, fps: fps, quality: quality, allowDimensionFallback: allowDimensionFallback)
            } else if allowDimensionFallback, width > 320, height > 240 {
                // The H.264 attempt also failed at this dimension (e.g. the
                // encoder cannot create a session at 4K). Retry once at half the
                // dimension so the host still ends up with a working encoder.
                let reducedWidth = max(2, width / 2) & ~1
                let reducedHeight = max(2, height / 2) & ~1
                logger.warning("H.264 session creation failed at \(width)x\(height); retrying once at reduced \(reducedWidth)x\(reducedHeight)")
                setup(width: reducedWidth, height: reducedHeight, codec: .h264, bitrateMbps: bitrateMbps, fps: fps, quality: quality, allowDimensionFallback: false)
                // Recorded after the reduced retry so its success path (below)
                // does not immediately clear it: encode() reads this to avoid
                // re-attempting the failing size on every captured frame.
                failedSetupDimension = (width, height)
            }
            return
        }

        self.session = session
        currentCodec = codec
        // A session was created at this size, so it is no longer a known-failing
        // dimension; allow encode() to reconfigure to it again in the future.
        if let failed = failedSetupDimension, failed.width == width, failed.height == height {
            failedSetupDimension = nil
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (bitrateMbps * 1000 * 1000) as CFNumber)
        // High profile gives better quality per bit than Main at the same bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Shorter keyframe interval: on a lossy link a dropped frame corrupts the
        // stream until the next IDR, so a 4 s interval meant up to 4 s of freeze.
        // 1.5 s bounds worst-case recovery; paced sends keep the more frequent
        // keyframes from re-introducing burst loss.
        let keyframeIntervalSeconds = 1.5
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeIntervalSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(Double(fps) * keyframeIntervalSeconds) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        
        // Low-latency tuning: emit each frame immediately instead of buffering
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // Quality-focused: let the hardware encoder spend more time per frame.
        // Do NOT set PrioritizeEncodingSpeedOverQuality — we want the best visual
        // quality the encoder can produce within real-time constraints.
        
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(bitrateMbps: bitrateMbps))
        if limitStatus != noErr {
            logger.warning("DataRateLimits rejected (\(limitStatus)); keyframe bursts are unbounded on this encoder config")
        }
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        logger.info("Video encoder setup complete: \(width)x\(height), \(bitrateMbps)Mbps, \(fps)fps, quality=\(quality), profile=\(codec == .hevc ? "HEVC Main" : "H.264 High")")
    }
    
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        sessionLock.lock()
        defer { sessionLock.unlock() }

        // Auto-reconfigure if the incoming frame resolution doesn't match the
        // encoder session. This happens when ScreenCaptureManager starts capture
        // at a different size than the encoder's initial placeholder (e.g. the
        // encoder was pre-created at 1920x1080 but the actual Retina capture is
        // 2880x1800).
        let frameWidth = CVPixelBufferGetWidth(imageBuffer)
        let frameHeight = CVPixelBufferGetHeight(imageBuffer)
        if frameWidth != currentWidth || frameHeight != currentHeight {
            if let failed = failedSetupDimension, failed.width == frameWidth, failed.height == frameHeight {
                // This exact size already failed session creation, so the encoder
                // is running at a reduced fallback size. Re-attempting setup for it
                // every frame would tear down the working session and force a
                // keyframe on each captured frame. Skip the reconfigure; the capture
                // layer must reduce to this size for frames to flow.
            } else {
                logger.info("Frame \(frameWidth)x\(frameHeight) != encoder \(self.currentWidth)x\(self.currentHeight) -- reconfiguring")
                setup(width: frameWidth, height: frameHeight, codec: currentCodec, bitrateMbps: currentBitrateMbps, fps: currentFps, quality: currentQuality)
                forceKeyFrame()
            }
        }
        
        guard let session = session else { return }
        
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        // Check if we need to force a keyframe
        keyframeLock.lock()
        let shouldForceKeyFrame = forceNextKeyFrame
        if forceNextKeyFrame {
            forceNextKeyFrame = false
        }
        keyframeLock.unlock()
        
        var frameProperties: CFDictionary? = nil
        if shouldForceKeyFrame {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            logger.debug("🔑 Encoding forced keyframe NOW")
        }
        
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }
    
    /// Update encoder parameters in-place without recreating the VTCompressionSession.
    /// VTSessionSetProperty supports live changes to bitrate, quality, and FPS.
    /// Returns true if all properties were set successfully.
    @discardableResult
    func updateLiveParameters(bitrateMbps: Int? = nil, fps: Int? = nil, quality: Float? = nil, keyframeIntervalSeconds: Double? = nil) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard let session = session else {
            logger.warning("updateLiveParameters: no active session")
            return false
        }
        
        var allOk = true
        
        if let bps = bitrateMbps, bps != currentBitrateMbps {
            currentBitrateMbps = bps
            let avgBitRate = bps * 1_000_000
            let s1 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBitRate as CFNumber)
            
            let s2 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(bitrateMbps: bps))
            
            if s1 == noErr && s2 == noErr {
                logger.info("Live update: bitrate → \(bps) Mbps")
            } else {
                logger.warning("Live update bitrate failed: avg=\(s1), limit=\(s2)")
                allOk = false
            }
        }
        
        if let newFps = fps, newFps != currentFps {
            currentFps = newFps
            let s = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: newFps as CFNumber)
            if s == noErr {
                logger.info("Live update: fps → \(newFps)")
            } else {
                logger.warning("Live update fps failed: \(s)")
                allOk = false
            }
        }
        
        if let q = quality, q != currentQuality {
            currentQuality = q
            let s = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
            if s == noErr {
                logger.info("Live update: quality → \(q)")
            } else {
                logger.warning("Live update quality failed: \(s)")
                allOk = false
            }
        }
        
        if let kfi = keyframeIntervalSeconds {
            let s1 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: kfi as CFNumber)
            let kfiFrames = currentFps * Int(kfi)
            let s2 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: kfiFrames as CFNumber)
            if s1 == noErr && s2 == noErr {
                logger.info("Live update: keyframe interval → \(kfi)s (\(kfiFrames) frames)")
            } else {
                logger.warning("Live update keyframe interval failed: \(s1)/\(s2)")
                allOk = false
            }
        }
        
        return allOk
    }
    
    /// DataRateLimits pair bounding bursts to ~1.5x the average bitrate over a
    /// 100ms window, so a keyframe is small enough to serialize onto the wire
    /// within a frame interval. With no retransmit, a multi-MB keyframe spends
    /// 100ms+ in flight and a single lost fragment discards the whole frame;
    /// keeping keyframes near the per-window budget trades a softer IDR for a
    /// stream that survives the uplink. VideoToolbox reads the array as
    /// alternating [bytes, seconds] CFNumbers and accepts fractional seconds;
    /// callers check the VTSessionSetProperty status since support varies by
    /// codec and OS version.
    private func dataRateLimits(bitrateMbps: Int) -> CFArray {
        if let ceiling = keyframeCeilingBytes {
            // Fast LAN: bound the keyframe burst to the receiver's fragment cap.
            // A keyframe is emitted within one frame interval (< 0.1s), so this
            // caps the keyframe size directly. The implied rate (ceiling / 0.1s)
            // sits far above the average bitrate, leaving P-frames unaffected.
            return [NSNumber(value: ceiling), NSNumber(value: 0.1)] as CFArray
        }
        let bytesPerSecond = (bitrateMbps * 1_000_000) / 8
        let windowSeconds = 0.1
        let burstBytes = Int(Double(bytesPerSecond) * 1.5 * windowSeconds)
        return [NSNumber(value: burstBytes), NSNumber(value: windowSeconds)] as CFArray
    }

    /// Set the Fast LAN keyframe byte ceiling (nil means resilient mode).
    /// Re-applies DataRateLimits live so an auto-selected switch, or a jumbo
    /// on/off change that moves the ceiling, takes effect without recreating the
    /// session. setup and updateLiveParameters read the same stored ceiling, so
    /// the limits stay consistent across a later resolution reconfigure.
    func setFastLAN(keyframeCeilingBytes: Int?) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard keyframeCeilingBytes != self.keyframeCeilingBytes else { return }
        self.keyframeCeilingBytes = keyframeCeilingBytes
        guard let session = session else { return }
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(bitrateMbps: currentBitrateMbps))
        if status != noErr {
            logger.warning("Live DataRateLimits update failed: \(status)")
        }
    }
    
    func invalidate() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if let session = session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
    
    func forceKeyFrame() {
        keyframeLock.lock()
        forceNextKeyFrame = true
        keyframeLock.unlock()
        logger.debug("🔑 Keyframe requested - will encode next frame as keyframe")
    }

    /// True while a forced keyframe is queued but not yet encoded. Lets the
    /// host's idle-frame skip still deliver the keyframe a new viewer is
    /// waiting for even when the screen content is static.
    var hasPendingForceKeyFrame: Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        return forceNextKeyFrame
    }
    
    private let compressionCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }
        
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
        
        // 1. Check for keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == false || attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        
        // 2. Extract elementary stream data (AVCC format - length prefixed)
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        
        guard let pointer = pointer else { return }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        var packetData = Data(capacity: length + 128)
        
        // 3. For keyframes, prepend parameter sets (SPS/PPS) with Annex B start codes
        if isKeyFrame {
            encoder.logger.debug("🔑 Encoding KEYFRAME")
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if let parameterSets = encoder.extractParameterSets(from: formatDescription) {
                    packetData.append(parameterSets)
                    encoder.logger.debug("🔑 Prepending SPS/PPS (\(parameterSets.count) bytes) to keyframe")
                }
            }
        }
        
        // 4. Convert AVCC data to Annex B format (replace length prefixes with start codes)
        let avccData = Data(bytes: pointer, count: length)
        let annexBData = encoder.convertAVCCToAnnexB(avccData)
        packetData.append(annexBData)
        
        if isKeyFrame {
            encoder.logger.debug("🔑 Sending keyframe packet: \(packetData.count) bytes (SPS/PPS + frame)")
        }
        
        encoder.delegate?.videoEncoder(encoder, didOutput: packetData, isKeyFrame: isKeyFrame, timestamp: timestamp)
    }
    
    private static let annexBStartCode: [UInt8] = [0, 0, 0, 1]
    
    /// Convert AVCC format (4-byte length prefix) to Annex B format (start codes).
    /// Works directly with the raw pointer to avoid copying into [UInt8].
    private func convertAVCCToAnnexB(_ avccData: Data) -> Data {
        var annexBData = Data(capacity: avccData.count + 32)
        
        avccData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buf.count
            var offset = 0
            
            while offset + 4 <= count {
                let nalLength = Int(base[offset]) << 24 | Int(base[offset+1]) << 16 | Int(base[offset+2]) << 8 | Int(base[offset+3])
                offset += 4
                
                if nalLength <= 0 || offset + nalLength > count {
                    if offset < count {
                        annexBData.append(contentsOf: Self.annexBStartCode)
                        annexBData.append(base + offset, count: count - offset)
                    }
                    break
                }
                
                annexBData.append(contentsOf: Self.annexBStartCode)
                annexBData.append(base + offset, count: nalLength)
                offset += nalLength
            }
        }
        
        return annexBData
    }
    
    private func extractParameterSets(from formatDescription: CMFormatDescription) -> Data? {
        var parameterSets = Data()
        
        if CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264 {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            
            for i in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer = pointer {
                    parameterSets.append(Data([0, 0, 0, 1])) // Start code
                    parameterSets.append(pointer, count: size)
                }
            }
        } else if CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC {
            // HEVC VPS/SPS/PPS handling
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            
            for i in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer = pointer {
                    parameterSets.append(Data([0, 0, 0, 1])) // Start code
                    parameterSets.append(pointer, count: size)
                }
            }
        }
        
        return parameterSets.isEmpty ? nil : parameterSets
    }
}

