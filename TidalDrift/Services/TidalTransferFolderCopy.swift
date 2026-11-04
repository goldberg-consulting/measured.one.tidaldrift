import Darwin
import Foundation
import os

/// Copies onto a local volume or a share already mounted in Finder. Each top-level
/// item is published with an exclusive rename only after the whole batch is staged.
enum TidalTransferFolderCopy {
    struct Progress: Sendable {
        let completedItems: Int
        let totalItems: Int
        let bytesCopied: Int64
        let totalBytes: Int64
        let currentName: String?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Entry: Sendable {
        let source: URL
        let relative: String
        let kind: mode_t
        let device: dev_t
        let inode: ino_t
        let size: Int64

        var isDirectory: Bool { kind == S_IFDIR }
    }

    /// The caller holds any security-scoped grants until this returns. Progress
    /// callbacks run off the main actor and are coalesced for large selections.
    static func copy(_ sources: [URL], to destination: URL,
                     progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> [URL] {
        guard !sources.isEmpty, destination.isFileURL else { throw Failure("Choose files and a destination folder.") }
        try Task.checkCancellation()
        let folder = try physicalDirectory(destination)
        let parent = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw failure(folder) }
        defer { close(parent) }
        let plan = try makePlan(sources, destination: folder)
        let ledger = Ledger(entries: plan, report: progress)
        ledger.update(name: nil, force: true)

        let temporary = ".tidal-transfer-" + UUID().uuidString
        guard mkdirat(parent, temporary, 0o700) == 0 else { throw failure(folder) }
        let stage = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            // Another writer in a mounted share can replace the name. No fd
            // means we cannot prove ownership for cleanup.
            throw Failure("Could not open the temporary copy folder \(temporary).")
        }
        defer { close(stage) }
        var saved: [URL] = []
        do {
            try await stageItems(plan, stage: stage, ledger: ledger)
            for (index, source) in sources.enumerated() {
                // Publishing is the commit phase. A late cancellation cannot
                // interrupt the batch between two already completed copies.
                try verifyDirectory(folder, descriptor: parent)
                guard TidalTransferDisk.isPinned(stage, in: parent, named: temporary) else {
                    throw Failure("The temporary folder moved during copying.")
                }
                let name = try publish(String(index), from: stage, into: parent, as: source.lastPathComponent)
                saved.append(folder.appendingPathComponent(name))
            }
            try verifyDirectory(folder, descriptor: parent)
        } catch {
            // The manifest is ordered by top-level selection, parent before child.
            // Previously published selections no longer belong to staging.
            let firstUnpublished = String(saved.count)
            discardStaged(plan.drop(while: { $0.relative != firstUnpublished }), from: stage)
            if !TidalTransferDisk.isPinned(stage, in: parent, named: temporary) || unlinkat(parent, temporary, AT_REMOVEDIR) != 0 {
                throw Failure("Copied \(saved.count) of \(sources.count) selected items. \(error.localizedDescription) The temporary folder \(temporary) moved or could not be fully cleaned up.")
            }
            guard !saved.isEmpty else { throw error }
            throw Failure("Copied \(saved.count) of \(sources.count) selected items. \(error.localizedDescription)")
        }
        guard TidalTransferDisk.isPinned(stage, in: parent, named: temporary),
              unlinkat(parent, temporary, AT_REMOVEDIR) == 0 else {
            throw Failure("All items were copied, but the temporary folder \(temporary) could not be removed.")
        }
        ledger.update(name: nil, force: true)
        return saved
    }

    /// Remove only planned names, with each parent pinned beneath the original
    /// staging descriptor. Never recursively delete a replacement by pathname.
    private static func discardStaged(_ entries: ArraySlice<Entry>, from stage: Int32) {
        var needsRetry = false
        for entry in entries.reversed() {
            if !TidalTransferDisk.removeEntry(entry.relative, from: stage, directory: entry.isDirectory) { needsRetry = true }
        }
        guard needsRetry else { return }
        // Copied Finder flags and directory permissions can prevent unlinkat.
        // Make remaining staged copies deletable from the top down. Do not
        // modify a symlink target, a mounted volume, or a multiply linked file.
        var stageInfo = stat()
        guard fstat(stage, &stageInfo) == 0 else { return }
        for entry in entries where entry.kind != S_IFLNK {
            let fd = openat(stage, entry.relative, O_EVTONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == stageInfo.st_dev,
                  info.st_mode & mode_t(S_IFMT) == entry.kind, entry.isDirectory || info.st_nlink == 1 else { continue }
            _ = fchflags(fd, 0)
            if entry.isDirectory { _ = fchmod(fd, 0o700) }
        }
        for entry in entries.reversed() {
            TidalTransferDisk.removeEntry(entry.relative, from: stage, directory: entry.isDirectory)
        }
    }

    private static func verifyDirectory(_ url: URL, descriptor: Int32) throws {
        var original = stat()
        var current = stat()
        guard fstat(descriptor, &original) == 0, lstat(url.path, &current) == 0, FileID(original) == FileID(current) else {
            throw Failure("The destination folder moved during the copy. Select it again.")
        }
    }

    private static func stageItems(_ plan: [Entry], stage: Int32, ledger: Ledger) async throws {
        let directories = plan.filter(\.isDirectory)
        for entry in directories {
            try Task.checkCancellation()
            guard mkdirat(stage, entry.relative, 0o700) == 0 else { throw failure(entry.source) }
        }
        try await copyLeaves(plan.filter { !$0.isDirectory }, stage: stage, ledger: ledger)
        for entry in directories.reversed() {
            try Task.checkCancellation()
            try copyDirectoryMetadata(entry, stage: stage)
            ledger.update(name: entry.source.lastPathComponent, completed: 1)
        }
        try Task.checkCancellation()
    }

    private static func makePlan(_ sources: [URL], destination: URL) throws -> [Entry] {
        var ancestors = Set<FileID>()
        var path = destination
        while true {
            var info = stat()
            guard stat(path.path, &info) == 0 else { throw failure(path) }
            ancestors.insert(FileID(info))
            let parent = path.deletingLastPathComponent()
            if path.path == "/" || parent.path == path.path { break }
            path = parent
        }
        var entries: [Entry] = []
        for (index, source) in sources.enumerated() {
            let name = source.lastPathComponent
            guard source.isFileURL, !name.isEmpty, name != "/", name != ".", name != ".." else {
                throw Failure("Choose files or folders inside a volume to copy.")
            }
            // Resolve enclosing aliases, but never resolve the item itself: a
            // dropped symbolic link should remain a link even if it is broken.
            let root = try physicalDirectory(source.deletingLastPathComponent()).appendingPathComponent(name, isDirectory: false)
            var stack = [(root, String(index))]
            var visitedDirectories = Set<FileID>()
            while let (url, relative) = stack.popLast() {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw failure(url) }
                let kind = info.st_mode & mode_t(S_IFMT)
                if relative == String(index),
                   info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK) != 0 {
                    throw Failure("“\(name)” is locked. Select its enclosing folder, or unlock the item before copying it.")
                }
                guard kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK else {
                    throw Failure("“\(url.lastPathComponent)” is not a regular file, folder, or symbolic link.")
                }
                entries.append(Entry(source: url, relative: relative, kind: kind, device: info.st_dev, inode: info.st_ino,
                                     size: kind == S_IFREG ? info.st_size : 0))
                if kind == S_IFDIR {
                    guard !ancestors.contains(FileID(info)) else { throw Failure("Choose a destination outside the folder being copied.") }
                    guard visitedDirectories.insert(FileID(info)).inserted else {
                        throw Failure("“\(url.lastPathComponent)” repeats a folder already in this selection.")
                    }
                    let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    for child in names {
                        stack.append((url.appendingPathComponent(child, isDirectory: false), relative + "/" + child))
                    }
                }
            }
        }
        return entries
    }

    private struct FileID: Hashable {
        let dev: dev_t
        let ino: ino_t
        init(_ info: stat) { dev = info.st_dev; ino = info.st_ino }
    }

    // Foundation may present /private/var as /var even after resolving a
    // URL. Darwin's O_NOFOLLOW_ANY needs the actual, symlink-free pathname.
    private static func physicalDirectory(_ url: URL) throws -> URL {
        guard let path = realpath(url.path, nil) else { throw failure(url) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func copyLeaves(_ entries: [Entry], stage: Int32, ledger: Ledger) async throws {
        // Keep at most four ordinary files in flight, including when the user
        // drops just one big directory. Never allocate a Task per tiny file.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, entry) in entries.enumerated() {
                if index >= 4 { try await group.next() }
                try Task.checkCancellation()
                group.addTask {
                    try Task.checkCancellation()
                    try TidalTransferNativeCopy.copy(entry, stage: stage, ledger: ledger)
                }
            }
            try await group.waitForAll()
        }
    }

    private static func copyDirectoryMetadata(_ entry: Entry, stage: Int32) throws {
        let input = try openSource(entry, flags: O_DIRECTORY)
        defer { close(input) }
        let output = openat(stage, entry.relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard output >= 0 else { throw failure(entry.source) }
        let result = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA))
        let errorCode = errno
        let closeResult = close(output)
        guard result == 0 else { throw failure(entry.source, code: errorCode) }
        guard closeResult == 0 else { throw failure(entry.source) }
    }

    static func openSource(_ entry: Entry, flags: Int32 = 0) throws -> Int32 {
        let fd = open(entry.source.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC | flags)
        guard fd >= 0 else { throw failure(entry.source) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == entry.device, info.st_ino == entry.inode,
              info.st_mode & mode_t(S_IFMT) == entry.kind else {
            close(fd)
            throw Failure("“\(entry.source.lastPathComponent)” changed while it was being copied. Drop it again.")
        }
        return fd
    }

    private static func publish(_ temporary: String, from stage: Int32, into parent: Int32, as original: String) throws -> String {
        for suffix in 0..<10_000 {
            var name = original
            if suffix > 0 {
                let nsName = original as NSString
                let ext = nsName.pathExtension
                let ending = " (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
                var stem = nsName.deletingPathExtension
                while (stem + ending).utf8.count > 255, !stem.isEmpty { stem.removeLast() }
                name = stem + ending
            }
            if renameatx_np(stage, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 { return name }
            let code = errno
            guard code == EEXIST || code == ENOTEMPTY else { throw failure(URL(fileURLWithPath: original), code: code) }
        }
        throw Failure("There are too many copies named “\(original)” at this destination.")
    }

    static func failure(_ url: URL, code: Int32 = errno) -> Failure {
        Failure("Could not copy “\(url.lastPathComponent)”: \(String(cString: strerror(code))).")
    }

    /// A native copy callback cannot suspend. This lock serializes accounting
    /// and progress delivery across the four workers, at most ten times a second.
    final class Ledger: Sendable {
        private struct State { var count = 0; var bytes: Int64 = 0; var last: TimeInterval = 0 }
        private let lock = OSAllocatedUnfairLock(initialState: State())
        private let count: Int
        private let bytes: Int64
        private let report: @Sendable (Progress) -> Void

        init(entries: [Entry], report: @escaping @Sendable (Progress) -> Void) {
            count = entries.count
            bytes = entries.reduce(0) { $0 + $1.size }
            self.report = report
        }

        func update(name: String?, bytes delta: Int64 = 0, completed: Int = 0, force: Bool = false) {
            lock.withLock { state in
                state.count += completed
                state.bytes += delta
                let now = ProcessInfo.processInfo.systemUptime
                guard force || now - state.last >= 0.1 else { return }
                state.last = now
                report(Progress(completedItems: state.count, totalItems: count, bytesCopied: state.bytes,
                                totalBytes: bytes, currentName: name))
            }
        }
    }
}
