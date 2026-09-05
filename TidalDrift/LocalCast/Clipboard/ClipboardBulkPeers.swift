import Foundation
import Network
import CryptoKit
import OSLog

/// Host side of the clipboard bulk channel: a TCP listener that serves fetches
/// of the host's outbound offer and accepts pushes the host has explicitly
/// requested. Runs only while a session with an authenticated, non-loopback
/// client is active.
final class ClipboardBulkHost: @unchecked Sendable {
    /// One armed inbound push: the token the host asked the client to use,
    /// what kind of content it may carry, where files stage, a timer covering
    /// "the client never connected", and the caller's completion.
    private struct ExpectedPush {
        let id: UUID
        let token: Data
        let kind: ClipboardContentKind
        let cacheDir: URL?
        let timeout: DispatchWorkItem
        let completion: (Result<ClipboardBulkReceived, Error>) -> Void
    }

    /// Upper bound on one bulk connection's lifetime. The channel is
    /// single-flight and the per-read idle timeout only bounds silence, so a
    /// peer trickling one byte every 29 s would otherwise hold the slot for
    /// the whole session. The transfer cap at a 1 MB/s floor plus handshake
    /// slack is generous for any real LAN.
    static let maxConnectionSeconds: TimeInterval =
        Double(LocalCastConfiguration.clipboardMaxTransferBytes) / 1_048_576 + 2 * LocalCastConfiguration.clipboardIdleTimeout

    /// Consecutive post-ready listener failures before the host stops
    /// rebinding for this session.
    private static let maxRebindFailures = 5

    private let logger = Logger(subsystem: "com.tidaldrift", category: "ClipboardBulkHost")
    private let queue = DispatchQueue(label: "com.tidaldrift.clipboard.bulk.host")
    private let lock = NSLock()

    private var listener: NWListener?
    private var active = false
    private var key: SymmetricKey?
    private var allowedHost: String?
    private var busy = false
    private var listening = false
    private var rebindFailures = 0

    private var outbound: (token: Data, manifest: ClipboardBulkManifest, content: ClipboardBulkContent)?
    private var expectedPush: ExpectedPush?

    /// Whether the listener is bound; false degrades the session to inline-only sync.
    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listening
    }

    private func setListening(_ value: Bool) {
        lock.lock()
        listening = value
        lock.unlock()
    }

    func start(key: SymmetricKey?, allowedHost: String?) {
        lock.lock()
        self.key = key
        self.allowedHost = allowedHost
        let alreadyActive = active
        active = true
        lock.unlock()
        guard !alreadyActive else { return }
        bind(attempt: 0)
    }

    func stop() {
        lock.lock()
        active = false
        listening = false
        let listener = self.listener
        self.listener = nil
        outbound = nil
        let push = expectedPush
        expectedPush = nil
        lock.unlock()
        listener?.cancel()
        if let push {
            push.timeout.cancel()
            push.completion(.failure(ClipboardBulkError.cancelled))
        }
    }

    /// Install the single outbound offer, superseding any previous one.
    func publishOffer(token: Data, manifest: ClipboardBulkManifest, content: ClipboardBulkContent) {
        lock.lock()
        outbound = (token, manifest, content)
        lock.unlock()
    }

    func clearOffer() {
        lock.lock()
        outbound = nil
        lock.unlock()
    }

    /// Arm the single expected-push slot. An unsolicited push (no armed slot,
    /// or a token mismatch) is rejected, so a peer can never write content the
    /// host did not just ask for.
    func expectPush(
        token: Data,
        kind: ClipboardContentKind,
        cacheDir: URL?,
        timeout: TimeInterval = LocalCastConfiguration.clipboardIdleTimeout,
        completion: @escaping (Result<ClipboardBulkReceived, Error>) -> Void
    ) {
        // The timer may fire after this slot was superseded or consumed; only
        // expire the slot it was armed for.
        let id = UUID()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.expectedPush?.id == id ? self.expectedPush : nil
            if expired != nil { self.expectedPush = nil }
            self.lock.unlock()
            expired?.completion(.failure(ClipboardBulkError.timedOut))
        }

        lock.lock()
        let superseded = expectedPush
        expectedPush = ExpectedPush(
            id: id, token: token, kind: kind, cacheDir: cacheDir,
            timeout: timeoutItem, completion: completion
        )
        lock.unlock()

        if let superseded {
            superseded.timeout.cancel()
            superseded.completion(.failure(ClipboardBulkError.cancelled))
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    private func bind(attempt: Int) {
        lock.lock()
        guard active else { lock.unlock(); return }
        lock.unlock()

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: LocalCastConfiguration.clipboardPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    self.listening = true
                    self.rebindFailures = 0
                    self.lock.unlock()
                    self.logger.info("📋 Clipboard bulk listener ready on \(LocalCastConfiguration.clipboardPort)")
                case .failed(let error):
                    self.lock.lock()
                    self.listening = false
                    self.listener = nil
                    self.rebindFailures += 1
                    let failures = self.rebindFailures
                    self.lock.unlock()
                    // Sleep/wake can invalidate the socket; rebind while the
                    // session stays active rather than silently degrading,
                    // but back off and eventually give up rather than spin.
                    guard failures <= Self.maxRebindFailures else {
                        self.logger.error("📋 Clipboard bulk listener failed \(failures) times (\(error.localizedDescription)); bulk sync disabled for this session")
                        return
                    }
                    let delay = min(60, 2 * pow(2.0, Double(failures - 1)))
                    self.logger.error("📋 Clipboard bulk listener failed: \(error.localizedDescription), rebinding in \(Int(delay)) s")
                    self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.bind(attempt: 0) }
                default:
                    break
                }
            }
            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
        } catch {
            setListening(false)
            guard attempt < 3 else {
                logger.error("📋 Clipboard bulk listener could not bind port \(LocalCastConfiguration.clipboardPort); file and large-payload sync disabled for this session")
                return
            }
            let delay = pow(2.0, Double(attempt))
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.bind(attempt: attempt + 1)
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        // The doc promises a disabled receiver refuses bulk connections, not
        // just that it stops offering.
        guard ClipboardSyncPreferences.isEnabledSnapshot() else {
            connection.cancel()
            return
        }

        lock.lock()
        let key = self.key
        let allowed = self.allowedHost
        let alreadyBusy = busy
        if !alreadyBusy { busy = true }
        lock.unlock()

        guard !alreadyBusy else {
            connection.cancel()
            return
        }

        let remote = ClipboardBulkPeerAddress.hostString(from: connection.endpoint)
        if let allowed, remote != allowed {
            // Keyless sessions have no cryptographic gate, so the address check
            // is the only one; on keyed sessions the sealed hello is the real
            // gate and a mismatch (multi-homed Mac, VPN) is tolerated.
            if key == nil {
                logger.warning("📋 Rejected clipboard connection from \(remote ?? "unknown") (expected \(allowed))")
                connection.cancel()
                lock.lock(); busy = false; lock.unlock()
                return
            }
            logger.info("📋 Clipboard connection from \(remote ?? "unknown") differs from session address \(allowed); sealed hello will decide")
        }

        let stream = ClipboardBulkStream(connection: connection, key: key, queue: queue)
        // Hard lifetime cap: cancelling the stream errors the pending receive
        // and unwinds the task below, freeing the single-flight slot.
        let lifetime = DispatchWorkItem { [logger] in
            logger.warning("📋 Clipboard bulk connection exceeded \(Int(Self.maxConnectionSeconds)) s; closing")
            stream.cancel()
        }
        queue.asyncAfter(deadline: .now() + Self.maxConnectionSeconds, execute: lifetime)
        Task { [weak self] in
            guard let self else { return }
            defer {
                lifetime.cancel()
                stream.cancel()
                self.markIdle()
            }
            do {
                try await stream.awaitReady(timeout: 10)
                guard let frame = try await stream.readFrame(), frame.type == .hello,
                      let hello = try? JSONDecoder().decode(ClipboardBulkHello.self, from: frame.body) else {
                    throw ClipboardBulkError.badFrame
                }
                switch hello.op {
                case .fetch:
                    try await self.serveFetch(token: hello.token, over: stream)
                case .push:
                    try await self.acceptPush(hello: hello, over: stream)
                }
            } catch {
                self.logger.warning("📋 Clipboard bulk connection ended: \(error.localizedDescription)")
            }
        }
    }

    // Synchronous state helpers, so async code never holds the lock directly.

    private func markIdle() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    private func currentOffer() -> (token: Data, manifest: ClipboardBulkManifest, content: ClipboardBulkContent)? {
        lock.lock()
        defer { lock.unlock() }
        return outbound
    }

    private func consumeOffer(token: Data) {
        lock.lock()
        if outbound?.token == token { outbound = nil }
        lock.unlock()
    }

    private func takeExpectedPush(matching token: Data, kind: ClipboardContentKind?) -> ExpectedPush? {
        lock.lock()
        defer { lock.unlock() }
        guard let expected = expectedPush,
              SessionCrypto.constantTimeEquals(expected.token, token),
              kind == nil || expected.kind == kind else { return nil }
        expectedPush = nil
        return expected
    }

    private func serveFetch(token: Data, over stream: ClipboardBulkStream) async throws {
        guard let offer = currentOffer(), SessionCrypto.constantTimeEquals(offer.token, token) else {
            throw ClipboardBulkError.tokenRejected
        }

        try await stream.writeFrame(type: .helloAck, body: try JSONEncoder().encode(offer.manifest))
        try await ClipboardBulkTransfer.send(offer.content, over: stream)

        // Image and text offers are one-shot; file offers stay valid so a
        // promise can be pasted more than once.
        if offer.manifest.kind != .files {
            consumeOffer(token: offer.token)
        }
        logger.info("📋 Served clipboard fetch (\(offer.manifest.totalBytes) bytes, kind \(offer.manifest.kind.rawValue))")
    }

    private func acceptPush(hello: ClipboardBulkHello, over stream: ClipboardBulkStream) async throws {
        guard let manifest = hello.manifest,
              let expected = takeExpectedPush(matching: hello.token, kind: manifest.kind) else {
            throw ClipboardBulkError.tokenRejected
        }
        expected.timeout.cancel()

        do {
            let received = try await ClipboardBulkTransfer.receive(
                manifest: manifest, over: stream, cacheDirectory: expected.cacheDir
            )
            try await stream.writeFrame(type: .done, body: Data())
            expected.completion(.success(received))
            logger.info("📋 Received clipboard push (\(manifest.totalBytes) bytes, kind \(manifest.kind.rawValue))")
        } catch {
            expected.completion(.failure(error))
            throw error
        }
    }
}

/// Client side of the clipboard bulk channel. The client initiates every
/// connection: it fetches the host's offers and pushes its own content when
/// the host sends a `clipboardFetchRequest`.
final class ClipboardBulkClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ClipboardBulkClient")
    private let queue = DispatchQueue(label: "com.tidaldrift.clipboard.bulk.client")
    private let lock = NSLock()
    private var current: ClipboardBulkStream?

    /// Cancel whatever transfer is in flight; a newer copy supersedes it.
    func cancelActive() {
        lock.lock()
        let stream = current
        current = nil
        lock.unlock()
        stream?.cancel()
    }

    func fetch(
        offer: ClipboardBulkOffer,
        expectedKind: ClipboardContentKind,
        host: String,
        key: SymmetricKey?,
        cacheDir: URL?
    ) async throws -> ClipboardBulkReceived {
        let stream = try await open(host: host, key: key)
        defer { finish(stream) }

        let hello = ClipboardBulkHello(op: .fetch, token: offer.token, manifest: nil)
        try await stream.writeFrame(type: .hello, body: try JSONEncoder().encode(hello))

        guard let frame = try await stream.readFrame(), frame.type == .helloAck,
              let manifest = try? JSONDecoder().decode(ClipboardBulkManifest.self, from: frame.body) else {
            throw ClipboardBulkError.tokenRejected
        }
        guard manifest.kind == expectedKind,
              manifest.totalBytes == offer.totalBytes,
              (manifest.files?.map(\.name) ?? []) == (offer.files?.map(\.name) ?? []) else {
            throw ClipboardBulkError.manifestMismatch
        }

        return try await ClipboardBulkTransfer.receive(manifest: manifest, over: stream, cacheDirectory: cacheDir)
    }

    func push(
        content: ClipboardBulkContent,
        manifest: ClipboardBulkManifest,
        token: Data,
        host: String,
        key: SymmetricKey?
    ) async throws {
        let stream = try await open(host: host, key: key)
        defer { finish(stream) }

        let hello = ClipboardBulkHello(op: .push, token: token, manifest: manifest)
        try await stream.writeFrame(type: .hello, body: try JSONEncoder().encode(hello))
        try await ClipboardBulkTransfer.send(content, over: stream)

        guard let frame = try await stream.readFrame(), frame.type == .done else {
            throw ClipboardBulkError.badFrame
        }
        logger.info("📋 Pushed clipboard content (\(manifest.totalBytes) bytes, kind \(manifest.kind.rawValue))")
    }

    private func open(host: String, key: SymmetricKey?) async throws -> ClipboardBulkStream {
        cancelActive()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: LocalCastConfiguration.clipboardPort)!,
            using: .tcp
        )
        let stream = ClipboardBulkStream(connection: connection, key: key, queue: queue)
        install(stream)
        do {
            try await stream.awaitReady(timeout: 10)
        } catch {
            // The callers' defer only exists after open returns; without this
            // a failed connect leaks the connection until the next copy.
            finish(stream)
            throw error
        }
        return stream
    }

    private func install(_ stream: ClipboardBulkStream) {
        lock.lock()
        current = stream
        lock.unlock()
    }

    private func finish(_ stream: ClipboardBulkStream) {
        stream.cancel()
        lock.lock()
        if current === stream { current = nil }
        lock.unlock()
    }
}

enum ClipboardBulkPeerAddress {
    /// Extract the bare host string from an endpoint, stripping any interface
    /// scope suffix ("fe80::1%en0" becomes "fe80::1"). Switches on the host
    /// enum rather than parsing the endpoint's description, whose format is
    /// not a stable API. On keyless sessions this string is the only peer
    /// gate, so both sides of the comparison must come through here.
    static func hostString(from endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        let described: String
        switch host {
        case .ipv4(let address):
            described = String(describing: address)
        case .ipv6(let address):
            described = String(describing: address)
        case .name(let name, _):
            described = name
        @unknown default:
            return nil
        }
        return described.split(separator: "%").first.map(String.init)
    }
}
