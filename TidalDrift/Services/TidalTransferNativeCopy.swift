import Darwin
import Foundation

/// Native file data path shared by the bounded folder-copy workers.
enum TidalTransferNativeCopy {
    typealias Copy = TidalTransferFolderCopy

    static func copy(_ entry: Copy.Entry, stage: Int32, ledger: Copy.Ledger, tryClone: Bool = true) throws {
        if entry.kind == S_IFLNK {
            try copyLink(entry, stage: stage)
            ledger.update(name: entry.source.lastPathComponent, completed: 1)
            return
        }
        let input = try Copy.openSource(entry)
        defer { close(input) }
        var sourceInfo = stat()
        guard fstat(input, &sourceInfo) == 0, sourceInfo.st_size == entry.size else {
            throw Copy.Failure("“\(entry.source.lastPathComponent)” changed before it could be copied.")
        }
        var stageInfo = stat()
        guard fstat(stage, &stageInfo) == 0 else { throw Copy.failure(entry.source) }

        // Clone across a single capable volume, including copy-on-write data.
        // When bytes must cross a volume boundary the clone syscall is unnecessary.
        if tryClone, entry.device == stageInfo.st_dev,
           fclonefileat(input, stage, entry.relative, UInt32(CLONE_NOOWNERCOPY | CLONE_ACL)) == 0 {
            ledger.update(name: entry.source.lastPathComponent, bytes: entry.size, completed: 1)
            return
        }
        let output = openat(stage, entry.relative, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Copy.failure(entry.source) }
        var mustClose = true
        defer { if mustClose { close(output) } }
        let context = ChunkProgress(entry: entry, ledger: ledger)
        guard let state = copyfile_state_alloc() else { throw Copy.failure(entry.source) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, raw in
            guard !Task.isCancelled, stage != COPYFILE_ERR else { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state, let raw {
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    Unmanaged<ChunkProgress>.fromOpaque(raw).takeUnretainedValue().advance(to: copied)
                }
            }
            return COPYFILE_CONTINUE
        }
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque()) == 0
        else { throw Copy.failure(entry.source) }

        let result = fcopyfile(input, output, state, copyfile_flags_t(COPYFILE_ALL))
        let errorCode = errno
        try Task.checkCancellation()
        guard result == 0 else { throw Copy.failure(entry.source, code: errorCode) }
        var after = stat()
        guard fstat(input, &after) == 0, after.st_size == entry.size,
              after.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec else {
            throw Copy.Failure("“\(entry.source.lastPathComponent)” changed during the copy. Drop it again.")
        }
        // Network file systems can defer a storage error until close.
        mustClose = false
        guard close(output) == 0 else { throw Copy.failure(entry.source) }
        context.advance(to: entry.size)
        ledger.update(name: entry.source.lastPathComponent, completed: 1)
    }

    /// Retain the actual link text, including relative, absolute and dangling
    /// targets. No reads or writes use the link target as a path.
    private static func copyLink(_ entry: Copy.Entry, stage: Int32) throws {
        let directory = open(entry.source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw Copy.failure(entry.source) }
        defer { close(directory) }
        var info = stat()
        let name = entry.source.lastPathComponent
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_ino == entry.inode, info.st_dev == entry.device, info.st_mode & mode_t(S_IFMT) == S_IFLNK else {
            throw Copy.Failure("The link “\(name)” changed during the copy.")
        }
        var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(directory, name, &target, target.count - 1)
        guard count >= 0 else { throw Copy.failure(entry.source) }
        guard count < target.count - 1 else { throw Copy.Failure("The link “\(name)” is too long to copy safely.") }
        target[count] = 0
        guard symlinkat(target, stage, entry.relative) == 0 else { throw Copy.failure(entry.source) }
    }

    // Only one synchronous fcopyfile invocation owns this callback context.
    private final class ChunkProgress {
        let entry: Copy.Entry
        let ledger: Copy.Ledger
        var accounted: Int64 = 0
        init(entry: Copy.Entry, ledger: Copy.Ledger) { self.entry = entry; self.ledger = ledger }

        func advance(to offset: Int64) {
            let latest = min(entry.size, max(accounted, offset))
            if latest > accounted {
                ledger.update(name: entry.source.lastPathComponent, bytes: latest - accounted)
                accounted = latest
            }
        }
    }
}
