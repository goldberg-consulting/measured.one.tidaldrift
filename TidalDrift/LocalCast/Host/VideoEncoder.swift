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
    
    deinit {
        // SAFETY: The VTCompressionSession callback holds an unretained pointer to
        // self (passUnretained). We MUST invalidate the session before deallocation
        // to prevent the callback from dereferencing freed memory.
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
    }
    
    func setup(width: Int, height: Int, codec: LocalCastConfiguration.Codec, bitrateMbps: Int, fps: Int, quality: Float = 0.8) {
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
        
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: vtCodec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            logger.error("Failed to create compression session: \(status)")
            return
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: (bitrateMbps * 1000 * 1000) as CFNumber)
        // High profile gives better quality per bit than Main at the same bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 4) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
        
        // Low-latency tuning: emit each frame immediately instead of buffering
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // Quality-focused: let the hardware encoder spend more time per frame.
        // Do NOT set PrioritizeEncodingSpeedOverQuality — we want the best visual
        // quality the encoder can produce within real-time constraints.
        
        // Relaxed data rate limit: allow bursts up to 3x average bitrate within
        // a 1-second window. On a LAN, burst spikes are acceptable and this lets
        // keyframes retain much higher quality instead of being aggressively quantized.
        let bytesPerSecond = (bitrateMbps * 1_000_000) / 8
        let burstLimit = bytesPerSecond * 3  // 3x average for keyframe headroom
        let dataRateLimit: [Int] = [burstLimit, 1]  // [bytes, seconds]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit as CFArray)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        logger.info("Video encoder setup complete: \(width)x\(height), \(bitrateMbps)Mbps, \(fps)fps, quality=\(quality), profile=\(codec == .hevc ? "HEVC Main" : "H.264 High")")
    }
    
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Auto-reconfigure if the incoming frame resolution doesn't match the
        // encoder session. This happens when ScreenCaptureManager starts capture
        // at a different size than the encoder's initial placeholder (e.g. the
        // encoder was pre-created at 1920x1080 but the actual Retina capture is
        // 2880x1800).
        let frameWidth = CVPixelBufferGetWidth(imageBuffer)
        let frameHeight = CVPixelBufferGetHeight(imageBuffer)
        if frameWidth != currentWidth || frameHeight != currentHeight {
            logger.info("Frame \(frameWidth)x\(frameHeight) != encoder \(self.currentWidth)x\(self.currentHeight) -- reconfiguring")
            setup(width: frameWidth, height: frameHeight, codec: currentCodec, bitrateMbps: currentBitrateMbps, fps: currentFps, quality: currentQuality)
            forceKeyFrame()
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
            logger.info("🔑 Encoding forced keyframe NOW")
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
        guard let session = session else {
            logger.warning("updateLiveParameters: no active session")
            return false
        }
        
        var allOk = true
        
        if let bps = bitrateMbps, bps != currentBitrateMbps {
            currentBitrateMbps = bps
            let avgBitRate = bps * 1_000_000
            let s1 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBitRate as CFNumber)
            
            // Also update the burst data rate limit (3x average in a 1-second window)
            let bytesPerSecond = avgBitRate / 8
            let burstLimit = bytesPerSecond * 3
            let dataRateLimit: [Int] = [burstLimit, 1]
            let s2 = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit as CFArray)
            
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
    
    func invalidate() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
    
    func forceKeyFrame() {
        keyframeLock.lock()
        forceNextKeyFrame = true
        keyframeLock.unlock()
        logger.info("🔑 Keyframe requested - will encode next frame as keyframe")
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
            encoder.logger.info("🔑 Encoding KEYFRAME")
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                if let parameterSets = encoder.extractParameterSets(from: formatDescription) {
                    packetData.append(parameterSets)
                    encoder.logger.info("🔑 Prepending SPS/PPS (\(parameterSets.count) bytes) to keyframe")
                }
            }
        }
        
        // 4. Convert AVCC data to Annex B format (replace length prefixes with start codes)
        let avccData = Data(bytes: pointer, count: length)
        let annexBData = encoder.convertAVCCToAnnexB(avccData)
        packetData.append(annexBData)
        
        if isKeyFrame {
            encoder.logger.info("🔑 Sending keyframe packet: \(packetData.count) bytes (SPS/PPS + frame)")
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

