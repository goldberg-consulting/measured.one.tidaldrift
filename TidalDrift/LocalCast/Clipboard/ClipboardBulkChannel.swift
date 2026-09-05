import Foundation
import Network
import CryptoKit
import OSLog
import os

/// One framed, sealed TCP stream of the clipboard bulk protocol.
/// Wraps an NWConnection with async frame reads and writes, enforcing the
/// frame-length cap and the seal rules (keyed sessions reject plaintext).
final class ClipboardBulkStream: @unchecked Sendable {
    private let connection: NWConnection
    private let key: SymmetricKey?
    private let queue: DispatchQueue

    init(connection: NWConnection, key: SymmetricKey?, queue: DispatchQueue) {
        self.connection = connection
        self.key = key
        self.queue = queue
    }

    func cancel() {
        connection.cancel()
    }

    /// Wait until the connection is ready, or throw.
    func awaitReady(timeout: TimeInterval) async throws {
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // The handler can fire again after resolution (.cancelled
                // following .ready); the lock guards the one-shot resume and
                // satisfies strict concurrency for the captured state.
                let finished = OSAllocatedUnfairLock(initialState: false)
                self.connection.stateUpdateHandler = { state in
                    let isTerminal: Bool
                    switch state {
                    // .waiting means no viable path right now (host gone, port
                    // closed). For a LAN peer with a live session this will
                    // not self-heal within our window; fail fast.
                    case .ready, .failed, .cancelled, .waiting:
                        isTerminal = true
                    default:
                        isTerminal = false
                    }
                    guard isTerminal else { return }
                    let shouldResume = finished.withLock { alreadyFinished in
                        if alreadyFinished { return false }
                        alreadyFinished = true
                        return true
                    }
                    guard shouldResume else { return }
                    if case .ready = state {
                        cont.resume()
                    } else {
                        cont.resume(throwing: ClipboardBulkError.connectionFailed)
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    func writeFrame(type: ClipboardBulkFrameType, body: Data, timeout: TimeInterval = LocalCastConfiguration.clipboardIdleTimeout) async throws {
        guard let frame = ClipboardBulkFraming.encodeFrame(type: type, body: body, key: key) else {
            throw ClipboardBulkError.sealRejected
        }
        try await withDeadline(timeout) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.connection.send(content: frame, completion: .contentProcessed { error in
                    if error != nil {
                        cont.resume(throwing: ClipboardBulkError.connectionFailed)
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }

    /// Read one frame. Returns nil on orderly remote close before any bytes.
    func readFrame(timeout: TimeInterval = LocalCastConfiguration.clipboardIdleTimeout) async throws -> (type: ClipboardBulkFrameType, body: Data)? {
        guard let header = try await receiveExactly(4, timeout: timeout, eofAllowed: true) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length > 0, Int(length) <= ClipboardBulkFraming.maxFrameLength else {
            throw ClipboardBulkError.frameTooLarge
        }
        guard let sealed = try await receiveExactly(Int(length), timeout: timeout, eofAllowed: false) else {
            throw ClipboardBulkError.badFrame
        }
        guard let plaintext = ClipboardBulkFraming.unseal(sealed, key: key) else {
            throw ClipboardBulkError.sealRejected
        }
        guard let frame = ClipboardBulkFraming.decodeFrame(plaintext) else {
            throw ClipboardBulkError.badFrame
        }
        return frame
    }

    /// Read exactly `count` bytes. `eofAllowed` permits a clean close before
    /// the first byte (returns nil); a close mid-read always throws.
    private func receiveExactly(_ count: Int, timeout: TimeInterval, eofAllowed: Bool) async throws -> Data? {
        var buffer = Data()
        var consecutiveEmptyReads = 0
        while buffer.count < count {
            let remaining = count - buffer.count
            let piece = try await withDeadline(timeout) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                    self.connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            cont.resume(returning: data)
                        } else if isComplete {
                            cont.resume(returning: nil)
                        } else if error != nil {
                            cont.resume(throwing: ClipboardBulkError.connectionFailed)
                        } else {
                            cont.resume(returning: Data())
                        }
                    }
                }
            }
            guard let piece else {
                if buffer.isEmpty && eofAllowed { return nil }
                throw ClipboardBulkError.badFrame
            }
            // An empty non-terminal read should not occur with a minimum
            // length of 1; bound it so a misbehaving stack cannot spin us.
            if piece.isEmpty {
                consecutiveEmptyReads += 1
                guard consecutiveEmptyReads <= 32 else { throw ClipboardBulkError.badFrame }
                continue
            }
            consecutiveEmptyReads = 0
            buffer.append(piece)
        }
        return buffer
    }

    /// Race an operation against a wall-clock deadline. The NWConnection
    /// callbacks never observe Swift task cancellation on their own, so the
    /// cancellation handler tears the connection down; that errors the pending
    /// callback, resumes the continuation, and lets the child unwind. Without
    /// it, a silent peer parks the operation child forever and the group never
    /// returns, wedging the single-flight channel.
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await operation()
                } onCancel: {
                    self.connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ClipboardBulkError.timedOut
            }
            guard let result = try await group.next() else { throw ClipboardBulkError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Content streaming

enum ClipboardBulkTransfer {
    /// Stream `content` as chunk frames followed by a trailer. Chunks never
    /// span file boundaries, so the receiver can attribute every byte to the
    /// current manifest entry.
    static func send(_ content: ClipboardBulkContent, over stream: ClipboardBulkStream) async throws {
        var hasher = SHA256()
        var sequence: UInt32 = 0

        func sendSlice(_ slice: Data) async throws {
            hasher.update(data: slice)
            let body = ClipboardBulkFraming.encodeChunkBody(sequence: sequence, content: slice)
            sequence &+= 1
            try await stream.writeFrame(type: .chunk, body: body)
        }

        switch content {
        case .data(_, let data):
            var offset = 0
            while offset < data.count {
                let end = min(offset + ClipboardBulkFraming.chunkSize, data.count)
                try await sendSlice(data.subdata(in: offset..<end))
                offset = end
            }
        case .files(let urls):
            for url in urls {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    throw ClipboardBulkError.fileUnreadable
                }
                defer { try? handle.close() }
                while let slice = try handle.read(upToCount: ClipboardBulkFraming.chunkSize), !slice.isEmpty {
                    try await sendSlice(slice)
                }
            }
        }

        let trailer = ClipboardBulkTrailer(sha256: Data(hasher.finalize()))
        try await stream.writeFrame(type: .trailer, body: try JSONEncoder().encode(trailer))
    }

    /// Receive chunk frames per `manifest` until the trailer, verifying the
    /// monotonic sequence, byte accounting, and content digest. Files stream
    /// to temporary siblings and move into `cacheDirectory` atomically only
    /// after the digest verifies; a failed transfer leaves nothing behind.
    static func receive(
        manifest: ClipboardBulkManifest,
        over stream: ClipboardBulkStream,
        cacheDirectory: URL?
    ) async throws -> ClipboardBulkReceived {
        guard manifest.totalBytes >= 0,
              manifest.totalBytes <= LocalCastConfiguration.clipboardMaxTransferBytes,
              (manifest.files?.count ?? 0) <= LocalCastConfiguration.clipboardMaxFiles else {
            throw ClipboardBulkError.limitExceeded
        }

        if let stubs = manifest.files {
            guard manifest.kind == .files, let cacheDirectory else { throw ClipboardBulkError.manifestMismatch }
            return try await receiveFiles(stubs: stubs, manifest: manifest, over: stream, cacheDirectory: cacheDirectory)
        }

        var hasher = SHA256()
        var expectedSequence: UInt32 = 0
        var receivedBytes: Int64 = 0
        var data = Data()
        while receivedBytes < manifest.totalBytes {
            guard let frame = try await stream.readFrame(), frame.type == .chunk,
                  let chunk = ClipboardBulkFraming.decodeChunkBody(frame.body),
                  chunk.sequence == expectedSequence,
                  receivedBytes + Int64(chunk.content.count) <= manifest.totalBytes else {
                throw ClipboardBulkError.badFrame
            }
            expectedSequence &+= 1
            hasher.update(data: chunk.content)
            data.append(chunk.content)
            receivedBytes += Int64(chunk.content.count)
        }

        try await verifyTrailer(stream: stream, hasher: hasher)
        return .data(kind: manifest.kind, data: data)
    }

    /// Sum of the per-file sizes a peer declared, or nil if any size is
    /// negative, over the transfer cap, or the sum overflows. Each size is
    /// range-checked before it is added: the sizes are peer-controlled Int64s,
    /// and summing first with a trapping `+` let two stubs (Int64.max, 1)
    /// crash the receiver.
    static func declaredTotal(of stubs: [ClipboardFileStub]) -> Int64? {
        var total: Int64 = 0
        for stub in stubs {
            guard stub.size >= 0, stub.size <= LocalCastConfiguration.clipboardMaxTransferBytes else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(stub.size)
            guard !overflow, sum <= LocalCastConfiguration.clipboardMaxTransferBytes else { return nil }
            total = sum
        }
        return total
    }

    /// Files branch of `receive`. Per-file sizes come from the peer's
    /// manifest, so they are validated against the declared total, which was
    /// itself validated against the transfer cap; without this a manifest
    /// declaring a tiny total with huge per-file sizes streams unbounded
    /// bytes to disk.
    private static func receiveFiles(
        stubs: [ClipboardFileStub],
        manifest: ClipboardBulkManifest,
        over stream: ClipboardBulkStream,
        cacheDirectory: URL
    ) async throws -> ClipboardBulkReceived {
        guard let declaredTotal = Self.declaredTotal(of: stubs),
              declaredTotal == manifest.totalBytes,
              declaredTotal <= LocalCastConfiguration.clipboardMaxTransferBytes else {
            throw ClipboardBulkError.limitExceeded
        }

        var hasher = SHA256()
        var expectedSequence: UInt32 = 0

        let staging = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var finished: [(name: String, temp: URL)] = []
        var failed = true
        defer { if failed { try? FileManager.default.removeItem(at: staging) } }

        for stub in stubs {
            guard let safeName = ClipboardBulkFraming.sanitizeFileName(stub.name) else {
                throw ClipboardBulkError.manifestMismatch
            }
            let temp = staging.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: temp) else {
                throw ClipboardBulkError.fileUnreadable
            }
            var remaining = stub.size
            while remaining > 0 {
                guard let frame = try await stream.readFrame(), frame.type == .chunk,
                      let chunk = ClipboardBulkFraming.decodeChunkBody(frame.body),
                      chunk.sequence == expectedSequence,
                      Int64(chunk.content.count) <= remaining else {
                    try? handle.close()
                    throw ClipboardBulkError.badFrame
                }
                expectedSequence &+= 1
                hasher.update(data: chunk.content)
                try handle.write(contentsOf: chunk.content)
                remaining -= Int64(chunk.content.count)
            }
            try handle.close()
            finished.append((safeName, temp))
        }

        try await verifyTrailer(stream: stream, hasher: hasher)

        var urls: [URL] = []
        for entry in finished {
            let destination = ClipboardBulkFraming.collisionFreeURL(for: entry.name, in: staging)
            try FileManager.default.moveItem(at: entry.temp, to: destination)
            urls.append(destination)
        }
        failed = false
        return .files(urls)
    }

    private static func verifyTrailer(stream: ClipboardBulkStream, hasher: SHA256) async throws {
        guard let frame = try await stream.readFrame(), frame.type == .trailer,
              let trailer = try? JSONDecoder().decode(ClipboardBulkTrailer.self, from: frame.body) else {
            throw ClipboardBulkError.badFrame
        }
        let digest = Data(hasher.finalize())
        guard SessionCrypto.constantTimeEquals(digest, trailer.sha256) else {
            throw ClipboardBulkError.digestMismatch
        }
    }
}
