import XCTest
@testable import TidalDrift

final class LocalCastWakeRecoveryTests: XCTestCase {
    func test_connectionRetries_whenWakeOutlastsGracePeriod_expectsRetriesUntilDeadline() {
        // The host may not resume its listener until after 25 seconds. The
        // troubleshooting status must not end the wake/auth retry loop.
        for elapsed in [6.0, 24.0, 26.0, 40.0, 58.0] {
            let action = ClientSession.diagnosticAction(
                elapsed: elapsed,
                isConnected: false,
                hasHeartbeat: false,
                hasAuthError: false
            )
            guard case .retryConnection = action else {
                XCTFail("Wake and authentication retries stopped at \(elapsed) seconds")
                continue
            }
        }
        XCTAssertEqual(
            ClientSession.diagnosticAction(elapsed: 26, isConnected: false, hasHeartbeat: false, hasAuthError: false),
            .retryConnection(.firewallBlocked)
        )
    }

    func test_connectionRetries_whenAttemptEnds_expectsNoFurtherWakeOrAuthentication() {
        for elapsed in [60.0, 62.0, 120.0] {
            XCTAssertEqual(
                ClientSession.diagnosticAction(elapsed: elapsed, isConnected: false, hasHeartbeat: false, hasAuthError: false),
                .stop
            )
        }
        XCTAssertEqual(
            ClientSession.diagnosticAction(elapsed: 30, isConnected: true, hasHeartbeat: true, hasAuthError: false),
            .stop
        )
        XCTAssertEqual(
            ClientSession.diagnosticAction(elapsed: 30, isConnected: false, hasHeartbeat: false, hasAuthError: true),
            .stop,
            "A wrong password must not be overwritten by wake troubleshooting"
        )
    }

    func test_connectionRetries_whenHostRespondsWithoutVideo_expectsCaptureRecovery() {
        XCTAssertEqual(
            ClientSession.diagnosticAction(elapsed: 30, isConnected: false, hasHeartbeat: true, hasAuthError: false),
            .requestVideo,
            "An awake, responding host needs a keyframe request rather than more wake packets"
        )
        XCTAssertEqual(
            ClientSession.diagnosticAction(elapsed: 2, isConnected: false, hasHeartbeat: false, hasAuthError: false),
            .wait,
            "Allow the initial connection handshake to finish before retrying wake"
        )
    }
}
