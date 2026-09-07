import Foundation

/// Delivers one callback result, including cancellation before the waiter starts.
actor AsyncCallbackResult<Value: Sendable> {
    private enum State {
        case pending
        case waiting(CheckedContinuation<Value?, Never>)
        case finished(Value?)
    }

    private var state: State = .pending

    func wait() async -> Value? {
        await withCheckedContinuation { continuation in
            switch state {
            case .pending:
                state = .waiting(continuation)
            case .finished(let value):
                continuation.resume(returning: value)
            case .waiting:
                preconditionFailure("A callback result supports one waiter")
            }
        }
    }

    func finish(_ value: Value?) {
        switch state {
        case .pending:
            state = .finished(value)
        case .waiting(let continuation):
            state = .finished(value)
            continuation.resume(returning: value)
        case .finished:
            break
        }
    }
}
