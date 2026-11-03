import Foundation
import ScreenCaptureKit

/// Failure state for one viewer. Starting a stream successfully does not
/// clear recent failures: WindowServer may immediately stop the new stream.
struct CaptureFailurePolicy {
    private(set) var isPaused = false
    private var recentFailures: [TimeInterval] = []
    private var retryAfter: TimeInterval = 0

    func canStart(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        !isPaused && now >= retryAfter
    }

    static func isStopRequest(_ error: Error) -> Bool {
        let failure = error as NSError
        guard failure.domain == SCStreamError.errorDomain else { return false }
        if [SCStreamError.Code.userStopped, .userDeclined].contains(where: { $0.rawValue == failure.code }) { return true }
        if #available(macOS 15, *), failure.code == SCStreamError.Code.systemStoppedStream.rawValue { return true }
        return false
    }

    mutating func record(_ error: Error, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !isPaused else { return }
        if Self.isStopRequest(error) {
            isPaused = true
            return
        }
        recentFailures.removeAll { now - $0 >= 60 }
        recentFailures.append(now)
        isPaused = recentFailures.count >= 5
        retryAfter = now + 0.8
    }
}
