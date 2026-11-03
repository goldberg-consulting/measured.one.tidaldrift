import XCTest
import Network
import ScreenCaptureKit
@testable import TidalDrift

final class LocalCastDisplaySafetyTests: XCTestCase {
    private final class RecordingTransport: UDPTransport {
        private(set) var sent: [LocalCastPacket.PacketType] = []
        override func send(packet: LocalCastPacket, to endpoint: NWEndpoint, forcePlaintext: Bool = false,
                           isKeyFrame: Bool = false) { sent.append(packet.type) }
    }

    @MainActor
    func test_pausedViewerStopsAutomaticTrafficAndCanExplicitlyDisconnect() async throws {
        let transport = RecordingTransport()
        let device = DiscoveredDevice(name: "Test host", hostname: "", ipAddress: "192.0.2.17")
        let client = ClientSession(device: device, transport: transport)
        try await client.connect()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertTrue(transport.sent.contains(.heartbeat))

        let host = NWEndpoint.hostPort(host: .init(device.ipAddress), port: .init(rawValue: LocalCastConfiguration.hostPort)!)
        client.udpTransport(transport, didReceivePacket: .init(type: .heartbeat, sequenceNumber: 1, timestamp: 0,
            payload: Data([HostSession.pongFlagCapturePaused, 0])), wasAuthenticated: false, from: host)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(client.capturePauseMessage, StreamResponse.pausedMessage)
        XCTAssertFalse(client.inputCaptureEnabled)
        let count = transport.sent.count
        client.requestKeyFrame()
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(transport.sent.count, count, "The paused viewer must not restart capture after the host sleeps")
        client.disconnect()
        XCTAssertEqual(Array(transport.sent.dropFirst(count)), [.disconnect])
    }

    func test_virtualDisplayRequiresOptInAndTwoConfirmedEmptyInventories() {
        typealias Inventory = HeadlessDisplayPolicy.Inventory
        let empty = Inventory(shareableCount: 0, onlineCount: 0)
        var policy = HeadlessDisplayPolicy()
        XCTAssertFalse(policy.reserveCreation(enabled: false, before: empty, after: empty))
        for unsafe in [Inventory(shareableCount: 0, onlineCount: 1), // asleep or mirrored
                       Inventory(shareableCount: 1, onlineCount: 0), // inventories disagree
                       Inventory(shareableCount: 0, onlineCount: nil)] { // query failed
            XCTAssertFalse(policy.reserveCreation(enabled: true, before: unsafe, after: empty))
            XCTAssertFalse(policy.reserveCreation(enabled: true, before: empty, after: unsafe))
        }
        XCTAssertTrue(policy.reserveCreation(enabled: true, before: empty, after: empty))
        XCTAssertFalse(policy.reserveCreation(enabled: true, before: empty, after: empty),
                       "Late registration and heartbeats cannot trigger repeated WindowServer attachments")
    }

    func test_captureStartCannotResetRepeatedFailureBudget() {
        let transient = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.internalError.rawValue)
        var policy = CaptureFailurePolicy()
        for time in [1.0, 10, 20, 30, 40] {
            XCTAssertTrue(policy.canStart(at: time))
            policy.record(transient, at: time)
            XCTAssertFalse(policy.canStart(at: time + 0.5))
        }
        XCTAssertTrue(policy.isPaused)
        XCTAssertFalse(policy.canStart(at: 1000), "A persistent viewer's heartbeat cannot reset the pause")
        var occasional = CaptureFailurePolicy()
        for time in [1.0, 61, 121, 181, 241] { occasional.record(transient, at: time) }
        XCTAssertFalse(occasional.isPaused)
    }

    func test_systemOrUserStopYieldsUntilViewerDisconnects() async throws {
        var codes = [SCStreamError.Code.userStopped.rawValue]
        if #available(macOS 15, *) { codes.append(SCStreamError.Code.systemStoppedStream.rawValue) }
        for code in codes {
            let host = HostSession(configuration: .default)
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
            host.isRunning = true
            host.setActiveClient(endpoint: endpoint, connection: nil)
            host.withCaptureState { host.captureActive = true }
            let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
            host.captureManager.setOutputStream(stream)
            let error = NSError(domain: SCStreamError.errorDomain, code: code)
            let (gate, release) = AsyncStream<Void>.makeStream()
            host.captureTransitions.enqueue {
                for await _ in gate {}
                XCTAssertNil(host.claimCaptureReplacement(), "A queued display change must yield to an OS stop")
            }
            let recovery = try XCTUnwrap(host.recoverCapture(after: error, from: stream, alreadyStopped: true))
            XCTAssertTrue(host.isCapturePaused, "Record the user or OS stop at callback receipt")
            release.finish()
            await recovery.value
            XCTAssertTrue(host.isCapturePaused)
            XCTAssertFalse(host.captureManager.isCurrentOutputStream(stream))
            host.declareRemoteUserActivity { _ in XCTFail("Paused capture must not request a display wake"); return 0 }
            for type in [LocalCastPacket.PacketType.heartbeat, .keyframeRequest] {
                host.udpTransport(host.transport, didReceivePacket: .init(type: type, sequenceNumber: 1,
                    timestamp: 0, payload: Data()), wasAuthenticated: false, from: endpoint)
            }
            host.beginCaptureForClient()
            XCTAssertFalse(host.isCaptureActive)
            XCTAssertNil(host.streamActivity)
            XCTAssertTrue(host.hasActiveClient, "The control connection persists while sharing is paused")
            host.udpTransport(host.transport, didReceivePacket: .init(type: .disconnect, sequenceNumber: 1,
                timestamp: 0, payload: Data()), wasAuthenticated: false, from: endpoint)
            XCTAssertFalse(host.isCapturePaused, "A new viewer can start without restarting the app")
            XCTAssertFalse(host.hasActiveClient)
            await host.captureTransitions.run {}
        }
    }

    func test_directAppStartRefusalSharesTheHeartbeatPause() async throws {
        let host = HostSession(configuration: .default)
        host.isRunning = true
        host.setActiveClient(endpoint: .hostPort(host: "127.0.0.1", port: 9), connection: nil)
        let claim = try XCTUnwrap(host.claimCaptureReplacement())
        let refusal = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let retry = await host.finishFailedStart(refusal, claim: claim.generation)
        XCTAssertFalse(retry)
        XCTAssertTrue(host.isCapturePaused)
        XCTAssertNil(host.claimCaptureReplacement())
        host.beginCaptureForClient()
        XCTAssertFalse(host.isCaptureActive)
    }
}
