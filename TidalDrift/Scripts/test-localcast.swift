#!/usr/bin/env swift

// LocalCast Pipeline Test - Single Machine Loopback
// Usage: swift test-localcast.swift
//
// This tests the encoder → decoder pipeline without network transport

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit

// MARK: - Simple Test Classes

class TestEncoder {
    private var session: VTCompressionSession?
    var onEncodedFrame: ((Data, Bool) -> Void)?
    
    func setup(width: Int, height: Int) {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard status == noErr, let sampleBuffer = sampleBuffer else {
                    print("❌ Encoder error: \(status)")
                    return
                }
                
                let encoder = Unmanaged<TestEncoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                
                // Check for keyframe
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
                let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == false || attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
                
                // Get data
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                guard let pointer = pointer else { return }
                
                let avccData = Data(bytes: pointer, count: length)
                var packetData = Data()
                
                // For keyframes, prepend SPS/PPS
                if isKeyFrame {
                    if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                        var parameterSetCount = 0
                        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
                        
                        for i in 0..<parameterSetCount {
                            var ptr: UnsafePointer<UInt8>?
                            var size = 0
                            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                            if let ptr = ptr {
                                packetData.append(Data([0, 0, 0, 1])) // Start code
                                packetData.append(ptr, count: size)
                            }
                        }
                    }
                }
                
                // Convert AVCC to Annex B
                let bytes = [UInt8](avccData)
                var offset = 0
                while offset + 4 <= bytes.count {
                    let nalLength = Int(bytes[offset]) << 24 | Int(bytes[offset+1]) << 16 | Int(bytes[offset+2]) << 8 | Int(bytes[offset+3])
                    offset += 4
                    if nalLength > 0 && offset + nalLength <= bytes.count {
                        packetData.append(Data([0, 0, 0, 1]))
                        packetData.append(contentsOf: bytes[offset..<(offset + nalLength)])
                        offset += nalLength
                    } else {
                        break
                    }
                }
                
                encoder.onEncodedFrame?(packetData, isKeyFrame)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("❌ Failed to create encoder: \(status)")
            return
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        
        print("✅ Encoder ready: \(width)x\(height)")
    }
    
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: duration, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    }
}

class TestDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    var onDecodedFrame: ((CVImageBuffer) -> Void)?
    
    func decode(_ data: Data) {
        // Parse NAL units
        let nalUnits = parseNALUnits(from: data)
        
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F
            
            switch nalType {
            case 7: // SPS
                if nal.count < 500 {
                    sps = nal
                    print("📦 Decoder: SPS (\(nal.count) bytes)")
                    tryCreateSession()
                }
            case 8: // PPS
                if nal.count < 500 {
                    pps = nal
                    print("📦 Decoder: PPS (\(nal.count) bytes)")
                    tryCreateSession()
                }
            case 1, 5: // Slice
                decodeFrame(nal)
            default:
                break
            }
        }
    }
    
    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        let bytes = [UInt8](data)
        var startPositions: [Int] = []
        var i = 0
        
        while i < bytes.count - 3 {
            if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startPositions.append(i)
                i += 4
            } else if bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startPositions.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        
        for j in 0..<startPositions.count {
            let pos = startPositions[j]
            let startCodeLen = (bytes[pos+2] == 1) ? 3 : 4
            let nalStart = pos + startCodeLen
            let nalEnd = (j + 1 < startPositions.count) ? startPositions[j + 1] : bytes.count
            if nalStart < nalEnd {
                nalUnits.append(Data(bytes[nalStart..<nalEnd]))
            }
        }
        
        return nalUnits
    }
    
    private func tryCreateSession() {
        guard let sps = sps, let pps = pps, formatDescription == nil else { return }
        
        let spsArray = [UInt8](sps)
        let ppsArray = [UInt8](pps)
        
        var formatDesc: CMFormatDescription?
        spsArray.withUnsafeBufferPointer { spsBuffer in
            ppsArray.withUnsafeBufferPointer { ppsBuffer in
                var pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                var sizes = [spsArray.count, ppsArray.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status != noErr {
                    print("❌ Format description error: \(status)")
                }
            }
        }
        
        guard let fd = formatDesc else { return }
        formatDescription = fd
        
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (refCon, sourceRefCon, status, flags, imageBuffer, pts, duration) in
                guard status == noErr, let buffer = imageBuffer else {
                    print("❌ Decode callback error: \(status)")
                    return
                }
                let decoder = Unmanaged<TestDecoder>.fromOpaque(refCon!).takeUnretainedValue()
                decoder.onDecodedFrame?(buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        var sess: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &sess
        )
        
        if status == noErr {
            session = sess
            print("✅ Decoder session created!")
        } else {
            print("❌ Decoder session error: \(status)")
        }
    }
    
    private func decodeFrame(_ nalUnit: Data) {
        guard let session = session, let formatDesc = formatDescription else { return }
        
        // Convert to AVCC (length-prefixed)
        var lengthPrefixed = Data()
        let length = UInt32(nalUnit.count).bigEndian
        withUnsafeBytes(of: length) { lengthPrefixed.append(contentsOf: $0) }
        lengthPrefixed.append(nalUnit)
        
        let frameData = lengthPrefixed as NSData
        
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: frameData.bytes),
            blockLength: frameData.length,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frameData.length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard let buffer = blockBuffer else { return }
        
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(Date().timeIntervalSince1970 * 1000), timescale: 1000), decodeTimeStamp: .invalid)
        let sampleSizes = [frameData.length]
        
        CMSampleBufferCreateReady(
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
        
        guard let sample = sampleBuffer else { return }
        
        var flags: VTDecodeFrameFlags = []
        var outputFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, frameRefcon: nil, infoFlagsOut: &outputFlags)
    }
}

// MARK: - Main Test

print("🧪 LocalCast Pipeline Test - Single Machine Loopback")
print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))

let encoder = TestEncoder()
let decoder = TestDecoder()

var encodedFrames = 0
var decodedFrames = 0

encoder.onEncodedFrame = { data, isKeyFrame in
    encodedFrames += 1
    let frameType = isKeyFrame ? "🔑 KEYFRAME" : "📦 P-frame"
    print("\(frameType) encoded: \(data.count) bytes")
    
    // Feed directly to decoder (bypass network)
    decoder.decode(data)
}

decoder.onDecodedFrame = { imageBuffer in
    decodedFrames += 1
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    print("🖥️ Decoded frame #\(decodedFrames): \(width)x\(height)")
}

// Get screen content
Task {
    do {
        print("\n📺 Requesting screen capture permission...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first else {
            print("❌ No display found")
            exit(1)
        }
        
        print("✅ Found display: \(display.width)x\(display.height)")
        
        // Use a smaller test resolution
        let testWidth = 1280
        let testHeight = 720
        
        encoder.setup(width: testWidth, height: testHeight)
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = testWidth
        config.height = testHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        class StreamDelegate: NSObject, SCStreamOutput {
            let encoder: TestEncoder
            init(encoder: TestEncoder) { self.encoder = encoder }
            
            func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
                guard type == .screen, sampleBuffer.isValid else { return }
                encoder.encode(sampleBuffer)
            }
        }
        
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let delegate = StreamDelegate(encoder: encoder)
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: .main)
        
        print("\n🎬 Starting capture for 5 seconds...")
        try await stream.startCapture()
        
        try await Task.sleep(nanoseconds: 5_000_000_000)
        
        try await stream.stopCapture()
        
        print("\n" + "=".padding(toLength: 50, withPad: "=", startingAt: 0))
        print("📊 Results:")
        print("   Encoded frames: \(encodedFrames)")
        print("   Decoded frames: \(decodedFrames)")
        print("   Success rate: \(decodedFrames > 0 ? "✅ PASS" : "❌ FAIL")")
        
        exit(decodedFrames > 0 ? 0 : 1)
        
    } catch {
        print("❌ Error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()





