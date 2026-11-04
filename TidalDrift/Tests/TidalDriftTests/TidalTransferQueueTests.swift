import AppKit
import Combine
import XCTest
@testable import TidalDrift

@MainActor
final class TidalTransferQueueTests: XCTestCase {
    private final class Gate {
        var resume: CheckedContinuation<Void, Never>?

        func hold(started: XCTestExpectation) async {
            await withCheckedContinuation {
                resume = $0
                started.fulfill()
            }
        }
    }

    func testEachDropKeepsDestinationAndQueuedCancellationDoesNotCopy() async throws {
        let gate = Gate()
        let started = expectation(description: "First copy is active")
        let finished = expectation(description: "Following drop finished")
        var routes: [String] = []
        let queue = TidalTransferQueue { urls, destination, _ in
            routes.append("\(urls[0].lastPathComponent):\(destination.name)")
            if routes.count == 1 { await gate.hold(started: started) }
        }
        let source = URL(fileURLWithPath: "/work/items")
        let firstFolder = TidalTransferDestination.folder(URL(fileURLWithPath: "/Volumes/Share/First"))
        let secondFolder = TidalTransferDestination.folder(URL(fileURLWithPath: "/Volumes/Share/Second"))
        queue.enqueue([source], to: firstFolder)
        let skipped = try XCTUnwrap(queue.enqueue([source], to: secondFolder))
        let last = try XCTUnwrap(queue.enqueue([source], to: secondFolder))
        let observer = queue.$batches.first { rows in rows.contains { $0.id == last && $0.state == .finished } }
            .sink { _ in finished.fulfill() }

        await fulfillment(of: [started], timeout: 3)
        queue.cancel(skipped)
        XCTAssertEqual(queue.batches.first(where: { $0.id == skipped })?.state, .cancelled)
        XCTAssertEqual(routes, ["items:First"])
        gate.resume?.resume()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(routes, ["items:First", "items:Second"])
        withExtendedLifetime(observer) {}
    }

    func testActiveCancellationWaitsForCleanupBeforeNextCopy() async throws {
        let gate = Gate()
        let started = expectation(description: "Copy running")
        let finished = expectation(description: "Second copy finished")
        var didCleanUp = false
        let queue = TidalTransferQueue { urls, _, report in
            if urls[0].lastPathComponent == "one" {
                await gate.hold(started: started)
                await report("Late progress", 0.9)
                didCleanUp = true
                try Task.checkCancellation()
            } else {
                XCTAssertTrue(didCleanUp)
            }
        }
        let folder = TidalTransferDestination.folder(URL(fileURLWithPath: "/Volumes/Share"))
        let first = try XCTUnwrap(queue.enqueue([URL(fileURLWithPath: "/one")], to: folder))
        let second = try XCTUnwrap(queue.enqueue([URL(fileURLWithPath: "/two")], to: folder))
        let observer = queue.$batches.first { rows in rows.contains { $0.id == second && $0.state == .finished } }
            .sink { _ in finished.fulfill() }

        await fulfillment(of: [started], timeout: 3)
        queue.cancel(first)
        XCTAssertEqual(queue.batches.map(\.state), [.stopping, .queued])
        gate.resume?.resume()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(queue.batches.map(\.state), [.cancelled, .finished])
        queue.clearFinished()
        XCTAssertTrue(queue.batches.isEmpty)
        withExtendedLifetime(observer) {}
    }

    func testLateCancelKeepsAnUncertainReceiptVisible() async throws {
        let gate = Gate()
        let started = expectation(description: "Copy reached commit")
        let finished = expectation(description: "Unconfirmed copy reported")
        let queue = TidalTransferQueue { _, _, _ in
            await gate.hold(started: started)
            throw TidalTransferChannel.Unconfirmed()
        }
        let folder = TidalTransferDestination.folder(URL(fileURLWithPath: "/Volumes/Share"))
        let id = try XCTUnwrap(queue.enqueue([URL(fileURLWithPath: "/one")], to: folder))
        let observer = queue.$batches.first { $0.first?.state == .failed(TidalTransferChannel.Unconfirmed().localizedDescription) }
            .sink { _ in finished.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        queue.cancel(id)
        gate.resume?.resume()
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testFinderDropReadsFileAndFolderURLsAndRejectsText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/Finder file"), URL(fileURLWithPath: "/tmp/A Folder", isDirectory: true)]
        XCTAssertTrue(pasteboard.writeObjects(files.map { $0 as NSURL }))
        XCTAssertEqual(TransferFinderPasteboard.fileURLs(from: pasteboard), files)
        pasteboard.clearContents()
        pasteboard.setString("a web page or plain text", forType: .string)
        XCTAssertTrue(TransferFinderPasteboard.fileURLs(from: pasteboard).isEmpty)
    }
}
