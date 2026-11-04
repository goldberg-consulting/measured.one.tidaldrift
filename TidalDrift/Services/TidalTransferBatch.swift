import Darwin
import Foundation

/// A batch is a bounded, parent-first manifest followed by the concatenated data
/// forks of its regular files. Directories and empty files consume no wire bytes.
enum TidalTransferBatch {
    static let maxManifestBytes = 8 * 1024 * 1024
    static let maxEntries = 50_000
    static let maxTotalBytes: Int64 = 64 * 1024 * 1024 * 1024
    static let chunkBytes = 1024 * 1024

    struct Entry: Codable, Sendable {
        let parent: Int // -1 denotes the receiver-created batch folder
        let name: String
        let directory: Bool
        let bytes: Int64
        let executable: Bool
        let modified: Int64 // Unix seconds
    }

    struct Plan: Sendable {
        let manifest: Data
        let total: Int64
        var count: Int { entries.count }
        fileprivate let entries: [Entry]
        fileprivate let sources: [Source]
    }

    fileprivate struct Source: Sendable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let modifiedNanos: Int
        let changeSeconds: Int
        let changeNanos: Int

        init(path: String, info: stat) {
            self.path = path
            device = info.st_dev
            inode = info.st_ino
            modifiedNanos = info.st_mtimespec.tv_nsec
            changeSeconds = info.st_ctimespec.tv_sec
            changeNanos = info.st_ctimespec.tv_nsec
        }

        func matches(_ info: stat, entry: Entry) -> Bool {
            info.st_mode & S_IFMT == S_IFREG && device == info.st_dev && inode == info.st_ino
                && info.st_size == entry.bytes && info.st_mtimespec.tv_sec == entry.modified
                && info.st_mtimespec.tv_nsec == modifiedNanos && info.st_ctimespec.tv_sec == changeSeconds
                && info.st_ctimespec.tv_nsec == changeNanos
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Scan without following links. Objects are pinned by identity and change time,
    /// and regular files are checked again before and after streaming from their fd.
    static func plan(_ sources: [URL]) throws -> Plan {
        var builder = Builder()
        for url in sources {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard url.isFileURL, valid(name: name) else { throw Failure("Choose a named file or folder.") }
            // /var and /tmp on macOS are links. Resolve only the user-selected
            // parent, never the selected leaf or any of its descendants.
            // URL.resolvingSymlinksInPath can return the /var alias again.
            // Keep the POSIX canonical path as bytes-to-String, not a new URL.
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw TidalTransferDisk.error(name) }
            defer { free(parent) }
            guard let prefix = String(validatingUTF8: parent) else { throw Failure("The source path is not valid UTF-8.") }
            let path = prefix == "/" ? prefix + name : prefix + "/" + name
            try builder.visit(path: path, name: name, parent: -1, depth: 1)
        }
        _ = try validate(builder.entries)
        let manifest = try JSONEncoder().encode(builder.entries)
        guard manifest.count <= maxManifestBytes else { throw Failure("Split this selection into smaller batches.") }
        return Plan(manifest: manifest, total: builder.total, entries: builder.entries, sources: builder.sources)
    }

    private struct Builder {
        var entries: [Entry] = []
        var sources: [Source] = []
        var total: Int64 = 0

        mutating func visit(path: String, name: String, parent: Int, depth: Int, relativeTo parentFD: Int32 = AT_FDCWD) throws {
            try Task.checkCancellation()
            guard valid(name: name), depth <= 64, path.utf8.count < Int(PATH_MAX), entries.count < maxEntries else {
                throw Failure("A name, folder depth, or entry count exceeds the batch limit.")
            }
            // Inspect without following the leaf before opening. O_NONBLOCK avoids
            // a FIFO blocking after a swap; O_NOFOLLOW_ANY covers every ancestor.
            var original = stat()
            let relativePath = parentFD == AT_FDCWD ? path : name
            guard fstatat(parentFD, relativePath, &original, AT_SYMLINK_NOFOLLOW) == 0 else { throw TidalTransferDisk.error(name) }
            let kind = original.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw Failure("“\(name)” is a link or special file. Use a folder destination for this selection.")
            }
            let fd = openat(parentFD, relativePath, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw TidalTransferDisk.error(name) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == original.st_dev, info.st_ino == original.st_ino,
                  info.st_mode & S_IFMT == kind else { throw Failure("“\(name)” changed while preparing the transfer.") }
            try TidalTransferDisk.checkFork(fd, name: name)
            let directory = kind == S_IFDIR
            let size: Int64 = directory ? 0 : info.st_size
            guard size >= 0, size <= maxTotalBytes - total else { throw Failure("The batch exceeds 64 GiB.") }
            let index = entries.count
            entries.append(Entry(parent: parent, name: name, directory: directory, bytes: size,
                                 executable: !directory && info.st_mode & 0o111 != 0, modified: Int64(info.st_mtimespec.tv_sec)))
            sources.append(Source(path: path, info: info))
            total += size
            guard directory else { return }
            try TidalTransferDisk.eachName(in: fd) { child in
                try visit(path: path + "/" + child, name: child, parent: index, depth: depth + 1, relativeTo: fd)
            }
        }
    }

    /// Inspect before requesting receiver consent or creating anything on disk.
    static func inspect(_ manifest: Data) throws -> (count: Int, total: Int64) {
        let (_, tree) = try decode(manifest)
        return (tree.paths.count, tree.total)
    }

    struct Tree {
        let paths: [String]
        let total: Int64
    }

    static func valid(name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains(":") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func decode(_ data: Data) throws -> ([Entry], Tree) {
        guard !data.isEmpty, data.count <= maxManifestBytes else { throw Failure("The batch manifest is too large or empty.") }
        let entries = try JSONDecoder().decode(LimitedEntries.self, from: data).entries
        return try (entries, validate(entries))
    }

    private struct LimitedEntries: Decodable {
        let entries: [Entry]
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            guard let count = container.count, (1...maxEntries).contains(count) else {
                throw Failure("The batch entry count is outside the allowed range.")
            }
            var result: [Entry] = []
            result.reserveCapacity(count)
            while !container.isAtEnd { result.append(try container.decode(Entry.self)) }
            entries = result
        }
    }

    private static func validate(_ entries: [Entry]) throws -> Tree {
        guard (1...maxEntries).contains(entries.count) else { throw Failure("Choose between 1 and 50,000 entries per batch.") }
        var paths: [String] = [], depths: [Int] = []
        var names: Set<String> = []
        var total: Int64 = 0
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard valid(name: entry.name), entry.parent == -1 || (entry.parent >= 0 && entry.parent < index && entries[entry.parent].directory),
                  entry.bytes >= 0, entry.bytes <= maxTotalBytes - total,
                  !entry.directory || (entry.bytes == 0 && !entry.executable) else { throw Failure("The batch has an invalid entry.") }
            let canonical = entry.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
            guard names.insert("\(entry.parent):\(canonical)").inserted else { throw Failure("Two items would have the same name in the same folder.") }
            let depth = entry.parent == -1 ? 1 : depths[entry.parent] + 1
            let path = entry.parent == -1 ? entry.name : paths[entry.parent] + "/" + entry.name
            guard depth <= 64, path.utf8.count < Int(PATH_MAX) else { throw Failure("A folder path in this batch is too long.") }
            depths.append(depth)
            paths.append(path)
            total += entry.bytes
        }
        return Tree(paths: paths, total: total)
    }

    /// Pack across file boundaries. A directory of small files therefore needs
    /// one write per MiB, not one networking operation per file.
    static func send(_ plan: Plan, write: (Data) async throws -> Void, progress: (Int64) -> Void = { _ in }) async throws {
        var buffer = Data(), sent: Int64 = 0
        buffer.reserveCapacity(chunkBytes)
        for (index, entry) in plan.entries.enumerated() where !entry.directory {
            try Task.checkCancellation()
            let source = plan.sources[index]
            let fd = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
            guard fd >= 0 else { throw TidalTransferDisk.error(entry.name) }
            defer { close(fd) }
            var info = stat()
            let changed = Failure("“\(entry.name)” changed during the transfer. Try again when it has finished saving.")
            guard fstat(fd, &info) == 0, source.matches(info, entry: entry) else { throw changed }
            var remaining = entry.bytes
            while remaining > 0 {
                try Task.checkCancellation()
                let count = min(chunkBytes - buffer.count, Int(remaining))
                let start = buffer.count
                buffer.count += count
                let copied = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    return Darwin.read(fd, base.advanced(by: start), count)
                }
                if copied < 0 {
                    buffer.count = start
                    if errno == EINTR { continue }
                    throw TidalTransferDisk.error(entry.name)
                }
                guard copied > 0 else { throw changed }
                buffer.count = start + copied
                remaining -= Int64(copied)
                if buffer.count == chunkBytes {
                    try await write(buffer)
                    sent += Int64(buffer.count)
                    progress(sent)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            guard fstat(fd, &info) == 0, source.matches(info, entry: entry) else { throw changed }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty { try await write(buffer); sent += Int64(buffer.count) }
        progress(sent)
    }
}
