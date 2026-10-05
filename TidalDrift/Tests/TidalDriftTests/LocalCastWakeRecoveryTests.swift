import XCTest
@testable import TidalDrift

final class LocalCastWakeRecoveryTests: XCTestCase {
    func test_candidateRefreshRetriesDNSWhileWakeOutlastsInitialLookup() throws {
        var refresh = ClientSession.CandidateRefreshState()
        XCTAssertNil(refresh.beginRefresh(elapsed: 7.9, hasHostResponse: false))
        let generation = try XCTUnwrap(refresh.beginRefresh(elapsed: 8, hasHostResponse: false))
        XCTAssertNil(refresh.beginRefresh(elapsed: 10, hasHostResponse: false))
        XCTAssertEqual(refresh.beginRefresh(elapsed: 16, hasHostResponse: false), generation)
        XCTAssertEqual(refresh.beginRefresh(elapsed: 40, hasHostResponse: false), generation)
        XCTAssertNil(refresh.beginRefresh(elapsed: 60, hasHostResponse: false))
    }

    func test_candidateRefreshCannotChangeAnAnsweredSessionOrExpiredAttempt() throws {
        var refresh = ClientSession.CandidateRefreshState()
        XCTAssertNil(refresh.beginRefresh(elapsed: 8, hasHostResponse: true))
        let generation = try XCTUnwrap(refresh.beginRefresh(elapsed: 8, hasHostResponse: false))
        XCTAssertTrue(refresh.acceptsResult(generation: generation, elapsed: 8.5, hasHostResponse: false))
        XCTAssertFalse(refresh.acceptsResult(generation: generation, elapsed: 8.5, hasHostResponse: true))
        XCTAssertFalse(refresh.acceptsResult(generation: generation, elapsed: 60, hasHostResponse: false))
    }

    func test_candidateRefreshDiscardsDNSResultAfterDisconnectOrNewAttempt() throws {
        var refresh = ClientSession.CandidateRefreshState()
        let oldGeneration = try XCTUnwrap(refresh.beginRefresh(elapsed: 8, hasHostResponse: false))
        refresh.invalidate()
        XCTAssertFalse(refresh.acceptsResult(generation: oldGeneration, elapsed: 9, hasHostResponse: false))
        let newGeneration = try XCTUnwrap(refresh.beginRefresh(elapsed: 8, hasHostResponse: false))
        XCTAssertNotEqual(newGeneration, oldGeneration)
        XCTAssertTrue(refresh.acceptsResult(generation: newGeneration, elapsed: 8.5, hasHostResponse: false))
    }

    func test_newAddressLearnedAfterWakeIsTriedBeforeStaleAdapters() {
        let existing = ["192.0.2.1", "192.0.2.2", "192.0.2.3"]
        XCTAssertEqual(ClientSession.mergingConnectionCandidates(
            existing: existing,
            refreshed: ["192.0.2.1", "192.0.2.4", "192.0.2.4"],
            currentAddress: "192.0.2.2"
        ), ["192.0.2.2", "192.0.2.4", "192.0.2.1", "192.0.2.3"])
        XCTAssertEqual(ClientSession.mergingConnectionCandidates(
            existing: existing, refreshed: ["192.0.2.3", "192.0.2.2"], currentAddress: "192.0.2.2"
        ), existing, "An unchanged DNS result must not restart the transport")
    }

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
