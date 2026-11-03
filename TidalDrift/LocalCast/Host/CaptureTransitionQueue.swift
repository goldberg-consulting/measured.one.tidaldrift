import Foundation

/// Strictly-ordered executor for capture stop/start transitions. Five triggers
/// can rebuild capture concurrently (display reconfiguration, transport
/// capacity reduction, client stream request, runtime config toggle, SCStream
/// failure restart), and each is a stop-then-start with suspension points in
/// between. Two interleaved transitions could overwrite the live SCStream
/// while another start was in flight (leaking a stream that keeps delivering
/// frames) or leave `captureActive` true with no stream, a silent permanent
/// freeze. Operations run one at a time in enqueue order; an actor cannot
/// provide this because actor methods interleave at await points.
final class CaptureTransitionQueue {
    private var lastTask: Task<Void, Never>?
    private let lock = NSLock()

    @discardableResult
    func enqueue(_ op: @escaping () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = lastTask
            let task = Task {
                await previous?.value
                await op()
            }
            lastTask = task
            return task
        }
    }

    func run(_ op: @escaping () async -> Void) async {
        await enqueue(op).value
    }

    func runThrowing<T>(_ op: @escaping () async throws -> T) async throws -> T {
        let task = lock.withLock {
            let previous = lastTask
            let task = Task { () throws -> T in
                await previous?.value
                return try await op()
            }
            lastTask = Task { _ = try? await task.value }
            return task
        }
        return try await task.value
    }
}
