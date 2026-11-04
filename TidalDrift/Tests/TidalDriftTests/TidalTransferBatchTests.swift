import Darwin
import Foundation
import XCTest
@testable import TidalDrift

final class TidalTransferBatchTests: XCTestCase {
    private typealias Batch = TidalTransferBatch

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(_ name: String, _ parent: Int = -1, bytes: Int64 = 0, directory: Bool = false) -> Batch.Entry {
        Batch.Entry(parent: parent, name: name, directory: directory, bytes: bytes, executable: false, modified: 1_600_000_000)
    }

    func test_manyFilesShareWireWritesAndRoundTripIncludingEmptyDirectories() async throws {
        let base = try fixture(), tree = base.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        for index in 0..<400 { try payload.write(to: tree.appendingPathComponent("\(index).bin")) }
        let empty = tree.appendingPathComponent(".empty")
        try Data().write(to: empty)
        let script = tree.appendingPathComponent("run")
        try Data("echo yes".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: Date(timeIntervalSince1970: 1_670_000_321)], ofItemAtPath: script.path)

        let plan = try Batch.plan([tree]), advertised = try Batch.inspect(plan.manifest)
        XCTAssertEqual(advertised.count, 404)
        XCTAssertEqual(advertised.total, 1_200_008)
        var chunks: [Data] = []
        try await Batch.send(plan, write: { chunks.append($0) })
        XCTAssertEqual(chunks.map(\.count), [Batch.chunkBytes, 1_200_008 - Batch.chunkBytes])
        let received = try await Batch.receive(manifest: plan.manifest, into: base, read: { count in
            let data = chunks.removeFirst()
            XCTAssertEqual(data.count, count)
            return data
        })
        let copy = received.appendingPathComponent("bundle")
        for index in 0..<400 {
            XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("\(index).bin")), payload)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: copy.appendingPathComponent("empty").path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent(".empty")), Data())
        let output = copy.appendingPathComponent("run")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: output.path))
        let metadata = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(metadata[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_670_000_321))
        XCTAssertGreaterThan(getxattr(output.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
    }

    func test_zeroByteTransfersPublishOnlyOnCommitAndNeverReplaceEachOther() async throws {
        let dest = try fixture()
        let manifest = try JSONEncoder().encode([entry("empty")])
        let noRead: (Int) async throws -> Data = { _ in XCTFail("No payload expected"); return Data() }
        do {
            _ = try await Batch.receive(manifest: manifest, into: dest, read: noRead, verifyEnd: { throw CancellationError() })
            XCTFail("Missing commit published")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [])
        let first = try await Batch.receive(manifest: manifest, into: dest, read: noRead)
        let second = try await Batch.receive(manifest: manifest, into: dest, read: noRead)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("empty").path))
    }

    func test_rejectsTraversalCollisionsInvalidParentsAndOversizedOffers() throws {
        for invalid in [[entry("../wrong")], [entry("a/b")], [entry("..")], [entry("x\u{0}")],
                        [entry("a", 0)], [entry("a"), entry("b", 0)], [entry("x", -2)],
                        [entry("café"), entry("CAFE\u{301}")], [entry("a"), entry("a")],
                        [entry("huge", bytes: .max)], [entry("bad", bytes: -1)],
                        [entry("folder", bytes: 1, directory: true)]] {
            XCTAssertThrowsError(try Batch.inspect(JSONEncoder().encode(invalid)))
        }
        XCTAssertThrowsError(try Batch.inspect(Data(repeating: 0, count: Batch.maxManifestBytes + 1)))
    }

    func test_linkAndRegularFileSubstitutionsCannotRedirectSend() async throws {
        let base = try fixture(), tree = base.appendingPathComponent("tree"), name = tree.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("hello".utf8).write(to: name)
        let plan = try Batch.plan([tree])
        let moved = base.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: tree, to: moved)
        try FileManager.default.createSymbolicLink(at: tree, withDestinationURL: moved)
        XCTAssertThrowsError(try Batch.plan([tree]))
        do {
            try await Batch.send(plan, write: { _ in XCTFail("Symlink followed") })
            XCTFail("Symlink followed")
        } catch {}
        try FileManager.default.removeItem(at: tree)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("other".utf8).write(to: name)
        do {
            try await Batch.send(plan, write: { _ in XCTFail("Sent substituted source") })
            XCTFail("Sent substituted source")
        } catch {}
    }

    func test_shortReadAndCancellationRemoveStage() async throws {
        let dest = try fixture(), manifest = try JSONEncoder().encode([entry("dir", directory: true), entry("part", 0, bytes: 30)])
        do {
            _ = try await Batch.receive(manifest: manifest, into: dest, read: { _ in Data(count: 15) })
            XCTFail("Published a partial batch")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [])
        do {
            _ = try await Batch.receive(manifest: manifest, into: dest, read: { _ in throw CancellationError() })
            XCTFail("Published a cancelled batch")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [])
    }

    func test_cleanupCannotFollowParentLinkOrRemoveUnrelatedContents() throws {
        let fm = FileManager.default, dest = try fixture(), outside = try fixture()
        try Data([42]).write(to: outside.appendingPathComponent("keep"))
        try fm.createSymbolicLink(at: dest.appendingPathComponent("dir"), withDestinationURL: outside)
        let fd = open(dest.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertFalse(TidalTransferDisk.removeEntry("dir/keep", from: fd, directory: false))
        XCTAssertFalse(TidalTransferDisk.removeEntry("../keep", from: fd, directory: false))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data([42]))
        let unexpected = dest.appendingPathComponent("unexpected")
        try fm.createDirectory(at: unexpected, withIntermediateDirectories: false)
        try Data([7]).write(to: unexpected.appendingPathComponent("unlisted"))
        XCTAssertFalse(TidalTransferDisk.removeEntry("unexpected", from: fd, directory: true))
        XCTAssertEqual(try Data(contentsOf: unexpected.appendingPathComponent("unlisted")), Data([7]))
    }

    func test_workspaceReplacementIsNeverPublishedOrRecursivelyRemoved() async throws {
        let fm = FileManager.default
        let manifest = try JSONEncoder().encode([entry("received", bytes: 1)])
        for cancel in [false, true] {
            let dest = try fixture()
            let moved = dest.appendingPathComponent("moved-workspace")
            var replacementMarker: URL?
            do {
                _ = try await Batch.receive(manifest: manifest, into: dest, read: { _ in Data([1]) }, verifyEnd: {
                    let stage = try XCTUnwrap(fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil).first)
                    try fm.moveItem(at: stage, to: moved)
                    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                    let marker = stage.appendingPathComponent("unrelated")
                    try Data([2]).write(to: marker)
                    replacementMarker = marker
                    if cancel { throw CancellationError() }
                })
                XCTFail("Published from a replaced workspace")
            } catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains("receiving folder changed")) }
            }
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacementMarker)), Data([2]))
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: moved.path).isEmpty, "Discard private payload using the original fd")
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: dest.path).count, 2, "Never publish the attacker's tree")
        }
    }

    func test_resourceForkAndSpecialFileAreNotSilentlyDiscarded() throws {
        let base = try fixture(), file = base.appendingPathComponent("fork"), fifo = base.appendingPathComponent("pipe")
        try Data().write(to: file)
        XCTAssertEqual("resource".withCString { setxattr(file.path, "com.apple.ResourceFork", $0, 8, 0, 0) }, 0)
        XCTAssertThrowsError(try Batch.plan([file]))
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try Batch.plan([fifo]))
    }
}
