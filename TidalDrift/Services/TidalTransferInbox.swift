import Foundation
import Combine

/// Receiving is an explicit, window-scoped choice. Only one batch can occupy
/// the inbox; each offer needs approval before its payload can be written.
@MainActor
final class TidalTransferInbox: ObservableObject {
    static let shared = TidalTransferInbox()
    struct Offer: Identifiable {
        let id: UUID
        let peer: String
        let count: Int
        let bytes: Int64
    }
    @Published var enabled = false {
        didSet {
            if !enabled {
                respond(accept: false)
                job?.cancel()
            }
        }
    }
    @Published private(set) var offer: Offer?
    @Published private(set) var status: String?
    private var job: Task<Void, Never>?
    private var activeID: UUID?
    private var decision: CheckedContinuation<Bool, Never>?
    private var offerExpiry: Task<Void, Never>?
    private let destination: () -> URL

    init(destination: @escaping () -> URL = { AppState.shared.settings.tidalDropFolder }) {
        self.destination = destination
    }

    func accept(_ channel: TidalTransferChannel, peer: String) {
        guard TidalDropService.isAcceptableSender(peer) else { channel.cancel(); return }
        guard enabled, activeID == nil else {
            Task { try? await channel.reply(.unavailable); channel.cancel() }
            return
        }
        let id = UUID()
        activeID = id
        status = "Checking an incoming batch…"
        job = Task {
            defer {
                offerExpiry?.cancel()
                respond(accept: false)
                channel.cancel()
                activeID = nil
                job = nil
            }
            do {
                let updates = TidalTransferByteUpdates()
                let url = try await withTaskCancellationHandler {
                    try await channel.receive(authorize: { count, bytes in
                        await self.approve(.init(id: id, peer: peer, count: count, bytes: bytes))
                    }, progress: { bytes, total in
                        guard updates.shouldReport() else { return }
                        Task { @MainActor in
                            guard self.activeID == id else { return }
                            self.status = "Receiving from \(peer) · \(Self.formatted(bytes)) of \(Self.formatted(total))"
                        }
                    })
                } onCancel: { channel.cancel() }
                status = "Saved to \(url.path)"
            } catch {
                if !Task.isCancelled { try? await channel.reply(.failed) }
                status = Task.isCancelled ? "Receiving stopped." : error.localizedDescription
            }
        }
    }

    private func approve(_ incoming: Offer) async -> URL? {
        guard enabled, !Task.isCancelled, activeID == incoming.id else { return nil }
        let approved = await withCheckedContinuation { continuation in
            decision = continuation
            offer = incoming
            status = nil
            offerExpiry = Task {
                do { try await Task.sleep(for: .seconds(75)) } catch { return }
                if self.offer?.id == incoming.id { self.respond(accept: false) }
            }
        }
        guard approved, enabled, !Task.isCancelled else { return nil }
        status = "Receiving from \(incoming.peer)…"
        return destination()
    }

    func respond(accept: Bool) {
        offerExpiry?.cancel()
        offerExpiry = nil
        offer = nil
        let current = decision
        decision = nil
        current?.resume(returning: accept)
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Do not enqueue a main-actor update for every file or chunk on a fast disk.
final class TidalTransferByteUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -Double.infinity
    func shouldReport() -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - last >= 0.15 else { return false }
            last = now
            return true
        }
    }
}
