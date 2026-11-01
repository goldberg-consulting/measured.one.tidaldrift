import XCTest
import Network
@testable import TidalDrift

final class NetworkTuningTests: XCTestCase {
    func testDefaultsLeaveExistingTransportUnchangedAndOldConfigsDecode() throws {
        XCTAssertFalse(NetworkTuning().enabled)
        XCTAssertFalse(NetworkTuning().diagnostics)
        let data = try JSONEncoder().encode(LocalCastConfiguration())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "networkTuning")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(LocalCastConfiguration.self, from: old).networkTuning)
    }

    func testSharedBudgetIncludesFrameBoundaryAndDoesNotCatchUpAfterStall() {
        var budget = MediaPacingBudget(settings: .init(rateMbps: 100, burstKB: 16))
        budget.sent(bytes: 16_000, at: 1)
        XCTAssertEqual(budget.delay(at: 1), 0.00128, accuracy: 0.000001)
        // A second frame gets the same deadline, not a fresh burst allowance.
        XCTAssertGreaterThan(budget.delay(at: 1.001), 0)
        budget.sent(bytes: 16_000, at: 10)
        XCTAssertEqual(budget.delay(at: 10), 0.00128, accuracy: 0.000001)
    }

    func testAdaptationIsOptionalAndRecoversWithinConfiguredBounds() {
        var fixed = MediaPacingBudget(settings: .init(adaptive: false))
        fixed.feedback(incompleteFrames: 10)
        XCTAssertEqual(fixed.rateMbps, 500)
        var adaptive = MediaPacingBudget(settings: .init())
        for _ in 0..<100 { adaptive.feedback(incompleteFrames: 1) }
        XCTAssertEqual(adaptive.rateMbps, 125)
        for _ in 0..<100 { adaptive.feedback(incompleteFrames: 0) }
        XCTAssertEqual(adaptive.rateMbps, 500)
        let invalid = NetworkTuning(rateMbps: -1, burstKB: Int.max).validated
        XCTAssertEqual(invalid.rateMbps, 25)
        XCTAssertEqual(invalid.burstKB, 64)
    }

    @MainActor
    func testHigherUDPProbeRatesStillStayBelowTCPHeadroom() {
        XCTAssertEqual(SpeedTestService.udpRate(forTCPMbps: 2500, limitMbps: 500), 500)
        XCTAssertEqual(SpeedTestService.udpRate(forTCPMbps: 300, limitMbps: 1000), 150)
        XCTAssertEqual(SpeedTestService.udpRate(forTCPMbps: 10_000, limitMbps: Int.max), 1000)
    }

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var packets: [UInt8] = []
        var times: [Double] = []
        func append(_ batch: [Data]) {
            lock.lock(); defer { lock.unlock() }
            packets += batch.map { $0[0] }
            times.append(ProcessInfo.processInfo.systemUptime)
        }
        func snapshot() -> ([UInt8], [Double]) {
            lock.lock(); defer { lock.unlock() }
            return (packets, times)
        }
    }

    private func readyConnection() async -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: 15999, using: .udp)
        let ready = expectation(description: "Local UDP connection ready")
        let once = AtomicFlag()
        connection.stateUpdateHandler = { state in
            if state == .ready, once.compareAndSwap(expected: false, desired: true) { ready.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "network-tuning-test"))
        await fulfillment(of: [ready], timeout: 3)
        return connection
    }

    func testFramesShareOneOrderedBurstScheduleAndStopCancelsPendingWork() async {
        let connection = await readyConnection()
        defer { connection.cancel() }
        let recorder = Recorder()
        let complete = expectation(description: "Two frames delivered")
        let scheduler = MediaSendScheduler(settings: .init(enabled: true, rateMbps: 25, burstKB: 4), send: { batch, _ in
            recorder.append(batch)
            if recorder.snapshot().0.count == 24 { complete.fulfill() }
        }, dropped: { XCTFail("Unexpected queue overflow") }, recover: {})
        scheduler.enqueue(Array(repeating: Data(repeating: 1, count: 1000), count: 12), on: connection)
        scheduler.enqueue(Array(repeating: Data(repeating: 2, count: 1000), count: 12), on: connection)
        await fulfillment(of: [complete], timeout: 3)
        let (packets, times) = recorder.snapshot()
        XCTAssertEqual(packets, Array(repeating: UInt8(1), count: 12) + Array(repeating: UInt8(2), count: 12))
        XCTAssertEqual(times.count, 6)
        // Five gaps of 4 KB at 25 Mbps. Allow minor clock/scheduler precision variation.
        XCTAssertGreaterThanOrEqual((times.last ?? 0) - (times.first ?? 0), 0.006)
        scheduler.enqueue(Array(repeating: Data(repeating: 3, count: 1000), count: 1000), on: connection)
        scheduler.stop()
        let stoppedCount = recorder.snapshot().0.count
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(recorder.snapshot().0.count, stoppedCount)
    }

    func testOverflowIsReportedSeparatelyAndBounded() async {
        let connection = await readyConnection()
        defer { connection.cancel() }
        let dropped = expectation(description: "Queue limit observed")
        let scheduler = MediaSendScheduler(settings: .init(enabled: true, rateMbps: 25), send: { _, _ in },
                                           dropped: { dropped.fulfill() }, recover: {})
        scheduler.enqueue(Array(repeating: Data(count: 1000), count: 8000), on: connection)
        scheduler.enqueue(Array(repeating: Data(count: 1000), count: 100), on: connection)
        await fulfillment(of: [dropped], timeout: 3)
        scheduler.stop()
    }
    func testTimeBudgetSkipsBacklogAndRequestsRecoveryAfterAcceptedFrame() async {
        let connection = await readyConnection()
        defer { connection.cancel() }
        let recorder = Recorder()
        let dropped = expectation(description: "Time budget limits backlog")
        let recovered = expectation(description: "Refresh follows accepted frame")
        let scheduler = MediaSendScheduler(settings: .init(enabled: true, rateMbps: 25, queueMilliseconds: 50),
                                           send: { batch, _ in recorder.append(batch) },
                                           dropped: { dropped.fulfill() }, recover: {
            XCTAssertEqual(recorder.snapshot().0.count, 200)
            recovered.fulfill()
        })
        let frame = Array(repeating: Data(repeating: 1, count: 1000), count: 200)
        scheduler.enqueue(frame, on: connection)
        scheduler.enqueue(frame, on: connection)
        await fulfillment(of: [dropped, recovered], timeout: 3)
        scheduler.stop()
    }

}
