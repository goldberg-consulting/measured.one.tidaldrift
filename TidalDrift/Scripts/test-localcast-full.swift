#!/usr/bin/env swift

// LocalCast Full Pipeline Test - Screen Capture → Encode → Decode → Metal Render
// Usage: swift test-localcast-full.swift
//
// This opens a window and displays the captured/encoded/decoded screen in real-time

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit
import MetalKit

// MARK: - Test Encoder

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
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                
                let encoder = Unmanaged<TestEncoder>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
                let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == false || attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
                
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                guard let pointer = pointer else { return }
                
                let avccData = Data(bytes: pointer, count: length)
                var packetData = Data()
                
                if isKeyFrame {
                    if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                        var parameterSetCount = 0
                        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
                        
                        for i in 0..<parameterSetCount {
                            var ptr: UnsafePointer<UInt8>?
                            var size = 0
                            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                            if let ptr = ptr {
                                packetData.append(Data([0, 0, 0, 1]))
                                packetData.append(ptr, count: size)
                            }
                        }
                    }
                }
                
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

// MARK: - Test Decoder

class TestDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    var onDecodedFrame: ((CVImageBuffer) -> Void)?
    
    func decode(_ data: Data) {
        let nalUnits = parseNALUnits(from: data)
        
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[0] & 0x1F
            
            switch nalType {
            case 7: // SPS
                if nal.count < 500 {
                    sps = nal
                    tryCreateSession()
                }
            case 8: // PPS
                if nal.count < 500 {
                    pps = nal
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
                guard status == noErr, let buffer = imageBuffer else { return }
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

// MARK: - Metal Renderer

class SimpleRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var currentTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private var vertices: MTLBuffer?
    private var texCoords: MTLBuffer?
    private var frameCount = 0
    
    init(mtkView: MTKView) {
        self.device = mtkView.device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
        
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                       constant float2 *vertices [[buffer(0)]],
                                       constant float2 *texCoords [[buffer(1)]]) {
            VertexOut out;
            out.position = float4(vertices[vertexID], 0.0, 1.0);
            out.texCoord = texCoords[vertexID];
            return out;
        }
        
        fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                        texture2d<float> texture [[texture(0)]]) {
            constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
            return texture.sample(textureSampler, in.texCoord);
        }
        """
        
        var library: MTLLibrary?
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            print("❌ Failed to compile shaders: \(error)")
        }
        
        if let library = library,
           let vertexFunc = library.makeFunction(name: "vertexShader"),
           let fragmentFunc = library.makeFunction(name: "fragmentShader") {
            
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunc
            pipelineDescriptor.fragmentFunction = fragmentFunc
            pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            
            do {
                self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
                print("✅ Pipeline state created")
            } catch {
                print("❌ Failed to create pipeline state: \(error)")
            }
        }
        
        let vertexData: [Float] = [
            -1.0, -1.0,
             1.0, -1.0,
            -1.0,  1.0,
             1.0,  1.0
        ]
        self.vertices = device.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.stride, options: [])
        
        let texCoordData: [Float] = [
            0.0, 1.0,
            1.0, 1.0,
            0.0, 0.0,
            1.0, 0.0
        ]
        self.texCoords = device.makeBuffer(bytes: texCoordData, length: texCoordData.count * MemoryLayout<Float>.stride, options: [])
        
        super.init()
        
        mtkView.device = device
        mtkView.delegate = self
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.framebufferOnly = false
    }
    
    func update(with imageBuffer: CVImageBuffer) {
        guard let cache = textureCache else { return }
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            imageBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        
        if status == kCVReturnSuccess, let texture = cvTexture {
            currentTexture = CVMetalTextureGetTexture(texture)
            frameCount += 1
            if frameCount == 1 {
                print("🖥️ First Metal frame: \(width)x\(height)")
            }
        }
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {
        guard let pipelineState = pipelineState,
              let texture = currentTexture,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertices, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(texCoords, offset: 0, index: 1)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Main Test

print("🧪 LocalCast Full Pipeline Test")
print("=" .padding(toLength: 50, withPad: "=", startingAt: 0))
print("This will open a window showing your screen via encode/decode")
print("")

// Create the app
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create window
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "LocalCast Pipeline Test"
window.center()

// Create Metal view
let mtkView = MTKView(frame: window.contentView!.bounds)
mtkView.autoresizingMask = [.width, .height]
mtkView.device = MTLCreateSystemDefaultDevice()
mtkView.colorPixelFormat = .bgra8Unorm
window.contentView?.addSubview(mtkView)

// Create renderer
let renderer = SimpleRenderer(mtkView: mtkView)

// Create encoder/decoder
let encoder = TestEncoder()
let decoder = TestDecoder()

var encodedFrames = 0
var decodedFrames = 0

encoder.onEncodedFrame = { data, isKeyFrame in
    encodedFrames += 1
    decoder.decode(data)
}

decoder.onDecodedFrame = { imageBuffer in
    decodedFrames += 1
    // Update renderer synchronously to ensure buffer isn't recycled
    renderer.update(with: imageBuffer)
}

// Start capture
Task {
    do {
        print("📺 Requesting screen capture permission...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first else {
            print("❌ No display found")
            exit(1)
        }
        
        print("✅ Found display: \(display.width)x\(display.height)")
        
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
        try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: DispatchQueue.global())
        
        print("🎬 Starting capture...")
        try await stream.startCapture()
        
        await MainActor.run {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        
        print("✅ Pipeline running! Close the window to exit.")
        print("   Stats will update every second...")
        
        // Stats timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            print("📊 Encoded: \(encodedFrames)/s  Decoded: \(decodedFrames)/s")
            encodedFrames = 0
            decodedFrames = 0
        }
        
    } catch {
        print("❌ Error: \(error)")
        exit(1)
    }
}

app.run()

