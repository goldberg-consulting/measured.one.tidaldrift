import Foundation
import Network

/// Small, newline-framed control messages. TCP proves return-path reachability before
/// a peer can start iperf. One request is outstanding per connection; reads are bounded.
@MainActor
final class SpeedTestControl {
    struct Message: Codable {
        var version = 1
        var action: String
        var port: UInt16?
        var error: String?
    }

    let connection: NWConnection
    private var buffer = Data()
    private static let queue = DispatchQueue(label: "com.tidaldrift.speedtest.control")

    init(connection: NWConnection) { self.connection = connection }

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return parameters
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completed = AtomicFlag()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if completed.compareAndSwap(expected: false, desired: true) { continuation.resume() }
                    case .failed, .cancelled:
                        if completed.compareAndSwap(expected: false, desired: true) {
                            continuation.resume(throwing: IPerfRunner.Failure.message(
                                "Cannot reach the peer's network test. Update both Macs and check Local Network permission."))
                        }
                    default: break
                    }
                }
                connection.start(queue: Self.queue)
                let connection = connection
                Self.queue.asyncAfter(deadline: .now() + 4) {
                    if completed.compareAndSwap(expected: false, desired: true) {
                        connection.cancel()
                        continuation.resume(throwing: IPerfRunner.Failure.message("The peer's network test did not answer."))
                    }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    func send(_ message: Message) async throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Message {
        while !buffer.contains(10) {
            let data: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let completed = AtomicFlag()
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
                        guard completed.compareAndSwap(expected: false, desired: true) else { return }
                        if let error { continuation.resume(throwing: error) } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else { continuation.resume(throwing: IPerfRunner.Failure.message(
                            done ? "The peer ended the network test." : "Empty network-test response.")) }
                    }
                    let connection = connection
                    Self.queue.asyncAfter(deadline: .now() + 15) {
                        if completed.compareAndSwap(expected: false, desired: true) {
                            connection.cancel()
                            continuation.resume(throwing: IPerfRunner.Failure.message("The peer's network test timed out."))
                        }
                    }
                }
            } onCancel: { [connection] in connection.cancel() }
            buffer.append(data)
            guard buffer.count <= 4096 else { throw IPerfRunner.Failure.message("Oversized network-test response.") }
        }
        let newline = buffer.firstIndex(of: 10)!
        let message = try JSONDecoder().decode(Message.self, from: buffer.prefix(upTo: newline))
        buffer.removeSubrange(...newline)
        guard message.version == 1 else { throw IPerfRunner.Failure.message("Update both Macs to use this network test.") }
        if let error = message.error { throw IPerfRunner.Failure.message(error) }
        return message
    }

    func exchange(_ action: String) async throws -> Message {
        try await send(Message(action: action))
        return try await receive()
    }

    var localAddress: String? {
        guard case .hostPort(let host, _) = connection.currentPath?.localEndpoint else { return nil }
        return "\(host)"
    }

    var interfaceDescription: String {
        guard let path = connection.currentPath else { return "Network" }
        if path.usesInterfaceType(.wiredEthernet) { return "Ethernet" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        return "Network"
    }
}
