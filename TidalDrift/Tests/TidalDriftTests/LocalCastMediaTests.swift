import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
import MetalKit
@testable import TidalDrift

final class LocalCastMediaTests: XCTestCase {
    func test_accessUnit_whenMultipleSlices_keepsOnePicture() throws {
        let nals = [Data([0x67, 0x64, 0, 0x1F]), Data([0x68, 0xAA]),
                    Data([0x65, 0x11]), Data([0x65, 0x22])]
        let annexB = nals.reduce(into: Data()) { $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1) }
        let unit = try XCTUnwrap(VideoAccessUnit(data: annexB))
        XCTAssertEqual(unit.codecHint, .h264)
        XCTAssertEqual(unit.pictureNALUnits(codec: .h264), Array(nals.suffix(2)))
        let avcc = VideoAccessUnit.lengthPrefixed(unit.pictureNALUnits(codec: .h264))
        XCTAssertEqual(VideoAccessUnit(data: avcc)?.nalUnits, Array(nals.suffix(2)))
    }

    func test_accessUnit_whenTruncated_rejectsEntirePicture() {
        XCTAssertNil(VideoAccessUnit(data: Data([0, 0, 0, 5, 0x65, 0xAB])))
        XCTAssertNil(VideoAccessUnit(data: Data([0, 0, 0, 2, 0x65, 0xAB, 0])))
        XCTAssertNil(VideoAccessUnit(data: Data([0, 0, 0, 1])))
        XCTAssertNil(VideoAccessUnit(data: Data([0, 0, 1, 0, 0, 1])))
    }

    func test_accessUnit_whenThreeByteStartCodesAndSlice_parsesFromDataIndices() throws {
        let framed = Data([0xAA, 0xBB, 0, 0, 1, 0x40, 1, 0, 0, 1, 0x26, 1, 0xAB])
        let unit = try XCTUnwrap(VideoAccessUnit(data: framed[2...] ))
        XCTAssertEqual(unit.codecHint, .hevc)
        XCTAssertEqual(unit.pictureNALUnits(codec: .hevc), [Data([0x26, 1, 0xAB])])
    }

    func test_colorConversion_whenFullAndVideoRange_preservesBlackWhiteAndNeutral() {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let conversion = VideoColorConversion(pixelFormat: format)
            let black = conversion.rgb(y: videoRange ? 16.0 / 255 : 0, cb: 128.0 / 255, cr: 128.0 / 255)
            let white = conversion.rgb(y: videoRange ? 235.0 / 255 : 1, cb: 128.0 / 255, cr: 128.0 / 255)
            for channel in 0..<3 {
                XCTAssertEqual(black[channel], 0, accuracy: 0.00001)
                XCTAssertEqual(white[channel], 1, accuracy: 0.00001)
            }
        }
    }

    func test_colorConversion_whenMatrixChanges_usesAttachedCoefficients() {
        let bt601 = VideoColorConversion(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                        matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let bt709 = VideoColorConversion(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                        matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        XCTAssertEqual(bt601.red.z, 1.402, accuracy: 0.00001)
        XCTAssertEqual(bt709.red.z, 1.5748, accuracy: 0.00001)
        XCTAssertEqual(MemoryLayout<VideoColorConversion>.stride, 48)
    }

    @MainActor
    func test_metalRenderer_whenStaticFirstFrame_lowLatencyPresentsWithoutPrimingDelay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("A Metal device is unavailable in this test environment.")
        }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), device: device)
        view.colorPixelFormat = .bgra8Unorm
        let renderer = try XCTUnwrap(MetalRenderer(mtkView: view), "Metal shaders and IOSurface texture cache must initialize")
        renderer.latencyMode = .low
        let sample = try sampleBuffer(width: 320, height: 240)
        let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        renderer.update(with: image)
        XCTAssertEqual(renderer.currentBufferDepth, 1)
        renderer.draw(in: view)
        XCTAssertEqual(renderer.currentBufferDepth, 0, "The first static frame must not wait for a second frame")
        view.isPaused = true
    }

    func test_hardwareRoundTrip_whenH264ResolutionChanges_rebuildsDecoder() throws {
        try hardwareRoundTrip(configurations: [(.h264, 320, 240), (.h264, 640, 360)])
    }

    func test_hardwareRoundTrip_whenCodecChanges_recoversBothDirections() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else {
            if ProcessInfo.processInfo.environment["LOCALCAST_REQUIRE_HARDWARE_TESTS"] == "1" {
                XCTFail("Release hardware must support HEVC decoding")
                return
            }
            throw XCTSkip("This Mac does not support hardware HEVC decoding.")
        }
        try hardwareRoundTrip(configurations: [(.h264, 320, 240), (.hevc, 320, 240), (.h264, 320, 240)])
    }

    private func hardwareRoundTrip(configurations: [(LocalCastConfiguration.Codec, Int, Int)]) throws {
        let encoder = VideoEncoder()
        let decoder = VideoDecoder()
        let probe = HardwareRoundTripProbe(decoder: decoder)
        encoder.delegate = probe
        decoder.delegate = probe
        defer { encoder.invalidate(); decoder.invalidate() }
        for (codec, width, height) in configurations {
            guard encoder.setup(width: width, height: height, codec: codec, bitrateMbps: 5, fps: 60) else {
                if ProcessInfo.processInfo.environment["LOCALCAST_REQUIRE_HARDWARE_TESTS"] == "1" {
                    XCTFail("Required hardware encoder failed for \(codec.rawValue)")
                    return
                }
                throw XCTSkip("Hardware encoding unavailable for \(codec.rawValue) at \(width)x\(height).")
            }
            if codec == .hevc, encoder.codecName != "HEVC" {
                if ProcessInfo.processInfo.environment["LOCALCAST_REQUIRE_HARDWARE_TESTS"] == "1" {
                    XCTFail("Required HEVC encoder fell back to H.264")
                    return
                }
                throw XCTSkip("VideoToolbox could not allocate hardware HEVC encoding; H.264 fallback is active.")
            }
            XCTAssertTrue(encoder.isHardwareAccelerated)
            let ready = expectation(description: "Decoded \(codec.rawValue) \(width)x\(height)")
            probe.expect(ready, width: width, height: height)
            encoder.encode(try sampleBuffer(width: width, height: height))
            wait(for: [ready], timeout: 5)
            XCTAssertTrue(decoder.isHardwareAccelerated)
            XCTAssertEqual(decoder.codecName, codec == .hevc ? "HEVC" : "H.264")
        }
    }

    /// Opt-in release gate on a physical Mac; CI runners need not have video engines.
    func test_hardwarePerformance_4K() throws {
        guard ProcessInfo.processInfo.environment["LOCALCAST_REQUIRE_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Run with LOCALCAST_REQUIRE_HARDWARE_TESTS=1 on release hardware.")
        }
        for codec in [LocalCastConfiguration.Codec.h264, .hevc] {
            let encoder = VideoEncoder()
            let decoder = VideoDecoder()
            let probe = HardwarePerformanceProbe(decoder: decoder)
            encoder.delegate = probe
            decoder.delegate = probe
            defer { encoder.invalidate(); decoder.invalidate() }
            XCTAssertTrue(encoder.setup(width: 3840, height: 2160, codec: codec, bitrateMbps: 150, fps: 60))
            XCTAssertEqual(encoder.codecName, codec == .hevc ? "HEVC" : "H.264")
            // Match ScreenCaptureKit's default IOSurface NV12 path; BGRA adds
            // a host color conversion which normal full-frame streaming avoids.
            let sample = try sampleBuffer(width: 3840, height: 2160, nv12: true)
            var durations: [Double] = []
            for frame in 0..<65 {
                XCTAssertEqual(probe.slots.wait(timeout: .now() + 5), .success)
                let start = ProcessInfo.processInfo.systemUptime
                encoder.encode(sample)
                XCTAssertEqual(probe.completed.wait(timeout: .now() + 5), .success)
                if frame >= 5 { durations.append(ProcessInfo.processInfo.systemUptime - start) }
            }
            XCTAssertTrue(encoder.isHardwareAccelerated)
            XCTAssertTrue(decoder.isHardwareAccelerated)
            let mean = durations.reduce(0, +) / Double(durations.count)
            let p95 = durations.sorted()[Int(Double(durations.count - 1) * 0.95)]
            print("LOCALCAST 4K \(codec.rawValue): encode+decode mean \(mean * 1000) ms, p95 \(p95 * 1000) ms")
            // Latency sums two stages; throughput overlaps the host encoder and
            // client decode worker. Bound outstanding work to three pictures.
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0..<120 {
                XCTAssertEqual(probe.slots.wait(timeout: .now() + 5), .success)
                encoder.encode(sample)
            }
            for _ in 0..<120 { XCTAssertEqual(probe.completed.wait(timeout: .now() + 5), .success) }
            let fps = 120 / (ProcessInfo.processInfo.systemUptime - started)
            print("LOCALCAST 4K \(codec.rawValue): pipelined \(fps) fps")
            // Functional hardware verification is mandatory for release. A wall-
            // clock capacity threshold requires an otherwise idle, controlled
            // machine: this Mac may concurrently encode conferencing video.
            if let threshold = ProcessInfo.processInfo.environment["LOCALCAST_MIN_4K_FPS"],
               let minimumFPS = Double(threshold) {
                XCTAssertGreaterThanOrEqual(fps, minimumFPS, "Controlled hardware capacity gate")
            }
        }
    }

    private func sampleBuffer(width: Int, height: Int, nv12: Bool = false) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                         kCVPixelBufferMetalCompatibilityKey: true]
        let pixelFormat = nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_32BGRA
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if nv12 {
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) {
                    memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                           * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &description), noErr)
        let format = try XCTUnwrap(description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

private final class HardwarePerformanceProbe: VideoEncoderDelegate, VideoDecoderDelegate {
    let completed = DispatchSemaphore(value: 0)
    let slots = DispatchSemaphore(value: 3)
    private let decodeQueue = DispatchQueue(label: "localcast.hardware-test.decode")
    let decoder: VideoDecoder
    init(decoder: VideoDecoder) { self.decoder = decoder }
    func videoEncoder(_ encoder: VideoEncoder, didOutput packet: Data, isKeyFrame: Bool, timestamp: CMTime) {
        decodeQueue.async { self.decoder.decode(packet) }
    }
    func videoDecoder(_ decoder: VideoDecoder, didDecode imageBuffer: CVImageBuffer) {
        XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), 3840)
        XCTAssertEqual(CVPixelBufferGetHeight(imageBuffer), 2160)
        completed.signal()
        slots.signal()
    }
}

private final class HardwareRoundTripProbe: VideoEncoderDelegate, VideoDecoderDelegate {
    private let decoder: VideoDecoder
    private let lock = NSLock()
    private var next: (XCTestExpectation, Int, Int)?

    init(decoder: VideoDecoder) { self.decoder = decoder }

    func expect(_ expectation: XCTestExpectation, width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        next = (expectation, width, height)
    }

    func videoEncoder(_ encoder: VideoEncoder, didOutput packet: Data, isKeyFrame: Bool, timestamp: CMTime) {
        decoder.decode(packet)
    }

    func videoDecoder(_ decoder: VideoDecoder, didDecode imageBuffer: CVImageBuffer) {
        lock.lock()
        let pending = next
        next = nil
        lock.unlock()
        guard let (expectation, width, height) = pending else { return }
        XCTAssertEqual(CVPixelBufferGetWidth(imageBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(imageBuffer), height)
        expectation.fulfill()
    }
}
