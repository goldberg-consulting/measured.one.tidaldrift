import XCTest
import Network
import Combine
@testable import TidalDrift

final class TidalTransferPeerTests: XCTestCase {
    private typealias Handler = @Sendable (TidalTransferChannel) async -> Void

    /// Same four-byte dispatch as the app's TidalDrop listener, bound only
    /// to loopback so tests cannot offer a real user's Mac any files.
    private func listener(_ handler: @escaping Handler) async throws -> (NWListener, NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "tidaltransfer.test.listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            let stream = TidalTransferChannel(connection)
            Task {
                do {
                    guard try await stream.read(4) == TidalTransferChannel.magic else { stream.cancel(); return }
                    await handler(stream)
                } catch { stream.cancel() }
            }
        }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if case .ready = listener.state, let port = listener.port, port.rawValue > 0 { return (listener, port) }
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.cancel()
        throw TidalTransferChannel.Failure("Test listener did not start.")
    }

    private func client(_ port: NWEndpoint.Port) async throws -> TidalTransferChannel {
        let stream = TidalTransferChannel(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        try await stream.connect()
        return stream
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testLegacyHeaderAndNewMagicAreUnambiguous() {
        XCTAssertEqual(TidalTransferChannel.length(0x01020304), Data([1, 2, 3, 4]))
        XCTAssertGreaterThan(TidalTransferChannel.magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }, 1_048_576)
    }

    func testUsesOnlyTheAddressShownForTheSelectedPeer() throws {
        var peer = DiscoveredDevice(name: "Peer", hostname: "peer.local", ipAddress: "192.168.1.10")
        peer.lastConnectedAddress = "192.168.1.99"
        XCTAssertEqual(try TidalTransferService.selectedAddress(for: peer), "192.168.1.10")
        peer.ipAddress = "1.1.1.1"
        XCTAssertThrowsError(try TidalTransferService.selectedAddress(for: peer))
    }

    @MainActor
    func testReceivingRequiresToggleAndConsentAndAcknowledgesSavedBytes() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample")
        let bytes = Data(repeating: 0xD3, count: TidalTransferBatch.chunkBytes + 17)
        try bytes.write(to: file)
        let plan = try TidalTransferBatch.plan([file])
        let destination = root.appendingPathComponent("incoming")
        let inbox = TidalTransferInbox { destination }
        let (server, port) = try await listener { channel in await inbox.accept(channel, peer: "127.0.0.1") }
        defer { server.cancel() }
        let disabled = try await client(port)
        try await disabled.write(TidalTransferChannel.magic)
        let disabledReply = try await disabled.read(1)
        XCTAssertEqual(disabledReply.first, TidalTransferChannel.Reply.unavailable.rawValue)
        disabled.cancel()
        inbox.enabled = true
        for accept in [false, true] {
            let observer = inbox.$offer.compactMap { $0 }.sink { offer in
                XCTAssertEqual(offer.bytes, plan.total)
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                Task { @MainActor in inbox.respond(accept: accept) }
            }
            let stream = try await client(port)
            do {
                try await stream.send(plan: plan) { _, _ in }
                XCTAssertTrue(accept)
            } catch {
                guard !accept else { throw error }
                XCTAssertTrue(error.localizedDescription.contains("accept"), "\(error)")
            }
            stream.cancel()
            observer.cancel()
            // Allow the receive task's defer to relinquish its slot.
            for _ in 0..<100 where inbox.status == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        let copies = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        let saved = try XCTUnwrap(copies.first).appendingPathComponent("sample")
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
    }

    func testBadTrailerCleansStagingWithoutPublishing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("inbox")
        let file = root.appendingPathComponent("file")
        try Data([1, 2, 3]).write(to: file)
        let plan = try TidalTransferBatch.plan([file])
        let (server, port) = try await listener { channel in
            do { _ = try await channel.receive(authorize: { _, _ in destination }, progress: { _, _ in }); XCTFail("Bad digest accepted") }
            catch { try? await channel.reply(.failed) }
            channel.cancel()
        }
        defer { server.cancel() }
        let stream = try await client(port)
        defer { stream.cancel() }
        try await stream.write(TidalTransferChannel.magic)
        try await stream.expect(.ready)
        try await stream.write(TidalTransferChannel.length(plan.manifest.count) + plan.manifest)
        try await stream.expect(.accepted)
        try await stream.write(Data([1, 2, 3]) + Data(repeating: 0, count: 36))
        let reply = try await stream.read(1)
        XCTAssertEqual(reply.first, TidalTransferChannel.Reply.failed.rawValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testCancelAfterCommitMarkerKeepsReceiptUnconfirmed() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("small")
        try Data([42]).write(to: file)
        let plan = try TidalTransferBatch.plan([file])
        let committed = expectation(description: "Receiver has the complete commit marker")
        let (gate, finish) = AsyncStream<Void>.makeStream()
        let (server, port) = try await listener { channel in
            defer { channel.cancel() }
            do {
                try await channel.reply(.ready)
                let size = try await channel.read(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).bigEndian) }
                _ = try await channel.read(size)
                try await channel.reply(.accepted)
                _ = try await channel.read(1 + 36)
                committed.fulfill()
                for await _ in gate {}
            } catch { XCTFail("Test peer stopped too early: \(error)") }
        }
        defer { server.cancel(); finish.finish() }
        let channel = try await client(port)
        let task = Task { try await channel.send(plan: plan) { _, _ in } }
        await fulfillment(of: [committed], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("Expected an unconfirmed receipt") }
        catch { XCTAssertTrue(error is TidalTransferChannel.Unconfirmed, "\(error)") }
    }

    /// Controlled comparison of one accepted batch versus repeated single-file
    /// transfers through the same copy/commit protocol. Not a Finder/SMB benchmark.
    func testManyFileLoopbackBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["TIDAL_TRANSFER_BENCH"] == "1" else {
            throw XCTSkip("Set TIDAL_TRANSFER_BENCH=1 to time the peer path.")
        }
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<300).map { root.appendingPathComponent("sample-\($0).bin") }
        let payload = Data(repeating: 0xAB, count: 4096)
        for file in files { try payload.write(to: file) }
        // Fresh output folders remove timestamp-name collision work from the timing.
        let destinations = (0..<302).map { root.appendingPathComponent("delivery-\($0)") }
        for url in destinations { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        actor Slots {
            var next = 0
            func take() -> Int { defer { next += 1 }; return next }
        }
        let slots = Slots()
        let (server, port) = try await listener { channel in
            do { _ = try await channel.receive(authorize: { _, _ in destinations[await slots.take()] }, progress: { _, _ in }) }
            catch { XCTFail("\(error)"); try? await channel.reply(.failed) }
            channel.cancel()
        }
        defer { server.cancel() }
        for groups in [[files], files.map { [$0] }, [files]] {
            let start = ProcessInfo.processInfo.systemUptime
            for group in groups {
                let plan = try TidalTransferBatch.plan(group)
                let channel = try await client(port)
                defer { channel.cancel() }
                try await channel.send(plan: plan) { _, _ in }
            }
            print("TIDAL_TRANSFER_BENCH files=300 bytesPerFile=4096 connections=\(groups.count) seconds=\(ProcessInfo.processInfo.systemUptime-start)")
        }
        let batches = try destinations.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        XCTAssertEqual(batches.count, 302)
        var checked = 0
        for batch in batches {
            for file in try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil) {
                XCTAssertEqual(try Data(contentsOf: file), payload)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 900)
    }
}
