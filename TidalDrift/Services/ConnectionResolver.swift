import Foundation
import Network
import OSLog

/// Resolves device addresses with bounded, cancellable DNS and connectivity checks.
actor ConnectionResolver {
    static let shared = ConnectionResolver()
    
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ConnectionResolver")
    private let lookup: @Sendable (String, Int) -> ResolvedAddress?
    
    /// Resolution strategy - determines the order of resolution attempts
    enum ResolutionStrategy {
        case hostnameFirst    // Prefer .local hostname (most reliable)
        case ipFirst          // Try cached IP first (faster if valid)
        case hostnameOnly     // Only use hostname resolution
        case ipOnly           // Only use cached IP
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
    
    init(lookup: @escaping @Sendable (String, Int) -> ResolvedAddress? = { hostname, port in
        ConnectionResolver.blockingGetaddrinfo(hostname: hostname, port: port)
    }) {
        self.lookup = lookup
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
    
    /// Quick connection test to verify an address is reachable
    func testConnection(address: String, port: Int, timeout: TimeInterval = 3.0) async -> Bool {
        guard !Task.isCancelled, !address.isEmpty, timeout.isFinite, timeout > 0,
              let rawPort = UInt16(exactly: port), rawPort > 0,
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else { return false }
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

    /// Try to resolve via mDNS hostname (.local)
    private func tryHostnameResolution(device: DiscoveredDevice, timeout: TimeInterval) async -> ResolvedAddress? {
        // Build the .local hostname
        let hostname = cleanHostname(device.hostname)
        guard !hostname.isEmpty else { return nil }
        
        let localHostname = hostname.contains(".") ? hostname : "\(hostname).local"
        logger.debug("🔍 Trying mDNS resolution: \(localHostname)")
        
        // Use getaddrinfo which respects mDNS
        return await resolveHostnameToIP(localHostname, port: device.port, timeout: timeout)
    }
    
    /// Try using cached IP address after verifying connectivity
    private func tryCachedIP(device: DiscoveredDevice, timeout: TimeInterval) async -> ResolvedAddress? {
        let ip = device.ipAddress
        guard !ip.isEmpty, ip != "Unknown", ip != "Resolving..." else { return nil }
        
        if let localIP = NetworkUtils.getLocalIPAddress(), ip == localIP {
            logger.warning("⚠️ Cached IP \(ip) is our own IP — skipping to avoid self-connection")
            return nil
        }
        
        logger.debug("🔍 Verifying cached IP: \(ip):\(device.port)")
        
        // Quick connectivity test
        let reachable = await testConnection(address: ip, port: device.port, timeout: min(timeout, 2.0))
        
        if reachable {
            return ResolvedAddress(
                address: ip,
                port: device.port,
                method: .cachedIP,
                hostname: device.hostname
            )
        }
        
        logger.debug("⚠️ Cached IP \(ip) is not reachable")
        return nil
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
                .resolved(await self.performGetaddrinfo(hostname: hostname, port: port))
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
    
    /// Bridge the blocking getaddrinfo onto the dedicated queue.
    private func performGetaddrinfo(hostname: String, port: Int) async -> ResolvedAddress? {
        let result = AsyncCallbackResult<ResolvedAddress>()
        let lookup = self.lookup
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            Self.getaddrinfoQueue.async {
                let address = lookup(hostname, port)
                Task { await result.finish(address) }
            }
            return await result.wait()
        } onCancel: {
            Task { await result.finish(nil) }
        }
    }

    /// Actual getaddrinfo call. Blocking; must only run on `getaddrinfoQueue`.
    private static func blockingGetaddrinfo(hostname: String, port: Int) -> ResolvedAddress? {
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
        
        guard status == 0, let addrInfo = result else {
            logger.debug("⚠️ getaddrinfo failed for \(hostname): \(String(cString: gai_strerror(status)))")
            return nil
        }
        
        // Extract IPv4 address
        if let sockaddr = addrInfo.pointee.ai_addr {
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                var sin_addr = addr.pointee.sin_addr
                inet_ntop(AF_INET, &sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            }
            
            let ip = String(cString: ipBuffer)
            if !ip.isEmpty && ip != "0.0.0.0" {
                // Guard: reject if the hostname resolved to our own IP.
                // This happens when two Macs share a similar default hostname
                // and mDNS resolves the ambiguous name to the local machine.
                if let localIP = NetworkUtils.getLocalIPAddress(), ip == localIP {
                    logger.warning("⚠️ Hostname \(hostname) resolved to local IP \(ip) — skipping to avoid self-connection")
                    return nil
                }
                
                logger.debug("✅ Resolved \(hostname) -> \(ip)")
                
                return ResolvedAddress(
                    address: ip,
                    port: port,
                    method: .mDNSHostname,
                    hostname: hostname
                )
            }
        }
        
        return nil
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
