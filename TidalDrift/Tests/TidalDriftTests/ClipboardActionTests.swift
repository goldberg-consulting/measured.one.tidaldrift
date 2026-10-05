import AppKit
import ApplicationServices
import XCTest
@testable import TidalDrift

final class ClipboardActionTests: XCTestCase {
    private let command = CGEventFlags.maskCommand.rawValue

    @MainActor
    private func pastePayload(_ text: String, bulk: ClipboardBulkOffer? = nil) -> ClipboardUpdatePayload {
        ClipboardUpdatePayload(updateId: UUID(), kind: .text, text: bulk == nil ? text : nil,
            rtf: nil, png: nil, bulk: bulk,
            digest: ClipboardPasteboard.textDigest(text: text, rtf: nil, html: nil), pasteModifiers: command)
    }

    @MainActor
    func test_explicitPasteIncludesPreconnectionCopyWithoutAutomaticDisclosure() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("copied before connection", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        var sent: [ClipboardUpdatePayload] = []
        engine.sendUpdate = { sent.append($0) }
        engine.start()
        defer { engine.stop() }
        engine.checkPasteboard()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(engine.sendPaste(modifiers: command))
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.text, "copied before connection")
        XCTAssertEqual(sent.first?.pasteModifiers, command)
    }

    @MainActor
    func test_explicitPasteNeverExposesConcealedContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("private", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.sendUpdate = { _ in XCTFail("Private clipboard content must not be sent") }
        engine.start()
        defer { engine.stop() }
        XCTAssertFalse(engine.sendPaste(modifiers: command))
    }

    @MainActor
    func test_folderCopyDoesNotPasteFinderFilenameText() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([FileManager.default.temporaryDirectory as NSURL])
        board.setString("folder name", forType: .string)
        XCTAssertNil(ClipboardPasteboard.capture(from: board))
    }

    @MainActor
    func test_duplicatePasteReplaysReceiptWithoutPastingTwiceButNewGesturePastesAgain() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        var pastes = 0
        var results: [ClipboardActionResult] = []
        engine.performPaste = { modifiers in
            XCTAssertEqual(modifiers, self.command)
            XCTAssertEqual(board.string(forType: .string), "ready first")
            pastes += 1
        }
        engine.sendActionResult = { results.append($0) }
        engine.start()
        defer { engine.stop() }
        let payload = pastePayload("ready first")
        engine.handleRemoteUpdate(payload)
        engine.handleRemoteUpdate(payload)
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.success))
        XCTAssertEqual(results[0].updateId, results[1].updateId)
        engine.handleRemoteUpdate(pastePayload("ready first"))
        XCTAssertEqual(pastes, 2, "The content digest must not swallow an intentional repeated paste")
    }

    @MainActor
    func test_bulkPasteWaitsForVerifiedClipboardBeforeInjectingKey() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old clipboard", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        var finish: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in finish = callback }
        var pasted = false
        let pasteCompleted = expectation(description: "Verified bulk clipboard is pasted")
        engine.performPaste = { _ in
            XCTAssertEqual(board.string(forType: .string), "new clipboard")
            pasted = true
            pasteCompleted.fulfill()
        }
        engine.start()
        defer { engine.stop() }
        let content = try JSONEncoder().encode(ClipboardTextContent(text: "new clipboard", rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 8, count: 32), totalBytes: Int64(content.count), files: nil)
        engine.handleRemoteUpdate(pastePayload("new clipboard", bulk: offer))
        XCTAssertFalse(pasted)
        XCTAssertEqual(board.string(forType: .string), "old clipboard")
        finish?(.success(.data(kind: .text, data: content)))
        await fulfillment(of: [pasteCompleted], timeout: 2)
        XCTAssertTrue(pasted)
    }

    @MainActor
    func test_bulkPasteFailureReportsFailureAndNeverPastesOldContent() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old clipboard", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        engine.fetchEager = { _, _, callback in callback(.failure(ClipboardBulkError.cancelled)) }
        engine.performPaste = { _ in XCTFail("Failed transfers must never paste") }
        var result: ClipboardActionResult?
        let resultReceived = expectation(description: "Bulk paste failure is reported")
        engine.sendActionResult = {
            let isFirstResult = result == nil
            result = $0
            if isFirstResult { resultReceived.fulfill() }
        }
        engine.start()
        defer { engine.stop() }
        let offer = ClipboardBulkOffer(token: Data(repeating: 8, count: 32), totalBytes: 10, files: nil)
        engine.handleRemoteUpdate(pastePayload("new clipboard", bulk: offer))
        await fulfillment(of: [resultReceived], timeout: 2)
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(board.string(forType: .string), "old clipboard")
    }

    @MainActor
    func test_peerClipboardMarkerStopsMatchingAsSoonAsLocalUserCopies() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.start()
        defer { engine.stop() }
        var payload = pastePayload("remote copy")
        payload.pasteModifiers = nil
        engine.handleRemoteUpdate(payload)
        XCTAssertTrue(engine.isCurrentClipboardFromPeer)
        board.clearContents()
        board.setString("local copy", forType: .string)
        XCTAssertFalse(engine.isCurrentClipboardFromPeer, "Do not wait for the next poll to detect a local copy")
    }

    @MainActor
    func test_targetResolutionFailureReportsFailureWithoutFetchingOrChangingClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        engine.prepareFileDrop = { _ in throw LocalCastError.hostNotReady }
        engine.fetchFilesForPaste = { _, _ in XCTFail("Do not transfer files before validating the destination") }
        var result: ClipboardActionResult?
        engine.sendActionResult = { result = $0 }
        engine.start()
        defer { engine.stop() }
        let offer = ClipboardBulkOffer(token: Data(repeating: 8, count: 32), totalBytes: 1,
            files: [ClipboardFileStub(name: "document.txt", size: 1)])
        engine.handleRemoteUpdate(ClipboardUpdatePayload(updateId: UUID(), kind: .files, text: nil,
            rtf: nil, png: nil, bulk: offer, digest: Data(repeating: 1, count: 32), eagerFiles: true,
            dropPoint: ClipboardDropPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(board.string(forType: .string), "keep")
    }

    @MainActor
    func test_targetedDropResolvesBeforeDownloadAndLeavesClipboardAlone() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep clipboard", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        var events: [String] = []
        var finish: ((Result<[URL], Error>) -> Void)?
        let staged = URL(fileURLWithPath: "/tmp/staged.txt")
        engine.prepareFileDrop = { point in
            XCTAssertEqual(point, ClipboardDropPoint(x: 0.25, y: 0.75))
            events.append("resolved")
            return { urls in
                XCTAssertEqual(urls, [staged])
                events.append("delivered")
                return urls
            }
        }
        engine.fetchFilesForPaste = { _, callback in
            events.append("fetch")
            finish = callback
        }
        var results: [ClipboardActionResult] = []
        let resultReceived = expectation(description: "Targeted file drop is completed")
        engine.sendActionResult = {
            results.append($0)
            if results.count == 1 { resultReceived.fulfill() }
        }
        engine.start()
        defer { engine.stop() }
        let offer = ClipboardBulkOffer(token: Data(repeating: 8, count: 32), totalBytes: 1,
            files: [ClipboardFileStub(name: "document.txt", size: 1)])
        let payload = ClipboardUpdatePayload(updateId: UUID(), kind: .files, text: nil, rtf: nil,
            png: nil, bulk: offer, digest: Data(repeating: 2, count: 32), eagerFiles: true,
            dropPoint: ClipboardDropPoint(x: 0.25, y: 0.75))
        engine.handleRemoteUpdate(payload)
        engine.handleRemoteUpdate(payload)
        XCTAssertEqual(events, ["resolved", "fetch"])
        XCTAssertTrue(results.isEmpty, "An offer is not a completed drop")
        finish?(.success([staged]))
        await fulfillment(of: [resultReceived], timeout: 2)
        XCTAssertEqual(events, ["resolved", "fetch", "delivered"])
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(board.string(forType: .string), "keep clipboard")
        engine.handleRemoteUpdate(payload)
        XCTAssertEqual(events.count, 3, "A lost result must not cause repeated file delivery")
        XCTAssertEqual(results.count, 2)
    }

    @MainActor
    func test_invalidPasteModifiersAndDropCoordinatesAreRejected() {
        var payload = pastePayload("text")
        payload.pasteModifiers = 0
        XCTAssertFalse(ClipboardSyncEngine.isValid(payload))
        payload.pasteModifiers = command
        payload.dropPoint = ClipboardDropPoint(x: .nan, y: 0)
        XCTAssertFalse(ClipboardSyncEngine.isValid(payload))
        XCTAssertFalse(ClipboardDropPoint(x: -0.01, y: 0).isValid)
        XCTAssertFalse(ClipboardDropPoint(x: 0, y: 1.01).isValid)
        XCTAssertTrue(ClipboardDropPoint(x: 0, y: 1).isValid)
    }

    @MainActor
    func test_unseenOlderRevisionCannotReplaceNewerClipboardOrCancelPaste() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        var pasted: [String] = []
        engine.performPaste = { _ in pasted.append(board.string(forType: .string) ?? "") }
        engine.start()
        defer { engine.stop() }
        let sender = UUID()
        var newer = pastePayload("newer")
        newer.senderID = sender
        newer.revision = 2
        var older = pastePayload("older")
        older.senderID = sender
        older.revision = 1
        engine.handleRemoteUpdate(newer)
        engine.handleRemoteUpdate(older)
        XCTAssertEqual(pasted, ["newer"])
        XCTAssertEqual(board.string(forType: .string), "newer")
        // Retransmitting a completed request still returns its cached result.
        var repeatedReceipt: ClipboardActionResult?
        engine.sendActionResult = { repeatedReceipt = $0 }
        engine.handleRemoteUpdate(newer)
        XCTAssertEqual(repeatedReceipt?.success, true)
        XCTAssertEqual(pasted.count, 1)
    }

    @MainActor
    func test_retiredSenderEpochCannotReviveOldClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.start()
        defer { engine.stop() }
        let previousSender = UUID()
        var previous = pastePayload("previous epoch")
        previous.pasteModifiers = nil
        previous.senderID = previousSender
        previous.revision = 10
        engine.handleRemoteUpdate(previous)
        var current = pastePayload("current epoch")
        current.pasteModifiers = nil
        current.senderID = UUID()
        current.revision = 1
        engine.handleRemoteUpdate(current)
        var delayed = pastePayload("delayed previous epoch")
        delayed.pasteModifiers = nil
        delayed.senderID = previousSender
        delayed.revision = 11
        engine.handleRemoteUpdate(delayed)
        XCTAssertEqual(board.string(forType: .string), "current epoch")
        var legacy = pastePayload("unsequenced packet")
        legacy.pasteModifiers = nil
        engine.handleRemoteUpdate(legacy)
        XCTAssertEqual(board.string(forType: .string), "current epoch")
    }

    @MainActor
    func test_delayedOlderAnnouncementCannotCancelNewerBulkPaste() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        var finish: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in finish = callback }
        var pasted: String?
        let pasteCompleted = expectation(description: "Newer bulk clipboard is pasted")
        engine.performPaste = { _ in
            pasted = board.string(forType: .string)
            pasteCompleted.fulfill()
        }
        engine.start()
        defer { engine.stop() }
        let data = try JSONEncoder().encode(ClipboardTextContent(text: "newer bulk content", rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 1, count: 32), totalBytes: Int64(data.count), files: nil)
        let sender = UUID()
        var newer = pastePayload("newer bulk content", bulk: offer)
        newer.senderID = sender
        newer.revision = 2
        engine.handleRemoteUpdate(newer)
        var old = pastePayload("delayed old copy")
        old.pasteModifiers = nil
        old.senderID = sender
        old.revision = 1
        engine.handleRemoteUpdate(old)
        finish?(.success(.data(kind: .text, data: data)))
        await fulfillment(of: [pasteCompleted], timeout: 2)
        XCTAssertEqual(pasted, "newer bulk content")
    }

    @MainActor
    func test_outboundCopiesShareAnEpochAndIncreaseRevision() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("first", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        var sent: [ClipboardUpdatePayload] = []
        engine.sendUpdate = { sent.append($0) }
        engine.start()
        defer { engine.stop() }
        XCTAssertTrue(engine.sendPaste(modifiers: command))
        board.clearContents()
        board.setString("second", forType: .string)
        XCTAssertTrue(engine.sendPaste(modifiers: command))
        XCTAssertEqual(sent.map(\.revision), [1, 2])
        XCTAssertNotNil(sent[0].senderID)
        XCTAssertEqual(sent[0].senderID, sent[1].senderID)
        var partial = sent[0]
        partial.senderID = nil
        XCTAssertFalse(ClipboardSyncEngine.isValid(partial))
        partial.senderID = sent[0].senderID
        partial.revision = 0
        XCTAssertFalse(ClipboardSyncEngine.isValid(partial))
    }

    @MainActor
    func test_bulkPasteCancelsBeforeClipboardMutationWhenTargetChanges() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        engine.isBulkSyncAllowed = { true }
        var focus = "original window"
        engine.preparePasteTarget = {
            let expected = focus
            return {
                guard focus == expected else { throw LocalCastError.clipboardActionFailed("Focus changed") }
            }
        }
        var finish: ((Result<ClipboardBulkReceived, Error>) -> Void)?
        engine.fetchEager = { _, _, callback in finish = callback }
        engine.performPaste = { _ in XCTFail("A delayed paste must not move to another window") }
        var result: ClipboardActionResult?
        let resultReceived = expectation(description: "Changed paste target is reported")
        engine.sendActionResult = {
            let isFirstResult = result == nil
            result = $0
            if isFirstResult { resultReceived.fulfill() }
        }
        engine.start()
        defer { engine.stop() }
        let data = try JSONEncoder().encode(ClipboardTextContent(text: "remote", rtf: nil))
        let offer = ClipboardBulkOffer(token: Data(repeating: 1, count: 32), totalBytes: Int64(data.count), files: nil)
        engine.handleRemoteUpdate(pastePayload("remote", bulk: offer))
        focus = "different window"
        finish?(.success(.data(kind: .text, data: data)))
        await fulfillment(of: [resultReceived], timeout: 2)
        XCTAssertEqual(board.string(forType: .string), "keep")
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(result?.message, "Focus changed")
    }

    func test_pasteFocusGuardRequiresMatchingProcessWindowAndControl() throws {
        // Opaque AX identities can be compared without inspecting an app or
        // requiring Accessibility permission in the test process.
        let window = AXUIElementCreateApplication(1001)
        let control = AXUIElementCreateApplication(1002)
        let replacement = AXUIElementCreateApplication(1003)
        let target = ClipboardPasteFocus(processID: 42, window: window, element: control)
        XCTAssertNoThrow(try target.validate(current: ClipboardPasteFocus(processID: 42,
            window: AXUIElementCreateApplication(1001), element: AXUIElementCreateApplication(1002))))
        XCTAssertThrowsError(try target.validate(current: ClipboardPasteFocus(processID: 43, window: window, element: control)))
        XCTAssertThrowsError(try target.validate(current: ClipboardPasteFocus(processID: 42, window: replacement, element: control)))
        XCTAssertThrowsError(try target.validate(current: ClipboardPasteFocus(processID: 42, window: window, element: replacement)))
        XCTAssertThrowsError(try target.validate(current: ClipboardPasteFocus(processID: 42, window: nil, element: control)))
    }

    func test_remotePasteRoutingAcceptsPeerClipboardWithoutCopyShortcutMarker() {
        XCTAssertTrue(ClientSession.shouldPasteExistingRemoteClipboard(
            remoteCopyChangeCount: nil, currentChangeCount: 10, clipboardFromPeer: true),
            "Host-origin file promises must paste on the host even without a viewer Cmd-C")
        XCTAssertTrue(ClientSession.shouldPasteExistingRemoteClipboard(
            remoteCopyChangeCount: 10, currentChangeCount: 10, clipboardFromPeer: false),
            "Rapid remote Cmd-C/V must not replace the host clipboard with stale local content")
        XCTAssertFalse(ClientSession.shouldPasteExistingRemoteClipboard(
            remoteCopyChangeCount: 10, currentChangeCount: 11, clipboardFromPeer: false),
            "A newer local copy must take the ordered transfer path")
        XCTAssertFalse(ClientSession.shouldPasteExistingRemoteClipboard(
            remoteCopyChangeCount: nil, currentChangeCount: 10, clipboardFromPeer: false))
    }

    func test_authenticatedClipboardNeverSendsWhileRecoveringOrWithoutItsKey() {
        XCTAssertFalse(ClientSession.clipboardTransportReady(requiresAuthentication: true,
            hasSessionKey: false, isAuthenticating: false, isRecovering: false))
        XCTAssertFalse(ClientSession.clipboardTransportReady(requiresAuthentication: true,
            hasSessionKey: true, isAuthenticating: true, isRecovering: false))
        XCTAssertFalse(ClientSession.clipboardTransportReady(requiresAuthentication: true,
            hasSessionKey: true, isAuthenticating: false, isRecovering: true))
        XCTAssertTrue(ClientSession.clipboardTransportReady(requiresAuthentication: true,
            hasSessionKey: true, isAuthenticating: false, isRecovering: false))
        XCTAssertTrue(ClientSession.clipboardTransportReady(requiresAuthentication: false,
            hasSessionKey: false, isAuthenticating: false, isRecovering: false),
            "Sessions explicitly configured without authentication retain inline clipboard support")
    }

    @MainActor
    func test_stoppedClipboardEpochDoesNotRetryOldPasteAfterRestart() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old action", forType: .string)
        let engine = ClipboardSyncEngine(pasteboard: board, isSyncEnabled: { true })
        var sent: [ClipboardUpdatePayload] = []
        engine.sendUpdate = { sent.append($0) }
        engine.start()
        XCTAssertTrue(engine.sendPaste(modifiers: command))
        let oldID = try XCTUnwrap(sent.first?.updateId)
        engine.stop()
        engine.start()
        defer { engine.stop() }
        engine.checkPasteboard()
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(sent.count, 1, "The 80/160ms retries must not survive session teardown")
        XCTAssertFalse(engine.isCurrentClipboardFromPeer)
        XCTAssertTrue(engine.sendPaste(modifiers: command))
        XCTAssertNotEqual(sent.last?.updateId, oldID, "A new user gesture creates a new action")
        XCTAssertNotEqual(sent.first?.senderID, sent.last?.senderID, "Recovery starts a new clipboard epoch")
    }
}
