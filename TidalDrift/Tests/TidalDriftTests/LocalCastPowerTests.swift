import XCTest
import Foundation
import IOKit.pwr_mgt
import Network
@testable import TidalDrift

final class LocalCastPowerTests: XCTestCase {
    func testFailedWakeDeclarationRetriesAfterBriefBackoff() {
        let host = HostSession(configuration: LocalCastConfiguration())
        let now = Date(timeIntervalSince1970: 1_000)
        var attempts = 0

        host.declareRemoteUserActivity(now: now) { _ in
            attempts += 1
            return kIOReturnNotReady
        }
        host.declareRemoteUserActivity(now: now.addingTimeInterval(0.1)) { _ in
            XCTFail("Failed wake requests must not retry on every input packet")
            return kIOReturnNotReady
        }
        host.declareRemoteUserActivity(now: now.addingTimeInterval(1)) { id in
            attempts += 1
            id = 42
            return kIOReturnSuccess
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(host.userActivityAssertionID, 42)
        XCTAssertEqual(host.lastUserActivityDeclaration, now.addingTimeInterval(1))
        // This ID belongs to the injected declaration, not to IOKit.
        host.userActivityAssertionID = 0
    }

    func testSuccessfulWakeDeclarationThrottlesAndReusesReturnedAssertion() {
        let host = HostSession(configuration: LocalCastConfiguration())
        let now = Date(timeIntervalSince1970: 1_000)
        var attempts = 0
        let declaration: (inout IOPMAssertionID) -> IOReturn = { id in
            XCTAssertEqual(id, attempts == 0 ? 0 : 42)
            attempts += 1
            id = 42
            return kIOReturnSuccess
        }

        host.declareRemoteUserActivity(now: now, declaration: declaration)
        host.declareRemoteUserActivity(now: now.addingTimeInterval(1), declaration: declaration)
        host.declareRemoteUserActivity(
            now: now.addingTimeInterval(HostSession.userActivityMinInterval),
            declaration: declaration
        )

        XCTAssertEqual(attempts, 2)
        host.userActivityAssertionID = 0
    }

    func testDisconnectReleasesPowerActivityWhenCaptureAlreadyFailed() async {
        let host = HostSession(configuration: LocalCastConfiguration())
        host.captureActive = false
        host.streamActivity = ProcessInfo.processInfo.beginActivity(options: [], reason: "LocalCast cleanup test")
        // Suppress the packet's real wake declaration, then verify disconnect
        // resets its throttle even when there is no active capture to stop.
        host.lastUserActivityDeclaration = .distantFuture
        let disconnect = LocalCastPacket(
            type: .disconnect,
            sequenceNumber: 0,
            timestamp: Date().timeIntervalSince1970,
            payload: Data()
        )

        host.udpTransport(
            host.transport,
            didReceivePacket: disconnect,
            wasAuthenticated: false,
            from: .hostPort(host: "127.0.0.1", port: 5904)
        )

        XCTAssertNil(host.streamActivity)
        XCTAssertEqual(host.lastUserActivityDeclaration, .distantPast)
        XCTAssertEqual(host.lastUserActivityAttempt, .distantPast)
        XCTAssertFalse(host.hasActiveClient)
        await host.captureTransitions.run {}
    }
}
