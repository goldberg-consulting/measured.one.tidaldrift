import XCTest
import CryptoKit
@testable import TidalDrift

final class LocalCastSettingsTests: XCTestCase {
    func test_qualityClampsWhenAlreadyAtBoundaryAndRejectsNonfiniteValues() {
        let tuning = StreamingTuning()
        tuning.quality = 1
        tuning.quality = 5
        XCTAssertEqual(tuning.quality, 1)
        tuning.quality = 0
        tuning.quality = -5
        XCTAssertEqual(tuning.quality, 0)
        for value in [Double.nan, .infinity, -.infinity] {
            tuning.quality = value
            XCTAssertTrue(tuning.quality.isFinite)
            XCTAssertTrue((15...120).contains(tuning.effectiveFps))
        }
    }

    func test_untrustedOverridesCannotOverflowEncoderParameters() {
        let tuning = StreamingTuning()
        tuning.apply(QualityUpdatePayload(
            quality: 0.8, fpsOverride: Int.max, bitrateOverride: Int.min,
            encoderQualityOverride: .nan, maxDimensionOverride: Int.max
        ))
        let parameters = StreamingParameters(tuning)
        XCTAssertEqual(parameters.fps, 120)
        XCTAssertEqual(parameters.bitrateMbps, 8)
        XCTAssertEqual(parameters.maxDimension, 8192)
        XCTAssertTrue(parameters.quality.isFinite)
        XCTAssertNoThrow(try JSONEncoder().encode(tuning.toPayload()))
    }

    func test_nativeAndAutomaticResolutionHaveDistinctContracts() {
        let tuning = StreamingTuning()
        var config = LocalCastConfiguration()
        let parameters = StreamingParameters(tuning)
        XCTAssertEqual(parameters.captureDimension(configuration: config), tuning.effectiveMaxDimension)
        config.maxDimensionOverride = -1
        XCTAssertEqual(parameters.captureDimension(configuration: config), Int.max)
        config.maxDimensionOverride = 1920
        XCTAssertEqual(parameters.captureDimension(configuration: config), 1920)
        tuning.maxDimensionOverride = 1280
        XCTAssertEqual(StreamingParameters(tuning).captureDimension(configuration: config), 1280)
    }

    func test_runtimeSettingsPreserveAuthenticationAndSession() async {
        var config = LocalCastConfiguration()
        let host = HostSession(configuration: config, password: "test-only-password")
        host.isRunning = true
        host.authState = .authenticated
        let key = host.sessionKey?.withUnsafeBytes { Data($0) }
        config.codec = .h264
        config.maxDimensionOverride = 1920
        config.forwardErrorCorrection = true
        config.requireAuthentication = false
        await host.updateRuntimeConfiguration(config)
        XCTAssertTrue(host.isRunning)
        XCTAssertEqual(host.configuration.codec, .h264)
        XCTAssertEqual(host.configuration.maxDimensionOverride, 1920)
        XCTAssertTrue(host.configuration.requireAuthentication)
        XCTAssertEqual(host.sessionKey?.withUnsafeBytes { Data($0) }, key)
        XCTAssertEqual(host.authState, .authenticated)
        XCTAssertFalse(host.isCaptureActive)
        await host.stop()
    }

    func test_authenticatedHostingWithoutPasswordFailsBeforeListening() async {
        let host = HostSession(configuration: LocalCastConfiguration())
        do {
            try await host.start()
            XCTFail("A required password must never silently disable authentication")
            await host.stop()
        } catch {
            XCTAssertFalse(host.isRunning)
        }
    }

    func test_stoppedHostCannotRestartCaptureFromLateCallback() {
        let host = HostSession(configuration: LocalCastConfiguration())
        host.beginCaptureForClient()
        XCTAssertFalse(host.isCaptureActive)
    }

    func test_missingWindowOrAppNeverWidensSharingScope() {
        let host = HostSession(configuration: LocalCastConfiguration())
        host.captureTarget = .window(42, title: "Private window")
        XCTAssertNil(host.windowLossFallback(afterStartFailure: false))
        XCTAssertNil(host.windowLossFallback(afterStartFailure: true))
        host.captureTarget = .app(-1, name: "Closed app")
        XCTAssertNil(host.windowLossFallback(afterStartFailure: false))
        XCTAssertNil(host.windowLossFallback(afterStartFailure: true))
    }

    func test_captureTransitionsContinueAfterFailure() async throws {
        let queue = CaptureTransitionQueue()
        do {
            try await queue.runThrowing { throw CancellationError() }
        } catch is CancellationError {
            // A cancelled transition must still release the next queued operation.
        }
        let value = try await queue.runThrowing { 42 }
        XCTAssertEqual(value, 42)
    }

    func test_failedReplacementKeepsFirstWorkingSettingsUntilEncodedFrame() {
        let recovery = CaptureSettingsRecovery()
        var configuration = LocalCastConfiguration()
        configuration.codec = .h264
        recovery.remember(configuration: configuration, parameters: nil)
        recovery.encodedFrame() // Output from the old capture cannot confirm the new one.
        configuration.codec = .hevc
        recovery.remember(configuration: configuration, parameters: nil)
        XCTAssertEqual(recovery.takeFallback()?.configuration.codec, .h264)
        XCTAssertNil(recovery.takeFallback(), "A rollback must not retry indefinitely")

        recovery.remember(configuration: configuration, parameters: nil)
        recovery.captureStarted()
        recovery.encodedFrame()
        XCTAssertNil(recovery.takeFallback(), "Working replacement retires the old settings")
    }
}
