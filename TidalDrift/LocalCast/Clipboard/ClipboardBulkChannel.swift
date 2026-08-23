import Foundation
import Network
import CryptoKit
import OSLog

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
                var finished = false
                self.connection.stateUpdateHandler = { state in
                    guard !finished else { return }
                    switch state {
                    case .ready:
                        finished = true
                        cont.resume()
                    case .failed, .cancelled:
                        finished = true
                        cont.resume(throwing: ClipboardBulkError.connectionFailed)
                    default:
                        break
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
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
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
            buffer.append(piece)
        }
        return buffer
    }

    /// Race an operation against a wall-clock deadline.
    private func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
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
                    throw ClipboardBulkError.fileUnreadable(url.lastPathComponent)
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

        var hasher = SHA256()
        var expectedSequence: UInt32 = 0
        var receivedBytes: Int64 = 0

        if let stubs = manifest.files {
            guard manifest.kind == .files, let cacheDirectory else { throw ClipboardBulkError.manifestMismatch }
            let staging = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var finished: [(name: String, temp: URL)] = []
            var failed = true
            defer { if failed { try? FileManager.default.removeItem(at: staging) } }

            for stub in stubs {
                guard let safeName = ClipboardBulkFraming.sanitizeFileName(stub.name), stub.size >= 0 else {
                    throw ClipboardBulkError.manifestMismatch
                }
                let temp = staging.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: temp.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: temp) else {
                    throw ClipboardBulkError.fileUnreadable(safeName)
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
                    receivedBytes += Int64(chunk.content.count)
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

    private static func verifyTrailer(stream: ClipboardBulkStream, hasher: SHA256) async throws {
        guard let frame = try await stream.readFrame(), frame.type == .trailer,
              let trailer = try? JSONDecoder().decode(ClipboardBulkTrailer.self, from: frame.body) else {
            throw ClipboardBulkError.badFrame
        }
        var finalHasher = hasher
        let digest = Data(finalHasher.finalize())
        guard SessionCrypto.constantTimeEquals(digest, trailer.sha256) else {
            throw ClipboardBulkError.digestMismatch
        }
    }
}
