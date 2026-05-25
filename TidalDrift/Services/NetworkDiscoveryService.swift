import Foundation
import Network
import Combine
import OSLog

private func runDnsSdLookup(name: String, type: String, domain: String, timeout: TimeInterval, maxLines: Int, logger: Logger) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
    process.arguments = ["-L", name, type, domain]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let outputLock = NSLock()
    var outputData = Data()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        outputLock.lock()
        outputData.append(data)
        outputLock.unlock()
    }
    process.terminationHandler = { _ in
        finished.signal()
    }
    do {
        try process.run()
    } catch {
        logger.warning("dns-sd -L failed to start for \(name): \(error.localizedDescription)")
        return ""
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let remaining = pipe.fileHandleForReading.availableData
    outputLock.lock()
    outputData.append(remaining)
    let data = outputData
    outputLock.unlock()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output
        .split(separator: "\n")
        .prefix(maxLines)
        .joined(separator: "\n")
}

class NetworkDiscoveryService: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "Discovery")
    static let shared = NetworkDiscoveryService()

    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var lastScanDate: Date?

    private var browsers: [NWBrowser] = []
    private var netServiceBrowser: NetServiceBrowser?
    private var udpListener: NWListener?
    private var deviceCache: [String: DiscoveredDevice] = [:]
    private let deviceCacheLock = NSLock()  // Thread-safe access to deviceCache
    private var scanTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var hasObservedInitialPath = false
    private let queue = DispatchQueue(label: "com.tidaldrift.discovery", qos: .userInitiated)

    private var publishDebounceWorkItem: DispatchWorkItem?

    // Store active connections to prevent premature deallocation
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()

    // Persistence keys
    private let savedDevicesKey = "com.tidaldrift.savedDevices"
    private let lastScanDateKey = "com.tidaldrift.lastScanDate"

    // Extended service types for better discovery
    private let serviceTypes: [String] = [
        "_rfb._tcp",           // VNC/Screen Sharing
        "_smb._tcp",           // Windows/Samba File Sharing
        "_afpovertcp._tcp",    // AFP (Apple Filing Protocol)
        "_ssh._tcp",           // SSH
        "_tidaldrift._tcp",    // TidalDrift Discovery
        "_tidaldrop._tcp",     // TidalDrop Transfer
        "_tidaldrift-cast._udp" // LocalCast Transfer
    ]

    private override init() {
        super.init()
        loadSavedDevices()

        // Clean stale devices on startup (devices not seen in 5+ minutes)
        clearStaleDevices()

        // Defer network setup to avoid blocking on init
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.setupNetworkMonitor()
            self?.startUDPListener()
        }
    }

    func startUDPListener() {
        let params = NWParameters.udp

        do {
            udpListener = try NWListener(using: params, on: 5903)
            udpListener?.stateUpdateHandler = { state in
                if case .ready = state { print("🌊 UDP Listener: Ready on port 5903") }
            }

            udpListener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receiveMessages(on: connection)
            }
            udpListener?.start(queue: queue)
        } catch {
            print("❌ UDP Listener: Initialization failed: \(error)")
        }
    }

    private func receiveMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let data = data, !data.isEmpty {
                if let peerInfo = try? JSONDecoder().decode(TidalDriftPeerService.PeerInfo.self, from: data) {
                    print("🌊 UDP Heartbeat: Received from \(peerInfo.hostname) (\(peerInfo.ipAddress))")
                    self?.markAsTidalDriftPeer(hostname: peerInfo.hostname, peerInfo: peerInfo)
                }
            }

            if error == nil {
                self?.receiveMessages(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    // MARK: - Persistence

    /// Load previously discovered devices from storage
    private func loadSavedDevices() {
        if let data = UserDefaults.standard.data(forKey: savedDevicesKey) {
            do {
                let devices = try JSONDecoder().decode([DiscoveredDevice].self, from: data)

                // Load into cache by stable identity so DHCP changes do not
                // create duplicate saved devices.
                deviceCacheLock.lock()
                for device in devices {
                    deviceCache[cacheKey(for: device)] = device
                }
                deviceCacheLock.unlock()

                // Update published devices from the deduped cache.
                discoveredDevices = Array(deviceCache.values).sorted { $0.name < $1.name }

                // Load last scan date
                if let scanDate = UserDefaults.standard.object(forKey: lastScanDateKey) as? Date {
                    lastScanDate = scanDate
                }

                #if DEBUG
                print("✅ Loaded \(devices.count) saved devices")
                #endif
            } catch {
                #if DEBUG
                print("❌ Failed to load saved devices: \(error)")
                #endif
            }
        }
    }

    /// Save current devices to storage
    private func saveDevices() {
        deviceCacheLock.lock()
        let devices = Array(deviceCache.values)
        deviceCacheLock.unlock()

        do {
            let data = try JSONEncoder().encode(devices)
            UserDefaults.standard.set(data, forKey: savedDevicesKey)

            if let scanDate = lastScanDate {
                UserDefaults.standard.set(scanDate, forKey: lastScanDateKey)
            }

            #if DEBUG
            print("💾 Saved \(devices.count) devices")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to save devices: \(error)")
            #endif
        }
    }

    /// Clear all saved devices
    func clearSavedDevices() {
        deviceCacheLock.lock()
        deviceCache.removeAll()
        deviceCacheLock.unlock()
        discoveredDevices.removeAll()
        lastScanDate = nil
        UserDefaults.standard.removeObject(forKey: savedDevicesKey)
        UserDefaults.standard.removeObject(forKey: lastScanDateKey)
    }

    /// Check if a device is stale (not seen recently)
    func isDeviceStale(_ device: DiscoveredDevice) -> Bool {
        let staleThreshold: TimeInterval = 24 * 60 * 60 // 24 hours
        return Date().timeIntervalSince(device.lastSeen) > staleThreshold
    }

    /// Remove a specific device by IP
    func removeDevice(ipAddress: String) {
        deviceCacheLock.lock()
        deviceCache = deviceCache.filter { $0.value.ipAddress != ipAddress }
        deviceCacheLock.unlock()
        updatePublishedDevices()
        saveDevices()
    }

    /// Clear all stale devices (not seen recently) - includes peers
    /// Uses 2 minutes for TidalDrift peers, 5 minutes for other devices
    func clearStaleDevices() {
        let peerStaleThreshold: TimeInterval = 2 * 60 // 2 minutes for peers
        let deviceStaleThreshold: TimeInterval = 5 * 60 // 5 minutes for other devices

        deviceCacheLock.lock()
        let staleIPs = deviceCache.filter { entry in
            let threshold = entry.value.isTidalDriftPeer ? peerStaleThreshold : deviceStaleThreshold
            return Date().timeIntervalSince(entry.value.lastSeen) > threshold
        }.map { $0.key }

        for ip in staleIPs {
            deviceCache.removeValue(forKey: ip)
        }
        deviceCacheLock.unlock()

        if !staleIPs.isEmpty {
            updatePublishedDevices()
            saveDevices()
            print("🧹 Cleared \(staleIPs.count) stale devices on startup/scan")
        }
    }

    /// Clear ALL devices and rediscover (full reset)
    func clearAllAndRescan() {
        deviceCacheLock.lock()
        deviceCache.removeAll()
        deviceCacheLock.unlock()
        updatePublishedDevices()
        saveDevices()
        print("🧹 Cleared all devices - starting fresh discovery")

        // Trigger fresh discovery
        refreshScan()
    }

    private func setupNetworkMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                guard let self else { return }
                if !self.hasObservedInitialPath {
                    self.hasObservedInitialPath = true
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.refreshScan()
                    TidalDriftPeerService.shared.restartAll()
                }
            }
        }
        pathMonitor?.start(queue: queue)
    }

    func startBrowsing() {
        guard browsers.isEmpty else { return }

        for serviceType in serviceTypes {
            // Skip UDP services in NWBrowser - use dns-sd instead.
            if serviceType.contains("_udp") {
                logger.info("🌊 Skipping \(serviceType) for NWBrowser - will use dns-sd")
                continue
            }

            let params = NWParameters()
            params.includePeerToPeer = true

            for domain in ["local.", ""] {
                let actualDomain = domain.isEmpty ? nil : domain
                let browser = NWBrowser(for: .bonjour(type: serviceType, domain: actualDomain), using: params)

                browser.stateUpdateHandler = { [weak self] state in
                    self?.handleBrowserState(state, for: serviceType)
                }
                browser.browseResultsChangedHandler = { [weak self] results, changes in
                    self?.handleBrowseResults(results, changes: changes, serviceType: serviceType)
                }

                browser.start(queue: queue)
                browsers.append(browser)
            }
        }

        // The helper forks `dns-sd`; keep the Process.run off main, but keep
        // the service lifecycle itself main-owned.
        queue.async { [weak self] in
            self?.startNetServiceBrowserForLocalCast()
        }

        lastScanDate = Date()

        Task {
            await scanARPTable()
        }
    }

    /// Use dns-sd command for UDP service discovery (more reliable than NWBrowser/NetServiceBrowser for UDP)
    private var dnsSdBrowseProcess: Process?

    private func startNetServiceBrowserForLocalCast() {
        logger.info("🌊 Starting dns-sd browse for _tidaldrift-cast._udp")

        // Use dns-sd -B to browse for services
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-B", "_tidaldrift-cast._udp", "local."]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        dnsSdBrowseProcess = process

        // Read output asynchronously
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

            self?.parseDnsSdBrowseOutput(output)
        }

        do {
            try process.run()
            logger.info("🌊 dns-sd browse started (PID: \(process.processIdentifier))")
        } catch {
            logger.error("🌊 Failed to start dns-sd browse: \(error.localizedDescription)")
        }
    }

    /// Parse dns-sd -B output to find LocalCast services
    private func parseDnsSdBrowseOutput(_ output: String) {
        // dns-sd -B output format:
        // Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
        // 21:46:09.297  Add        3   1 local.               _tidaldrift-cast._udp. Eli's-MacBook-Pro

        let lines = output.split(separator: "\n")
        for line in lines {
            let lineStr = String(line)

            // Skip header lines
            if lineStr.contains("Timestamp") || lineStr.contains("STARTING") || lineStr.contains("DATE:") || lineStr.contains("Browsing for") {
                continue
            }

            // Look for "Add" lines
            if lineStr.contains("Add") && lineStr.contains("_tidaldrift-cast") {
                // Extract the instance name (everything after the service type)
                if let range = lineStr.range(of: "_tidaldrift-cast._udp.") {
                    let instanceName = String(lineStr[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !instanceName.isEmpty {
                        logger.info("🌊 dns-sd found LocalCast service: '\(instanceName)'")

                        // Try to match by name and resolve
                        DispatchQueue.main.async { [weak self] in
                            self?.markDeviceAsLocalCastHost(name: instanceName, authRequired: nil)
                        }

                        // Also resolve via dns-sd -L
                        resolveLocalCastViaDnsSd(name: instanceName)
                    }
                }
            }
        }
    }

    /// Resolve a LocalCast service using dns-sd -L
    private func resolveLocalCastViaDnsSd(name: String) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let output = runDnsSdLookup(
                name: name,
                type: "_tidaldrift-cast._udp",
                domain: "local.",
                timeout: 5,
                maxLines: 20,
                logger: self.logger
            )

            self.logger.debug("dns-sd -L output for '\(name)': \(output)")

            // Parse output for hostname - look for "can be reached at" or hostname.local.:port
            let lines = output.split(separator: "\n")
            for line in lines {
                let lineStr = String(line)

                // Look for hostname pattern like "hostname.local.:5904"
                if lineStr.contains(".local.") {
                    // Extract hostname using regex
                    if let hostMatch = lineStr.range(of: "[a-zA-Z0-9\\-]+\\.local\\.", options: .regularExpression) {
                        var hostname = String(lineStr[hostMatch])
                        hostname = hostname.replacingOccurrences(of: ".local.", with: "")

                        self.logger.info("🌊 dns-sd resolved '\(name)' to hostname: \(hostname)")
                        self.resolveHostnameAndMarkLocalCast(hostname, originalName: name, authRequired: nil)
                    }
                }
            }
        }
    }

    /// Scan ARP table for additional devices that might not advertise Bonjour services
    private func scanARPTable() async {
        let result = ShellExecutor.execute("arp -a")
        let lines = result.output.split(separator: "\n")

        for line in lines {
            let lineStr = String(line)

            // Parse: "? (192.168.1.100) at aa:bb:cc:dd:ee:ff on en0"
            if let ipRange = lineStr.range(of: "\\([0-9.]+\\)", options: .regularExpression) {
                var ip = String(lineStr[ipRange])
                ip = ip.trimmingCharacters(in: CharacterSet(charactersIn: "()"))

                // Skip broadcast and self
                if ip.hasSuffix(".255") || ip.hasSuffix(".1") { continue }

                // Check if we already know this device
                let knownIPs = await MainActor.run { discoveredDevices.map { $0.ipAddress } }
                if knownIPs.contains(ip) { continue }

                // Try to discover services on this IP
                await scanIPForAllServices(ip)
            }
        }
    }

    func stopBrowsing() {
        stopServiceBrowsing()

        stopLocalCastBrowsing()

        pathMonitor?.cancel()
        pathMonitor = nil

        udpListener?.cancel()
        udpListener = nil
    }

    private func stopServiceBrowsing() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
    }

    private func stopLocalCastBrowsing() {
        if let process = dnsSdBrowseProcess, process.isRunning {
            process.terminate()
        }
        dnsSdBrowseProcess = nil

        netServiceBrowser?.stop()
        netServiceBrowser = nil
        discoveredLocalCastServices.removeAll()
    }

    func refreshScan() {
        stopServiceBrowsing()
        stopLocalCastBrowsing()

        deviceCacheLock.lock()
        // Preserve TidalDrift peer info before clearing cache
        let tidalDriftPeers = deviceCache.filter { $0.value.isTidalDriftPeer }

        deviceCache.removeAll()

        // Restore TidalDrift peer entries (they'll be updated when rediscovered)
        for (key, device) in tidalDriftPeers {
            deviceCache[key] = device
        }
        deviceCacheLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startBrowsing()

            // Also trigger TidalDrift peer re-discovery
            if AppState.shared.settings.peerDiscoveryEnabled {
                // Restart peer discovery to re-sync
                TidalDriftPeerService.shared.stopDiscovery()
                TidalDriftPeerService.shared.startDiscovery()
            }
        }
    }

    func startPeriodicScanning(interval: TimeInterval) {
        stopPeriodicScanning()

        startBrowsing()

        Task {
            await scanSubnet(baseIP: NetworkUtils.getLocalIPAddress() ?? "192.168.1.1")
        }

        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshScan()
            Task {
                await self?.scanSubnet(baseIP: NetworkUtils.getLocalIPAddress() ?? "192.168.1.1")
            }
        }
    }

    func stopPeriodicScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
        stopBrowsing()
    }

    private func handleBrowserState(_ state: NWBrowser.State, for serviceType: String) {
        switch state {
        case .ready:
            if serviceType.contains("cast") {
                logger.info("🌊 LocalCast browser READY for \(serviceType)")
            }
        case .cancelled:
            break
        case .failed(let error):
            logger.error("Browser failed for \(serviceType): \(error.localizedDescription)")
        default:
            break
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>, serviceType: String) {
        let isLocalCastService = serviceType.contains("cast") || serviceType.contains("_tidaldrift-cast")

        if isLocalCastService {
            logger.info("🌊 LocalCast browse: \(results.count) services found for \(serviceType)")
        }

        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                if isLocalCastService || type.contains("cast") {
                    logger.info("🌊 LocalCast found: '\(name)' type:\(type) domain:\(domain)")
                    // For LocalCast (UDP), resolve via dns-sd and mark device
                    resolveLocalCastService(name: name, type: type, domain: domain)
                } else {
                    resolveService(name: name, type: type, domain: domain, serviceType: serviceType)
                }
            default:
                break
            }
        }

        for change in changes {
            switch change {
            case .removed(let result):
                handleDeviceRemoved(result)
            default:
                break
            }
        }
    }

    /// Resolve LocalCast service using dns-sd command (more reliable for UDP)
    private func resolveLocalCastService(name: String, type: String, domain: String) {
        logger.info("🌊 Resolving LocalCast: '\(name)'")

        // First try to match by name to existing devices
        markDeviceAsLocalCastHost(name: name, authRequired: nil)

        // Also resolve via dns-sd to get the IP directly
        queue.async { [weak self] in
            guard let self = self else { return }

            // Service type/domain are constrained, but the service name is passed
            // as a Process argument so apostrophes in Bonjour names are safe.
            let safeType2 = type.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            let safeDomain = domain.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
            let output = runDnsSdLookup(
                name: name,
                type: safeType2,
                domain: safeDomain,
                timeout: 3,
                maxLines: 10,
                logger: self.logger
            )
            let authRequired: Bool? =
                output.contains("auth=1") ? true :
                (output.contains("auth=0") ? false : nil)

            // Parse output for host info - look for "can be reached at" or hostname
            let lines = output.split(separator: "\n")
            for line in lines {
                let lineStr = String(line)
                self.logger.debug("dns-sd output: \(lineStr)")

                // Look for hostname pattern like "hostname.local.:5904"
                if lineStr.contains(".local.") || lineStr.contains("can be reached at") {
                    // Extract hostname
                    if let hostMatch = lineStr.range(of: "[a-zA-Z0-9-]+\\.local\\.", options: .regularExpression) {
                        let hostname = String(lineStr[hostMatch]).replacingOccurrences(of: ".local.", with: "")
                        self.logger.info("🌊 LocalCast hostname: \(hostname)")

                        // Resolve hostname to IP
                        self.resolveHostnameAndMarkLocalCast(hostname, originalName: name, authRequired: authRequired)
                    }
                }
            }
        }
    }

    /// Resolve hostname to IP and mark device as LocalCast host
    private func resolveHostnameAndMarkLocalCast(_ hostname: String, originalName: String, authRequired: Bool?) {
        let cleanHostname = hostname.hasSuffix(".local") ? hostname : "\(hostname).local"

        var hints = addrinfo()
        hints.ai_family = AF_INET // IPv4
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(cleanHostname, nil, &hints, &result)

        defer { if result != nil { freeaddrinfo(result) } }

        guard status == 0, let addrInfo = result else {
            logger.warning("🌊 LocalCast: Failed to resolve hostname \(hostname)")
            return
        }

        var addr = addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
        let ipAddress = String(cString: ipBuffer)

        logger.info("🌊 LocalCast resolved: \(hostname) -> \(ipAddress)")

        // Mark device at this IP as LocalCast host
        DispatchQueue.main.async { [weak self] in
            self?.addLocalCastToDevice(ipAddress: ipAddress, name: originalName, authRequired: authRequired)
        }
    }

    /// Add LocalCast service to a device by IP address
    private func addLocalCastToDevice(ipAddress: String, name: String, authRequired: Bool?) {
        deviceCacheLock.lock()

        if let existingKey = cacheKey(matchingIP: ipAddress), var device = deviceCache[existingKey] {
            if !device.services.contains(.localCast) {
                device.services.insert(.localCast)
            }
            if let authRequired {
                device.localCastAuthRequired = authRequired
            }
            let updatedKey = cacheKey(for: device)
            deviceCache[updatedKey] = device
            if updatedKey != existingKey {
                deviceCache.removeValue(forKey: existingKey)
            }
            logger.info("🌊 ✅ Added/updated LocalCast on existing device: \(device.name) at \(ipAddress), auth=\(authRequired.map(String.init(describing:)) ?? "unknown")")
        } else {
            // Create new device entry for this LocalCast host
            let displayName = name.replacingOccurrences(of: "-", with: " ")
            let newDevice = DiscoveredDevice(
                name: displayName,
                hostname: "\(name).local",
                ipAddress: ipAddress,
                services: [.localCast],
                lastSeen: Date(),
                localCastAuthRequired: authRequired
            )
            deviceCache[cacheKey(for: newDevice)] = newDevice
            logger.info("🌊 ✅ Created new LocalCast device: \(displayName) at \(ipAddress), auth=\(authRequired.map(String.init(describing:)) ?? "unknown")")
        }

        deviceCacheLock.unlock()
        updatePublishedDevices()
    }

    /// Normalize a name for comparison (removes special chars, lowercases, etc)
    private func normalizeName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Mark a device as supporting LocalCast based on its advertised name
    private func markDeviceAsLocalCastHost(name: String, authRequired: Bool?) {
        let normalizedName = normalizeName(name)

        deviceCacheLock.lock()
        var foundMatch = false

        // Log all devices in cache for debugging
        logger.info("🌊 LocalCast matching: Looking for '\(name)' (normalized: '\(normalizedName)')")
        logger.info("🌊 LocalCast matching: Cache has \(self.deviceCache.count) devices:")
        for (ip, device) in deviceCache {
            let normalizedDeviceName = normalizeName(device.name)
            let normalizedHostName = normalizeName(device.hostname)
            logger.info("🌊   - '\(device.name)' (\(ip)) [normalized: '\(normalizedDeviceName)', host: '\(normalizedHostName)']")
        }

        // Find device by name match
        for (ip, var device) in deviceCache {
            let normalizedDeviceName = normalizeName(device.name)
            let normalizedHostName = normalizeName(device.hostname)

            // Check for match (exact or substring)
            let isMatch = normalizedDeviceName == normalizedName ||
                         normalizedHostName == normalizedName ||
                         normalizedDeviceName.contains(normalizedName) ||
                         normalizedName.contains(normalizedDeviceName) ||
                         normalizedHostName.contains(normalizedName) ||
                         normalizedName.contains(normalizedHostName)

            if isMatch {
                if !device.services.contains(.localCast) {
                    device.services.insert(.localCast)
                }
                if let authRequired {
                    device.localCastAuthRequired = authRequired
                }
                deviceCache[ip] = device
                logger.info("🌊 ✅ Marked '\(device.name)' at \(ip) as LocalCast host (name match), auth=\(authRequired.map(String.init(describing:)) ?? "unknown")")
                foundMatch = true
            }
        }

        deviceCacheLock.unlock()

        if foundMatch {
            DispatchQueue.main.async { [weak self] in
                self?.updatePublishedDevices()
            }
        } else {
            logger.warning("🌊 No device match for LocalCast name: '\(name)' - will try to resolve hostname")
        }
    }

    private func resolveService(name: String, type: String, domain: String, serviceType: String) {
        // Method 1: Use NWConnection to resolve
        // Use UDP parameters for UDP services, TCP for others
        let isUDPService = type.contains("_udp")
        let params = isUDPService ? NWParameters.udp : NWParameters.tcp
        params.includePeerToPeer = true

        print("🌊 Discovery: Resolving \(name) type:\(type) (UDP: \(isUDPService))")

        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: params)
        let connectionId = UUID()

        // Store connection to prevent premature deallocation
        connectionsLock.lock()
        activeConnections[connectionId] = connection
        connectionsLock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let innerEndpoint = connection.currentPath?.remoteEndpoint {
                    self?.extractIPAddress(from: innerEndpoint, name: name, serviceType: serviceType)
                }
                self?.cleanupConnection(id: connectionId)
            case .failed:
                // Try fallback resolution via dns-sd
                self?.resolveServiceViaDNSSD(name: name, type: type, domain: domain, serviceType: serviceType)
                self?.cleanupConnection(id: connectionId)
            case .cancelled:
                // Remove from storage once fully cancelled
                self?.connectionsLock.lock()
                self?.activeConnections.removeValue(forKey: connectionId)
                self?.connectionsLock.unlock()
            default:
                break
            }
        }

        connection.start(queue: queue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.connectionsLock.lock()
            let conn = self.activeConnections[connectionId]
            self.connectionsLock.unlock()

            if let conn = conn, conn.state != .ready && conn.state != .cancelled {
                // `resolveServiceViaDNSSD` forks `dns-sd` and blocks for up to
                // 2.5s on a DispatchSemaphore. Run it on the discovery queue
                // so the main runloop never parks here.
                self.queue.async { [weak self] in
                    self?.resolveServiceViaDNSSD(name: name, type: type, domain: domain, serviceType: serviceType)
                }
                self.cleanupConnection(id: connectionId)
            }
        }
    }

    private func cleanupConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = activeConnections[id] {
            connection.cancel()
            // Don't remove here - wait for .cancelled state
        }
        connectionsLock.unlock()
    }

    /// Fallback resolution using dns-sd command
    private func resolveServiceViaDNSSD(name: String, type: String, domain: String, serviceType: String) {
        // Service type should only contain alphanumeric, underscore, hyphen, period
        let safeType = type.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        let safeDomain = domain.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }

        guard !safeType.isEmpty else { return }

        let output = runDnsSdLookup(
            name: name,
            type: safeType,
            domain: safeDomain,
            timeout: 2,
            maxLines: 5,
            logger: logger
        )

        // Parse output for host info
        // Example: "hostname.local.:5900"
        let lines = output.split(separator: "\n")
        if let advertisedIP = advertisedIPAddress(in: output) {
            let service = mapServiceType(serviceType)
            DispatchQueue.main.async { [weak self] in
                self?.addOrUpdateDevice(name: name, ipAddress: advertisedIP, port: 5900, service: service)
            }
            return
        }

        for line in lines {
            let lineStr = String(line)
            if lineStr.contains("can be reached at") {
                // Extract hostname
                if let hostRange = lineStr.range(of: "[a-zA-Z0-9-]+\\.local\\.", options: .regularExpression) {
                    let hostname = String(lineStr[hostRange])
                    // Resolve hostname to IP
                    resolveHostname(hostname, name: name, serviceType: serviceType)
                }
            }
        }
    }

    private func advertisedIPAddress(in dnsSdOutput: String) -> String? {
        guard let match = dnsSdOutput.range(of: #"ip=\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        let value = dnsSdOutput[match].dropFirst(3)
        return String(value)
    }

    /// Resolve a hostname to IP address
    private func resolveHostname(_ hostname: String, name: String, serviceType: String) {
        let cleanHostname = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        var hints = addrinfo()
        hints.ai_family = AF_INET // IPv4
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(cleanHostname, nil, &hints, &result)

        defer { freeaddrinfo(result) }

        guard status == 0, let addrInfo = result else { return }

        var addr = addrInfo.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
        let ipAddress = String(cString: ipBuffer)

        let service = mapServiceType(serviceType)
        DispatchQueue.main.async { [weak self] in
            self?.addOrUpdateDevice(name: name, ipAddress: ipAddress, port: 5900, service: service)
        }
    }

    private func extractIPAddress(from endpoint: NWEndpoint, name: String, serviceType: String) {
        guard case .hostPort(let host, let port) = endpoint else { return }

        let portNumber = Int(port.rawValue)
        let service = mapServiceType(serviceType)

        switch host {
        case .ipv4(let addr):
            let ipAddress = cleanIPAddress("\(addr)")
            DispatchQueue.main.async { [weak self] in
                self?.addOrUpdateDevice(name: name, ipAddress: ipAddress, port: portNumber, service: service)
            }
        case .ipv6(let addr):
            // Only use IPv6 if it's not a link-local address
            let ipAddress = cleanIPAddress("\(addr)")
            if !ipAddress.hasPrefix("fe80") {
                DispatchQueue.main.async { [weak self] in
                    self?.addOrUpdateDevice(name: name, ipAddress: ipAddress, port: portNumber, service: service)
                }
            }
        case .name(let hostname, _):
            // Resolve hostname to IP address
            resolveHostnameToIP(hostname) { [weak self] resolvedIP in
                if let ip = resolvedIP {
                    DispatchQueue.main.async {
                        self?.addOrUpdateDevice(name: name, ipAddress: self?.cleanIPAddress(ip) ?? ip, port: portNumber, service: service)
                    }
                }
            }
        @unknown default:
            break
        }
    }

    /// Remove interface suffix from IP addresses (e.g., "192.168.1.125%en0" -> "192.168.1.125")
    private func cleanIPAddress(_ ip: String) -> String {
        if let percentIndex = ip.firstIndex(of: "%") {
            return String(ip[..<percentIndex])
        }
        return ip
    }

    private func cacheKey(for device: DiscoveredDevice) -> String {
        device.discoveryKey
    }

    private func cacheKey(matchingIP ipAddress: String) -> String? {
        deviceCache.first { $0.value.ipAddress == ipAddress }?.key
    }

    private func resolveHostnameToIP(_ hostname: String, completion: @escaping (String?) -> Void) {
        // Use getaddrinfo to resolve hostname to IP
        queue.async {
            var hints = addrinfo()
            hints.ai_family = AF_INET  // Prefer IPv4
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, &hints, &result)

            defer {
                if result != nil {
                    freeaddrinfo(result)
                }
            }

            guard status == 0, let addrInfo = result else {
                // Try IPv6 if IPv4 fails
                var hints6 = addrinfo()
                hints6.ai_family = AF_INET6
                hints6.ai_socktype = SOCK_STREAM

                var result6: UnsafeMutablePointer<addrinfo>?
                let status6 = getaddrinfo(hostname, nil, &hints6, &result6)

                defer {
                    if result6 != nil {
                        freeaddrinfo(result6)
                    }
                }

                guard status6 == 0, let addrInfo6 = result6 else {
                    completion(nil)
                    return
                }

                // Extract IPv6 address
                if let sockaddr = addrInfo6.pointee.ai_addr {
                    var ipBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr in
                        var sin6_addr = addr.pointee.sin6_addr
                        inet_ntop(AF_INET6, &sin6_addr, &ipBuffer, socklen_t(INET6_ADDRSTRLEN))
                    }
                    let ip = String(cString: ipBuffer)
                    if !ip.isEmpty && !ip.hasPrefix("fe80") {
                        completion(ip)
                        return
                    }
                }
                completion(nil)
                return
            }

            // Extract IPv4 address
            if let sockaddr = addrInfo.pointee.ai_addr {
                var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                    var sin_addr = addr.pointee.sin_addr
                    inet_ntop(AF_INET, &sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
                }
                let ip = String(cString: ipBuffer)
                if !ip.isEmpty {
                    completion(ip)
                    return
                }
            }

            completion(nil)
        }
    }

    private func mapServiceType(_ type: String) -> DiscoveredDevice.ServiceType? {
        let service: DiscoveredDevice.ServiceType?
        switch type {
        case "_rfb._tcp", "_rfb._tcp.":
            service = .screenSharing
        case "_smb._tcp", "_smb._tcp.":
            service = .fileSharing
        case "_afpovertcp._tcp", "_afpovertcp._tcp.":
            service = .afp
        case "_ssh._tcp", "_ssh._tcp.":
            service = .ssh
        case "_tidaldrift._tcp", "_tidaldrift._tcp.":
            service = .tidalDrift
        case "_tidaldrop._tcp", "_tidaldrop._tcp.":
            service = .tidalDrop
        case "_tidaldrift-cast._udp", "_tidaldrift-cast._udp.":
            print("🌊 Discovery: Found LocalCast service!")
            service = .localCast
        default:
            service = nil
        }
        return service
    }

    private func addOrUpdateDevice(name: String, ipAddress: String, port: Int, service: DiscoveredDevice.ServiceType?) {
        var services: Set<DiscoveredDevice.ServiceType> = []
        if let service {
            services.insert(service)
        }
        let incomingDevice = DiscoveredDevice(
            name: name,
            hostname: "\(name).local",
            ipAddress: ipAddress,
            services: services,
            lastSeen: Date(),
            port: port
        )
        let newCacheKey = cacheKey(for: incomingDevice)

        if service == .localCast {
            print("🌊 Discovery: Adding LocalCast service for \(name) at \(ipAddress)")
        }

        deviceCacheLock.lock()
        let existingKey = deviceCache[newCacheKey] != nil ? newCacheKey : cacheKey(matchingIP: ipAddress)
        if let existingKey, var existingDevice = deviceCache[existingKey] {
            existingDevice.lastSeen = Date()
            existingDevice.ipAddress = ipAddress
            existingDevice.port = port
            if let service = service {
                let wasAdded = existingDevice.services.insert(service).inserted
                if service == .localCast && wasAdded {
                    print("🌊 Discovery: ✅ LocalCast added to existing device \(existingDevice.name)")
                }
            }
            // Prefer more descriptive names over generic ones
            if existingDevice.name.hasPrefix("Mac at ") && !name.hasPrefix("Mac at ") {
                existingDevice.name = name
                existingDevice.hostname = "\(name).local"
            }
            let updatedKey = cacheKey(for: existingDevice)
            deviceCache[updatedKey] = existingDevice
            if updatedKey != existingKey {
                deviceCache.removeValue(forKey: existingKey)
            }
        } else {
            deviceCache[newCacheKey] = incomingDevice
        }
        deviceCacheLock.unlock()

        updatePublishedDevices()
    }

    private func handleDeviceRemoved(_ result: NWBrowser.Result) {
        switch result.endpoint {
        case .service(let name, _, _, _):
            // Find and remove device by name match
            deviceCacheLock.lock()
            deviceCache = deviceCache.filter { !$0.value.name.lowercased().contains(name.lowercased()) }
            deviceCacheLock.unlock()
            updatePublishedDevices()
        default:
            break
        }
    }

    /// Coalesces rapid device-cache mutations into a single sort + publish + save.
    private func updatePublishedDevices() {
        publishDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deviceCacheLock.lock()
            let devices = Array(self.deviceCache.values).sorted { a, b in
                if a.isTidalDriftPeer != b.isTidalDriftPeer { return a.isTidalDriftPeer }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
            self.deviceCacheLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.discoveredDevices = devices
                self?.saveDevices()
            }
        }
        publishDebounceWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func addManualDevice(name: String, ipAddress: String, port: Int = 5900, services: Set<DiscoveredDevice.ServiceType> = [.screenSharing]) {
        let device = DiscoveredDevice(
            name: name,
            hostname: ipAddress,
            ipAddress: ipAddress,
            services: services,
            lastSeen: Date(),
            savedCredentialRef: "ip-\(ipAddress)",
            port: port
        )

        deviceCacheLock.lock()
        deviceCache[cacheKey(for: device)] = device
        deviceCacheLock.unlock()
        updatePublishedDevices()
    }

    /// Mark a device as a TidalDrift peer with enhanced info from TidalDriftPeerService
    func markAsTidalDriftPeer(hostname: String, peerInfo: TidalDriftPeerService.PeerInfo) {
        print("🌊 TidalDrift PEER: Attempting to mark '\(hostname)' at \(peerInfo.ipAddress) as peer")

        DispatchQueue.main.async {
            // Normalize input hostname
            let inputHostname = hostname.lowercased().replacingOccurrences(of: ".local", with: "")
            let inputIP = peerInfo.ipAddress
            let inputPeerId = peerInfo.peerId

            self.deviceCacheLock.lock()

            // Check cache directly first
            var matchedIP: String?

            // Match by stable peer identity first, then by current IP, then by hostname.
            if let inputPeerId, !inputPeerId.isEmpty,
               let existing = self.deviceCache.first(where: { $0.value.peerId == inputPeerId }) {
                matchedIP = existing.key
            } else if !inputIP.isEmpty,
                      let existing = self.deviceCache.first(where: { $0.value.ipAddress == inputIP }) {
                matchedIP = existing.key
            } else {
                // Match by hostname or name in cache
                for (ip, device) in self.deviceCache {
                    let dName = device.name.lowercased()
                    let dHost = device.hostname.lowercased().replacingOccurrences(of: ".local", with: "")

                    if dName == inputHostname || dHost == inputHostname ||
                       dName.contains(inputHostname) || inputHostname.contains(dName) {
                        matchedIP = ip
                        break
                    }
                }
            }

            if let ip = matchedIP, var device = self.deviceCache[ip] {
                device.isTidalDriftPeer = true
                device.services.insert(.ssh)
                device.services.insert(.tidalDrift)
                device.peerModelName = peerInfo.modelName
                device.peerModelIdentifier = peerInfo.modelIdentifier
                device.peerProcessorInfo = peerInfo.processorInfo
                device.peerMemoryGB = peerInfo.memoryGB
                device.peerMacOSVersion = peerInfo.macOSVersion
                device.peerUserName = peerInfo.userName
                device.peerUptimeHours = peerInfo.uptimeHours
                device.peerTidalDriftName = peerInfo.tidalDriftName
                device.peerId = peerInfo.peerId

                // Keep the most accurate IP
                if !inputIP.isEmpty && inputIP != "Unknown" {
                    device.ipAddress = inputIP
                }

                let updatedKey = self.cacheKey(for: device)
                if ip != updatedKey {
                    self.deviceCache.removeValue(forKey: ip)
                }
                self.deviceCache[updatedKey] = device
                self.deviceCacheLock.unlock()
                print("🌊 TidalDrift PEER: ✅ Updated cache entry '\(device.displayName)' as peer")
            } else {
                // Create a new device entry for this TidalDrift peer
                let displayName = hostname.replacingOccurrences(of: ".local", with: "")
                let newDevice = DiscoveredDevice(
                    name: displayName,
                    hostname: hostname.hasSuffix(".local") ? hostname : "\(hostname).local",
                    ipAddress: peerInfo.ipAddress.isEmpty || peerInfo.ipAddress == "Unknown" ? "Resolving..." : peerInfo.ipAddress,
                    services: [.screenSharing, .ssh, .tidalDrift],
                    lastSeen: Date(),
                    isTrusted: false,
                    isTidalDriftPeer: true,
                    peerModelName: peerInfo.modelName,
                    peerModelIdentifier: peerInfo.modelIdentifier,
                    peerProcessorInfo: peerInfo.processorInfo,
                    peerMemoryGB: peerInfo.memoryGB,
                    peerMacOSVersion: peerInfo.macOSVersion,
                    peerUserName: peerInfo.userName,
                    peerUptimeHours: peerInfo.uptimeHours,
                    peerTidalDriftName: peerInfo.tidalDriftName,
                    peerId: peerInfo.peerId
                )
                self.deviceCache[self.cacheKey(for: newDevice)] = newDevice
                self.deviceCacheLock.unlock()
                print("🌊 TidalDrift PEER: ✅ Created new device entry for peer '\(displayName)'")
            }
            self.updatePublishedDevices()
        }
    }

    // MARK: - Active IP Scanning (for VPNs and when Bonjour fails)

    @Published var isScanningSubnet: Bool = false
    @Published var scanProgress: Double = 0

    /// Scan a specific IP address for screen sharing service
    func scanIP(_ ipAddress: String, port: Int = 5900) async -> Bool {
        return await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(ipAddress)
            let port = NWEndpoint.Port(rawValue: UInt16(port))!
            let connection = NWConnection(host: host, port: port, using: .tcp)
            let connectionId = UUID()

            // Store connection to prevent premature deallocation
            self.connectionsLock.lock()
            self.activeConnections[connectionId] = connection
            self.connectionsLock.unlock()

            let didResume = AtomicFlag()

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !didResume.value else { return }
                    didResume.value = true
                    self?.cleanupConnection(id: connectionId)
                    continuation.resume(returning: true)
                case .failed:
                    guard !didResume.value else { return }
                    didResume.value = true
                    self?.cleanupConnection(id: connectionId)
                    continuation.resume(returning: false)
                case .cancelled:
                    // Clean up storage once fully cancelled
                    self?.connectionsLock.lock()
                    self?.activeConnections.removeValue(forKey: connectionId)
                    self?.connectionsLock.unlock()

                    // Resume if not already done (timeout case)
                    guard !didResume.value else { return }
                    didResume.value = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: self.queue)

            // 2 second timeout per IP
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard !didResume.value else { return }
                didResume.value = true
                self?.cleanupConnection(id: connectionId)
                continuation.resume(returning: false)
            }
        }
    }

    /// Scan a range of IPs (e.g., 192.168.1.1 to 192.168.1.254)
    func scanSubnet(baseIP: String, startHost: Int = 1, endHost: Int = 254) async {
        await MainActor.run {
            isScanningSubnet = true
            scanProgress = 0.01 // Show immediate progress

            // Clear stale devices (including old peers) before fresh scan
            clearStaleDevices()
        }

        // Parse base IP (e.g., "192.168.1" from "192.168.1.100")
        let components = baseIP.split(separator: ".")
        guard components.count >= 3 else {
            await MainActor.run { isScanningSubnet = false }
            return
        }
        let subnet = components.prefix(3).joined(separator: ".")

        // Get the current host number to prioritize nearby IPs
        let currentHost = Int(components.last ?? "1") ?? 1

        // Reorder to scan nearby IPs first (more likely to find devices quickly)
        var hostsToScan = Array(startHost...endHost)
        hostsToScan.sort { abs($0 - currentHost) < abs($1 - currentHost) }

        let totalIPs = hostsToScan.count

        // Track which IPs responded during this scan
        final class ScanTracker: @unchecked Sendable {
            var scannedCount: Int = 0
            var respondedIPs: Set<String> = []
            let lock = NSLock()

            func addRespondedIP(_ ip: String) {
                lock.lock()
                respondedIPs.insert(ip)
                lock.unlock()
            }

            func incrementScanned() {
                lock.lock()
                scannedCount += 1
                lock.unlock()
            }

            func getScannedCount() -> Int {
                lock.lock()
                defer { lock.unlock() }
                return scannedCount
            }

            func getRespondedIPs() -> Set<String> {
                lock.lock()
                defer { lock.unlock() }
                return respondedIPs
            }
        }
        let tracker = ScanTracker()

        // Structure to hold scan results for an IP
        struct ScanResult: Sendable {
            let ip: String
            let hasScreenSharing: Bool
            let hasFileSharing: Bool
            let hasAFP: Bool
            let hasSSH: Bool
        }

        // Scan in batches, processing nearby IPs first for faster initial results
        let batchSize = 25 // Larger batches for faster scanning
        for batchStart in stride(from: 0, to: hostsToScan.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, hostsToScan.count)
            let batch = Array(hostsToScan[batchStart..<batchEnd])

            await withTaskGroup(of: ScanResult.self) { group in
                for hostNum in batch {
                    let ip = "\(subnet).\(hostNum)"
                    group.addTask {
                        // Check all services in parallel for each IP
                        async let screenShare = self.scanIP(ip, port: 5900)
                        async let fileShare = self.scanIP(ip, port: 445)
                        async let afp = self.scanIP(ip, port: 548)

                        // Only scan for SSH if enabled in settings
                        let shouldScanSSH = await MainActor.run { AppState.shared.settings.sshDiscoveryEnabled }
                        async let ssh = shouldScanSSH ? self.scanIP(ip, port: 22) : false

                        return ScanResult(
                            ip: ip,
                            hasScreenSharing: await screenShare,
                            hasFileSharing: await fileShare,
                            hasAFP: await afp,
                            hasSSH: await ssh
                        )
                    }
                }

                for await result in group {
                    tracker.incrementScanned()
                    await MainActor.run {
                        scanProgress = Double(tracker.getScannedCount()) / Double(totalIPs)
                    }

                    let hasAnyService = result.hasScreenSharing || result.hasFileSharing || result.hasAFP || result.hasSSH

                    if hasAnyService {
                        tracker.addRespondedIP(result.ip)
                        let name = self.getHostname(for: result.ip) ?? "Mac at \(result.ip)"

                        await MainActor.run {
                            if result.hasScreenSharing {
                                self.addOrUpdateDevice(name: name, ipAddress: result.ip, port: 5900, service: .screenSharing)
                            }
                            if result.hasFileSharing {
                                self.addOrUpdateDevice(name: name, ipAddress: result.ip, port: 445, service: .fileSharing)
                            }
                            if result.hasAFP {
                                self.addOrUpdateDevice(name: name, ipAddress: result.ip, port: 548, service: .afp)
                            }
                            if result.hasSSH {
                                self.addOrUpdateDevice(name: name, ipAddress: result.ip, port: 22, service: .ssh)
                            }
                        }
                    }
                }
            }
        }

        // After scan completes, remove devices on this subnet that didn't respond
        // (but keep TidalDrift peers and manually added devices)
        let respondedIPs = tracker.getRespondedIPs()
        await MainActor.run {
            removeUnresponsiveDevices(onSubnet: subnet, respondedIPs: respondedIPs)
            isScanningSubnet = false
            scanProgress = 1.0
        }
    }

    /// Remove devices on the given subnet that didn't respond during scan
    /// Preserves TidalDrift peers (they're discovered via Bonjour, not port scan)
    private func removeUnresponsiveDevices(onSubnet subnet: String, respondedIPs: Set<String>) {
        var devicesToRemove: [String] = []

        deviceCacheLock.lock()
        for (key, device) in deviceCache {
            // Skip if not on the scanned subnet
            guard device.ipAddress.hasPrefix(subnet + ".") else { continue }

            // Skip TidalDrift peers - they may not have open ports but are valid
            if device.isTidalDriftPeer { continue }

            // Skip if this IP responded during the scan
            if respondedIPs.contains(device.ipAddress) { continue }

            // This device is on our subnet but didn't respond - mark for removal
            devicesToRemove.append(key)
        }

        // Remove unresponsive devices
        for ip in devicesToRemove {
            deviceCache.removeValue(forKey: ip)
            #if DEBUG
            print("🧹 Removed unresponsive device: \(ip)")
            #endif
        }
        deviceCacheLock.unlock()

        if !devicesToRemove.isEmpty {
            updatePublishedDevices()
            #if DEBUG
            print("🧹 Cleaned up \(devicesToRemove.count) devices that didn't respond during subnet scan")
            #endif
        }
    }

    /// Scan common ports on a single IP
    func scanIPForAllServices(_ ipAddress: String) async {
        // Check VNC (screen sharing)
        if await scanIP(ipAddress, port: 5900) {
            let name = getHostname(for: ipAddress) ?? "Mac at \(ipAddress)"
            await MainActor.run {
                addOrUpdateDevice(name: name, ipAddress: ipAddress, port: 5900, service: .screenSharing)
            }
        }

        // Check SMB (file sharing)
        if await scanIP(ipAddress, port: 445) {
            let name = getHostname(for: ipAddress) ?? "Mac at \(ipAddress)"
            await MainActor.run {
                addOrUpdateDevice(name: name, ipAddress: ipAddress, port: 445, service: .fileSharing)
            }
        }

        // Check AFP
        if await scanIP(ipAddress, port: 548) {
            let name = getHostname(for: ipAddress) ?? "Mac at \(ipAddress)"
            await MainActor.run {
                addOrUpdateDevice(name: name, ipAddress: ipAddress, port: 548, service: .afp)
            }
        }

        // Check SSH (only if enabled)
        if AppState.shared.settings.sshDiscoveryEnabled {
            if await scanIP(ipAddress, port: 22) {
                let name = getHostname(for: ipAddress) ?? "Mac at \(ipAddress)"
                await MainActor.run {
                    addOrUpdateDevice(name: name, ipAddress: ipAddress, port: 22, service: .ssh)
                }
            }
        }
    }

    private func getHostname(for ipAddress: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ipAddress, nil, &hints, &result) == 0, let addrInfo = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let error = getnameinfo(
            addrInfo.pointee.ai_addr,
            addrInfo.pointee.ai_addrlen,
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            0
        )

        if error == 0 {
            let name = String(cString: hostname)
            // Return nil if it just returned the IP back
            if name != ipAddress && !name.isEmpty {
                // Clean up .local suffix for display
                return name.replacingOccurrences(of: ".local", with: "")
            }
        }
        return nil
    }

    // MARK: - NetServiceBrowserDelegate (for LocalCast UDP discovery)

    private var discoveredLocalCastServices: [NetService] = []

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        logger.info("🌊 NetServiceBrowser: Started searching for LocalCast services")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        logger.info("🌊 NetServiceBrowser: Stopped searching")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        logger.error("🌊 NetServiceBrowser: Failed to search - \(errorDict)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        logger.info("🌊 NetServiceBrowser: Found LocalCast service '\(service.name)' type:\(service.type)")

        // Store and resolve the service
        discoveredLocalCastServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10.0)

        // Also try to match by name immediately
        markDeviceAsLocalCastHost(name: service.name, authRequired: nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        logger.info("🌊 NetServiceBrowser: LocalCast service removed '\(service.name)'")
        discoveredLocalCastServices.removeAll { $0.name == service.name }

        // TODO: Could remove LocalCast capability from device, but leave for now
    }

    // MARK: - NetServiceDelegate (for LocalCast service resolution)

    func netServiceDidResolveAddress(_ sender: NetService) {
        logger.info("🌊 NetService: Resolved '\(sender.name)' - host: \(sender.hostName ?? "nil"), port: \(sender.port)")

        // Get IP addresses from the resolved addresses
        if let addresses = sender.addresses {
            for addressData in addresses {
                if let ipAddress = extractIPAddress(from: addressData) {
                    logger.info("🌊 NetService: LocalCast '\(sender.name)' at IP: \(ipAddress)")

                    DispatchQueue.main.async { [weak self] in
                        self?.addLocalCastToDevice(ipAddress: ipAddress, name: sender.name, authRequired: nil)
                    }
                }
            }
        }

        // Also try hostname resolution
        if let hostname = sender.hostName?.replacingOccurrences(of: ".local.", with: "") {
            resolveHostnameAndMarkLocalCast(hostname, originalName: sender.name, authRequired: nil)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        logger.error("🌊 NetService: Failed to resolve '\(sender.name)' - \(errorDict)")
    }

    /// Extract IPv4 address from sockaddr data
    private func extractIPAddress(from addressData: Data) -> String? {
        var storage = sockaddr_storage()
        addressData.withUnsafeBytes { bytes in
            let sockaddrPointer = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self)
            if let sockaddr = sockaddrPointer {
                memcpy(&storage, sockaddr, min(addressData.count, MemoryLayout<sockaddr_storage>.size))
            }
        }

        // Check for IPv4
        if storage.ss_family == UInt8(AF_INET) {
            var addr = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: buffer)

            // Skip localhost
            if ip.hasPrefix("127.") {
                return nil
            }
            return ip
        }

        return nil
    }
}
