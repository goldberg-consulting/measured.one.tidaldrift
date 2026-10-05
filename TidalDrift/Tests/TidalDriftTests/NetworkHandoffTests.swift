import XCTest
@testable import TidalDrift

final class NetworkHandoffTests: XCTestCase {
    private func device() -> DiscoveredDevice {
        var device = DiscoveredDevice(name: "Office Mac", hostname: "office.local", ipAddress: "192.0.2.1", peerId: "stable-peer")
        device.networkAddresses = [
            .init(address: "192.0.2.1", kind: .wifi),
            .init(address: "192.0.2.2", kind: .ethernet)
        ]
        return device
    }

    func test_cachedAdaptersRace_withoutWaitingForDeadWiFiOrDNS() async throws {
        let resolver = ConnectionResolver(addressLookup: { _, _ in
            Thread.sleep(forTimeInterval: 1)
            return []
        }, probe: { address, _, _ in
            if address == "192.0.2.2" { return true }
            do { try await Task.sleep(for: .seconds(2)) } catch { return false }
            return false
        })
        let start = Date()
        let result = try await resolver.resolve(device: device(), strategy: .ipFirst, timeout: 3)
        XCTAssertEqual(result.address, "192.0.2.2")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func test_dnsChecksAllAddresses_andDoesNotAcceptDeadFirstResult() async throws {
        let resolver = ConnectionResolver(addressLookup: { hostname, port in
            ["192.0.2.1", "192.0.2.2"].map {
                .init(address: $0, port: port, method: .mDNSHostname, hostname: hostname)
            }
        }, probe: { address, port, _ in
            XCTAssertEqual(port, 445)
            return address == "192.0.2.2"
        })
        var target = device()
        target.port = 445
        let result = try await resolver.resolve(device: target, strategy: .hostnameOnly)
        XCTAssertEqual(result.address, "192.0.2.2")
        XCTAssertEqual(result.port, 445)
    }

    func test_dnsSuccessWithoutReachableService_isFailure() async {
        let resolver = ConnectionResolver(addressLookup: { host, port in
            [.init(address: "192.0.2.1", port: port, method: .mDNSHostname, hostname: host)]
        }, probe: { _, _, _ in false })
        do {
            _ = try await resolver.resolve(device: device(), strategy: .hostnameOnly)
            XCTFail("DNS presence alone must not count as connectivity")
        } catch {}
    }

    func test_cancellationStopsAdapterProbes() async {
        let began = expectation(description: "Probe started")
        began.assertForOverFulfill = false
        let resolver = ConnectionResolver(addressLookup: { _, _ in [] }, probe: { _, _, _ in
            began.fulfill()
            do { try await Task.sleep(for: .seconds(10)) } catch { return false }
            return true
        })
        let target = device()
        let task = Task { try await resolver.resolve(device: target, strategy: .ipOnly) }
        await fulfillment(of: [began], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled probes must not succeed")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func test_udpCandidatesDoNotRequireTCPService() async {
        let resolver = ConnectionResolver(addressLookup: { host, port in
            [.init(address: "192.0.2.3", port: port, method: .mDNSHostname, hostname: host)]
        }, probe: { _, _, _ in
            XCTFail("UDP route selection must not probe a TCP service")
            return false
        })
        let addresses = await resolver.connectionCandidates(for: device())
        XCTAssertEqual(addresses, ["192.0.2.1", "192.0.2.2", "192.0.2.3"])
    }

    func test_savedDevicesFromPreviousVersionDecode_andIdentitySurvivesHandoff() throws {
        var original = device()
        original.networkAddresses = nil
        let data = try JSONEncoder().encode(original)
        var decoded = try JSONDecoder().decode(DiscoveredDevice.self, from: data)
        XCTAssertNil(decoded.networkAddresses)
        XCTAssertEqual(decoded.connectionAddresses, ["192.0.2.1"])
        decoded.rememberAddress(decoded.ipAddress)
        decoded.rememberAddress("192.0.2.2")
        decoded.ipAddress = "192.0.2.2"
        XCTAssertEqual(decoded.identityKey, original.identityKey)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.connectionAddresses, ["192.0.2.1", "192.0.2.2"])
    }

    func test_adapterTXTIsBoundedValidatedAndRetainsLabels() throws {
        let addresses = try XCTUnwrap(device().networkAddresses)
        XCTAssertEqual(DeviceNetworkAddress.fromTXT(DeviceNetworkAddress.txtValue(addresses)), addresses)
        XCTAssertNil(DeviceNetworkAddress.fromTXT(nil))
        XCTAssertEqual(DeviceNetworkAddress.fromTXT(""), [])
        XCTAssertEqual(DeviceNetworkAddress.fromTXT("garbage|wifi,192.0.2.1|wifi,192.0.2.1|ethernet"), [addresses[0]])
        let many = (1...100).map { DeviceNetworkAddress(address: "192.0.2.\($0)", kind: .ethernet) }
        XCTAssertLessThanOrEqual(DeviceNetworkAddress.txtValue(many).utf8.count + "addrs=".utf8.count, 255)
    }
}
