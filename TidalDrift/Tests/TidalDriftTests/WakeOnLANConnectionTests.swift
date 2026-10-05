import XCTest
@testable import TidalDrift

final class WakeOnLANConnectionTests: XCTestCase {
    private func device() -> DiscoveredDevice {
        var target = DiscoveredDevice(name: "Wake test Mac", hostname: "wake-test.local.", ipAddress: "192.0.2.1")
        target.networkAddresses = [
            .init(address: "192.0.2.1", kind: .wifi),
            .init(address: "192.0.2.2", kind: .ethernet)
        ]
        return target
    }

    func test_wakeTargetsIncludeEveryAdapterAndHostnameWithoutDuplicates() {
        XCTAssertEqual(WakeOnLANService.wakeHosts(for: device()), ["192.0.2.1", "192.0.2.2", "wake-test.local"])
        var target = device()
        target.hostname = "wake-test"
        XCTAssertEqual(WakeOnLANService.wakeHosts(for: target).last, "wake-test.local")
        target.hostname = "Resolving..."
        XCTAssertEqual(WakeOnLANService.wakeHosts(for: target), ["192.0.2.1", "192.0.2.2"])
    }

    func test_screenSharingReadinessUsesWorkingAdapterAndCustomVNCPort() async {
        let resolver = ConnectionResolver(addressLookup: { _, _ in [] }, probe: { address, port, _ in
            XCTAssertEqual(port, 5999)
            return address == "192.0.2.2"
        })
        var target = device()
        target.port = 5999
        // A fresh Bonjour record is intentionally not treated as readiness.
        XCTAssertTrue(target.isOnline)
        let ready = await WakeOnLANService(resolver: resolver).probe(device: target, service: .screenSharing)
        XCTAssertTrue(ready)
    }

    func test_freshBonjourRecordDoesNotProveScreenSharingIsReady() async {
        let resolver = ConnectionResolver(addressLookup: { _, _ in [] }, probe: { _, _, _ in false })
        let target = device()
        XCTAssertTrue(target.isOnline)
        let ready = await WakeOnLANService(resolver: resolver).probe(device: target, service: .screenSharing)
        XCTAssertFalse(ready)
    }

    func test_localCastReadinessNeverRequiresTCPOrScreenSharing() async {
        let resolver = ConnectionResolver(addressLookup: { _, _ in
            XCTFail("UDP readiness belongs to the LocalCast handshake")
            return []
        }, probe: { _, _, _ in
            XCTFail("A TCP port cannot establish LocalCast readiness")
            return false
        })
        XCTAssertNil(WakeOnLANService.readinessPort(for: .localCast, device: device()))
        let ready = await WakeOnLANService(resolver: resolver).probe(device: device(), service: .localCast)
        XCTAssertFalse(ready)
    }

    func test_wakeReadinessRetriesUntilServiceActuallyStarts() async {
        var probes = 0
        var wakes = 0
        let ready = await WakeOnLANService.waitForReadiness(timeout: 1, retryInterval: 0.001, probe: { _ in
            probes += 1
            return probes == 3
        }, requestWake: {
            wakes += 1
        })
        XCTAssertTrue(ready)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(wakes, 3)
    }

    func test_manualWakeCanUseOptionalVNCResponseForLocalCastOnlyDiscovery() async {
        let resolver = ConnectionResolver(addressLookup: { _, _ in [] }, probe: { address, port, _ in
            XCTAssertEqual(port, 5900)
            return address == "192.0.2.2"
        })
        var target = device()
        target.services = [.localCast]
        let awake = await WakeOnLANService(resolver: resolver).isDeviceReachableAfterWake(target, service: nil)
        XCTAssertTrue(awake)
    }

    func test_cancellationEndsWakeRetryDelayPromptly() async {
        let began = expectation(description: "First readiness probe")
        let task = Task {
            await WakeOnLANService.waitForReadiness(timeout: 30, probe: { _ in
                began.fulfill()
                return false
            }, requestWake: {})
        }
        await fulfillment(of: [began], timeout: 1)
        task.cancel()
        let ready = await task.value
        XCTAssertFalse(ready)
    }

    func test_expiredReadinessBudgetDoesNotReportWakeSuccess() async {
        let ready = await WakeOnLANService.waitForReadiness(timeout: 0.01, retryInterval: 0.001, probe: { _ in false }, requestWake: {})
        XCTAssertFalse(ready)
        let invalid = await WakeOnLANService.waitForReadiness(timeout: 0, probe: { _ in
            XCTFail("An expired attempt must not probe")
            return true
        }, requestWake: { XCTFail("An expired attempt must not send wake packets") })
        XCTAssertFalse(invalid)
    }
}
