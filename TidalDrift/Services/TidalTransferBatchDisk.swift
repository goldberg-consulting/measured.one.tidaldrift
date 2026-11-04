import Darwin
import Foundation

/// POSIX operations used by the peer batch codec. Incoming paths are relative
/// to a private staging descriptor and never interpreted as shell commands.
enum TidalTransferDisk {
    static func error(_ name: String, code: Int32 = errno) -> TidalTransferBatch.Failure {
        .init("Could not copy “\(name)”: \(String(cString: strerror(code))).")
    }

    static func isPinned(_ fd: Int32, in parent: Int32, named name: String) -> Bool {
        var opened = stat(), linked = stat()
        return fstat(fd, &opened) == 0 && fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0
            && opened.st_dev == linked.st_dev && opened.st_ino == linked.st_ino
    }

    static func makePrivateDirectory(in parent: Int32, named name: String) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 else { throw error(name) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error(name) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              isPinned(fd, in: parent, named: name) else {
            close(fd)
            throw TidalTransferBatch.Failure("The receiving folder could not provide private staging.")
        }
        return fd
    }

    static func checkFork(_ fd: Int32, name: String) throws {
        let size = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
        if size > 0 { throw TidalTransferBatch.Failure("“\(name)” has a resource fork. Choose a folder destination to preserve it.") }
        if size < 0, errno != ENOATTR, errno != ENOTSUP { throw error(name) }
    }

    static func eachName(in fd: Int32, visit: (String) throws -> Void) throws {
        let copy = dup(fd)
        guard copy >= 0 else { throw error("folder") }
        guard let directory = fdopendir(copy) else {
            let failure = error("folder")
            close(copy)
            throw failure
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw error("folder") }
                return
            }
            let size = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: size + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw TidalTransferBatch.Failure("A filename cannot be represented as UTF-8.") }
            if name != ".", name != ".." { try visit(name) }
        }
    }

    /// Received files are private to the receiving user. Only the ordinary
    /// executable bit is restored. Never copy ownership, ACLs or privilege bits.
    static func finish(_ fd: Int32, entry: TidalTransferBatch.Entry, quarantine: String) throws {
        if entry.executable, fchmod(fd, 0o700) != 0 { throw error(entry.name) }
        guard quarantine.withCString({ fsetxattr(fd, "com.apple.quarantine", $0, quarantine.utf8.count, 0, 0) }) == 0 else {
            throw error(entry.name)
        }
        let timestamp = timespec(tv_sec: Int(entry.modified), tv_nsec: 0)
        let times = [timestamp, timestamp]
        guard futimens(fd, times) == 0 else { throw error(entry.name) }
    }

    static func write(_ data: Data, range: Range<Int>, to fd: Int32, name: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = range.lowerBound
            while offset < range.upperBound {
                let count = Darwin.write(fd, base.advanced(by: offset), range.upperBound - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw error(name) }
                offset += count
            }
        }
    }
}

extension TidalTransferBatch {
    /// Read a batch into a private folder. The final callback must verify that
    /// the sender finished successfully before the exclusive atomic rename.
    static func receive(manifest: Data, into folder: URL, read: (Int) async throws -> Data,
                        progress: (Int64) -> Void = { _ in }, verifyEnd: () async throws -> Void = {}) async throws -> URL {
        let (entries, tree) = try decode(manifest)
        let destination = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw TidalTransferDisk.error(folder.lastPathComponent) }
        defer { close(destination) }
        var volume = statfs()
        guard fstatfs(destination, &volume) == 0 else { throw TidalTransferDisk.error(folder.lastPathComponent) }
        let space = Double(volume.f_bavail) * Double(volume.f_bsize)
        guard space > Double(tree.total) + Double(entries.count) * Double(volume.f_bsize) else {
            throw Failure("There is not enough free space in the receiving folder.")
        }
        let temporary = ".tidal-transfer-" + UUID().uuidString
        // Other users may have rename access in a shared drop folder. Pin
        // the owner-only workspace: its public name is never a publication
        // source or a recursive cleanup target.
        let work = try TidalTransferDisk.makePrivateDirectory(in: destination, named: temporary)
        defer {
            if TidalTransferDisk.isPinned(work, in: destination, named: temporary) {
                _ = unlinkat(destination, temporary, AT_REMOVEDIR)
            }
            close(work)
        }
        let payload = "payload"
        let stage = try TidalTransferDisk.makePrivateDirectory(in: work, named: payload)
        var published = false
        defer {
            if !published, TidalTransferDisk.isPinned(stage, in: work, named: payload) {
                _ = removefileat(work, payload, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))
            }
            close(stage)
        }
        let epoch = Int(Date().timeIntervalSince1970)
        let quarantine = "0081;\(String(epoch, radix: 16));TidalDrift;\(UUID().uuidString)"
        var chunk = Data(), position = 0, received: Int64 = 0

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let path = tree.paths[index]
            if entry.directory {
                // mkdirat has no no-follow option: pin the verified parent
                // before creating its child, even if the stage is moved.
                let parent = entry.parent == -1 ? dup(stage) :
                    openat(stage, tree.paths[entry.parent], O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                guard parent >= 0 else { throw TidalTransferDisk.error(entry.name) }
                defer { close(parent) }
                guard mkdirat(parent, entry.name, 0o700) == 0 else { throw TidalTransferDisk.error(entry.name) }
                continue
            }
            let fd = openat(stage, path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw TidalTransferDisk.error(entry.name) }
            // Observe close failures from e.g. an SMB destination reporting a
            // delayed I/O error. On any error the entire private batch is removed.
            var needsClose = true
            defer { if needsClose { close(fd) } }
            var remaining = entry.bytes
            while remaining > 0 {
                try Task.checkCancellation()
                if position == chunk.count {
                    let count = min(chunkBytes, Int(tree.total - received))
                    chunk = try await read(count)
                    guard chunk.count == count else { throw Failure("The sender disconnected before the batch was complete.") }
                    position = 0
                }
                let count = min(chunk.count - position, Int(remaining))
                try TidalTransferDisk.write(chunk, range: position..<(position + count), to: fd, name: entry.name)
                position += count
                remaining -= Int64(count)
                received += Int64(count)
                if position == chunk.count { progress(received) }
            }
            try TidalTransferDisk.finish(fd, entry: entry, quarantine: quarantine)
            needsClose = false
            guard close(fd) == 0 else { throw TidalTransferDisk.error(entry.name) }
        }
        // Creating children changes directory timestamps. Restore them last.
        for index in entries.indices.reversed() where entries[index].directory {
            try Task.checkCancellation()
            let fd = openat(stage, tree.paths[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { throw TidalTransferDisk.error(entries[index].name) }
            defer { close(fd) }
            try TidalTransferDisk.finish(fd, entry: entries[index], quarantine: quarantine)
        }
        try Task.checkCancellation()
        try await verifyEnd()
        try Task.checkCancellation()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Tidal Transfer " + formatter.string(from: Date())
        for suffix in 1...10_000 {
            let name = suffix == 1 ? base : "\(base) (\(suffix))"
            guard TidalTransferDisk.isPinned(destination, in: AT_FDCWD, named: folder.path),
                  TidalTransferDisk.isPinned(work, in: destination, named: temporary),
                  TidalTransferDisk.isPinned(stage, in: work, named: payload) else {
                throw Failure("The receiving folder changed during the transfer. No batch was published.")
            }
            if renameatx_np(work, payload, destination, name, UInt32(RENAME_EXCL)) == 0 {
                published = true
                progress(received)
                return folder.appendingPathComponent(name, isDirectory: true)
            }
            guard errno == EEXIST else { throw TidalTransferDisk.error(name) }
        }
        throw Failure("Could not find a free name for the received batch.")
    }
}
