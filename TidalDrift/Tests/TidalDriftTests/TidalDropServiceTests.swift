import XCTest
@testable import TidalDrift

/// Receiver-side validation for the unauthenticated TidalDrop listener
/// (#144, #156): filename sanitization, sender filtering, and non-clobbering
/// destination selection.
final class TidalDropServiceTests: XCTestCase {

    func test_sanitizeFilename_rejectsPathsAndSpecials() {
        XCTAssertNil(TidalDropService.sanitizeFilename("/"), "'/' used to resolve to the drop folder itself")
        XCTAssertNil(TidalDropService.sanitizeFilename("a/b"))
        XCTAssertNil(TidalDropService.sanitizeFilename("../secret"))
        XCTAssertNil(TidalDropService.sanitizeFilename(".."))
        XCTAssertNil(TidalDropService.sanitizeFilename("."))
        XCTAssertNil(TidalDropService.sanitizeFilename(".hidden"))
        XCTAssertNil(TidalDropService.sanitizeFilename(""))
        XCTAssertNil(TidalDropService.sanitizeFilename("   "))
        XCTAssertNil(TidalDropService.sanitizeFilename("a:b"))
        XCTAssertNil(TidalDropService.sanitizeFilename("a\0b"))
        XCTAssertNil(TidalDropService.sanitizeFilename(String(repeating: "x", count: 256)))
    }

    func test_sanitizeFilename_acceptsPlainNames() {
        XCTAssertEqual(TidalDropService.sanitizeFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(TidalDropService.sanitizeFilename("  photo (1).jpg "), "photo (1).jpg")
        XCTAssertEqual(TidalDropService.sanitizeFilename("no-extension"), "no-extension")
    }

    func test_isAcceptableSender_localOnly() {
        XCTAssertTrue(TidalDropService.isAcceptableSender("127.0.0.1"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("::1"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("192.168.1.20"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("10.0.0.5"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("172.16.4.9"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("fe80::1c2a:3b4c"))
        XCTAssertTrue(TidalDropService.isAcceptableSender("fd12:3456::1"))
        XCTAssertFalse(TidalDropService.isAcceptableSender("8.8.8.8"))
        XCTAssertFalse(TidalDropService.isAcceptableSender("2001:4860:4860::8888"))
    }

    func test_uniqueDestination_neverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidaldrop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = TidalDropService.uniqueDestination(in: folder, for: "notes.txt")
        XCTAssertEqual(first.lastPathComponent, "notes.txt")
        try Data("a".utf8).write(to: first)

        let second = TidalDropService.uniqueDestination(in: folder, for: "notes.txt")
        XCTAssertEqual(second.lastPathComponent, "notes (1).txt")
        try Data("b".utf8).write(to: second)

        let third = TidalDropService.uniqueDestination(in: folder, for: "notes.txt")
        XCTAssertEqual(third.lastPathComponent, "notes (2).txt")

        let bare = TidalDropService.uniqueDestination(in: folder, for: "README")
        try Data("c".utf8).write(to: bare)
        XCTAssertEqual(TidalDropService.uniqueDestination(in: folder, for: "README").lastPathComponent, "README (1)")

        XCTAssertEqual(try Data(contentsOf: first), Data("a".utf8), "original file untouched")
    }
}
