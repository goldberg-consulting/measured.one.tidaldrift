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

    // MARK: - Remote input wire format (#146)

    func test_remoteInput_deserialize_rejectsOutOfRangeMouseButton() {
        var packet = InputInjector.RemoteInput.mouseDown(button: 1, x: 0.5, y: 0.5).serialize()
        XCTAssertNotNil(InputInjector.RemoteInput.deserialize(packet))
        packet[1] = 3
        XCTAssertNil(InputInjector.RemoteInput.deserialize(packet), "button 3 has no CGMouseButton and must be rejected")
        packet[1] = 255
        XCTAssertNil(InputInjector.RemoteInput.deserialize(packet))
        var up = InputInjector.RemoteInput.mouseUp(button: 2, x: 0, y: 0).serialize()
        XCTAssertNotNil(InputInjector.RemoteInput.deserialize(up))
        up[1] = 7
        XCTAssertNil(InputInjector.RemoteInput.deserialize(up))
    }

    func test_remoteInput_deserialize_worksOnSlices() {
        let inner = InputInjector.RemoteInput.keyDown(keyCode: 0x24, modifiers: 0x100000).serialize()
        let framed = Data([0xAA, 0xBB]) + inner
        let slice = framed[2...]
        XCTAssertNotEqual(slice.startIndex, 0)
        guard case .keyDown(let code, let mods)? = InputInjector.RemoteInput.deserialize(slice) else {
            return XCTFail("slice did not deserialize")
        }
        XCTAssertEqual(code, 0x24)
        XCTAssertEqual(mods, 0x100000)
    }

    func test_remoteInput_coordinateClamp() {
        XCTAssertEqual(InputInjector.clampNormalized(0.25), 0.25)
        XCTAssertEqual(InputInjector.clampNormalized(-3), 0)
        XCTAssertEqual(InputInjector.clampNormalized(5), 1)
        XCTAssertEqual(InputInjector.clampNormalized(.nan), 0)
        XCTAssertEqual(InputInjector.clampNormalized(.infinity), 0)
        XCTAssertEqual(InputInjector.clampNormalized(-.infinity), 0)
    }

    // MARK: - Tile codec bounds (#147)

    func test_tileCodec_rejectsOversizedHeaderBeforeAllocating() {
        // 65535 x 65535 LZFSE tile with a 1-byte body: must return nil without
        // materializing the 17 GB output buffer.
        var header = Data()
        for v: UInt16 in [0, 0, 0xFFFF, 0xFFFF] {
            header.append(UInt8(v >> 8)); header.append(UInt8(v & 0xFF))
        }
        header.append(TileEncoding.lzfse.rawValue)
        header.append(0x00)
        XCTAssertNil(TileCodec.decode(header))
    }

    func test_tileCodec_roundTripAndCanvasBounds() {
        let w = 8, h = 4
        var pixels = Data(count: w * h * 4)
        for i in 0..<pixels.count { pixels[i] = UInt8(truncatingIfNeeded: i * 7) }
        let payload = TileCodec.encode(x: 10, y: 20, width: w, height: h, bgra: pixels)!
        let tile = TileCodec.decode(payload)
        XCTAssertEqual(tile?.bgra, pixels)
        XCTAssertNotNil(TileCodec.decode(payload, canvas: (width: 18, height: 24)))
        XCTAssertNil(TileCodec.decode(payload, canvas: (width: 17, height: 24)), "tile past the right edge")
        XCTAssertNil(TileCodec.decode(payload, canvas: (width: 18, height: 23)), "tile past the bottom edge")
    }

    // MARK: - Pairing handshake

    func test_authRequestPayload_roundTripsVersionAndStaysV1Compatible() {
        let nonce = SessionCrypto.generateNonce()

        // A bare 32-byte nonce is what pre-v2 clients send; it must parse as v1.
        let v1 = SessionCrypto.authRequestPayload(nonce: nonce, version: .v1)
        XCTAssertEqual(v1, nonce)
        XCTAssertEqual(SessionCrypto.parseAuthRequest(v1)?.version, .v1)
        XCTAssertEqual(SessionCrypto.parseAuthRequest(v1)?.nonce, nonce)

        let v2 = SessionCrypto.authRequestPayload(nonce: nonce, version: .v2)
        XCTAssertEqual(v2.count, nonce.count + 1)
        XCTAssertEqual(SessionCrypto.parseAuthRequest(v2)?.version, .v2)
        XCTAssertEqual(SessionCrypto.parseAuthRequest(v2)?.nonce, nonce)

        XCTAssertNil(SessionCrypto.parseAuthRequest(Data(repeating: 1, count: 31)))
        XCTAssertNil(SessionCrypto.parseAuthRequest(nonce + Data([0xFF])), "unknown version byte must be rejected")
    }

    func test_derivePairingKey_v2DiffersFromV1AndIsDeterministic() {
        let clientNonce = SessionCrypto.generateNonce()
        let hostNonce = SessionCrypto.generateNonce()

        let v1 = SessionCrypto.derivePairingKey(password: "correct horse", clientNonce: clientNonce, hostNonce: hostNonce, version: .v1)
        let v2a = SessionCrypto.derivePairingKey(password: "correct horse", clientNonce: clientNonce, hostNonce: hostNonce, version: .v2)
        let v2b = SessionCrypto.derivePairingKey(password: "correct horse", clientNonce: clientNonce, hostNonce: hostNonce, version: .v2)
        let v2wrong = SessionCrypto.derivePairingKey(password: "correct horsf", clientNonce: clientNonce, hostNonce: hostNonce, version: .v2)

        XCTAssertEqual(v2a.withUnsafeBytes { Data($0) }, v2b.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(v1.withUnsafeBytes { Data($0) }, v2a.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(v2a.withUnsafeBytes { Data($0) }, v2wrong.withUnsafeBytes { Data($0) })

        // The session key wrapped under a v2 pairing key opens with the same
        // derivation and with nothing else; this is the challenge step.
        let sessionKey = SessionCrypto.generateSessionKey().withUnsafeBytes { Data($0) }
        let wrapped = SessionCrypto.encrypt(sessionKey, using: v2a)
        XCTAssertNotNil(wrapped)
        XCTAssertEqual(SessionCrypto.decrypt(wrapped!, using: v2b), sessionKey)
        XCTAssertNil(SessionCrypto.decrypt(wrapped!, using: v1))
        XCTAssertNil(SessionCrypto.decrypt(wrapped!, using: v2wrong))
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
