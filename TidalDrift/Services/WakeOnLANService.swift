import Foundation
import Network

/// Service for sending Wake-on-LAN magic packets to wake sleeping Macs
class WakeOnLANService {
    static let shared = WakeOnLANService()

    private let resolver: ConnectionResolver

    init(resolver: ConnectionResolver = .shared) {
        self.resolver = resolver
    }

    struct WakePacketTarget: Hashable {
        let address: String
        let port: UInt16
    }

    // MARK: - Magic Packet Generation

    /// Wake a device using its MAC address
    /// - Parameters:
    ///   - macAddress: MAC address in format "AA:BB:CC:DD:EE:FF" or "AA-BB-CC-DD-EE-FF"
    ///   - broadcastAddress: Broadcast address (default: 255.255.255.255)
    ///   - port: WOL port (uses settings if nil)
    /// - Returns: True if packet was sent successfully
    func wake(macAddress: String, broadcastAddress: String = "255.255.255.255", port: UInt16? = nil) async -> Bool {
        // Check if WOL is enabled in settings
        let settings = AppState.shared.settings
        guard settings.wakeOnLANEnabled else {
            return false
        }

        guard let macBytes = parseMACAddress(macAddress) else {
            return false
        }

        guard let wolPort = port ?? UInt16(exactly: settings.wakeOnLANPort), wolPort > 0 else { return false }
        let retries = settings.wakeOnLANRetries

        let magicPacket = createMagicPacket(macBytes: macBytes)

        // Send multiple packets based on retry setting
        var success = false
        for _ in 0..<max(0, retries) {
            guard !Task.isCancelled else { return success }
            if await sendPacket(magicPacket, to: broadcastAddress, port: wolPort) {
                success = true
            }
            // Small delay between retries
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        return success
    }

    /// Wake a device using limited and directed broadcasts on common WOL ports.
    func wakeBroadly(macAddress: String) async -> Bool {
        let settings = AppState.shared.settings
        guard settings.wakeOnLANEnabled else {
            return false
        }

        guard let macBytes = parseMACAddress(macAddress) else {
            return false
        }

        let magicPacket = createMagicPacket(macBytes: macBytes)
        guard let port = UInt16(exactly: settings.wakeOnLANPort), port > 0 else { return false }
        let targets = wakePacketTargets(primaryPort: port)
        var success = false

        for _ in 0..<max(0, settings.wakeOnLANRetries) {
            guard !Task.isCancelled else { return success }
            for target in targets {
                if await sendPacket(magicPacket, to: target.address, port: target.port) {
                    success = true
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return success
    }

    /// Wake a device and wait for it to come online
    /// - Parameters:
    ///   - macAddress: MAC address
    ///   - ipAddress: Expected IP address to ping
    ///   - timeout: Maximum time to wait (seconds)
    /// - Returns: True if device came online within timeout
    func wakeAndWait(macAddress: String, ipAddress: String, timeout: TimeInterval = 60) async -> Bool {
        // Send wake packet
        guard await wakeBroadly(macAddress: macAddress) else {
            return false
        }

        // Wait for device to come online
        let startTime = Date()
        while !Task.isCancelled, Date().timeIntervalSince(startTime) < timeout {
            // Check if device is responding
            if await NetworkDiscoveryService.shared.scanIP(ipAddress, port: 5900) {
                return true
            }

            // Wait before retrying
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        }

        return false
    }

    func wakeAndWait(device: DiscoveredDevice, service: DiscoveredDevice.ServiceType? = nil, timeout: TimeInterval = 60) async -> Bool {
        guard let macAddress = device.storedMACAddress else {
            return false
        }
        guard await wakeBroadly(macAddress: macAddress) else {
            return false
        }

        let startTime = Date()
        while !Task.isCancelled, Date().timeIntervalSince(startTime) < timeout {
            if await isDeviceReachableAfterWake(device, service: service) {
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        return false
    }

    /// Check if Wake-on-LAN is enabled in settings
    var isEnabled: Bool {
        AppState.shared.settings.wakeOnLANEnabled
    }

    /// Check if auto-wake before connect is enabled
    var shouldAutoWakeBeforeConnect: Bool {
        let settings = AppState.shared.settings
        return settings.wakeOnLANEnabled && settings.autoWakeBeforeConnect
    }

    func prepareForConnection(to device: DiscoveredDevice, service: DiscoveredDevice.ServiceType, timeout: TimeInterval = 30) async {
        guard shouldAutoWakeBeforeConnect, !Task.isCancelled else { return }

        // LocalCast establishes readiness through its authenticated UDP
        // handshake. Waiting for TCP 5900 here delays UDP-only hosts for the
        // entire timeout, and prevents their real service traffic from waking
        // a sleep proxy. Start the viewer's handshake immediately.
        if service == .localCast {
            knock(device: device, service: service)
            return
        }

        // A sleep proxy keeps Bonjour records fresh while the Mac sleeps.
        // Check the requested service rather than trusting `isOnline`.
        if await probe(device: device, service: service, timeout: 0.5) { return }

        let token = await WakeProgressTracker.shared.begin(device: device, service: service)
        defer {
            Task { @MainActor in WakeProgressTracker.shared.end(token) }
        }

        _ = await Self.waitForReadiness(timeout: timeout, probe: { remaining in
            await self.probe(device: device, service: service, timeout: remaining)
        }, requestWake: {
            self.knock(device: device, service: service)
        })
    }

    /// Keep wake requests and service checks alive for the bounded connection
    /// attempt. Cancellation ends the wait, including its retry delay.
    static func waitForReadiness(
        timeout: TimeInterval,
        retryInterval: TimeInterval = 2,
        probe: (TimeInterval) async -> Bool,
        requestWake: () -> Void
    ) async -> Bool {
        guard timeout.isFinite, timeout > 0, retryInterval.isFinite, retryInterval > 0 else { return false }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            requestWake()
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            guard seconds > 0 else { return false }
            if await probe(min(2, seconds)), !Task.isCancelled { return true }
            let nextProbe = min(deadline, ContinuousClock.now.advanced(by: .seconds(retryInterval)))
            do {
                try await Task.sleep(until: nextProbe, clock: .continuous)
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Wake on Demand (Bonjour sleep proxy)

    /// TCP port for the macOS Screen Sharing / RFB service. A network's Bonjour
    /// sleep proxy wakes a sleeping host when it sees an inbound connection to
    /// this port, which is how Apple Screen Sharing wakes a sleeping Mac.
    private static let screenSharingPort: UInt16 = 5900

    /// Prod all known adapters and the current hostname while the actual
    /// service handshake retries. LocalCast's UDP traffic supplies its own
    /// sleep-proxy wake trigger; TCP screen sharing and WOL are fallbacks.
    /// Respects the same auto-wake setting as `prepareForConnection`.
    func knock(device: DiscoveredDevice, service: DiscoveredDevice.ServiceType = .localCast) {
        guard shouldAutoWakeBeforeConnect else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            // Do not serialize magic packets behind a dead TCP address.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.triggerWakeOnDemand(to: device, service: service, timeout: 1.5) }
                if let macAddress = device.storedMACAddress {
                    group.addTask { _ = await self.wakeBroadly(macAddress: macAddress) }
                }
            }
        }
    }

    /// Trigger a Bonjour Wake on Demand by briefly opening a TCP connection to
    /// the host's screen-sharing port. The act of attempting the connection is
    /// what prompts the network sleep proxy to wake the host; the connection
    /// does not need to fully succeed and no stored MAC address is required.
    /// The connection is always cancelled once it becomes ready, fails, or the
    /// timeout elapses, so it never blocks the connect flow.
    private func triggerWakeOnDemand(to device: DiscoveredDevice, service: DiscoveredDevice.ServiceType, timeout: TimeInterval) async {
        let ports = Set([Int(Self.screenSharingPort), Self.readinessPort(for: service, device: device)].compactMap { $0 })
        await withTaskGroup(of: Void.self) { group in
            for host in Self.wakeHosts(for: device) {
                for port in ports {
                    group.addTask {
                        _ = await self.resolver.testConnection(address: host, port: port, timeout: timeout)
                    }
                }
            }
        }
    }

    static func wakeHosts(for device: DiscoveredDevice) -> [String] {
        var hosts = device.connectionAddresses
        let rawHostname = device.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = rawHostname
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !hostname.isEmpty, rawHostname.lowercased() != "unknown", rawHostname.lowercased() != "resolving..." {
            hosts.append(hostname.contains(".") ? hostname : "\(hostname).local")
        }
        let local = Set(NetworkUtils.localNetworkAddresses().map(\.address))
        var seen = Set<String>()
        return hosts.filter { !local.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - MAC Address Parsing

    private func parseMACAddress(_ mac: String) -> [UInt8]? {
        // Support both ":" and "-" separators
        let cleanMAC = mac.replacingOccurrences(of: "-", with: ":")
        let parts = cleanMAC.split(separator: ":")

        guard parts.count == 6 else { return nil }

        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }

        return bytes
    }

    /// Validate MAC address format
    func isValidMACAddress(_ mac: String) -> Bool {
        return parseMACAddress(mac) != nil
    }

    /// Format MAC address consistently
    func formatMACAddress(_ mac: String) -> String? {
        guard let bytes = parseMACAddress(mac) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - Magic Packet Creation

    private func createMagicPacket(macBytes: [UInt8]) -> Data {
        var packet = Data()

        // Magic packet header: 6 bytes of 0xFF
        for _ in 0..<6 {
            packet.append(0xFF)
        }

        // Followed by MAC address repeated 16 times
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        return packet
    }

    // MARK: - Network Transmission

    private func sendPacket(_ packet: Data, to address: String, port: UInt16) async -> Bool {
        return await withCheckedContinuation { continuation in
            // Create UDP socket
            var sock: Int32 = -1

            sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else {
                continuation.resume(returning: false)
                return
            }

            defer { close(sock) }

            // Enable broadcast
            var broadcastEnable: Int32 = 1
            let optResult = setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
            guard optResult >= 0 else {
                continuation.resume(returning: false)
                return
            }

            // Setup destination address
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(address)

            // Send packet
            let sent = packet.withUnsafeBytes { buffer -> Int in
                withUnsafePointer(to: &addr) { addrPtr -> Int in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr -> Int in
                        sendto(sock, buffer.baseAddress, buffer.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            continuation.resume(returning: sent == packet.count)
        }
    }

    func wakePacketTargets(primaryPort: UInt16) -> [WakePacketTarget] {
        var targets: [WakePacketTarget] = []
        let addresses = ["255.255.255.255"] + interfaceBroadcastAddresses()
        let ports = Self.wakePorts(primaryPort: primaryPort)

        for address in addresses {
            for port in ports {
                targets.append(WakePacketTarget(address: address, port: port))
            }
        }

        var seen: Set<WakePacketTarget> = []
        return targets.filter { seen.insert($0).inserted }
    }

    static func wakePorts(primaryPort: UInt16) -> [UInt16] {
        var ports = [primaryPort]
        for fallback in [UInt16(9), UInt16(7)] where !ports.contains(fallback) {
            ports.append(fallback)
        }
        return ports
    }

    static func directedBroadcastAddress(ipAddress: String, netmask: String) -> String? {
        var ip = in_addr()
        var mask = in_addr()
        guard inet_pton(AF_INET, ipAddress, &ip) == 1,
              inet_pton(AF_INET, netmask, &mask) == 1 else {
            return nil
        }

        let hostIP = UInt32(bigEndian: ip.s_addr)
        let hostMask = UInt32(bigEndian: mask.s_addr)
        let broadcast = (hostIP & hostMask) | ~hostMask
        var broadcastAddr = in_addr(s_addr: broadcast.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &broadcastAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    static func macStorageKey(for device: DiscoveredDevice) -> String {
        "mac_\(device.identityKey)"
    }

    private func interfaceBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let netmaskPointer = interface.ifa_netmask else {
                continue
            }

            let addr = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var maskBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var ipAddr = addr.sin_addr
            var maskAddr = mask.sin_addr

            guard inet_ntop(AF_INET, &ipAddr, &ipBuffer, socklen_t(INET_ADDRSTRLEN)) != nil,
                  inet_ntop(AF_INET, &maskAddr, &maskBuffer, socklen_t(INET_ADDRSTRLEN)) != nil,
                  let broadcast = Self.directedBroadcastAddress(
                    ipAddress: String(cString: ipBuffer),
                    netmask: String(cString: maskBuffer)
                  ) else {
                continue
            }
            addresses.append(broadcast)
        }

        return addresses
    }

    func isDeviceReachableAfterWake(_ device: DiscoveredDevice, service: DiscoveredDevice.ServiceType?) async -> Bool {
        if let service {
            return await probe(device: device, service: service)
        }

        // Manual Wake Device may use an optional VNC response as evidence that
        // the Mac resumed, even if only LocalCast was discovered. This is not
        // a prerequisite for starting LocalCast's own UDP handshake.
        var services = device.services
        if services.contains(.localCast) { services.insert(.screenSharing) }
        // An ARP cache entry can survive sleep or belong to a sleep proxy. It
        // is not proof that the Mac or one of its services has resumed.
        return await withTaskGroup(of: Bool.self) { group in
            for service in services {
                group.addTask { await self.probe(device: device, service: service) }
            }
            for await ready in group where ready {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    static func readinessPort(for service: DiscoveredDevice.ServiceType, device: DiscoveredDevice) -> Int? {
        switch service {
        case .screenSharing, .tidalDrift:
            return device.port
        case .fileSharing:
            return 445
        case .afp:
            return 548
        case .ssh:
            return 22
        case .localCast:
            return nil
        case .tidalDrop:
            return 5902
        }
    }

    func probe(device: DiscoveredDevice, service: DiscoveredDevice.ServiceType, timeout: TimeInterval = 2) async -> Bool {
        guard let port = Self.readinessPort(for: service, device: device), !Task.isCancelled else { return false }
        var target = device
        target.port = port
        // Resolve and race all adapters; the cached primary IP may belong to
        // Wi-Fi that was disconnected while Ethernet is already awake.
        return (try? await resolver.resolve(device: target, strategy: .ipFirst, timeout: timeout)) != nil
    }

    // MARK: - MAC Address Discovery

    /// Get MAC address from IP using ARP table
    func getMACAddress(for ipAddress: String) -> String? {
        // Validate IP address format to prevent command injection
        let ipParts = ipAddress.split(separator: ".")
        guard ipParts.count == 4,
              ipParts.allSatisfy({ part in
                  guard let num = Int(part) else { return false }
                  return num >= 0 && num <= 255
              }) else {
            return nil
        }

        let result = ShellExecutor.execute(executable: "/usr/sbin/arp", arguments: ["-n", ipAddress])

        // Parse ARP output: "? (192.168.1.100) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
        let pattern = "([0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2})"

        if let range = result.output.range(of: pattern, options: .regularExpression) {
            let mac = String(result.output[range])
            return formatMACAddress(mac)
        }

        return nil
    }

    /// Scan network and get MAC addresses for all discovered devices
    func discoverMACAddresses() -> [String: String] {
        // First, ping the broadcast to populate ARP table
        _ = ShellExecutor.execute(executable: "/sbin/ping", arguments: ["-c", "1", "-t", "1", "255.255.255.255"], timeout: 5)

        // Get ARP table
        let result = ShellExecutor.execute(executable: "/usr/sbin/arp", arguments: ["-a"])

        var macAddresses: [String: String] = [:]
        let lines = result.output.split(separator: "\n")

        for line in lines {
            // Parse: "? (192.168.1.100) at aa:bb:cc:dd:ee:ff on en0"
            let lineStr = String(line)

            // Extract IP
            if let ipRange = lineStr.range(of: "\\([0-9.]+\\)", options: .regularExpression) {
                var ip = String(lineStr[ipRange])
                ip = ip.trimmingCharacters(in: CharacterSet(charactersIn: "()"))

                // Extract MAC
                if let macRange = lineStr.range(of: "([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}", options: .regularExpression) {
                    let mac = String(lineStr[macRange])
                    if let formatted = formatMACAddress(mac) {
                        macAddresses[ip] = formatted
                    }
                }
            }
        }

        return macAddresses
    }
}

// MARK: - DiscoveredDevice Extension

extension DiscoveredDevice {
    /// Store MAC address in UserDefaults. Reads walk every identity alias the
    /// computer has been keyed by (plus the legacy per-IP key) and migrate a
    /// hit to the canonical key, mirroring the credential lookup, so a stored
    /// MAC survives IP rotation and late peer-ID discovery.
    var storedMACAddress: String? {
        get {
            let canonicalKey = WakeOnLANService.macStorageKey(for: self)
            if let mac = UserDefaults.standard.string(forKey: canonicalKey) {
                return mac
            }

            var fallbackKeys = credentialAliases.dropFirst().map { "mac_\($0)" }
            fallbackKeys.append("mac_\(ipAddress)")
            for key in fallbackKeys {
                guard let mac = UserDefaults.standard.string(forKey: key) else { continue }
                UserDefaults.standard.set(mac, forKey: canonicalKey)
                UserDefaults.standard.removeObject(forKey: key)
                return mac
            }
            return nil
        }
        set {
            let canonicalKey = WakeOnLANService.macStorageKey(for: self)
            var staleKeys = credentialAliases.dropFirst().map { "mac_\($0)" }
            staleKeys.append("mac_\(ipAddress)")
            if let mac = newValue {
                UserDefaults.standard.set(mac, forKey: canonicalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: canonicalKey)
            }
            for key in staleKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Check if device supports Wake-on-LAN
    var supportsWOL: Bool {
        storedMACAddress != nil
    }
}
