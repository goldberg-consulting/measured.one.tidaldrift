import Foundation
import VideoToolbox
import OSLog

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didOutput packet: Data, isKeyFrame: Bool, timestamp: CMTime)
}

class VideoEncoder {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "VideoEncoder")
    
    weak var delegate: VideoEncoderDelegate?
    /// Delivered asynchronously after session access is unlocked. The host can
    /// restore capture settings without reentering a VideoToolbox operation.
    var onError: ((String) -> Void)?
    
    private var session: VTCompressionSession?

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

    private var hardwareAccelerated = false
    private var failedAutomaticDimensions: (width: Int, height: Int)?
    private var lastSubmissionFailure: OSStatus?
    private var keyframeIntervalSeconds = 1.5
    private var lastKeyframeTimestamp: CMTime = .invalid

    var isHardwareAccelerated: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return hardwareAccelerated
    }

    var codecName: String {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return currentCodec == .hevc ? "HEVC" : "H.264"
    }

    deinit {
        // SAFETY: The VTCompressionSession callback holds an unretained pointer to
        // self (passUnretained). We MUST invalidate the session before deallocation
        // to prevent the callback from dereferencing freed memory.
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
    
    /// Creates a hardware session, retaining the working session if replacement fails.
    /// HEVC may fall back to hardware H.264 at the requested dimensions.
    @discardableResult
    func setup(width: Int, height: Int, codec: LocalCastConfiguration.Codec, bitrateMbps: Int, fps: Int, quality: Float = 0.8, allowDimensionFallback: Bool = true) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        // An explicit settings change permits a retry after resources or codec
        // choices change. Automatic attempts record failure after setup returns.
        failedAutomaticDimensions = nil
        lastSubmissionFailure = nil
        guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max),
              bitrateMbps > 0, bitrateMbps <= 1_000, fps > 0, fps <= 240,
              quality.isFinite, (0...1).contains(quality) else { return false }

        let vtCodec: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var createdSession: VTCompressionSession?
        // LowLatencyRateControl is a requirement, not a preference. Retry the
        // same codec without it before sacrificing HEVC compression efficiency.
        var status: OSStatus = kVTVideoEncoderNotAvailableNowErr
        for lowLatency in [true, false] {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ]
            if lowLatency {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
            }
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: vtCodec, encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: compressionCallback,
                refcon: Unmanaged.passUnretained(self).toOpaque(),
                compressionSessionOut: &createdSession)
            if status == noErr, createdSession != nil { break }
            if let partial = createdSession { VTCompressionSessionInvalidate(partial) }
            createdSession = nil
        }
        guard status == noErr, let session = createdSession else {
            logger.error("Hardware encoder creation failed for \(width)x\(height): \(status)")
            if codec == .hevc {
                return setup(width: width, height: height, codec: .h264,
                    bitrateMbps: bitrateMbps, fps: fps, quality: quality,
                    allowDimensionFallback: false)
            }
            // A smaller encoder cannot accept the larger capture buffers. Fail
            // explicitly so the host can renegotiate capture instead of freezing.
            return false
        }
        var hardware: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware)
        // The low-latency hardware encoder can reject this diagnostic property
        // (-12900) even though creation with RequireHardware succeeded. That
        // specification forbids software fallback; a missing diagnostic is not
        // evidence that hardware is unavailable. Still reject an explicit false.
        guard (hardwareStatus == noErr && hardware as? Bool == true)
                || hardwareStatus == kVTPropertyNotSupportedErr else {
            VTCompressionSessionInvalidate(session)
            logger.error("VideoToolbox could not verify hardware encoding")
            return false
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeIntervalSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Int(Double(fps) * keyframeIntervalSeconds) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        
        // Low-latency tuning: emit each frame immediately instead of buffering
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // The host is a desktop streaming at hundreds of Mbps; never let the
        // encoder trade frame time for power.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
        if codec == .h264 {
            // CABAC is ~10% smaller than CAVLC at equal quality and the hardware
            // decoder handles it at any of our frame rates.
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        }
        // Retain the encoder's quality policy. Speed priority did not improve
        // 4K throughput in the shared-machine benchmark enough to justify
        // changing compression decisions without a visual quality comparison.
        
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(bitrateMbps: bitrateMbps))
        if limitStatus != noErr {
            logger.warning("DataRateLimits rejected (\(limitStatus)); keyframe bursts are unbounded on this encoder config")
        }
        
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            logger.error("Hardware encoder preparation failed: \(prepareStatus)")
            return false
        }
        if let old = self.session { VTCompressionSessionInvalidate(old) }
        self.session = session
        hardwareAccelerated = true
        currentWidth = width
        currentHeight = height
        currentCodec = codec
        currentBitrateMbps = bitrateMbps
        currentFps = fps
        currentQuality = quality
        lastKeyframeTimestamp = .invalid
        forceKeyFrame()
        logger.info("Video encoder setup complete: \(width)x\(height), \(bitrateMbps)Mbps, \(fps)fps, quality=\(quality), profile=\(codec == .hevc ? "HEVC Main" : "H.264 High")")
        return true
    }
    
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var failureMessage: String?
        sessionLock.lock()
        defer {
            sessionLock.unlock()
            if let failureMessage {
                Task { [weak self] in self?.onError?(failureMessage) }
            }
        }

        // Auto-reconfigure if the incoming frame resolution doesn't match the
        // encoder session. This happens when ScreenCaptureManager starts capture
        // at a different size than the encoder's initial placeholder (e.g. the
        // encoder was pre-created at 1920x1080 but the actual Retina capture is
        // 2880x1800).
        let frameWidth = CVPixelBufferGetWidth(imageBuffer)
        let frameHeight = CVPixelBufferGetHeight(imageBuffer)
        if frameWidth != currentWidth || frameHeight != currentHeight {
            if let failed = failedAutomaticDimensions,
               failed.width == frameWidth, failed.height == frameHeight { return }
            guard setup(width: frameWidth, height: frameHeight, codec: currentCodec,
                        bitrateMbps: currentBitrateMbps, fps: currentFps, quality: currentQuality) else {
                failedAutomaticDimensions = (frameWidth, frameHeight)
                failureMessage = "Hardware encoding is unavailable at \(frameWidth)x\(frameHeight). Restore the previous resolution or choose a smaller capture size."
                return
            }
        }

        guard let session = session else { return }
        
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        // Check if we need to force a keyframe
        keyframeLock.lock()
        // The low-latency rate controller uses an infinite GOP. Force periodic
        // IDRs explicitly so recovery is bounded even when interval keys are ignored.
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(presentationTimestamp, lastKeyframeTimestamp))
        let periodicKeyFrame = !lastKeyframeTimestamp.isValid || !elapsed.isFinite
            || elapsed < 0 || elapsed >= keyframeIntervalSeconds
        let shouldForceKeyFrame = forceNextKeyFrame || periodicKeyFrame
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
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimestamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status == noErr, !flags.contains(.frameDropped) {
            lastSubmissionFailure = nil
            if shouldForceKeyFrame { lastKeyframeTimestamp = presentationTimestamp }
        } else {
            forceKeyFrame()
            logger.error("Hardware encode submission failed or dropped a frame: \(status)")
            if status != noErr, lastSubmissionFailure != status {
                lastSubmissionFailure = status
                failureMessage = "Hardware video encoding failed (\(status)). Restore the capture settings or retry the stream."
            }
        }
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
            guard (1...1_000).contains(bps) else { return false }
            let avgBitRate = bps * 1_000_000
            let s1 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBitRate as CFNumber)
            
            let s2 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits(bitrateMbps: bps))
            
            if s1 == noErr && s2 == noErr {
                currentBitrateMbps = bps
                logger.info("Live update: bitrate → \(bps) Mbps")
            } else {
                logger.warning("Live update bitrate failed: avg=\(s1), limit=\(s2)")
                allOk = false
            }
        }
        
        if let newFps = fps, newFps != currentFps {
            guard (1...240).contains(newFps) else { return false }
            let s = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: newFps as CFNumber)
            if s == noErr {
                currentFps = newFps
                logger.info("Live update: fps → \(newFps)")
            } else {
                logger.warning("Live update fps failed: \(s)")
                allOk = false
            }
        }
        
        if let q = quality, q != currentQuality {
            guard q.isFinite, (0...1).contains(q) else { return false }
            let s = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: q as CFNumber)
            if s == noErr {
                currentQuality = q
                logger.info("Live update: quality → \(q)")
            } else {
                logger.warning("Live update quality failed: \(s)")
                allOk = false
            }
        }
        
        if let kfi = keyframeIntervalSeconds {
            guard kfi.isFinite, (0.1...60).contains(kfi) else { return false }
            self.keyframeIntervalSeconds = kfi
            let s1 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: kfi as CFNumber)
            // Round rather than truncate: Int(1.5) is 1, which at 60 fps
            // requested a keyframe every 60 frames while the duration key
            // asked for 90, and the encoder honours whichever fires first.
            let kfiFrames = max(1, Int((Double(currentFps) * kfi).rounded()))
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
        hardwareAccelerated = false
        lastKeyframeTimestamp = .invalid
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
        guard let outputCallbackRefCon else { return }
        let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
        guard status == noErr, let sampleBuffer else {
            encoder.forceKeyFrame()
            return
        }
        
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
