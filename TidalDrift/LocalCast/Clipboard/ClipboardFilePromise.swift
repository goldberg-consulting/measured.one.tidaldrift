import AppKit
import OSLog
import UniformTypeIdentifiers

/// Serves NSFilePromiseProvider callbacks for a single file offer.
///
/// Copied files never transfer eagerly: the receiving pasteboard holds one
/// provider per offered file, and the first paste triggers a single fetch of
/// the whole offer into a staging directory (single-flight, cached for the
/// offer's lifetime). Each provider then copies its staged file to the exact
/// destination URL the pasting app supplies, so bytes land where the user
/// pasted and nothing persists from an idle copy.
final class ClipboardFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    /// Fetch the whole offer, delivering staged URLs in offer order.
    typealias FetchHandler = (@escaping (Result<[URL], Error>) -> Void) -> Void

    private let logger = Logger(subsystem: "com.tidaldrift", category: "ClipboardFilePromise")
    private let stubs: [ClipboardFileStub]
    private let fetch: FetchHandler
    private let callbackQueue = OperationQueue()

    private let lock = NSLock()
    private var staged: [URL]?
    private var fetchError: Error?
    private var waiters: [(Result<[URL], Error>) -> Void] = []
    private var fetching = false
    private var invalidated = false

    init(stubs: [ClipboardFileStub], fetch: @escaping FetchHandler) {
        self.stubs = stubs
        self.fetch = fetch
        callbackQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    /// One provider per offered file; the provider's userInfo carries its
    /// index into the offer.
    func makeProviders() -> [NSFilePromiseProvider] {
        stubs.enumerated().map { index, stub in
            let ext = (stub.name as NSString).pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = index
            return provider
        }
    }

    /// Drop the cached staging directory. Called when the offer is superseded
    /// or the session ends; outstanding pastes fail cleanly.
    func invalidate() {
        lock.lock()
        invalidated = true
        let stagedURLs = staged
        staged = nil
        let pending = waiters
        waiters = []
        lock.unlock()

        for waiter in pending { waiter(.failure(ClipboardBulkError.cancelled)) }
        if let first = stagedURLs?.first {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
        }
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let index = filePromiseProvider.userInfo as? Int, stubs.indices.contains(index) else { return "clipboard" }
        return stubs[index].name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        callbackQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let index = filePromiseProvider.userInfo as? Int, stubs.indices.contains(index) else {
            completionHandler(ClipboardBulkError.badFrame)
            return
        }
        ensureStaged { result in
            switch result {
            case .success(let urls):
                guard urls.indices.contains(index) else {
                    completionHandler(ClipboardBulkError.manifestMismatch)
                    return
                }
                do {
                    try FileManager.default.copyItem(at: urls[index], to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            case .failure(let error):
                completionHandler(error)
            }
        }
    }

    /// Single-flight fetch of the whole offer.
    private func ensureStaged(_ completion: @escaping (Result<[URL], Error>) -> Void) {
        lock.lock()
        if invalidated {
            lock.unlock()
            completion(.failure(ClipboardBulkError.cancelled))
            return
        }
        if let staged {
            lock.unlock()
            completion(.success(staged))
            return
        }
        waiters.append(completion)
        let shouldFetch = !fetching
        fetching = true
        lock.unlock()

        guard shouldFetch else { return }
        logger.info("📋 Paste triggered fetch of \(self.stubs.count) promised file(s)")
        fetch { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.fetching = false
            if case .success(let urls) = result, !self.invalidated {
                self.staged = urls
            }
            let pending = self.waiters
            self.waiters = []
            let finalResult: Result<[URL], Error> = self.invalidated ? .failure(ClipboardBulkError.cancelled) : result
            self.lock.unlock()
            for waiter in pending { waiter(finalResult) }
        }
    }
}
