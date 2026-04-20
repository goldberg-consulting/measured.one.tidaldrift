import Foundation
import VideoToolbox
import OSLog
import CoreMedia
import QuartzCore

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecode imageBuffer: CVImageBuffer)
}

class VideoDecoder {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "VideoDecoder")
    weak var delegate: VideoDecoderDelegate?
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    // Store parameter sets for session creation
    private var sps: Data?
    private var pps: Data?
    private var vps: Data? // For HEVC
    
    private var isHEVC = false
    private var frameCount = 0
    private var hasLoggedFirstFrame = false
    
    deinit {
        // SAFETY: The VTDecompressionSession callback holds an unretained pointer
        // to self. Invalidate before deallocation to prevent use-after-free.
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
    
    func decode(_ data: Data) {
        // Log incoming data for debugging
        if frameCount == 0 {
            let hexPrefix = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            logger.info("🎬 First packet received! \(data.count) bytes. First 32: \(hexPrefix)")
        }
        
        // Check if data starts with Annex B start code (00 00 00 01 or 00 00 01)
        let hasAnnexBStartCode = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let b = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let n = buf.count
            return (n >= 4 && b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1) ||
                   (n >= 3 && b[0] == 0 && b[1] == 0 && b[2] == 1)
        }
        
        if hasAnnexBStartCode {
            // Parse NAL units from Annex B format
            let nalUnits = parseNALUnits(from: data)
            if nalUnits.isEmpty && frameCount < 10 {
                print("🎬 VideoDecoder: No NAL units parsed from Annex B data")
            }
            for nal in nalUnits {
                handleNALUnit(nal)
            }
        } else {
            // Assume AVCC format (length-prefixed) - parse accordingly
            parseAVCCNALUnits(from: data)
        }
    }
    
    /// Parse NAL units from AVCC format (4-byte length prefix)
    private func parseAVCCNALUnits(from data: Data) {
        let bytes = [UInt8](data)
        var offset = 0
        
        while offset + 4 < bytes.count {
            // Read 4-byte length (big endian)
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
            offset += 4
            
            if length <= 0 || offset + length > bytes.count {
                if frameCount < 10 {
                    print("🎬 VideoDecoder: Invalid AVCC NAL length \(length) at offset \(offset-4)")
                }
                break
            }
            
            let nalData = Data(bytes[offset..<(offset + length)])
            handleNALUnit(nalData)
            offset += length
        }
    }
    
    /// Parse NAL units from Annex B format (start code prefixed)
    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        
        // Find all start code positions
        var startPositions: [Int] = []
        
        while i < bytes.count - 3 {
            // Check for 4-byte start code (00 00 00 01)
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startPositions.append(i)
                i += 4
            }
            // Check for 3-byte start code (00 00 01)
            else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startPositions.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        
        // Extract NAL units between start codes
        for j in 0..<startPositions.count {
            let startCodePos = startPositions[j]
            let startCodeLen = (bytes[startCodePos+2] == 1) ? 3 : 4
            let nalStart = startCodePos + startCodeLen
            
            let nalEnd: Int
            if j + 1 < startPositions.count {
                nalEnd = startPositions[j + 1]
            } else {
                nalEnd = bytes.count
            }
            
            if nalStart < nalEnd {
                let nalData = Data(bytes[nalStart..<nalEnd])
                nalUnits.append(nalData)
            }
        }
        
        // Log parsing results for debugging
        if nalUnits.isEmpty {
            logger.warning("🎬 NAL parser: No NAL units found in \(data.count) bytes")
        } else if frameCount == 0 {
            logger.info("🎬 NAL parser: Found \(nalUnits.count) NAL units from \(data.count) bytes")
            for (idx, nal) in nalUnits.prefix(5).enumerated() {
                let nalType = nal.first.map { $0 & 0x1F } ?? 0
                logger.info("🎬   NAL[\(idx)]: type=\(nalType), size=\(nal.count)")
            }
        }
        
        return nalUnits
    }
    
    private func handleNALUnit(_ nalUnit: Data) {
        guard !nalUnit.isEmpty else { return }
        
        let firstByte = nalUnit[0]
        let h264NalType = firstByte & 0x1F  // H.264 NAL type (lower 5 bits)
        
        // Debug first few NAL units
        if frameCount < 5 {
            print("🎬 VideoDecoder: NAL unit - firstByte=0x\(String(format: "%02X", firstByte)), H264Type=\(h264NalType), size=\(nalUnit.count)")
        }
        
        // Try H.264 first (default codec)
        switch h264NalType {
        case 7:  // SPS (H.264)
            // SPS should be small (typically < 100 bytes)
            if nalUnit.count > 500 {
                logger.warning("🎬 Suspicious SPS size: \(nalUnit.count) bytes (expected < 100)")
                return
            }
            logger.info("🎬 ✅ Received H.264 SPS (\(nalUnit.count) bytes)")
            sps = nalUnit
            isHEVC = false
            tryCreateSession()
            return
            
        case 8:  // PPS (H.264)
            // PPS should be small (typically < 50 bytes)
            if nalUnit.count > 500 {
                logger.warning("🎬 Suspicious PPS size: \(nalUnit.count) bytes (expected < 50)")
                return
            }
            logger.info("🎬 ✅ Received H.264 PPS (\(nalUnit.count) bytes)")
            pps = nalUnit
            isHEVC = false
            tryCreateSession()
            return
            
        case 1:  // Non-IDR slice (H.264)
            frameCount += 1
            decodeVideoFrame(nalUnit)
            return
            
        case 5:  // IDR slice (H.264)
            frameCount += 1
            if !hasLoggedFirstFrame {
                print("🎬 VideoDecoder: ✅ Decoding first H.264 IDR frame!")
                hasLoggedFirstFrame = true
            }
            decodeVideoFrame(nalUnit)
            return
            
        case 6:  // SEI (Supplemental Enhancement Info)
            // Skip SEI NAL units
            return
            
        case 9:  // Access Unit Delimiter
            // Skip AUD
            return
            
        default:
            break
        }
        
        // If not recognized as H.264, check HEVC
        if nalUnit.count >= 2 {
            let hevcNalType = (firstByte >> 1) & 0x3F
            
            switch hevcNalType {
            case 32:  // VPS
                print("🎬 VideoDecoder: ✅ Received HEVC VPS (\(nalUnit.count) bytes)")
                vps = nalUnit
                isHEVC = true
                return
                
            case 33:  // SPS
                print("🎬 VideoDecoder: ✅ Received HEVC SPS (\(nalUnit.count) bytes)")
                sps = nalUnit
                isHEVC = true
                tryCreateSession()
                return
                
            case 34:  // PPS
                print("🎬 VideoDecoder: ✅ Received HEVC PPS (\(nalUnit.count) bytes)")
                pps = nalUnit
                isHEVC = true
                tryCreateSession()
                return
                
            case 0...9, 16...21:  // HEVC VCL NAL units
                if isHEVC {
                    frameCount += 1
                    if !hasLoggedFirstFrame {
                        print("🎬 VideoDecoder: ✅ Decoding first HEVC frame!")
                        hasLoggedFirstFrame = true
                    }
                    decodeVideoFrame(nalUnit)
                }
                return
                
            default:
                break
            }
        }
        
        // If we have a session, try to decode anyway
        if decompressionSession != nil && h264NalType != 0 {
            frameCount += 1
            decodeVideoFrame(nalUnit)
        } else if frameCount < 10 {
            print("🎬 VideoDecoder: Unknown NAL type \(h264NalType), size=\(nalUnit.count)")
        }
    }
    
    private func tryCreateSession() {
        guard sps != nil, pps != nil else { return }
        guard formatDescription == nil else { return } // Already created
        
        if isHEVC {
            createHEVCSession()
        } else {
            createH264Session()
        }
    }
    
    private func createH264Session() {
        guard let spsData = sps, let ppsData = pps else { return }
        
        logger.info("🎬 Creating H.264 session with SPS(\(spsData.count) bytes) PPS(\(ppsData.count) bytes)")
        
        var formatDesc: CMFormatDescription?
        
        // Convert Data to arrays to ensure stable pointers
        let spsArray = [UInt8](spsData)
        let ppsArray = [UInt8](ppsData)
        
        spsArray.withUnsafeBufferPointer { spsBuffer in
            ppsArray.withUnsafeBufferPointer { ppsBuffer in
                var parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBuffer.baseAddress!,
                    ppsBuffer.baseAddress!
                ]
                var parameterSetSizes: [Int] = [spsArray.count, ppsArray.count]
                
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                
                if status != noErr {
                    print("🎬 VideoDecoder: ❌ Failed to create H.264 format description: \(status)")
                } else {
                    print("🎬 VideoDecoder: ✅ Created H.264 format description")
                }
            }
        }
        
        guard let fd = formatDesc else { return }
        formatDescription = fd
        
        createDecompressionSession(with: fd)
    }
    
    private func createHEVCSession() {
        guard let sps = sps, let pps = pps else { return }
        
        var formatDesc: CMFormatDescription?
        
        if let vps = vps {
            // With VPS
            let vpsArray = [UInt8](vps)
            let spsArray = [UInt8](sps)
            let ppsArray = [UInt8](pps)
            
            vpsArray.withUnsafeBufferPointer { vpsBuffer in
                spsArray.withUnsafeBufferPointer { spsBuffer in
                    ppsArray.withUnsafeBufferPointer { ppsBuffer in
                        var pointers: [UnsafePointer<UInt8>] = [
                            vpsBuffer.baseAddress!,
                            spsBuffer.baseAddress!,
                            ppsBuffer.baseAddress!
                        ]
                        var sizes: [Int] = [vpsArray.count, spsArray.count, ppsArray.count]
                        
                        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: &pointers,
                            parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &formatDesc
                        )
                        
                        if status != noErr {
                            print("🎬 VideoDecoder: ❌ Failed to create HEVC format description: \(status)")
                        } else {
                            print("🎬 VideoDecoder: ✅ Created HEVC format description")
                        }
                    }
                }
            }
        } else {
            // Without VPS (some streams don't have it)
            let spsArray = [UInt8](sps)
            let ppsArray = [UInt8](pps)
            
            spsArray.withUnsafeBufferPointer { spsBuffer in
                ppsArray.withUnsafeBufferPointer { ppsBuffer in
                    var pointers: [UnsafePointer<UInt8>] = [
                        spsBuffer.baseAddress!,
                        ppsBuffer.baseAddress!
                    ]
                    var sizes: [Int] = [spsArray.count, ppsArray.count]
                    
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &formatDesc
                    )
                    
                    if status != noErr {
                        print("🎬 VideoDecoder: ❌ Failed to create HEVC format description (no VPS): \(status)")
                    } else {
                        print("🎬 VideoDecoder: ✅ Created HEVC format description (no VPS)")
                    }
                }
            }
        }
        
        guard let fd = formatDesc else { return }
        formatDescription = fd
        
        createDecompressionSession(with: fd)
    }
    
    private func createDecompressionSession(with formatDescription: CMFormatDescription) {
        logger.info("🎬 Creating decompression session...")
        
        // Destination image buffer attributes
        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        
        if status == noErr {
            decompressionSession = session
            print("🎬 VideoDecoder: ✅ Created decompression session successfully (HEVC: \(isHEVC))")
        } else {
            print("🎬 VideoDecoder: ❌ Failed to create decompression session: \(status)")
        }
    }
    
    private func decodeVideoFrame(_ nalUnit: Data) {
        guard let session = decompressionSession, let formatDesc = formatDescription else {
            // Session not ready yet - might be waiting for SPS/PPS
            return
        }
        
        // Convert Annex B NAL to AVCC format (length-prefixed)
        // CRITICAL: We must keep this data alive until the decode completes!
        let length = UInt32(nalUnit.count).bigEndian
        var lengthPrefixed = Data(capacity: 4 + nalUnit.count)
        withUnsafeBytes(of: length) { lengthPrefixed.append(contentsOf: $0) }
        lengthPrefixed.append(nalUnit)
        
        // Make a copy that we can safely reference
        let frameData = lengthPrefixed as NSData
        
        // Create block buffer that properly manages memory
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: frameData.bytes),
            blockLength: frameData.length,
            blockAllocator: kCFAllocatorNull,  // We manage the memory via NSData
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            print("🎬 VideoDecoder: ❌ Failed to create block buffer: \(status)")
            return
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000),
            decodeTimeStamp: CMTime.invalid
        )
        
        let sampleSizes = [frameData.length]
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: sampleSizes,
            sampleBufferOut: &sampleBuffer
        )
        
        guard createStatus == noErr, let sample = sampleBuffer else {
            print("🎬 VideoDecoder: ❌ Failed to create sample buffer: \(createStatus)")
            return
        }
        
        // Decode - use synchronous mode so frameData stays alive
        var flags: VTDecodeFrameFlags = []  // Synchronous
        var outputFlags = VTDecodeInfoFlags()
        
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &outputFlags
        )
        
        if decodeStatus != noErr && frameCount < 10 {
            print("🎬 VideoDecoder: ❌ Decode error: \(decodeStatus)")
        }
    }
    
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        sps = nil
        pps = nil
        vps = nil
    }
    
    private static var decodedFrameCount = 0
    
    private let decompressionCallback: VTDecompressionOutputCallback = { (decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
        guard status == noErr, let buffer = imageBuffer else {
            if status != noErr {
                print("🎬 VideoDecoder: ❌ Decompression callback error: \(status)")
            }
            return
        }
        
        VideoDecoder.decodedFrameCount += 1
        if VideoDecoder.decodedFrameCount == 1 {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            print("🎬 VideoDecoder: ✅✅✅ FIRST DECODED FRAME! \(width)x\(height)")
        } else if VideoDecoder.decodedFrameCount % 60 == 0 {
            print("🎬 VideoDecoder: Decoded \(VideoDecoder.decodedFrameCount) frames")
        }
        
        let decoder = Unmanaged<VideoDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
        decoder.delegate?.videoDecoder(decoder, didDecode: buffer)
    }
}
