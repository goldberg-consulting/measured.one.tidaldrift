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
            .restoreAppsRequest, .qualityUpdate, .clipboardUpdate, .clipboardFetchRequest
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

    // MARK: - Modifier key direction

    func test_modifierKey_isPress_trueOnlyWhileBitPresent() {
        // A flagsChanged event carries no direction, so the press/release call
        // is made from the flags it reports. Releasing Cmd reports flags with
        // the Command bit cleared; reading that as a press latched the modifier
        // on the host and made every later keystroke behave as a shortcut.
        let leftCommand: UInt16 = 55

        XCTAssertEqual(ModifierKey.isPress(keyCode: leftCommand, flags: .maskCommand), true)
        XCTAssertEqual(ModifierKey.isPress(keyCode: leftCommand, flags: []), false)

        // Releasing Cmd while Shift stays held still reads as a Cmd release.
        XCTAssertEqual(ModifierKey.isPress(keyCode: leftCommand, flags: .maskShift), false)
    }

    func test_modifierKey_isPress_coversBothSidesOfKeyboard() {
        let pairs: [(UInt16, CGEventFlags)] = [
            (54, .maskCommand), (55, .maskCommand),
            (56, .maskShift), (60, .maskShift),
            (58, .maskAlternate), (61, .maskAlternate),
            (59, .maskControl), (62, .maskControl),
            (57, .maskAlphaShift), (63, .maskSecondaryFn)
        ]

        for (keyCode, flag) in pairs {
            XCTAssertEqual(
                ModifierKey.isPress(keyCode: keyCode, flags: flag), true,
                "Key code \(keyCode) should read as a press when its own bit is set"
            )
            XCTAssertEqual(
                ModifierKey.isPress(keyCode: keyCode, flags: []), false,
                "Key code \(keyCode) should read as a release when its bit is cleared"
            )
        }
    }

    func test_modifierKey_isPress_nilForNonModifiers() {
        // 'C' and 'V': the copy/paste keys must not be mistaken for modifiers,
        // or their flagsChanged handling would swallow real key events.
        XCTAssertNil(ModifierKey.isPress(keyCode: 8, flags: .maskCommand))
        XCTAssertNil(ModifierKey.isPress(keyCode: 9, flags: .maskCommand))
        XCTAssertFalse(ModifierKey.isModifier(8))
        XCTAssertTrue(ModifierKey.isModifier(55))
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
