import Foundation
import VideoToolbox
import OSLog
import CoreMedia
import QuartzCore

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecode imageBuffer: CVImageBuffer)
}

/// Decodes complete access units with mandatory hardware acceleration.
/// Session operations are serialized with teardown; output callbacks do not take
/// the session lock because VideoToolbox may invoke them on another thread.
final class VideoDecoder {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "VideoDecoder")
    weak var delegate: VideoDecoderDelegate?
    /// Called on the decode worker. The owner must move UI updates to MainActor.
    var onError: ((String) -> Void)?

    private let sessionLock = NSRecursiveLock()
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [Int: Data] = [:]
    private var codec: LocalCastConfiguration.Codec = .h264
    private var hardwareAccelerated = false
    private var lastError: String?
    private var needsKeyFrame = true

    var codecName: String {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return codec == .hevc ? "HEVC" : "H.264"
    }

    var isHardwareAccelerated: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return hardwareAccelerated
    }

    deinit {
        if let session = decompressionSession { VTDecompressionSessionInvalidate(session) }
    }

    func decode(_ data: Data) {
        guard let accessUnit = VideoAccessUnit(data: data) else { return }
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if let incomingCodec = accessUnit.codecHint, incomingCodec != codec {
            resetSession()
            parameterSets.removeAll()
            codec = incomingCodec
        }

        let parameterTypes = codec == .hevc ? [32, 33, 34] : [7, 8]
        var nextSets = parameterSets
        for nal in accessUnit.nalUnits {
            let type = codec == .hevc ? Int((nal[0] >> 1) & 0x3F) : Int(nal[0] & 0x1F)
            if parameterTypes.contains(type) {
                guard nal.count <= 65_536 else { return }
                nextSets[type] = nal
            }
        }
        // Rebuild for VPS and PPS changes too, after collecting the entire
        // packet, so new SPS never gets paired with a previous picture's PPS.
        if nextSets != parameterSets {
            resetSession()
            parameterSets = nextSets
        }
        if needsKeyFrame, !accessUnit.isRandomAccess(codec: codec) { return }
        if decompressionSession == nil {
            guard parameterTypes.allSatisfy({ parameterSets[$0] != nil }) else { return }
            guard createSession(parameterTypes: parameterTypes) else { return }
        }
        let picture = accessUnit.pictureNALUnits(codec: codec)
        guard !picture.isEmpty else { return }
        decodePicture(VideoAccessUnit.lengthPrefixed(picture))
    }

    private func createSession(parameterTypes: [Int]) -> Bool {
        let sets = parameterTypes.compactMap { parameterSets[$0] }.map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map(\.length)
        var description: CMFormatDescription?
        let formatStatus = withExtendedLifetime(sets) {
            if codec == .hevc {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        }
        guard formatStatus == noErr, let description else {
            reportError("Invalid compressed video format (\(formatStatus)). Waiting for a fresh keyframe.")
            return false
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var createdSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback,
            decompressionSessionOut: &createdSession)
        guard status == noErr, let createdSession else {
            reportError("Hardware video decoding is unavailable (\(status)). Free video resources or try H.264 on the host.")
            return false
        }
        var hardware: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(createdSession,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware)
        guard hardwareStatus == noErr, hardware as? Bool == true else {
            VTDecompressionSessionInvalidate(createdSession)
            reportError("LocalCast could not verify hardware video decoding on this Mac.")
            return false
        }
        VTSessionSetProperty(createdSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = createdSession
        formatDescription = description
        hardwareAccelerated = true
        lastError = nil
        logger.info("Hardware \(self.codecName) decoder ready")
        return true
    }

    private func decodePicture(_ data: Data) {
        guard let session = decompressionSession, let formatDescription else { return }
        // Core Media owns the compressed bytes, including if VideoToolbox retains
        // the sample beyond DecodeFrame. No borrowed NSData storage escapes.
        var block: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard blockStatus == noErr, let block else { return }
        let copyStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == noErr else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = data.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { return }
        // The caller already has a serial decode worker. Synchronous hardware
        // submission bounds work in flight and preserves ordering with tile heals.
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
            flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status != noErr {
            resetSession()
            reportError("Video decoder needs a fresh keyframe (\(status)).")
        } else {
            needsKeyFrame = false
        }
    }

    func invalidate() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        resetSession()
        parameterSets.removeAll()
        codec = .h264
        lastError = nil
    }

    private func resetSession() {
        if let session = decompressionSession { VTDecompressionSessionInvalidate(session) }
        decompressionSession = nil
        formatDescription = nil
        hardwareAccelerated = false
        needsKeyFrame = true
    }

    private func reportError(_ message: String) {
        guard message != lastError else { return }
        lastError = message
        logger.error("\(message)")
        onError?(message)
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        refcon, _, status, _, imageBuffer, _, _ in
        guard let refcon else { return }
        let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr, let imageBuffer else {
            if status != noErr { decoder.onError?("Hardware video decode failed (\(status)). Waiting for recovery.") }
            return
        }
        decoder.delegate?.videoDecoder(decoder, didDecode: imageBuffer)
    }
}
