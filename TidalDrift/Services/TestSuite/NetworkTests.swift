import Foundation
import Network

extension TidalDriftTestRunner {

    func testUDPPortBind() async -> (Bool, String) {
        testBSDSocketBind(label: "UDP", type: SOCK_DGRAM, port: 15904)
    }

    func testTCPPortBind() async -> (Bool, String) {
        testBSDSocketBind(label: "TCP", type: SOCK_STREAM, port: 15902)
    }

    /// Tests port binding using BSD sockets on loopback.
    /// NWListener requires Local Network permission (which the build script resets),
    /// so we use raw sockets to test the kernel's ability to bind without needing
    /// any TCC entitlement.
    private func testBSDSocketBind(label: String, type: Int32, port: UInt16) -> (Bool, String) {
        let sock = socket(AF_INET, type, 0)
        guard sock >= 0 else {
            return (false, "\(label) socket() failed: errno \(errno)")
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return (true, "\(label) bound to loopback:\(port)")
        }
        let err = errno
        let msg: String
        switch err {
        case EADDRINUSE: msg = "port already in use"
        case EACCES:     msg = "permission denied"
        default:         msg = "errno \(err)"
        }
        return (false, "\(label) bind failed on loopback:\(port) — \(msg)")
    }

    func testLoopbackTCPRoundtrip() async -> (Bool, String) {
        let testPort: UInt16 = 15910
        let testPayload = "TidalDrift-TCP-Test-\(UUID().uuidString)"
        var receivedData: String?

        let listener: NWListener
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: testPort)!)
            listener = try NWListener(using: params)
        } catch {
            return (false, "Cannot create TCP listener: \(error.localizedDescription)")
        }

        let queue = DispatchQueue(label: "test.tcp.roundtrip")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                if let data = data, let str = String(data: data, encoding: .utf8) {
                    receivedData = str
                    conn.send(content: data, completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
        }
        listener.start(queue: queue)

        defer { listener.cancel() }

        try? await Task.sleep(nanoseconds: 500_000_000)

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: testPort)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        var echoReceived: String?

        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: testPayload.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                        if let data = data { echoReceived = String(data: data, encoding: .utf8) }
                        conn.cancel()
                    }
                })
            }
        }
        conn.start(queue: queue)

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if echoReceived != nil { break }
        }

        if let echo = echoReceived, echo == testPayload {
            return (true, "TCP loopback echo: sent and received \(testPayload.count) bytes")
        }
        if receivedData != nil {
            return (false, "Server received data but client did not get echo back")
        }
        return (false, "TCP loopback roundtrip timed out")
    }

    func testLoopbackUDPRoundtrip() async -> (Bool, String) {
        let testPort: UInt16 = 15911
        let testPayload = "TidalDrift-UDP-Test-\(UUID().uuidString)"
        var received = false

        let listener: NWListener
        do {
            let params = NWParameters.udp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: testPort)!)
            listener = try NWListener(using: params)
        } catch {
            return (false, "Cannot create UDP listener: \(error.localizedDescription)")
        }

        let queue = DispatchQueue(label: "test.udp.roundtrip")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receiveMessage { data, _, _, _ in
                if let data = data, String(data: data, encoding: .utf8) == testPayload {
                    received = true
                }
                conn.cancel()
            }
        }
        listener.start(queue: queue)

        defer { listener.cancel() }

        try? await Task.sleep(nanoseconds: 500_000_000)

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: testPort)!)
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                conn.send(content: testPayload.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        conn.start(queue: queue)

        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if received { break }
        }

        return (received,
                received ? "UDP loopback: sent and received \(testPayload.count) bytes"
                         : "UDP loopback roundtrip timed out")
    }

    func testWakeOnLANBroadcastPlanning() async -> (Bool, String) {
        guard WakeOnLANService.directedBroadcastAddress(
            ipAddress: "192.168.12.34",
            netmask: "255.255.255.0"
        ) == "192.168.12.255" else {
            return (false, "Directed broadcast calculation failed for /24")
        }

        let ports = WakeOnLANService.wakePorts(primaryPort: 9)
        guard ports == [9, 7] else {
            return (false, "Expected WOL ports [9, 7], got \(ports)")
        }

        let alternatePorts = WakeOnLANService.wakePorts(primaryPort: 40000)
        guard alternatePorts == [40000, 9, 7] else {
            return (false, "Expected custom port plus fallbacks, got \(alternatePorts)")
        }

        return (true, "WOL planner includes directed broadcast and port fallbacks")
    }

    func testWakeOnLANMACMigration() async -> (Bool, String) {
        let device = DiscoveredDevice(
            name: "WOL Test",
            hostname: "wol-test.local",
            ipAddress: "198.51.100.10",
            peerId: "wol-test-\(UUID().uuidString)"
        )
        let legacyKey = "mac_\(device.ipAddress)"
        let identityKey = WakeOnLANService.macStorageKey(for: device)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: identityKey)
        UserDefaults.standard.set("AA:BB:CC:DD:EE:FF", forKey: legacyKey)

        guard device.storedMACAddress == "AA:BB:CC:DD:EE:FF" else {
            return (false, "Legacy MAC was not readable")
        }
        guard UserDefaults.standard.string(forKey: identityKey) == "AA:BB:CC:DD:EE:FF" else {
            return (false, "Legacy MAC did not migrate to identity key")
        }
        guard UserDefaults.standard.string(forKey: legacyKey) == nil else {
            return (false, "Legacy MAC key was not removed after migration")
        }

        var mutable = device
        mutable.storedMACAddress = nil
        return (true, "MAC storage migrated from IP key to identity key")
    }
}
