import XCTest
@testable import TidalDrift

final class SystemPowerMonitorTests: XCTestCase {
    private func sample(_ continuous: TimeInterval, _ awake: TimeInterval) -> SystemResumeDetector.Sample {
        .init(continuousSeconds: continuous, awakeSeconds: awake)
    }

    func test_networkWakeWithoutNotificationRecoversOnceAfterShortSleep() {
        var detector = SystemResumeDetector()
        detector.resetBaseline(at: sample(100, 100))

        // Five seconds awake plus the observed seventeen-second lid sleep.
        XCTAssertTrue(detector.shouldRecover(at: sample(122, 105)))
        XCTAssertFalse(detector.shouldRecover(at: sample(127, 110)))
    }

    func test_delayedTimerWhileAwakeDoesNotRestartHosting() {
        var detector = SystemResumeDetector()
        detector.resetBaseline(at: sample(100, 80))

        XCTAssertFalse(detector.shouldRecover(at: sample(160, 140)))
        XCTAssertFalse(detector.shouldRecover(at: sample(165.01, 145)))
    }

    func test_fullWakeNotificationBeforeWatchdogCoalesces() {
        var detector = SystemResumeDetector()
        detector.resetBaseline(at: sample(100, 100))

        XCTAssertTrue(detector.shouldRecover(at: sample(122, 105), notified: true))
        XCTAssertFalse(detector.shouldRecover(at: sample(123, 106)))
        XCTAssertFalse(detector.shouldRecover(at: sample(124, 107), notified: true))
    }

    func test_fullWakeAfterWatchdogAndListenerRestartCoalesces() {
        var detector = SystemResumeDetector()
        detector.resetBaseline(at: sample(100, 100))

        XCTAssertTrue(detector.shouldRecover(at: sample(122, 105)))
        detector.resetBaseline(at: sample(123, 106))
        XCTAssertFalse(detector.shouldRecover(at: sample(124, 107), notified: true))
        XCTAssertFalse(detector.shouldRecover(at: sample(244, 227), notified: true),
                       "A later transition from dark to full wake does not repeat network recovery")
    }

    func test_secondSleepStillRecoversImmediately() {
        var detector = SystemResumeDetector()
        detector.resetBaseline(at: sample(100, 100))

        XCTAssertTrue(detector.shouldRecover(at: sample(122, 105)))
        XCTAssertTrue(detector.shouldRecover(at: sample(125, 106)))
    }

    func test_fullWakeNotificationWorksWithoutWatchdogBaseline() {
        var detector = SystemResumeDetector()
        XCTAssertTrue(detector.shouldRecover(at: sample(100, 80), notified: true))
        XCTAssertFalse(detector.shouldRecover(at: sample(105, 85)))
    }
}
