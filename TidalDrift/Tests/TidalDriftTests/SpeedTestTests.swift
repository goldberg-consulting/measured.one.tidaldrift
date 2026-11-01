import XCTest
@testable import TidalDrift

final class SpeedTestTests: XCTestCase {
    @MainActor
    func testReceiverStatisticsWinOverSenderStatistics() throws {
        let json = Data(#"{"end":{"sum_sent":{"seconds":5,"bits_per_second":100000000,"lost_percent":0},"sum_received":{"seconds":5,"bits_per_second":95000000,"packets":1000,"lost_percent":5,"jitter_ms":0.25}}}"#.utf8)
        let result = try IPerfRunner.parse(json, udp: true)
        XCTAssertEqual(result.mbps, 95)
        XCTAssertEqual(result.lossPercent, 5)
        XCTAssertEqual(result.jitterMs, 0.25)
    }

    @MainActor
    func testFailedAndIncompleteReportsNeverBecomePacketLoss() {
        for json in [#"{"error":"server is busy"}"#, #"{"end":{}}"#,
                     #"{"end":{"sum_received":{"seconds":5,"bits_per_second":0,"packets":0,"lost_percent":100,"jitter_ms":0}}}"#] {
            XCTAssertThrowsError(try IPerfRunner.parse(Data(json.utf8), udp: true))
        }
    }

    @MainActor
    func testTCPDoesNotInventLossOrJitter() throws {
        let json = Data(#"{"end":{"sum_received":{"seconds":5,"bits_per_second":9400000000}}}"#.utf8)
        let result = try IPerfRunner.parse(json, udp: false)
        XCTAssertEqual(result.mbps, 9400)
        XCTAssertNil(result.lossPercent)
        XCTAssertNil(result.jitterMs)
    }

    @MainActor
    func testArgumentsBindRouteAndPaceUDP() {
        let args = IPerfRunner.clientArguments(host: "192.168.1.2", localAddress: "192.168.1.1", port: 5555,
                                              reverse: true, udpRateMbps: 50)
        XCTAssertTrue(args.contains("-R"))
        XCTAssertTrue(args.contains("-u"))
        XCTAssertEqual(args[args.firstIndex(of: "-B")! + 1], "192.168.1.1")
        XCTAssertEqual(args[args.firstIndex(of: "-b")! + 1], "50000000")
        XCTAssertEqual(args[args.firstIndex(of: "-l")! + 1], "1400")
        XCTAssertEqual(SpeedTestService.udpRate(forTCPMbps: 9400), 100)
        XCTAssertEqual(SpeedTestService.udpRate(forTCPMbps: 40), 20)
    }

    /// Explicit opt-in: this exercises real TCP and UDP sockets for ~25 seconds.
    @MainActor
    func testBundledIPerfLoopbackAndCancellation() async throws {
        guard let path = ProcessInfo.processInfo.environment["TIDALDRIFT_TEST_IPERF"] else {
            throw XCTSkip("Set TIDALDRIFT_TEST_IPERF to the bundled helper to run the network integration check.")
        }
        let service = SpeedTestService(helperURL: URL(fileURLWithPath: path))
        service.startResponder()
        defer { service.stopResponder() }
        try await Task.sleep(for: .milliseconds(300))
        let result = try await service.runTest(toHost: "127.0.0.1", udpLimitMbps: 500)
        XCTAssertEqual(result.downloadUDPRateMbps, min(500, max(0.1, result.downloadMbps * 0.5)))
        XCTAssertGreaterThan(result.downloadMbps, 0)
        XCTAssertGreaterThan(result.uploadMbps, 0)
        XCTAssertTrue((0...100).contains(result.downloadLossPct))
        XCTAssertTrue((0...100).contains(result.uploadLossPct))
        XCTAssertTrue(result.route.contains("127.0.0.1"))
        print("iperf integration: TCP down \(result.downloadMbps), up \(result.uploadMbps) Mbps; UDP down \(result.downloadLossPct), up \(result.uploadLossPct)%")
        try await Task.sleep(for: .milliseconds(300))
        let task = Task { try await service.runTest(toHost: "127.0.0.1") }
        try await Task.sleep(for: .seconds(2))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled test must not return a result") } catch {}
    }
}
