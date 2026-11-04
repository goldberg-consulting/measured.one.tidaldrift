import Foundation
import Network
import CryptoKit

/// One bounded TCP stream. The magic is outside v1 TidalDrop's legal header
/// lengths, so an older receiver closes before any names or payload are sent.
final class TidalTransferChannel: @unchecked Sendable {
    static let magic = Data("TTB1".utf8)
    enum Reply: UInt8 { case ready = 1, accepted, saved, unavailable, declined, failed }
    struct Failure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    struct Unconfirmed: LocalizedError {
        var errorDescription: String? { "The saved copy wasn’t confirmed. Check the receiving Mac before sending again." }
    }

    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }
    func cancel() { connection.cancel() }

    private func bounded<T: Sendable>(_ seconds: Int, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await body()
                } onCancel: { self.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Failure("The other Mac didn’t respond in time.")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }

    func connect() async throws {
        try await bounded(6) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = AtomicFlag()
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.compareAndSwap(expected: false, desired: true) { cont.resume() }
                    case .failed, .waiting, .cancelled:
                        if once.compareAndSwap(expected: false, desired: true) {
                            cont.resume(throwing: Failure("Couldn’t reach Tidal Transfer on that Mac."))
                        }
                    default: break
                    }
                }
                self.connection.start(queue: DispatchQueue(label: "com.tidaldrift.transfer.peer", qos: .userInitiated))
            }
        }
    }

    func write(_ data: Data) async throws {
        try await bounded(60) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
    }

    func read(_ count: Int, seconds: Int = 60) async throws -> Data {
        guard count > 0, count <= TidalTransferBatch.maxManifestBytes else { throw Failure("Invalid batch length.") }
        // A single deadline covers even a peer that only sends one byte at a time.
        return try await bounded(seconds) {
            var buffer = Data()
            while buffer.count < count {
                let needed = count - buffer.count
                let part: Data = try await withCheckedThrowingContinuation { cont in
                    self.connection.receive(minimumIncompleteLength: needed, maximumLength: needed) { data, _, _, error in
                        if let error { cont.resume(throwing: error) }
                        else if let data, !data.isEmpty { cont.resume(returning: data) }
                        else { cont.resume(throwing: Failure("The other Mac closed the connection.")) }
                    }
                }
                if part.count == count { return part }
                buffer.append(part)
            }
            return buffer
        }
    }

    func reply(_ value: Reply) async throws { try await write(Data([value.rawValue])) }

    func expect(_ expected: Reply, seconds: Int = 60) async throws {
        let message = try await read(1, seconds: seconds)
        switch message.first.flatMap(Reply.init(rawValue:)) {
        case expected: return
        case .unavailable: throw Failure("Open Tidal Transfer on the other Mac and enable receiving. It can accept one batch at a time.")
        case .declined: throw Failure("The other Mac didn’t accept the batch.")
        default: throw Failure("The other Mac couldn’t finish the transfer.")
        }
    }

    static func length(_ count: Int) -> Data {
        withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
    }

    func send(plan: TidalTransferBatch.Plan, status: @escaping @Sendable (String, Double?) async -> Void) async throws {
        try await write(Self.magic)
        do { try await expect(.ready, seconds: 8) }
        catch let error as Failure where error.text == "The other Mac closed the connection." {
            throw Failure("This Mac doesn’t support batch transfers yet. Update TidalDrift on the receiving Mac.")
        }
        try await write(Self.length(plan.manifest.count))
        try await write(plan.manifest)
        await status("Waiting for the other Mac to accept…", nil)
        try await expect(.accepted, seconds: 95)
        var digest = SHA256()
        digest.update(data: plan.manifest)
        var sent: Int64 = 0
        var lastUpdate = -Double.infinity
        try await TidalTransferBatch.send(plan, write: { chunk in
            digest.update(data: chunk)
            try await self.write(chunk)
            sent += Int64(chunk.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastUpdate >= 0.12 {
                lastUpdate = now
                await status("Sending…", Double(sent) / Double(max(1, plan.total)))
            }
        }, progress: { _ in })
        try Task.checkCancellation()
        await status("Waiting for the saved copy…", nil)
        try Task.checkCancellation()
        // Once END1 is attempted the receiver might publish the complete batch.
        do {
            try await write(Data("END1".utf8) + Data(digest.finalize()))
            try await expect(.saved, seconds: 600)
        } catch { throw Unconfirmed() }
    }

    /// Called after the listener has consumed the magic and reserved one receive slot.
    func receive(authorize: @escaping @Sendable (Int, Int64) async -> URL?,
                 progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try await reply(.ready)
        let size = try await read(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
        let manifest = try await read(size)
        let offer = try TidalTransferBatch.inspect(manifest)
        guard let folder = await authorize(offer.count, offer.total) else {
            try await reply(.declined)
            throw Failure("Batch not accepted.")
        }
        try Task.checkCancellation()
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < offer.total { throw Failure("There isn’t enough space in the receiving folder.") }

        var digest = SHA256()
        digest.update(data: manifest)
        try await reply(.accepted)
        let result = try await TidalTransferBatch.receive(manifest: manifest, into: folder, read: { needed in
            let next = try await self.read(needed)
            digest.update(data: next)
            return next
        }, progress: { progress($0, offer.total) }, verifyEnd: {
            let expected = Data("END1".utf8) + Data(digest.finalize())
            guard try await self.read(expected.count) == expected else { throw Failure("The batch didn’t pass its integrity check.") }
        })
        // Once published, the receiver owns a complete copy even if the sender
        // disconnects just before this acknowledgement reaches it.
        try? await reply(.saved)
        return result
    }
}
