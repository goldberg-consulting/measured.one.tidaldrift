import AppKit
import XCTest
@testable import TidalDrift

final class ClipboardRecoveryTests: XCTestCase {
    @MainActor
    private func textPayload(_ text: String, html: Data? = nil, bulk: ClipboardBulkOffer? = nil) -> ClipboardUpdatePayload {
        ClipboardUpdatePayload(
            updateId: UUID(), kind: .text, text: bulk == nil ? text : nil, rtf: nil,
            html: bulk == nil ? html : nil, png: nil, bulk: bulk,
            digest: ClipboardPasteboard.textDigest(text: text, rtf: nil, html: html)
        )
    }

    @MainActor
    func test_htmlRoundTrip_whenRichTextCopied_preservesOriginalRepresentations() throws {
        let source = NSPasteboard.withUniqueName()
        let destination = NSPasteboard.withUniqueName()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let html = Data("<b>Hello</b> <a href='https://example.com'>world</a>".utf8)
        source.clearContents()
        source.setString("Hello world", forType: .string)
        source.setData(html, forType: .html)
        let snapshot = try XCTUnwrap(ClipboardPasteboard.capture(from: source))
        XCTAssertEqual(snapshot.html, html)
        ClipboardPasteboard.applyInline(kind: .text, text: snapshot.text, rtf: snapshot.rtf,
                                        html: snapshot.html, png: nil, to: destination)
        let copied = try XCTUnwrap(ClipboardPasteboard.capture(from: destination))
        XCTAssertEqual(copied.html, html)
        XCTAssertEqual(copied.digest, snapshot.digest)
    }

    @MainActor
    func test_invalidImage_whenApplied_preservesExistingClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("local copy", forType: .string)
        let count = pasteboard.changeCount
        ClipboardPasteboard.applyInline(kind: .image, text: nil, rtf: nil,
                                        png: Data("invalid".utf8), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "local copy")
        XCTAssertEqual(pasteboard.changeCount, count)
    }

    @MainActor
    func test_eagerCompletion_whenLocalCopyArrivesBeforePoll_preservesLocalCopy() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isSyncEnabled: { true })
        defer { engine.stop() }
        var completion: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in completion = callback }
        engine.isBulkSyncAllowed = { true }
        engine.start()
        let text = "remote image caption"
        let data = try JSONEncoder().encode(ClipboardTextContent(text: text, rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 7, count: 32), totalBytes: Int64(data.count), files: nil)
        engine.handleRemoteUpdate(textPayload(text, bulk: offer))
        XCTAssertNotNil(completion)
        pasteboard.clearContents()
        pasteboard.setString("new local copy", forType: .string)
        completion?(.success(.data(kind: .text, data: data)))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(pasteboard.string(forType: .string), "new local copy")
    }

    @MainActor
    func test_eagerCompletion_whenSupersededByRemoteCopy_preservesNewestUpdate() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isSyncEnabled: { true })
        defer { engine.stop() }
        var completion: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in completion = callback }
        engine.isBulkSyncAllowed = { true }
        engine.start()
        let data = try JSONEncoder().encode(ClipboardTextContent(text: "old", rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 7, count: 32), totalBytes: Int64(data.count), files: nil)
        engine.handleRemoteUpdate(textPayload("old", bulk: offer))
        engine.handleRemoteUpdate(textPayload("new"))
        completion?(.success(.data(kind: .text, data: data)))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(pasteboard.string(forType: .string), "new")
    }

    @MainActor
    func test_eagerCompletion_whenEngineStopped_doesNotWritePasteboard() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isSyncEnabled: { true })
        var completion: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in completion = callback }
        engine.isBulkSyncAllowed = { true }
        engine.start()
        let data = try JSONEncoder().encode(ClipboardTextContent(text: "old", rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 7, count: 32), totalBytes: Int64(data.count), files: nil)
        engine.handleRemoteUpdate(textPayload("old", bulk: offer))
        engine.stop()
        completion?(.success(.data(kind: .text, data: data)))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    @MainActor
    func test_disabledInterval_whenReenabled_doesNotBroadcastPrivateCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var enabled = true
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isSyncEnabled: { enabled })
        defer { engine.stop() }
        var sent: [ClipboardUpdatePayload] = []
        engine.sendUpdate = { sent.append($0) }
        engine.start()
        enabled = false
        engine.checkPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("copied while disabled", forType: .string)
        enabled = true
        engine.checkPasteboard()
        engine.checkPasteboard()
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func test_invalidFileOffer_whenTotalsDisagree_isRejectedBeforePromises() {
        let offer = ClipboardBulkOffer(token: Data(repeating: 7, count: 32), totalBytes: 1,
                                       files: [ClipboardFileStub(name: "a.txt", size: 100)])
        let payload = ClipboardUpdatePayload(updateId: UUID(), kind: .files, text: nil, rtf: nil, png: nil,
                                             bulk: offer, digest: Data(repeating: 0, count: 32))
        XCTAssertFalse(ClipboardSyncEngine.isValid(payload))
    }

    @MainActor
    func test_emptyFileCopy_whenKeyed_createsOffer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: pasteboard, isSyncEnabled: { true })
        defer { engine.stop() }
        engine.isBulkSyncAllowed = { true }
        var offered: ClipboardSyncEngine.OutboundBulk?
        engine.publishOutbound = { offered = $0 }
        engine.start()
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        engine.checkPasteboard()
        XCTAssertEqual(offered?.manifest.totalBytes, 0)
        XCTAssertEqual(offered?.manifest.files?.count, 1)
    }

    func test_manifestMatch_whenFileSizesReassigned_rejectsSameNamesAndTotal() {
        let offeredFiles = [ClipboardFileStub(name: "a", size: 1), ClipboardFileStub(name: "b", size: 2)]
        let offer = ClipboardBulkOffer(token: Data(repeating: 1, count: 32), totalBytes: 3, files: offeredFiles)
        let manifest = ClipboardBulkManifest(updateId: UUID(), kind: .files, totalBytes: 3,
                                            files: [ClipboardFileStub(name: "a", size: 2), ClipboardFileStub(name: "b", size: 1)])
        XCTAssertFalse(manifest.matches(offer, kind: .files))
    }

    func test_chunkValidation_whenEmptyOrOversized_rejectsFrame() {
        XCTAssertNil(ClipboardBulkFraming.decodeChunkBody(Data(repeating: 0, count: 4)))
        XCTAssertNil(ClipboardBulkFraming.decodeChunkBody(Data(repeating: 0, count: ClipboardBulkFraming.chunkSize + 5)))
    }

    func test_fileNameValidation_whenNulOrBackslashPresent_rejectsName() {
        XCTAssertNil(ClipboardBulkFraming.sanitizeFileName("name\0.txt"))
        XCTAssertNil(ClipboardBulkFraming.sanitizeFileName("..\\name.txt"))
    }
}
