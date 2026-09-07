import XCTest
@testable import TidalDrift

final class ConnectionResolverTests: XCTestCase {
    private func device(port: Int = 5900) -> DiscoveredDevice {
        DiscoveredDevice(name: "Remote", hostname: "remote.local", ipAddress: "192.0.2.2", port: port)
    }

    func test_resolve_whenDNSBlocks_returnsAtDeadline() async {
        let resolver = ConnectionResolver { _, _ in
            Thread.sleep(forTimeInterval: 1.5)
            return nil
        }
        let start = Date()
        do {
            _ = try await resolver.resolve(device: device(), strategy: .hostnameOnly, timeout: 0.03)
            XCTFail("A blocked lookup must time out")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func test_resolve_whenCancelled_releasesBlockedDNSWaiter() async throws {
        let started = expectation(description: "Lookup started")
        let release = DispatchSemaphore(value: 0)
        let resolver = ConnectionResolver { _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return nil
        }
        defer { release.signal() }
        let remote = device()
        let task = Task { try await resolver.resolve(device: remote, strategy: .hostnameOnly, timeout: 10) }
        await fulfillment(of: [started], timeout: 1)
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled lookup must throw")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func test_connectionProbe_whenPortOrTimeoutInvalid_returnsFalse() async {
        let resolver = ConnectionResolver()
        for port in [-1, 0, 65536, Int.max] {
            let result = await resolver.testConnection(address: "192.0.2.2", port: port)
            XCTAssertFalse(result)
        }
        for timeout in [Double.nan, .infinity, -1, 0] {
            let result = await resolver.testConnection(address: "192.0.2.2", port: 5900, timeout: timeout)
            XCTAssertFalse(result)
        }
    }

    func test_callbackResult_whenCancelledBeforeWait_ignoresLateSuccess() async {
        let result = AsyncCallbackResult<String>()
        await result.finish(nil)
        await result.finish("late DNS result")
        let value = await result.wait()
        XCTAssertNil(value)
    }

    func test_vncURL_whenIPv6AndReservedCredentials_encodesComponents() throws {
        let address = ConnectionResolver.ResolvedAddress(address: "fd12::1", port: 5901, method: .cachedIP, hostname: nil)
        let url = try XCTUnwrap(address.vncURL(username: "user@host", password: "p:a/s?#%"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "[fd12::1]")
        XCTAssertEqual(components.port, 5901)
        XCTAssertEqual(components.user, "user@host")
        XCTAssertEqual(components.password, "p:a/s?#%")
        XCTAssertNil(ConnectionResolver.ResolvedAddress(address: "192.0.2.2", port: -1, method: .cachedIP, hostname: nil).vncURL)
    }
}
