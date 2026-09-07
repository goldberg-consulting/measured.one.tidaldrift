import XCTest
@testable import TidalDrift

final class DiscoverySettingsTests: XCTestCase {
    func test_localCastNameMatching_whenNameIsPrefixOrEmpty_doesNotMatchDifferentMac() {
        XCTAssertFalse(NetworkDiscoveryService.localCastNameMatches("Eli", deviceName: "Elis MacBook Pro", hostname: "elis-macbook-pro.local"))
        XCTAssertFalse(NetworkDiscoveryService.localCastNameMatches("", deviceName: "Studio", hostname: "studio.local"))
        XCTAssertFalse(NetworkDiscoveryService.localCastNameMatches("Studio Pro", deviceName: "Studio", hostname: "studio.local"))
        XCTAssertTrue(NetworkDiscoveryService.localCastNameMatches("Studio Mac", deviceName: "Other Name", hostname: "studio-mac.local."))
    }

    func test_discoveryLineBuffer_whenUTF8AndLinesSplit_reassemblesWholeLines() {
        let buffer = DiscoveryLineBuffer()
        let first = "21:46 Add _tidaldrift-cast._udp. José’s Mac"
        var lines: [String] = []
        for byte in Data((first + "\nsecond\r\n").utf8) {
            lines.append(contentsOf: buffer.append(Data([byte])))
        }
        XCTAssertEqual(lines, [first, "second"])
        XCTAssertTrue(buffer.append(Data("partial".utf8)).isEmpty)
        XCTAssertEqual(buffer.append(Data(" line\n".utf8)), ["partial line"])
    }

    func test_discoveryLineBuffer_whenLineExceedsLimit_discardsItAndRecovers() {
        let buffer = DiscoveryLineBuffer(maximumLineBytes: 4)
        XCTAssertTrue(buffer.append(Data("oversized".utf8)).isEmpty)
        XCTAssertEqual(buffer.append(Data(" suffix\nok\n".utf8)), ["ok"])
    }

    func test_settingsDecode_whenOlderFileOmitsNewFields_preservesExistingPreferences() throws {
        let data = Data(#"{"showNotifications":false,"theme":"dark","useBiometrics":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(settings.showNotifications)
        XCTAssertTrue(settings.useBiometrics)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.peerDiscoveryEnabled)
        XCTAssertEqual(settings.wakeOnLANPort, 9)
    }

    func test_settingsDecode_whenNumericValuesAreUnsafe_usesSafeDefaults() throws {
        let data = Data(#"{"scanIntervalSeconds":0,"wakeOnLANPort":65536,"wakeOnLANRetries":-1,"theme":"future"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.scanIntervalSeconds, 30)
        XCTAssertEqual(settings.wakeOnLANPort, 9)
        XCTAssertEqual(settings.wakeOnLANRetries, 3)
        XCTAssertEqual(settings.theme, .system)
    }

    func test_settingsDecode_whenFieldHasWrongType_rejectsFile() {
        let data = Data(#"{"useBiometrics":"false"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data))
    }

    func test_settingsRoundTrip_preservesAllFields() throws {
        let settings = AppSettings(
            launchAtLogin: true, scanIntervalSeconds: 120, showNotifications: false,
            useBiometrics: true, enableConnectionLogging: false, showMenuBarIcon: false,
            autoConnectTrustedDevices: true, peerDiscoveryEnabled: false,
            sshDiscoveryEnabled: false, showExperimentalFeatures: true, theme: .dark,
            wakeOnLANEnabled: false, wakeOnLANPort: 7, wakeOnLANRetries: 10,
            autoWakeBeforeConnect: false, tidalDropDestination: "/tmp/received",
            tidalDropDestinationBookmark: Data([1, 2, 3]), tidalDriftDisplayName: "Studio")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func test_resetDestination_whenCustomBookmarkExists_clearsBothOverrides() {
        var settings = AppSettings(tidalDropDestination: "/tmp/received", tidalDropDestinationBookmark: Data([1]))
        settings.resetTidalDropDestination()
        XCTAssertEqual(settings.tidalDropDestination, "")
        XCTAssertNil(settings.tidalDropDestinationBookmark)
        XCTAssertEqual(settings.tidalDropFolder, AppSettings.default.tidalDropFolder)
    }

    func test_vncPort_whenOtherServicesArrive_preservesScreenSharingDestination() {
        for service in [DiscoveredDevice.ServiceType.fileSharing, .afp, .ssh, .localCast] {
            XCTAssertEqual(NetworkDiscoveryService.screenSharingPort(existing: 5901, incoming: 22, service: service), 5901)
            XCTAssertEqual(NetworkDiscoveryService.screenSharingPort(existing: nil, incoming: 22, service: service), 5900)
        }
        XCTAssertEqual(NetworkDiscoveryService.screenSharingPort(existing: 5900, incoming: 5902, service: .screenSharing), 5902)
    }

    func test_advertisedIP_whenMalformedOrUnusable_rejectsTXT() {
        for value in ["999.1.1.1", "192.168.1.1oops", "0.0.0.0", "127.0.0.1", "::1", "255.255.255.255"] {
            XCTAssertNil(NetworkDiscoveryService.advertisedIPAddress(in: "ip=\(value) auth=1"), value)
        }
        XCTAssertNil(NetworkDiscoveryService.advertisedIPAddress(in: "otherip=192.168.1.2"))
        XCTAssertEqual(NetworkDiscoveryService.advertisedIPAddress(in: "ip=192.168.1.2 auth=1"), "192.168.1.2")
        XCTAssertEqual(NetworkDiscoveryService.advertisedIPAddress(in: "ip=fd12::1 auth=1"), "fd12::1")
    }
}
