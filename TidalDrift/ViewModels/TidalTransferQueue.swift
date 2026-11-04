import Foundation
import Combine

enum TidalTransferDestination {
    case folder(URL)
    case peer(DiscoveredDevice)

    var name: String {
        switch self {
        case .folder(let url): return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .peer(let device): return device.displayName
        }
    }

    var detail: String {
        switch self {
        case .folder(let url): return url.path
        case .peer(let device): return device.ipAddress
        }
    }
}

/// Each drop snapshots its destination. A second drop waits for the first copy to
/// finish, including cancellation cleanup, before touching either filesystem.
@MainActor
final class TidalTransferQueue: ObservableObject {
    typealias Progress = @Sendable (String, Double?) async -> Void
    typealias Copy = @MainActor ([URL], TidalTransferDestination, @escaping Progress) async throws -> Void

    struct Batch: Identifiable {
        enum State: Equatable {
            case queued, copying(String, Double?), stopping, finished, cancelled, failed(String)

            var canCancel: Bool {
                switch self {
                case .queued, .copying: return true
                default: return false
                }
            }

            var isFinal: Bool {
                switch self {
                case .finished, .cancelled, .failed: return true
                default: return false
                }
            }
        }

        let id: UUID
        let title: String
        let destination: String
        var state: State
    }

    private struct Job {
        let id: UUID
        let sources: [URL]
        let destination: TidalTransferDestination
    }

    @Published private(set) var batches: [Batch] = []
    /// Keep running and queued copies visible above the most recent receipts.
    var activity: [Batch] {
        batches.filter { !$0.state.isFinal } + batches.reversed().filter { $0.state.isFinal }
    }
    private var pending: [Job] = []
    private var active: (id: UUID, task: Task<Void, Never>)?
    private let copy: Copy

    init(copy: @escaping Copy) { self.copy = copy }

    @discardableResult
    func enqueue(_ sources: [URL], to destination: TidalTransferDestination) -> UUID? {
        guard let first = sources.first, sources.allSatisfy(\.isFileURL) else { return nil }
        let title = sources.count == 1 ? first.lastPathComponent : "\(first.lastPathComponent) + \(sources.count - 1) more"
        let job = Job(id: UUID(), sources: sources, destination: destination)
        pending.append(job)
        batches.append(Batch(id: job.id, title: title, destination: destination.name, state: .queued))
        pruneHistory()
        startNext()
        return job.id
    }

    func cancel(_ id: UUID) {
        if active?.id == id {
            update(id, to: .stopping)
            active?.task.cancel()
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            update(id, to: .cancelled)
        }
    }

    func clearFinished() { batches.removeAll { $0.state.isFinal } }

    private func pruneHistory() {
        var extra = batches.lazy.filter { $0.state.isFinal }.count - 30
        guard extra > 0 else { return }
        batches.removeAll {
            guard extra > 0, $0.state.isFinal else { return false }
            extra -= 1
            return true
        }
    }

    private func update(_ id: UUID, to state: Batch.State) {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return }
        batches[index].state = state
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        update(job.id, to: .copying("Preparing…", nil))
        let task = Task { await run(job) }
        active = (job.id, task)
    }

    private func run(_ job: Job) async {
        defer {
            active = nil
            pruneHistory()
            startNext()
        }
        do {
            try Task.checkCancellation()
            try await copy(job.sources, job.destination) { [weak self] detail, fraction in
                await self?.showProgress(for: job.id, detail: detail, fraction: fraction)
            }
            // A committed copy wins if Cancel was clicked after publication.
            update(job.id, to: .finished)
        } catch {
            update(job.id, to: error is CancellationError ? .cancelled : .failed(error.localizedDescription))
        }
    }

    private func showProgress(for id: UUID, detail: String, fraction: Double?) {
        guard active?.id == id, active?.task.isCancelled == false else { return }
        let value = fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        update(id, to: .copying(detail, value))
    }
}
