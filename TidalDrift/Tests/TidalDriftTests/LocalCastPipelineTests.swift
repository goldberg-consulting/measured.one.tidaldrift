import XCTest
@testable import TidalDrift
import Foundation
import Network

/// Deterministic pipeline tests that don't require screen recording permission.
/// The full loopback validation (capture → encode → transport → decode →
/// render) lives in the in-app Test Suite (`TidalDriftTestRunner`) and must
/// be run from Settings → Tests while the app is launched, because
/// `SCStream` cannot be created from a command-line test runner.
final class LocalCastPipelineTests: XCTestCase {

    // MARK: - Packet wire format

    func test_packetProtocol_roundTrip_allTypes() {
        let timestamp = Date().timeIntervalSince1970
        let payload = Data(repeating: 0xA5, count: 256)

        // Every packet type defined on the wire should survive a
        // serialize → deserialize round trip. The enum isn't CaseIterable
        // (intentional — raw values are the wire format and shouldn't drift
        // via synthesized conformances), so we list them explicitly.
        let allTypes: [LocalCastPacket.PacketType] = [
            .videoFrame, .inputEvent, .heartbeat, .stats, .keyframeRequest,
            .config, .appListRequest, .appListResponse, .streamAppRequest,
            .streamAppResponse, .windowResize, .authRequest, .authChallenge,
            .authComplete, .authSuccess, .focusAppRequest, .isolateAppRequest,
            .restoreAppsRequest, .qualityUpdate
        ]

        for type in allTypes {
            let original = LocalCastPacket(
                type: type,
                sequenceNumber: 42,
                timestamp: timestamp,
                payload: payload
            )

            let serialized = original.serialize()
            XCTAssertFalse(serialized.isEmpty, "Packet type \(type) produced empty serialization")

            guard let decoded = LocalCastPacket.deserialize(serialized) else {
                XCTFail("Packet type \(type) failed to deserialize")
                continue
            }

            XCTAssertEqual(decoded.type, original.type, "Type mismatch for \(type)")
            XCTAssertEqual(decoded.sequenceNumber, original.sequenceNumber, "Sequence mismatch for \(type)")
            XCTAssertEqual(decoded.payload, original.payload, "Payload mismatch for \(type)")
            XCTAssertEqual(decoded.timestamp, original.timestamp, accuracy: 0.001, "Timestamp mismatch for \(type)")
        }
    }

    // MARK: - Streaming tuning

    func test_streamingTuning_qualityClampedAndMonotonic() {
        let tuning = StreamingTuning()

        tuning.quality = -5.0
        XCTAssertGreaterThanOrEqual(tuning.quality, 0.0)

        tuning.quality = 5.0
        XCTAssertLessThanOrEqual(tuning.quality, 1.0)

        tuning.quality = 0.0
        let lowFps = tuning.effectiveFps
        let lowBitrate = tuning.effectiveBitrateMbps
        let lowDim = tuning.effectiveMaxDimension

        tuning.quality = 1.0
        XCTAssertGreaterThan(tuning.effectiveFps, lowFps)
        XCTAssertGreaterThan(tuning.effectiveBitrateMbps, lowBitrate)
        XCTAssertGreaterThan(tuning.effectiveMaxDimension, lowDim)
    }

    // Note: the real network round-trip for the Metal pipeline is covered
    // by the in-app Test Suite (`TidalDriftTestRunner`): "LocalCast Bonjour
    // Advertise+Browse" exercises discovery over dns-sd, and "Host Session
    // Start (loopback)" exercises ScreenCaptureKit + VideoToolbox + UDP
    // listener end-to-end. Those run inside the signed app, where Local
    // Network and Screen Recording entitlements are granted; running them
    // from a command-line XCTest runner is flaky because of entitlement
    // sandboxing and is intentionally not attempted here.
}
