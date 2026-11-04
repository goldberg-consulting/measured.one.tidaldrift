import Darwin
import Foundation
import os
import XCTest
@testable import TidalDrift

final class TidalTransferFolderCopyTests: XCTestCase {
    private let files = FileManager.default

    private func sandbox() throws -> URL {
        let url = files.temporaryDirectory.appendingPathComponent("tidal-copy-test-" + UUID().uuidString)
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testFolderCopyKeepsBothNamesAndPreservesLinksAndMetadata() async throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("Album")
        let empty = source.appendingPathComponent("empty")
        let dest = root.appendingPathComponent("dest")
        try files.createDirectory(at: empty, withIntermediateDirectories: true)
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        let original = source.appendingPathComponent(".settings")
        let content = Data("ordinary file".utf8)
        try content.write(to: original)
        let timestamp = Date(timeIntervalSince1970: 1_600_000_000)
        try files.setAttributes([.posixPermissions: 0o640, .modificationDate: timestamp], ofItemAtPath: original.path)
        let xattr = "com.tidaldrift.transfer-test"
        XCTAssertEqual(original.path.withCString { path in
            content.withUnsafeBytes { setxattr(path, xattr, $0.baseAddress, $0.count, 0, 0) }
        }, 0)
        try files.createSymbolicLink(atPath: source.appendingPathComponent("dangling").path, withDestinationPath: "../missing")
        let existing = dest.appendingPathComponent("Album")
        try files.createSymbolicLink(atPath: existing.path, withDestinationPath: "../do-not-replace")
        let seen = OSAllocatedUnfairLock<TidalTransferFolderCopy.Progress?>(initialState: nil)
        let saved = try await TidalTransferFolderCopy.copy([source], to: dest) { value in seen.withLock { $0 = value } }
        let copy = try XCTUnwrap(saved.first)
        XCTAssertEqual(copy.lastPathComponent, "Album (1)")
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: existing.path), "../do-not-replace")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: copy.appendingPathComponent("empty").path), [])
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("dangling").path), "../missing")
        let copiedFile = copy.appendingPathComponent(".settings")
        XCTAssertEqual(try Data(contentsOf: copiedFile), content)
        let attributes = try files.attributesOfItem(atPath: copiedFile.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, timestamp)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(getxattr(copiedFile.path, xattr, nil, 0, 0, 0), content.count)
        let last = try XCTUnwrap(seen.withLock { $0 })
        XCTAssertEqual(last.totalItems, 4)
        XCTAssertEqual(last.completedItems, last.totalItems)
        XCTAssertEqual(last.bytesCopied, Int64(content.count))
    }

    func testDestinationAliasCannotCopyFolderIntoItself() async throws {
        let root = try sandbox()
        let inside = root.appendingPathComponent("album/photos")
        try files.createDirectory(at: inside, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("dest")
        try files.createSymbolicLink(at: alias, withDestinationURL: inside)
        do {
            _ = try await TidalTransferFolderCopy.copy([root.appendingPathComponent("album")], to: alias)
            XCTFail("A destination alias pointing inside the source must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside"))
        }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: inside.path), [])
    }

    func testChangedSourceRollsBackTheUnpublishedBatch() async throws {
        let root = try sandbox()
        let dest = root.appendingPathComponent("out")
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let nested = first.appendingPathComponent("nested/deeper")
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: nested.appendingPathComponent("data"))
        try Data("goodbye".utf8).write(to: second)
        do {
            _ = try await TidalTransferFolderCopy.copy([first, second], to: dest) { tick in
                if tick.completedItems == 0 { try? FileManager.default.removeItem(at: second) }
            }
            XCTFail("A vanished source must fail the batch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("second"))
        }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dest.path), [])
        XCTAssertTrue(files.fileExists(atPath: first.path))
    }

    func testCancellationLeavesNoPartialItems() async throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("file.txt")
        let dest = root.appendingPathComponent("out")
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: source)
        let copy = Task {
            try await TidalTransferFolderCopy.copy([source], to: dest) { tick in
                if tick.completedItems == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await copy.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dest.path), [])
    }

    func testConcurrentBatchesPublishDistinctNames() async throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("notes.txt")
        let dest = root.appendingPathComponent("out")
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: source)
        async let first = TidalTransferFolderCopy.copy([source], to: dest)
        async let second = TidalTransferFolderCopy.copy([source], to: dest)
        let outputs = try await first + second
        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), ["notes.txt", "notes (1).txt"])
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dest.path).count, 2)
    }

    func testLockedRootDeclinesBeforePublishingEarlierSelections() async throws {
        let root = try sandbox()
        let first = root.appendingPathComponent("first")
        let locked = root.appendingPathComponent("locked")
        let dest = root.appendingPathComponent("out")
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: locked)
        try XCTSkipUnless(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0, "The volume must support the Finder Locked flag.")
        defer { _ = chflags(locked.path, 0) }
        do {
            _ = try await TidalTransferFolderCopy.copy([first, locked], to: dest)
            XCTFail("A locked top-level item cannot safely publish under its final name")
        } catch { XCTAssertTrue(error.localizedDescription.contains("is locked")) }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dest.path), [])
    }

    func testCleanupKeepsPublishedSelectionWhenLaterStagedCopyIsLocked() async throws {
        let root = try sandbox()
        let first = root.appendingPathComponent("first")
        let locked = root.appendingPathComponent("locked")
        let dest = root.appendingPathComponent("out")
        try files.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: locked)
        try XCTSkipUnless(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0, "The volume must support the Finder Locked flag.")
        XCTAssertEqual(chflags(locked.path, 0), 0)
        defer { _ = chflags(locked.path, 0) }
        do {
            // A concurrent Finder lock after preflight is preserved by the
            // native clone. The second rename fails after the first succeeds.
            _ = try await TidalTransferFolderCopy.copy([first, locked], to: dest) { tick in
                if tick.completedItems == 0 { _ = chflags(locked.path, UInt32(UF_IMMUTABLE)) }
            }
            XCTFail("Publishing the locked staged copy must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Copied 1 of 2"))
            XCTAssertFalse(error.localizedDescription.contains("could not be fully cleaned up"))
        }
        XCTAssertEqual(try files.contentsOfDirectory(atPath: dest.path), ["first"])
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("first")), Data("first".utf8))
    }

    func testNativeDataCopyWithoutClonePreservesPayloadAndReportsBytes() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("file.bin")
        let content = Data(repeating: 0x55, count: 5 * 1024 * 1024)
        try content.write(to: source)
        var info = stat()
        XCTAssertEqual(lstat(source.path, &info), 0)
        guard let path = realpath(source.path, nil) else { throw CocoaError(.fileReadUnknown) }
        defer { free(path) }
        let physicalSource = URL(fileURLWithPath: String(cString: path))
        let entry = TidalTransferFolderCopy.Entry(source: physicalSource, relative: "copy.bin", kind: mode_t(S_IFREG),
                                                  device: info.st_dev, inode: info.st_ino, size: info.st_size)
        let observed = OSAllocatedUnfairLock(initialState: [Int64]())
        let ledger = TidalTransferFolderCopy.Ledger(entries: [entry]) { tick in
            observed.withLock { $0.append(tick.bytesCopied) }
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(fd) }
        try TidalTransferNativeCopy.copy(entry, stage: fd, ledger: ledger, tryClone: false)
        ledger.update(name: nil, force: true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy.bin")), content)
        let counts = observed.withLock { $0 }
        XCTAssertEqual(counts.last, Int64(content.count))
        XCTAssertGreaterThan(try XCTUnwrap(counts.first), 0)
    }
}
