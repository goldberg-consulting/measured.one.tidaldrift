import XCTest
@testable import TidalDrift

/// The username decision drives whether Screen Sharing gets credentials in
/// the vnc:// URL; a wrong answer either re-breaks Raspberry Pi connects
/// ("incompatible software") or strips credentials from Mac connects.
/// Type sets below were measured from live servers where noted.
final class RFBSecurityProbeTests: XCTestCase {

    func test_macOSHost_acceptsUsername() {
        // Measured from macOS Tahoe Screen Sharing (RFB 003.889).
        XCTAssertTrue(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: [30, 33, 35, 36]))
    }

    func test_tigervnc_vncAuthOnly_rejectsUsername() {
        // Measured from TigerVNC on Debian 13 with SecurityTypes=VncAuth.
        XCTAssertFalse(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: [2]))
    }

    func test_tigervnc_defaultList_rejectsUsername() {
        // TigerVNC default: VeNCrypt + VncAuth. Neither takes a username.
        XCTAssertFalse(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: [19, 2]))
    }

    func test_realVNC_rsaAES_acceptsUsername() {
        // RealVNC servers offer the RSA-AES family, which Screen Sharing
        // authenticates with username + password.
        XCTAssertTrue(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: [2, 5, 6, 130]))
    }

    func test_noAuthServer_rejectsUsername() {
        XCTAssertFalse(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: [1]))
    }

    func test_emptySet_rejectsUsername() {
        XCTAssertFalse(ScreenShareConnectionService.serverAcceptsUsername(securityTypes: []))
    }
}
