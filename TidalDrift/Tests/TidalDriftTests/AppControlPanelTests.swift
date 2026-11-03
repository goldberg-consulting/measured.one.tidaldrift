import AppKit
import XCTest
@testable import TidalDrift

final class AppControlPanelTests: XCTestCase {
    @MainActor
    func testClosingCompanionKeepsViewerSessionConnected() {
        _ = NSApplication.shared
        let device = DiscoveredDevice(name: "Panel test", hostname: "panel.local", ipAddress: "192.0.2.1")
        let session = ClientSession(device: device)
        session.isConnected = true
        session.connectionPhase = .streaming

        var closes = 0
        autoreleasepool {
            // Create the window without ordering it on screen or connecting to a host.
            let panel = AppControlPanelController(device: device, session: session, showViewer: {})
            panel.onClose = { closes += 1 }
            panel.close()
        }
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.connectionPhase, .streaming)
    }
}
