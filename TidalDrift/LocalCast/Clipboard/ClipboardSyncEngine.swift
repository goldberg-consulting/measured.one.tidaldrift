import AppKit
import OSLog

/// Role-agnostic clipboard sync core, owned by both `HostSession` and
/// `ClientSession`. Watches the local pasteboard while a session is active,
/// decides inline versus bulk, applies remote updates, and suppresses echoes.
/// The owning session supplies the transport hooks. Main actor: NSPasteboard
/// is not safe from arbitrary queues, and the poll interval (0.5 s, the rate
/// the legacy service used) is negligible next to 60 fps video.
@MainActor
final class ClipboardSyncEngine {
    struct OutboundBulk {
        let updateId: UUID
        let token: Data
        let manifest: ClipboardBulkManifest
        let content: ClipboardBulkContent
    }

    // MARK: - Hooks supplied by the owning session

    /// Send one clipboardUpdate packet to the peer. The engine calls this
    /// three times per update (input-event precedent); the receiver dedups.
    var sendUpdate: ((ClipboardUpdatePayload) -> Void)?
    /// Install outbound bulk content so the peer can fetch it (host: listener
    /// offer slot; client: registry answered on clipboardFetchRequest).
    var publishOutbound: ((OutboundBulk) -> Void)?
    /// Invalidate the previous outbound offer and any transfer in flight.
    var cancelOutbound: (() -> Void)?
    /// Resolve an eager image or large-text offer.
    var fetchEager: ((ClipboardBulkOffer, ClipboardContentKind, @escaping (Result<ClipboardBulkReceived, Error>) -> Void) -> Void)?
    /// Resolve a file offer at paste time, delivering staged URLs in offer order.
    var fetchFilesForPaste: ((ClipboardBulkOffer, @escaping (Result<[URL], Error>) -> Void) -> Void)?
    /// Whether the bulk (TCP) channel may be used. Bulk needs a keyed session:
    /// on a keyless one the offer token rides in a sniffable UDP packet and
    /// the listener has no cryptographic gate, so any LAN host could fetch the
    /// offered content or push into an armed slot. Keyless sessions sync
    /// inline (small text and images) only.
    var isBulkSyncAllowed: (() -> Bool)?

    private let logger = Logger(subsystem: "com.tidaldrift", category: "ClipboardSyncEngine")
    private let pasteboard: NSPasteboard
    private let isSyncEnabled: @MainActor () -> Bool
    private var pendingRemoteUpdateID: UUID?
    private var updateSendTask: Task<Void, Never>?
    private var wasSyncEnabled = false
    private var timer: Timer?
    private var lastChangeCount = 0
    private var lastAppliedDigest: Data?
    /// When the last remote apply happened. The outbound digest gate only
    /// suppresses within a short window after an apply: its sole job is the
    /// app-rewrite echo (an app observing our write and re-writing the same
    /// content with a new change count), which happens promptly. An unbounded
    /// gate would swallow the user deliberately re-copying that content for
    /// the rest of the session.
    private var lastAppliedAt: Date = .distantPast
    private static let appliedEchoWindow: TimeInterval = 2.0
    private var recentUpdateIds: [UUID] = []
    private var promiseDelegate: ClipboardFilePromiseDelegate?
    private(set) var isRunning = false

    init(pasteboard: NSPasteboard = .general, isSyncEnabled: (@MainActor () -> Bool)? = nil) {
        self.pasteboard = pasteboard
        self.isSyncEnabled = isSyncEnabled ?? { ClipboardSyncPreferences.shared.isEnabled }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        wasSyncEnabled = isSyncEnabled()
        // Whatever was copied before the session started stays private.
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPasteboard() }
        }
        logger.info("📋 Clipboard sync engine started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingRemoteUpdateID = nil
        updateSendTask?.cancel()
        updateSendTask = nil
        timer?.invalidate()
        timer = nil
        promiseDelegate?.invalidate()
        promiseDelegate = nil
        cancelOutbound?()
        lastAppliedDigest = nil
        recentUpdateIds.removeAll()
        logger.info("📋 Clipboard sync engine stopped")
    }

    // MARK: - Local pasteboard to peer

    func checkPasteboard() {
        guard isRunning else { return }
        let enabled = isSyncEnabled()
        if !enabled || !wasSyncEnabled {
            // Copies made with sync disabled remain private after re-enabling.
            lastChangeCount = pasteboard.changeCount
            if wasSyncEnabled != enabled {
                supersedePendingContent()
                lastAppliedDigest = nil
            }
            wasSyncEnabled = enabled
            return
        }
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let snapshot = ClipboardPasteboard.capture(from: pasteboard) else {
            // Concealed or unsupported content still invalidates an older offer.
            supersedePendingContent()
            lastAppliedDigest = nil
            return
        }
        // Echo gate: the content we just applied from the peer, rewritten by
        // an app that bumps the change count. Time-boxed; see lastAppliedAt.
        if snapshot.digest == lastAppliedDigest,
           Date().timeIntervalSince(lastAppliedAt) < Self.appliedEchoWindow {
            return
        }
        broadcast(snapshot)
    }

    /// Explicit user gesture; does not replace or expose the sender's clipboard.
    func receiveDrop(from source: NSPasteboard) -> Bool {
        // Reject a mixed file/folder drop as a whole rather than silently
        // transferring only some items (or sending a folder's name as text).
        if let urls = source.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty,
           !urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map {
               $0.isRegularFile == true && $0.isSymbolicLink != true
           } == true }) { return false }
        guard isRunning, isSyncEnabled(), isBulkSyncAllowed?() == true,
              let snapshot = ClipboardPasteboard.capture(from: source),
              snapshot.totalContentBytes <= LocalCastConfiguration.clipboardMaxTransferBytes else { return false }
        if snapshot.kind == .files,
           makeOutbound(updateId: UUID(), snapshot: snapshot) == nil { return false }
        lastChangeCount = pasteboard.changeCount
        broadcast(snapshot, eagerFiles: snapshot.kind == .files)
        return true
    }

    private func broadcast(_ snapshot: ClipboardSnapshot, eagerFiles: Bool = false) {
        // A newer copy supersedes whatever was offered or in flight.
        supersedePendingContent()
        // The local pasteboard has moved on, so the receive-side duplicate
        // gate must not keep suppressing the content it once applied.
        lastAppliedDigest = nil

        let updateId = UUID()

        if snapshot.kind != .files {
            let inline = ClipboardUpdatePayload(
                updateId: updateId, kind: snapshot.kind,
                text: snapshot.text, rtf: snapshot.rtf, html: snapshot.html, png: snapshot.png,
                bulk: nil, digest: snapshot.digest
            )
            if let encoded = try? JSONEncoder().encode(inline),
               encoded.count <= LocalCastConfiguration.clipboardInlineLimit {
                send(inline)
                return
            }
        }

        if isBulkSyncAllowed?() != true {
            logger.info("📋 \(snapshot.kind == .files ? "File" : "Large") copy not offered: bulk sync requires a password-protected session")
            return
        }

        guard let outbound = makeOutbound(updateId: updateId, snapshot: snapshot) else { return }
        publishOutbound?(outbound)
        let offer = ClipboardBulkOffer(
            token: outbound.token,
            totalBytes: outbound.manifest.totalBytes,
            files: outbound.manifest.files
        )
        send(ClipboardUpdatePayload(
            updateId: updateId, kind: snapshot.kind,
            text: nil, rtf: nil, png: nil,
            bulk: offer, digest: snapshot.digest, eagerFiles: eagerFiles ? true : nil
        ))
    }

    private func makeOutbound(updateId: UUID, snapshot: ClipboardSnapshot) -> OutboundBulk? {
        let content: ClipboardBulkContent
        switch snapshot.kind {
        case .files:
            guard snapshot.fileURLs.count <= LocalCastConfiguration.clipboardMaxFiles else {
                logger.info("📋 Copy skipped: \(snapshot.fileURLs.count) files exceeds the \(LocalCastConfiguration.clipboardMaxFiles)-file limit")
                return nil
            }
            content = .files(snapshot.fileURLs)
        case .image:
            guard let png = snapshot.png else { return nil }
            content = .data(kind: .image, data: png)
        case .text:
            guard let text = snapshot.text,
                  let encoded = try? JSONEncoder().encode(ClipboardTextContent(text: text, rtf: snapshot.rtf, html: snapshot.html)) else { return nil }
            content = .data(kind: .text, data: encoded)
        }

        let totalBytes = content.totalBytes
        guard (totalBytes > 0 || snapshot.kind == .files),
              totalBytes <= LocalCastConfiguration.clipboardMaxTransferBytes else {
            logger.info("📋 Copy skipped: \(totalBytes) bytes exceeds the transfer limit")
            return nil
        }

        let manifest = ClipboardBulkManifest(
            updateId: updateId,
            kind: snapshot.kind,
            totalBytes: totalBytes,
            files: snapshot.kind == .files ? snapshot.fileStubs : nil
        )
        return OutboundBulk(updateId: updateId, token: SessionCrypto.generateNonce(), manifest: manifest, content: content)
    }

    private func send(_ payload: ClipboardUpdatePayload) {
        sendUpdate?(payload)
        updateSendTask?.cancel()
        updateSendTask = Task { @MainActor [weak self] in
            // Space retries across separate network bursts. Back-to-back copies
            // are commonly all lost in the same Wi-Fi queue overflow.
            for delay in [80_000_000, 160_000_000] {
                do { try await Task.sleep(nanoseconds: UInt64(delay)) }
                catch { return }
                guard let self, self.isRunning, self.isSyncEnabled() else { return }
                self.sendUpdate?(payload)
            }
        }
    }

    private func supersedePendingContent() {
        pendingRemoteUpdateID = nil
        updateSendTask?.cancel()
        updateSendTask = nil
        cancelOutbound?()
        promiseDelegate?.invalidate()
        promiseDelegate = nil
    }

    // MARK: - Peer to local pasteboard

    func handleRemoteUpdate(_ payload: ClipboardUpdatePayload) {
        guard isRunning, isSyncEnabled(), Self.isValid(payload) else { return }
        guard !recentUpdateIds.contains(payload.updateId) else { return }
        recentUpdateIds.append(payload.updateId)
        if recentUpdateIds.count > 16 { recentUpdateIds.removeFirst() }

        guard payload.eagerFiles == true || payload.digest != lastAppliedDigest else { return }
        supersedePendingContent()
        pendingRemoteUpdateID = payload.updateId
        let expectedChangeCount = pasteboard.changeCount

        guard let bulk = payload.bulk else {
            let count = ClipboardPasteboard.applyInline(
                kind: payload.kind, text: payload.text, rtf: payload.rtf, html: payload.html, png: payload.png,
                to: pasteboard
            )
            recordApplied(changeCount: count, digest: payload.digest)
            return
        }

        guard isBulkSyncAllowed?() == true else { return }
        switch payload.kind {
        case .files:
            if payload.eagerFiles == true {
                fetchFilesForPaste?(bulk) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning, self.isSyncEnabled(),
                              self.pendingRemoteUpdateID == payload.updateId,
                              self.pasteboard.changeCount == expectedChangeCount else { return }
                        switch result {
                        case .success(let urls):
                            self.pasteboard.clearContents()
                            self.pasteboard.writeObjects(urls as [NSURL])
                            self.recordApplied(changeCount: self.pasteboard.changeCount, digest: payload.digest)
                        case .failure(let error):
                            self.logger.error("LocalCast drop failed: \(error.localizedDescription)")
                        }
                    }
                }
                return
            }
            applyFileOffer(bulk, digest: payload.digest)
        case .text, .image:
            guard bulk.totalBytes <= LocalCastConfiguration.clipboardMaxTransferBytes else { return }
            fetchEager?(bulk, payload.kind) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.isSyncEnabled(),
                          self.pendingRemoteUpdateID == payload.updateId,
                          self.pasteboard.changeCount == expectedChangeCount else { return }
                    switch result {
                    case .success(.data(let kind, let data)):
                        guard kind == payload.kind else { return }
                        self.applyFetched(kind: kind, data: data, digest: payload.digest)
                    case .success(.files):
                        self.logger.error("📋 Eager fetch unexpectedly returned files")
                    case .failure(let error):
                        self.logger.warning("📋 Eager clipboard fetch failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func applyFetched(kind: ClipboardContentKind, data: Data, digest: Data) {
        switch kind {
        case .text:
            guard let content = try? JSONDecoder().decode(ClipboardTextContent.self, from: data),
                  ClipboardPasteboard.textDigest(text: content.text, rtf: content.rtf, html: content.html) == digest else { return }
            let count = ClipboardPasteboard.applyInline(kind: .text, text: content.text, rtf: content.rtf, html: content.html, png: nil, to: pasteboard)
            recordApplied(changeCount: count, digest: digest)
        case .image:
            guard ClipboardPasteboard.isValidInline(kind: .image, text: nil, rtf: nil, png: data),
                  ClipboardPasteboard.digest(kind: .image, chunks: [data]) == digest else { return }
            let count = ClipboardPasteboard.applyInline(kind: .image, text: nil, rtf: nil, png: data, to: pasteboard)
            recordApplied(changeCount: count, digest: digest)
        case .files:
            break
        }
    }

    /// Reject malformed announcements before they change the pasteboard or
    /// allocate file promise state. Limits cover both inline and bulk shapes.
    static func isValid(_ payload: ClipboardUpdatePayload) -> Bool {
        guard payload.digest.count == 32 else { return false }
        if let bulk = payload.bulk {
            guard payload.text == nil, payload.rtf == nil, payload.html == nil, payload.png == nil,
                  bulk.token.count == 32, bulk.totalBytes >= 0,
                  bulk.totalBytes <= LocalCastConfiguration.clipboardMaxTransferBytes else { return false }
            if payload.kind == .files {
                guard let files = bulk.files, !files.isEmpty,
                      files.count <= LocalCastConfiguration.clipboardMaxFiles,
                      files.allSatisfy({ ClipboardBulkFraming.sanitizeFileName($0.name) != nil }),
                      ClipboardBulkTransfer.declaredTotal(of: files) == bulk.totalBytes else { return false }
                return true
            }
            return bulk.files == nil && bulk.totalBytes > 0
        }
        guard let encoded = try? JSONEncoder().encode(payload),
              encoded.count <= LocalCastConfiguration.clipboardInlineLimit,
              ClipboardPasteboard.isValidInline(kind: payload.kind, text: payload.text, rtf: payload.rtf,
                                                 html: payload.html, png: payload.png) else { return false }
        switch payload.kind {
        case .text:
            return ClipboardPasteboard.textDigest(text: payload.text ?? "", rtf: payload.rtf, html: payload.html) == payload.digest
        case .image:
            return ClipboardPasteboard.digest(kind: .image, chunks: [payload.png ?? Data()]) == payload.digest
        case .files:
            return false
        }
    }

    private func applyFileOffer(_ offer: ClipboardBulkOffer, digest: Data) {
        guard let stubs = offer.files, !stubs.isEmpty,
              stubs.count <= LocalCastConfiguration.clipboardMaxFiles,
              stubs.allSatisfy({ ClipboardBulkFraming.sanitizeFileName($0.name) != nil }) else { return }

        promiseDelegate?.invalidate()
        let delegate = ClipboardFilePromiseDelegate(stubs: stubs) { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.isSyncEnabled(),
                      self.isBulkSyncAllowed?() == true, let fetchFiles = self.fetchFilesForPaste else {
                    completion(.failure(ClipboardBulkError.cancelled))
                    return
                }
                fetchFiles(offer, completion)
            }
        }
        promiseDelegate = delegate
        let count = ClipboardPasteboard.applyPromises(delegate.makeProviders(), to: pasteboard)
        recordApplied(changeCount: count, digest: digest)
        logger.info("📋 Placed \(stubs.count) promised file(s) on the pasteboard")
    }

    private func recordApplied(changeCount: Int, digest: Data) {
        lastChangeCount = max(lastChangeCount, changeCount)
        lastAppliedDigest = digest
        lastAppliedAt = Date()
    }
}
