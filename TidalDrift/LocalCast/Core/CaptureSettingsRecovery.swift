import Foundation

/// Retains the previous settings until a replacement capture actually encodes.
final class CaptureSettingsRecovery {
    struct Snapshot {
        let configuration: LocalCastConfiguration
        let parameters: StreamingParameters?
    }

    private let lock = NSLock()
    private var previous: Snapshot?
    private var replacementStarted = false

    func remember(configuration: LocalCastConfiguration, parameters: StreamingParameters?) {
        lock.lock()
        defer { lock.unlock() }
        if previous == nil { previous = Snapshot(configuration: configuration, parameters: parameters) }
        replacementStarted = false
    }

    func captureStarted() {
        lock.lock()
        replacementStarted = true
        lock.unlock()
    }

    func encodedFrame() {
        lock.lock()
        if replacementStarted { previous = nil }
        lock.unlock()
    }

    /// A failed replacement can roll back once, without an endless retry loop.
    func takeFallback() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        let result = previous
        previous = nil
        replacementStarted = false
        return result
    }
}
