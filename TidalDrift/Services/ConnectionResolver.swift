import Foundation
import Network
import OSLog

/// Resolves device addresses with bounded, cancellable DNS and connectivity checks.
actor ConnectionResolver {
    static let shared = ConnectionResolver()
    
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ConnectionResolver")
    private let lookup: @Sendable (String, Int) -> [ResolvedAddress]
    private let probe: (@Sendable (String, Int, TimeInterval) async -> Bool)?
    
    /// Resolution strategy - determines the order of resolution attempts
    enum ResolutionStrategy {
        case hostnameFirst    // Prefer .local hostname (most reliable)
        case ipFirst          // Try cached IP first (faster if valid)
        case hostnameOnly     // Only use hostname resolution
        case ipOnly           // Only use cached adapter addresses
    }
    
    /// Result of address resolution
    struct ResolvedAddress: Sendable {
        let address: String           // The resolved IP address or hostname
        let port: Int
        let method: ResolutionMethod  // How this address was resolved
        let hostname: String?         // The original hostname (if available)
        
        /// Construct a VNC URL for this resolved address
        var vncURL: URL? {
            vncURL(username: nil, password: nil)
        }
        
        /// Construct a VNC URL with credentials
        func vncURL(username: String?, password: String?) -> URL? {
            guard (1...65535).contains(port), !address.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "vnc"
            components.host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
            components.port = port
            if let username, !username.isEmpty {
                components.user = username
                if let password, !password.isEmpty { components.password = password }
            }
            return components.url
        }
    }
    
    enum ResolutionMethod: String {
        case mDNSHostname = "mDNS"      // Resolved via .local hostname
        case cachedIP = "CachedIP"       // Used cached IP directly
        case freshIPLookup = "IPLookup"  // Re-resolved IP via getaddrinfo
    }
    
    enum ResolutionError: LocalizedError {
        case allMethodsFailed(attempts: [String])
        case timeout
        case invalidDevice
        
        var errorDescription: String? {
            switch self {
            case .allMethodsFailed(let attempts):
                return "Failed to resolve address. Tried: \(attempts.joined(separator: ", "))"
            case .timeout:
                return "Address resolution timed out"
            case .invalidDevice:
                return "Invalid device information"
            }
        }
    }
    
    init(
        addressLookup: @escaping @Sendable (String, Int) -> [ResolvedAddress] = {
            ConnectionResolver.blockingGetaddrinfo(hostname: $0, port: $1)
        },
        probe: (@Sendable (String, Int, TimeInterval) async -> Bool)? = nil
    ) {
        self.lookup = addressLookup
        self.probe = probe
    }

    init(lookup: @escaping @Sendable (String, Int) -> ResolvedAddress?) {
        self.lookup = { hostname, port in lookup(hostname, port).map { [$0] } ?? [] }
        self.probe = nil
    }

    // MARK: - Public API
    
    /// Resolve the best address for connecting to a device
    /// - Parameters:
    ///   - device: The device to connect to
    ///   - strategy: Resolution strategy (default: hostnameFirst)
    ///   - timeout: Maximum time to spend resolving (default: 10 seconds)
    /// - Returns: A resolved address ready for connection
    func resolve(
        device: DiscoveredDevice,
        strategy: ResolutionStrategy = .hostnameFirst,
        timeout: TimeInterval = 10.0
    ) async throws -> ResolvedAddress {
        try Task.checkCancellation()
        guard (1...65535).contains(device.port), timeout.isFinite, timeout > 0 else {
            throw ResolutionError.invalidDevice
        }
        logger.info("🔍 Resolving address for '\(device.name)' using strategy: \(String(describing: strategy))")
        logger.info("🔍 Device info - hostname: \(device.hostname), ip: \(device.ipAddress), port: \(device.port)")
        
        var failedAttempts: [String] = []
        
        switch strategy {
        case .hostnameFirst:
            // Strategy 1: Try mDNS hostname first (most reliable). The old
            // "fresh IP lookup" second step ran the identical getaddrinfo
            // call again, burning a third of the timeout budget on a repeat.
            if let resolved = await tryHostnameResolution(device: device, timeout: timeout / 2) {
                logger.info("✅ Resolved via mDNS hostname: \(resolved.address)")
                return resolved
            }
            failedAttempts.append("mDNS hostname")
            
            // Strategy 2: Fall back to cached IP (verify connectivity)
            if let resolved = await tryCachedIP(device: device, timeout: timeout / 2) {
                logger.info("✅ Using verified cached IP: \(resolved.address)")
                return resolved
            }
            failedAttempts.append("Cached IP")
            
        case .ipFirst:
            // Race the cached-IP probe against the mDNS hostname lookup and
            // take whichever lands first. On a healthy LAN the TCP probe of
            // the cached IP wins in milliseconds; when the cached IP is stale
            // the hostname lookup is already in flight instead of only
            // starting after the probe times out, so the worst case is the
            // slower of the two rather than their sum.
            if let resolved = await raceCachedIPAndHostname(device: device, timeout: timeout) {
                return resolved
            }
            failedAttempts.append("Cached IP")
            failedAttempts.append("mDNS hostname")
            
        case .hostnameOnly:
            if let resolved = await tryHostnameResolution(device: device, timeout: timeout) {
                return resolved
            }
            failedAttempts.append("mDNS hostname (only method)")
            
        case .ipOnly:
            if let resolved = await tryCachedIP(device: device, timeout: timeout) {
                return resolved
            }
            failedAttempts.append("Cached IP (only method)")
        }
        
        try Task.checkCancellation()
        logger.error("❌ All resolution methods failed for '\(device.name)'")
        throw ResolutionError.allMethodsFailed(attempts: failedAttempts)
    }
    
    /// UDP callers must verify the application response, not TCP readiness.
    /// Supply all candidates with a bounded DNS wait for their handshake retries.
    func connectionCandidates(for device: DiscoveredDevice, timeout: TimeInterval = 0.5) async -> [String] {
        guard timeout.isFinite, timeout > 0, !Task.isCancelled else { return [] }
        let hostname = cleanHostname(device.hostname)
        let fresh: [ResolvedAddress] = await withTaskGroup(of: [ResolvedAddress].self) { group in
            guard !hostname.isEmpty else { return [] }
            group.addTask {
                await self.performGetaddrinfo(hostname: hostname.contains(".") ? hostname : "\(hostname).local", port: device.port)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
        guard !Task.isCancelled else { return [] }
        let local = Set(NetworkUtils.localNetworkAddresses().map(\.address))
        var seen = Set<String>()
        return (device.connectionAddresses + fresh.map(\.address)).filter {
            !local.contains($0) && seen.insert($0).inserted
        }
    }

    /// Quick connection test to verify an address is reachable
    func testConnection(address: String, port: Int, timeout: TimeInterval = 3.0) async -> Bool {
        guard !Task.isCancelled, !address.isEmpty, timeout.isFinite, timeout > 0,
              let rawPort = UInt16(exactly: port), rawPort > 0,
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else { return false }
        if let probe { return await probe(address, port, timeout) }
        let result = AsyncCallbackResult<Bool>()
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        return await withTaskCancellationHandler {
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await result.finish(true) }
                case .failed, .cancelled:
                    Task { await result.finish(false) }
                default:
                    break
                }
            }
            
            connection.start(queue: .global(qos: .userInitiated))
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                await result.finish(false)
            }
            let reachable = await result.wait() ?? false
            deadline.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            return !Task.isCancelled && reachable
        } onCancel: {
            connection.cancel()
            Task { await result.finish(false) }
        }
    }
    
    // MARK: - Private Resolution Methods

    /// Run the cached-IP connectivity probe and the mDNS hostname resolution
    /// concurrently, returning the first success. Nil when both fail.
    private func raceCachedIPAndHostname(device: DiscoveredDevice, timeout: TimeInterval) async -> ResolvedAddress? {
        await withTaskGroup(of: ResolvedAddress?.self) { group in
            group.addTask {
                await self.tryCachedIP(device: device, timeout: min(timeout, 2.0))
            }
            group.addTask {
                await self.tryHostnameResolution(device: device, timeout: timeout)
            }

            var winner: ResolvedAddress?
            for await result in group {
                if let result {
                    winner = result
                    group.cancelAll()
                    break
                }
            }
            return winner
        }
    }

    /// Resolve all mDNS addresses and return the first reachable service.
    private func tryHostnameResolution(device: DiscoveredDevice, timeout: TimeInterval) async -> ResolvedAddress? {
        // Build the .local hostname
        let hostname = cleanHostname(device.hostname)
        guard !hostname.isEmpty else { return nil }
        
        let localHostname = hostname.contains(".") ? hostname : "\(hostname).local"
        logger.debug("🔍 Trying mDNS resolution: \(localHostname)")
        
        // Use getaddrinfo which respects mDNS
        return await resolveHostnameToIP(localHostname, port: device.port, timeout: timeout)
    }
    
    /// Race cached adapter addresses after verifying service connectivity.
    private func tryCachedIP(device: DiscoveredDevice, timeout: TimeInterval) async -> ResolvedAddress? {
        let addresses = device.connectionAddresses.map {
            ResolvedAddress(address: $0, port: device.port, method: .cachedIP, hostname: device.hostname)
        }
        return await firstReachable(addresses, timeout: timeout)
    }

    /// Race all adapters. A stale Wi-Fi address cannot hold up Ethernet.
    private func firstReachable(_ addresses: [ResolvedAddress], timeout: TimeInterval) async -> ResolvedAddress? {
        let localIPs = Set(NetworkUtils.localNetworkAddresses().map(\.address))
        return await withTaskGroup(of: ResolvedAddress?.self) { group in
            var seen = Set<String>()
            for address in addresses where !localIPs.contains(address.address) && seen.insert(address.address).inserted {
                group.addTask {
                    guard await self.testConnection(address: address.address, port: address.port, timeout: timeout),
                          !Task.isCancelled else { return nil }
                    return address
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// Dedicated queue for blocking getaddrinfo calls. Concurrent so one slow
    /// mDNS lookup (which can block 5-30s for a gone host) cannot serialize
    /// behind another, and off the Swift concurrency cooperative pool so a
    /// blocked lookup never starves unrelated async work.
    private static let getaddrinfoQueue = DispatchQueue(
        label: "com.tidaldrift.resolver.getaddrinfo",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Resolve hostname to IP using getaddrinfo, bounded by `timeout`.
    ///
    /// The timeout must be decided by whichever child finishes FIRST. The
    /// previous implementation kept looping past the timeout sentinel and
    /// awaited the lookup child anyway, so a blocked getaddrinfo held the
    /// whole connect flow for its full duration (the "connect hangs forever"
    /// symptom). When the timeout wins, the orphaned lookup finishes later on
    /// its own queue and is discarded.
    private func resolveHostnameToIP(_ hostname: String, port: Int, timeout: TimeInterval) async -> ResolvedAddress? {
        enum Outcome {
            case resolved(ResolvedAddress?)
            case timedOut
        }
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                .resolved(await self.resolveReachableHostname(hostname, port: port, timeout: timeout))
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }

            var resolved: ResolvedAddress?
            if let first = await group.next() {
                switch first {
                case .resolved(let address):
                    resolved = address
                case .timedOut:
                    self.logger.debug("⚠️ getaddrinfo timed out after \(timeout)s for \(hostname)")
                    resolved = nil
                }
            }
            group.cancelAll()
            return resolved
        }
    }
    
    private func resolveReachableHostname(_ hostname: String, port: Int, timeout: TimeInterval) async -> ResolvedAddress? {
        let addresses = await performGetaddrinfo(hostname: hostname, port: port)
        guard !Task.isCancelled else { return nil }
        return await firstReachable(addresses, timeout: timeout)
    }

    /// Bridge the blocking getaddrinfo onto the dedicated queue.
    private func performGetaddrinfo(hostname: String, port: Int) async -> [ResolvedAddress] {
        let result = AsyncCallbackResult<[ResolvedAddress]>()
        let lookup = self.lookup
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [] }
            Self.getaddrinfoQueue.async {
                let address = lookup(hostname, port)
                Task { await result.finish(address) }
            }
            return await result.wait() ?? []
        } onCancel: {
            Task { await result.finish(nil) }
        }
    }

    /// Actual getaddrinfo call. Blocking; must only run on `getaddrinfoQueue`.
    private static func blockingGetaddrinfo(hostname: String, port: Int) -> [ResolvedAddress] {
        let logger = Logger(subsystem: "com.tidaldrift", category: "ConnectionResolver")
        var hints = addrinfo()
        hints.ai_family = AF_INET // IPv4
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = 0 // Allow mDNS resolution
        
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        
        defer {
            if result != nil {
                freeaddrinfo(result)
            }
        }
        
        guard status == 0 else {
            logger.debug("getaddrinfo failed for \(hostname): \(status)")
            return []
        }
        var addresses: [ResolvedAddress] = []
        var current = result
        while let info = current {
            defer { current = info.pointee.ai_next }
            guard let address = info.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, info.pointee.ai_addrlen, &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            guard ip != "0.0.0.0", !ip.hasPrefix("127.") else { continue }
            addresses.append(ResolvedAddress(address: ip, port: port, method: .mDNSHostname, hostname: hostname))
        }
        return addresses
    }

    /// Clean up hostname for resolution
    private func cleanHostname(_ hostname: String) -> String {
        // Remove trailing periods and normalize
        let clean = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        // Handle cases where hostname might be an IP
        if NetworkUtils.isValidIPAddress(clean) {
            return ""
        }
        
        return clean
    }
}
