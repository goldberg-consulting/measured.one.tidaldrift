import ApplicationServices
import XCTest
@testable import TidalDrift

final class RemoteFileDropTests: XCTestCase {
    private let manager = FileManager.default

    func test_validateVisibleWindow_whenExpectedWindowIsExposed_expectsSuccess() throws {
        let target = RemoteFileDrop.WindowSnapshot(
            id: 100, ownerPID: 10, bounds: CGRect(x: 100, y: 200, width: 400, height: 300), alpha: 1)

        let result = try RemoteFileDrop.validateVisibleWindow(
            at: CGPoint(x: 150, y: 250), expectedWindowID: 100, windows: [target])

        XCTAssertEqual(result.id, 100)
        XCTAssertEqual(result.ownerPID, 10)
    }

    func test_validateVisibleWindow_whenAnotherFinderWindowCoversTarget_expectsRejection() {
        let bounds = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            RemoteFileDrop.WindowSnapshot(id: 101, ownerPID: 10, bounds: bounds, alpha: 1),
            RemoteFileDrop.WindowSnapshot(id: 100, ownerPID: 10, bounds: bounds, alpha: 1)
        ]

        XCTAssertThrowsError(try RemoteFileDrop.validateVisibleWindow(
            at: CGPoint(x: 150, y: 250), expectedWindowID: 100, windows: windows))
    }

    func test_validateVisibleWindow_whenAnotherAppOverlayCoversTarget_expectsRejection() {
        let bounds = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            RemoteFileDrop.WindowSnapshot(id: 200, ownerPID: 20, bounds: bounds, alpha: 0.1),
            RemoteFileDrop.WindowSnapshot(id: 100, ownerPID: 10, bounds: bounds, alpha: 1)
        ]

        XCTAssertThrowsError(try RemoteFileDrop.validateVisibleWindow(
            at: CGPoint(x: 150, y: 250), expectedWindowID: 100, windows: windows))
    }

    func test_validateVisibleWindow_whenOnlyTransparentOrNonIntersectingWindowsAreAbove_expectsSuccess() throws {
        let targetBounds = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            RemoteFileDrop.WindowSnapshot(id: 200, ownerPID: 20, bounds: targetBounds, alpha: 0),
            RemoteFileDrop.WindowSnapshot(id: 101, ownerPID: 10,
                                         bounds: CGRect(x: 600, y: 200, width: 400, height: 300), alpha: 1),
            RemoteFileDrop.WindowSnapshot(id: 100, ownerPID: 10, bounds: targetBounds, alpha: 1)
        ]

        XCTAssertNoThrow(try RemoteFileDrop.validateVisibleWindow(
            at: CGPoint(x: 150, y: 250), expectedWindowID: 100, windows: windows))
    }

    func test_validateVisibleWindow_whenExpectedWindowIsAbsent_expectsRejection() {
        XCTAssertThrowsError(try RemoteFileDrop.validateVisibleWindow(
            at: CGPoint(x: 150, y: 250), expectedWindowID: 100, windows: []))
        let target = RemoteFileDrop.WindowSnapshot(
            id: 100, ownerPID: 10, bounds: CGRect(x: 100, y: 200, width: 400, height: 300), alpha: 1)
        XCTAssertThrowsError(try RemoteFileDrop.validateVisibleWindow(
            at: .zero, expectedWindowID: 100, windows: [target]))
    }

    func test_resolve_whenHitIsFolderInsideFinderWindow_expectsClosestFolder() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let child = root.appendingPathComponent("Nested", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: false)

        let destination = try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXRowRole as String, documentURL: nil, itemURL: child),
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ]))

        XCTAssertEqual(destination.directoryURL, child.resolvingSymlinksInPath())
    }

    func test_resolve_whenContentHasNoURL_expectsItsFinderWindowFolder() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }

        let destination = try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXScrollAreaRole as String, documentURL: nil, itemURL: nil),
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ]))

        XCTAssertEqual(destination.directoryURL, root.resolvingSymlinksInPath())
    }

    func test_resolve_whenTargetIsAnotherApp_expectsRejection() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }

        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: false, ancestry: [
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ])))
    }

    func test_resolve_whenAncestryHasNoWindow_expectsRejection() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }

        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXApplicationRole as String, documentURL: root, itemURL: nil)
        ])))
    }

    func test_resolve_whenWindowIsSearchView_expectsNoArbitraryFolderFallback() throws {
        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXWindowRole as String, documentURL: URL(string: "search://recent"), itemURL: nil)
        ])))
    }

    func test_resolve_whenHitIsFileIcon_expectsNoWindowFolderFallback() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("document.txt")
        try Data("existing document".utf8).write(to: file)

        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXImageRole as String, documentURL: nil, itemURL: file),
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ])))
    }

    func test_resolve_whenHitFolderDisappeared_expectsNoWindowFolderFallback() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }

        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXRowRole as String, documentURL: nil, itemURL: root.appendingPathComponent("Missing")),
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ])))
    }

    func test_resolve_whenHitHasNonFileURL_expectsNoWindowFolderFallback() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }

        XCTAssertThrowsError(try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXRowRole as String, documentURL: nil, itemURL: URL(string: "search://recent")),
            .init(role: kAXWindowRole as String, documentURL: root, itemURL: nil)
        ])))
    }

    func test_deliver_whenDestinationCapturedBeforeOtherWindow_expectsOriginalFolder() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let original = try makeDirectory("Original", in: root)
        let other = try makeDirectory("Other", in: root)
        let source = root.appendingPathComponent("report.txt")
        try Data("verified content".utf8).write(to: source)
        let captured = try destination(for: original)
        _ = try destination(for: other)

        let urls = try RemoteFileDrop.deliver([source], to: captured)

        XCTAssertEqual(urls, [original.appendingPathComponent("report.txt").resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data("verified content".utf8))
        XCTAssertFalse(manager.fileExists(atPath: other.appendingPathComponent("report.txt").path))
        XCTAssertTrue(manager.fileExists(atPath: source.path), "delivery leaves cleanup of staging to its owner")
    }

    func test_deliver_whenNameCollidesWithFileAndSymlink_expectsUniqueNameAndNoOverwrite() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let folder = try makeDirectory("Target", in: root)
        let source = root.appendingPathComponent("notes.txt")
        let existing = folder.appendingPathComponent("notes.txt")
        try Data("new".utf8).write(to: source)
        try Data("original".utf8).write(to: existing)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("notes (1).txt"), withDestinationURL: existing)

        let urls = try RemoteFileDrop.deliver([source], to: destination(for: folder))

        XCTAssertEqual(urls.first?.lastPathComponent, "notes (2).txt")
        XCTAssertEqual(try Data(contentsOf: existing), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data("new".utf8))
        XCTAssertFalse(try manager.contentsOfDirectory(atPath: folder.path).contains(where: { $0.hasPrefix(".localcast-") }))
    }

    func test_deliver_whenFolderIsReplacedAfterOffer_expectsRejection() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let folder = try makeDirectory("Target", in: root)
        let captured = try destination(for: folder)
        let source = root.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)
        try manager.moveItem(at: folder, to: root.appendingPathComponent("Moved"))
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)

        XCTAssertThrowsError(try RemoteFileDrop.deliver([source], to: captured)) { error in
            guard case RemoteFileDrop.DropError.destinationChanged = error else {
                return XCTFail("Expected stale destination rejection, got \(error)")
            }
        }
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func test_deliver_whenSourceIsSymbolicLink_expectsRejectionAndNoFiles() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let folder = try makeDirectory("Target", in: root)
        let source = root.appendingPathComponent("original.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("private".utf8).write(to: source)
        try manager.createSymbolicLink(at: link, withDestinationURL: source)

        XCTAssertThrowsError(try RemoteFileDrop.deliver([link], to: destination(for: folder)))
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func test_deliver_whenLaterFileIsInvalid_expectsExplicitPartialCount() throws {
        let root = try temporaryDirectory()
        defer { try? manager.removeItem(at: root) }
        let folder = try makeDirectory("Target", in: root)
        let source = root.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)

        XCTAssertThrowsError(try RemoteFileDrop.deliver([source, root], to: destination(for: folder))) { error in
            guard case RemoteFileDrop.DropError.deliveryFailed(let completed, _) = error else {
                return XCTFail("Expected a delivery failure, got \(error)")
            }
            XCTAssertEqual(completed, 1)
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("report.txt")), Data("new".utf8))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path), ["report.txt"])
    }

    private func temporaryDirectory() throws -> URL {
        let root = manager.temporaryDirectory.appendingPathComponent("localcast-drop-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(_ name: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func destination(for folder: URL) throws -> RemoteFileDrop.Destination {
        try RemoteFileDrop.resolve(snapshot: .init(isFinder: true, ancestry: [
            .init(role: kAXWindowRole as String, documentURL: folder, itemURL: nil)
        ]))
    }
}
