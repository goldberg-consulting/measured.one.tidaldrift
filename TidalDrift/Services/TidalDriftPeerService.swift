import Foundation
import Network
import IOKit
import os.log
import Combine
import AppKit

/// Service to advertise this TidalDrift instance and discover peers
/// Uses Network.framework for modern, reliable Bonjour discovery
class TidalDriftPeerService: NSObject, ObservableObject {
    static let shared = TidalDriftPeerService()
    
    private static let logger = Logger(subsystem: "com.tidaldrift", category: "PeerService")
    private static let installIdKey = "com.tidaldrift.peerInstallId"
    
    // Background queue for file logging to avoid blocking main thread
    private static let logQueue = DispatchQueue(label: "com.tidaldrift.peer.log", qos: .utility)
    
    static func log(_ message: String) {
        // System logger and console print are fast - do immediately
        logger.info("\(message)")
        #if DEBUG
        print("🌊 TidalDrift PEER: \(message)")
        #endif
        
        // File I/O is slow - do on background queue
        logQueue.async {
            let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tidaldrift-peer.log")
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logLine = "[\(timestamp)] \(message)\n"
            if let data = logLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logPath.path) {
                    if let handle = try? FileHandle(forWritingTo: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logPath)
                }
            }
        }
    }
    
    @Published var discoveredPeers: [String: PeerInfo] = [:] // keyed by IP
    @Published var isAdvertising = false
    
    /// Tracks when each peer IP was last seen for stale-peer pruning.
    private var peerLastSeen: [String: Date] = [:]
    
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.tidaldrift.peer.network", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    
    // Fallback: Use NetService for reliable Bonjour advertising
    private var netService: NetService?
    private var netServiceBrowser: NetServiceBrowser?
    
    private var telemetryTimer: Timer?
    private var peerPruneTimer: Timer?

    /// Periodically re-resolves already-discovered peers so they stay fresh.
    /// `dns-sd -B` emits an Add only once, and mDNS does not re-announce existing
    /// services often, so without this a present peer's lastSeen ages out and it
    /// gets pruned (losing its TidalDrift-peer status / red outline).
    private var reconfirmTimer: Timer?
    private static let peerReconfirmInterval: TimeInterval = 45
    
    private let serviceType = "_tidaldrift._tcp"
    private let dropServiceType = "_tidaldrop._tcp"

    static var localPeerId: String {
        if let existing = UserDefaults.standard.string(forKey: installIdKey), !existing.isEmpty {
            return existing
        }

        let peerId = UUID().uuidString.lowercased()
        UserDefaults.standard.set(peerId, forKey: installIdKey)
        return peerId
    }
    
    /// The advertised name: custom TidalDrift display name if set, otherwise system computer name
    var advertisedName: String {
        let custom = AppState.shared.settings.tidalDriftDisplayName
        if !custom.isEmpty {
            return custom.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "-")
        }
        return NetworkUtils.sanitizedComputerName
    }
    
    private let localInfo: PeerInfo
    
    struct PeerInfo: Codable {
        let peerId: String?
        let hostname: String
        let ipAddress: String
        let modelName: String
        let modelIdentifier: String
        let processorInfo: String
        let memoryGB: Int
        let macOSVersion: String
        let userName: String
        let uptimeHours: Int
        let tidalDriftVersion: String
        let screenSharingEnabled: Bool
        let fileSharingEnabled: Bool
        var tidalDriftName: String?
    }
    
    private override init() {
        // Gather local system info
        let hostname = NetworkUtils.computerName
        let ipAddress = NetworkUtils.getLocalIPAddress() ?? "Unknown"
        
        localInfo = PeerInfo(
            peerId: Self.localPeerId,
            hostname: hostname,
            ipAddress: ipAddress,
            modelName: Self.getModelName(),
            modelIdentifier: Self.getModelIdentifier(),
            processorInfo: Self.getProcessorInfo(),
            memoryGB: Self.getMemoryGB(),
            macOSVersion: Self.getMacOSVersion(),
            userName: NSUserName(),
            uptimeHours: Self.getUptimeHours(),
            tidalDriftVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            screenSharingEnabled: true,
            fileSharingEnabled: true
        )
        
        super.init()
        Self.log("Service initialized with Network.framework")
        Self.log("Local hostname: \(hostname)")
        Self.log("Local IP: \(ipAddress)")
        Self.log("Service Type: \(serviceType)")
        
        setupSettingsBinding()
    }
    
    private func setupSettingsBinding() {
        AppState.shared.$settings
            .map { $0.peerDiscoveryEnabled }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                Self.log("Peer discovery setting changed: \(enabled)")
                if enabled {
                    self?.startAdvertising()
                    self?.startDiscovery()
                } else {
                    self?.stopAdvertising()
                    self?.stopDiscovery()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Advertising (dns-sd helper, hardened)
    //
    // The peer beacon is advertised by running `dns-sd -R`. The registration
    // lives only as long as the helper process and mDNSResponder's acceptance
    // of it, so this path is hardened against the failure modes that made
    // discovery intermittently slow or absent:
    //   1. Registration is confirmed by parsing the helper's stdout, not just
    //      "is the process alive" (a live-but-unregistered helper used to look
    //      healthy forever).
    //   2. A watchdog restarts on process death, unconfirmed registration, or a
    //      change in the local IP (so the advertised `ip=` TXT, which the
    //      discovery fast path keys on, never goes stale).
    //   3. The advertisement is re-registered on wake from sleep.
    //   4. App Nap is suppressed (idle system sleep still allowed) so the
    //      watchdog and helper stay responsive while the app is in the
    //      background, which is always for a menu-bar accessory.

    private var dnssdProcess: Process?
    private var advertisePipe: Pipe?
    private var advertiseMonitorTimer: Timer?

    /// IP currently baked into the advertised TXT record (`ip=`).
    private var advertisedIP: String?
    /// True once dns-sd confirms "Name now registered and active" on stdout.
    private var advertiseRegistered = false
    /// When the current `dns-sd -R` process launched (registration grace window).
    private var advertiseLaunchedAt: Date?
    /// Keeps the app out of App Nap while advertising (idle sleep still allowed).
    private var advertiseActivity: NSObjectProtocol?
    private var sleepWakeObserved = false

    private static let advertiseWatchdogInterval: TimeInterval = 4
    private static let advertiseRegistrationGrace: TimeInterval = 3

    func startAdvertising() {
        guard dnssdProcess == nil else {
            Self.log("Already advertising, skipping")
            return
        }

        Self.log("📢 Starting Bonjour advertisement via dns-sd")
        if advertiseActivity == nil {
            advertiseActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
                reason: "TidalDrift Bonjour advertising"
            )
        }
        observeSleepWake()
        launchAdvertiseProcess()
        startAdvertiseMonitor()
    }

    private func launchAdvertiseProcess() {
        let currentIP = NetworkUtils.getLocalIPAddress() ?? localInfo.ipAddress

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")

        let customName = AppState.shared.settings.tidalDriftDisplayName
        var txtParts = [
            "peerId=\(Self.localPeerId)",
            "model=\(localInfo.modelName)",
            "modelId=\(localInfo.modelIdentifier)",
            "cpu=\(localInfo.processorInfo)",
            "mem=\(localInfo.memoryGB)",
            "os=\(localInfo.macOSVersion)",
            "user=\(localInfo.userName)",
            "uptime=\(Self.getUptimeHours())",
            "version=\(localInfo.tidalDriftVersion)",
            "screen=\(localInfo.screenSharingEnabled ? "1" : "0")",
            "file=\(localInfo.fileSharingEnabled ? "1" : "0")",
            "ip=\(currentIP)"
        ]
        if !customName.isEmpty {
            txtParts.append("tdname=\(customName)")
        }

        let advName = advertisedName
        var args = ["-R", advName, serviceType, "local.", "5959"]
        args.append(contentsOf: txtParts)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: the helper exited. Remove the handler so it does not spin on
            // empty reads; the watchdog relaunches with a fresh pipe.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let output = String(data: data, encoding: .utf8) else { return }
            // dns-sd -R prints "Name now registered and active" once mDNSResponder
            // accepts the registration. Until then the ad is not actually live.
            if output.contains("registered and active") {
                DispatchQueue.main.async { [weak self] in
                    self?.advertiseRegistered = true
                    self?.isAdvertising = true
                }
            }
        }

        advertiseRegistered = false
        advertiseLaunchedAt = Date()
        advertisedIP = currentIP

        do {
            try process.run()
            dnssdProcess = process
            advertisePipe = pipe
            Self.log("✅ dns-sd advertising: \(advName) on \(serviceType), ip=\(currentIP), \(txtParts.count) TXT fields")
            DispatchQueue.main.async { self.isAdvertising = true }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            Self.log("❌ Failed to start dns-sd: \(error)")
        }
    }

    private func startAdvertiseMonitor() {
        advertiseMonitorTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.advertiseMonitorTimer = Timer.scheduledTimer(
                withTimeInterval: Self.advertiseWatchdogInterval, repeats: true
            ) { [weak self] _ in
                self?.checkAdvertiseHealth()
            }
        }
    }

    /// Watchdog: restart the advertisement if the helper died, never confirmed
    /// registration, or the local IP changed out from under the `ip=` TXT.
    private func checkAdvertiseHealth() {
        guard let proc = dnssdProcess else { return }

        if !proc.isRunning {
            Self.log("⚠️ Advertise process died (exit \(proc.terminationStatus)), restarting")
            relaunchAdvertise()
            return
        }

        if !advertiseRegistered,
           let launched = advertiseLaunchedAt,
           Date().timeIntervalSince(launched) > Self.advertiseRegistrationGrace {
            Self.log("⚠️ Advertise registration unconfirmed after \(Int(Self.advertiseRegistrationGrace))s, restarting")
            relaunchAdvertise()
            return
        }

        if let current = NetworkUtils.getLocalIPAddress(), current != advertisedIP {
            Self.log("🌐 Local IP changed (\(self.advertisedIP ?? "nil") → \(current)), re-advertising")
            relaunchAdvertise()
        }
    }

    private func relaunchAdvertise() {
        advertisePipe?.fileHandleForReading.readabilityHandler = nil
        advertisePipe = nil
        if let proc = dnssdProcess, proc.isRunning {
            proc.terminate()
        }
        dnssdProcess = nil
        launchAdvertiseProcess()
    }

    /// Re-register the advertisement on wake; sleep can drop the helper's
    /// registration and the IP often changes across a sleep/wake cycle.
    private func observeSleepWake() {
        guard !sleepWakeObserved else { return }
        sleepWakeObserved = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.dnssdProcess != nil else { return }
            Self.log("⏰ Woke from sleep — re-advertising")
            self.relaunchAdvertise()
        }
    }

    func stopAdvertising() {
        advertiseMonitorTimer?.invalidate()
        advertiseMonitorTimer = nil

        telemetryTimer?.invalidate()
        telemetryTimer = nil

        listener?.cancel()
        listener = nil

        if let service = netService {
            service.remove(from: .main, forMode: .common)
            service.stop()
        }
        netService = nil

        advertisePipe?.fileHandleForReading.readabilityHandler = nil
        advertisePipe = nil
        if let process = dnssdProcess, process.isRunning {
            process.terminate()
            Self.log("Terminated dns-sd process")
        }
        dnssdProcess = nil
        advertiseRegistered = false
        advertisedIP = nil
        advertiseLaunchedAt = nil

        if let activity = advertiseActivity {
            ProcessInfo.processInfo.endActivity(activity)
            advertiseActivity = nil
        }

        DispatchQueue.main.async {
            self.isAdvertising = false
        }
        Self.log("Stopped advertising")
    }
    
    func restartAdvertising() {
        stopAdvertising()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startAdvertising()
        }
    }
    
    /// Full restart of advertising and discovery, e.g. after a network change.
    func restartAll() {
        Self.log("🔄 Full restart: network change or recovery")
        stopAdvertising()
        stopDiscovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startAdvertising()
            self?.startDiscovery()
        }
    }
    
    private func createTXTRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["peerId"] = Self.localPeerId
        txt["model"] = localInfo.modelName
        txt["modelId"] = localInfo.modelIdentifier
        txt["cpu"] = localInfo.processorInfo
        txt["mem"] = "\(localInfo.memoryGB)"
        txt["os"] = localInfo.macOSVersion
        txt["user"] = localInfo.userName
        txt["uptime"] = "\(localInfo.uptimeHours)"
        txt["version"] = localInfo.tidalDriftVersion
        txt["screen"] = localInfo.screenSharingEnabled ? "1" : "0"
        txt["file"] = localInfo.fileSharingEnabled ? "1" : "0"
        return txt
    }
    
    private func createTXTDictionary() -> [String: Data] {
        var dict = [String: Data]()
        dict["peerId"] = Self.localPeerId.data(using: .utf8)
        dict["model"] = localInfo.modelName.data(using: .utf8)
        dict["modelId"] = localInfo.modelIdentifier.data(using: .utf8)
        dict["cpu"] = localInfo.processorInfo.data(using: .utf8)
        dict["mem"] = "\(localInfo.memoryGB)".data(using: .utf8)
        dict["os"] = localInfo.macOSVersion.data(using: .utf8)
        dict["user"] = localInfo.userName.data(using: .utf8)
        dict["uptime"] = "\(localInfo.uptimeHours)".data(using: .utf8)
        dict["version"] = localInfo.tidalDriftVersion.data(using: .utf8)
        dict["screen"] = (localInfo.screenSharingEnabled ? "1" : "0").data(using: .utf8)
        dict["file"] = (localInfo.fileSharingEnabled ? "1" : "0").data(using: .utf8)
        return dict.compactMapValues { $0 }
    }
    
    // MARK: - Discovery (Network.framework)
    
    private var browseProcess: Process?
    private var browseOutputPipe: Pipe?
    
    private var browseMonitorTimer: Timer?
    
    func startDiscovery() {
        guard browseProcess == nil else {
            Self.log("Already browsing, skipping")
            return
        }
        
        Self.log("Starting discovery for \(serviceType) via dns-sd")
        launchBrowseProcess()
        startBrowseMonitor()
        
        if peerPruneTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.peerPruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    self?.pruneStaleDiscoveredPeers()
                }
            }
        }

        if reconfirmTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.reconfirmTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.peerReconfirmInterval, repeats: true
                ) { [weak self] _ in
                    self?.reconfirmKnownPeers()
                }
            }
        }
    }

    /// Re-resolve already-discovered peers so their lastSeen stays current.
    /// A present peer refreshes (keeping it online and out of the prune window);
    /// a departed peer simply fails to resolve and ages out as intended.
    private func reconfirmKnownPeers() {
        let names = Set(discoveredPeers.values.map { $0.hostname }).subtracting([advertisedName])
        guard !names.isEmpty else { return }
        for name in names {
            resolveServiceViaDnsSd(name: name)
        }
    }
    
    private func launchBrowseProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-B", serviceType, "local."]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        browseOutputPipe = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF: the browse helper exited. Remove the handler to avoid a tight
            // empty-read spin; the browse watchdog relaunches with a fresh pipe.
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let output = String(data: data, encoding: .utf8) else { return }
            self?.parseBrowseOutput(output)
        }
        
        do {
            try process.run()
            browseProcess = process
            Self.log("✅ dns-sd browse process started with PID \(process.processIdentifier)")
        } catch {
            Self.log("❌ Failed to start dns-sd browse: \(error)")
        }
    }
    
    private func startBrowseMonitor() {
        browseMonitorTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.browseMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let proc = self.browseProcess, !proc.isRunning {
                    Self.log("⚠️ Browse process died (exit \(proc.terminationStatus)), restarting")
                    self.browseProcess = nil
                    self.browseOutputPipe?.fileHandleForReading.readabilityHandler = nil
                    self.browseOutputPipe = nil
                    self.launchBrowseProcess()
                }
            }
        }
    }
    
    func stopDiscovery() {
        browseMonitorTimer?.invalidate()
        browseMonitorTimer = nil
        
        browser?.cancel()
        browser = nil
        
        netServiceBrowser?.stop()
        netServiceBrowser = nil
        
        browseOutputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = browseProcess, process.isRunning {
            process.terminate()
            Self.log("Terminated dns-sd browse process")
        }
        browseProcess = nil
        browseOutputPipe = nil

        clearResolveState()
        
        peerPruneTimer?.invalidate()
        peerPruneTimer = nil

        reconfirmTimer?.invalidate()
        reconfirmTimer = nil

        Self.log("Stopped discovery")
    }

    private func clearResolveState() {
        resolveLock.lock()
        for pipe in resolvePipes.values {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for process in resolveProcesses.values where process.isRunning {
            process.terminate()
        }
        resolvePipes.removeAll()
        resolveProcesses.removeAll()
        resolveLock.unlock()

        lookupLock.lock()
        for pipe in lookupPipes.values {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for process in lookupProcesses.values where process.isRunning {
            process.terminate()
        }
        lookupPipes.removeAll()
        lookupProcesses.removeAll()
        lookupCompleted.removeAll()
        lookupLock.unlock()

        txtRecordsLock.lock()
        resolvedTXTRecords.removeAll()
        txtRecordsLock.unlock()
    }
    
    private func pruneStaleDiscoveredPeers() {
        let staleThreshold: TimeInterval = 5 * 60
        let now = Date()
        var pruned = 0
        
        for (ip, lastSeen) in peerLastSeen where now.timeIntervalSince(lastSeen) > staleThreshold {
            discoveredPeers.removeValue(forKey: ip)
            peerLastSeen.removeValue(forKey: ip)
            pruned += 1
        }
        
        if pruned > 0 {
            Self.log("Pruned \(pruned) stale peer(s) from discoveredPeers")
        }
    }
    
    private func parseBrowseOutput(_ output: String) {
        // Parse dns-sd -B output format:
        // Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
        // 21:22:27.364  Add        3   1 local.               _tidaldrift._tcp.    Eli's-MacBook-Pro
        
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            // Skip header lines and empty lines
            if line.contains("Browsing for") || line.contains("DATE:") || 
               line.contains("Timestamp") || line.contains("STARTING") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            
            // Check if this is an "Add" line
            if line.contains("Add") {
                // Extract the instance name (last column)
                let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if components.count >= 7 {
                    // Instance name is everything after the service type
                    let serviceTypeIndex = components.firstIndex { $0.contains("_tidaldrift") }
                    if let idx = serviceTypeIndex, idx + 1 < components.count {
                        let instanceName = components[(idx + 1)...].joined(separator: " ")
                        
                        let isSelf = instanceName == advertisedName
                        Self.log("🔎 Discovered via dns-sd: '\(instanceName)'\(isSelf ? " (self)" : "")")
                        
                        // Resolve the service to get IP
                        resolveServiceViaDnsSd(name: instanceName)
                    }
                }
            }
        }
    }
    
    private var resolveProcesses: [String: Process] = [:]
    private var resolvePipes: [String: Pipe] = [:]
    private let resolveLock = NSLock()  // Thread-safe access to resolve dictionaries
    
    private var lookupPipes: [String: Pipe] = [:]
    private var lookupProcesses: [String: Process] = [:]
    private var lookupCompleted: Set<String> = []
    private let lookupLock = NSLock()
    
    // Store NWConnection instances to prevent premature deallocation
    private var activeNWConnections: [UUID: NWConnection] = [:]
    private let nwConnectionsLock = NSLock()
    
    private func resolveServiceViaDnsSd(name: String) {
        // Skip if already resolving this service
        resolveLock.lock()
        let alreadyResolving = resolveProcesses[name] != nil
        resolveLock.unlock()
        guard !alreadyResolving else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", name, serviceType, "local."]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let output = String(data: data, encoding: .utf8) else { return }
            self?.parseResolveOutput(output, name: name)
        }
        
        do {
            try process.run()
            
            resolveLock.lock()
            resolveProcesses[name] = process
            resolvePipes[name] = pipe
            resolveLock.unlock()
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.cleanupResolve(name: name)
            }
        } catch {
            Self.log("❌ Failed to resolve \(name): \(error)")
        }
    }
    
    private func cleanupResolve(name: String) {
        resolveLock.lock()
        
        // Remove handler before terminating
        resolvePipes[name]?.fileHandleForReading.readabilityHandler = nil
        resolvePipes[name] = nil
        
        if let p = resolveProcesses[name], p.isRunning {
            p.terminate()
        }
        resolveProcesses[name] = nil
        
        resolveLock.unlock()
        
        // Evict any orphaned TXT record that was never consumed by addDiscoveredPeer
        txtRecordsLock.lock()
        resolvedTXTRecords.removeValue(forKey: name)
        txtRecordsLock.unlock()
    }
    
    private var resolvedTXTRecords: [String: [String: String]] = [:]
    private let txtRecordsLock = NSLock()
    
    private func parseResolveOutput(_ output: String, name: String) {
        let lines = output.components(separatedBy: "\n")
        var resolvedHostname: String?

        for line in lines {
            if line.contains("=") && !line.contains("can be reached at") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                for part in parts {
                    if part.contains("=") {
                        let kv = part.components(separatedBy: "=")
                        if kv.count == 2 {
                            let key = kv[0]
                            var value = kv[1]
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .replacingOccurrences(of: "\\", with: "")
                            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                                value = String(value.dropFirst().dropLast())
                            }
                            
                            txtRecordsLock.lock()
                            if resolvedTXTRecords[name] == nil {
                                resolvedTXTRecords[name] = [:]
                            }
                            resolvedTXTRecords[name]?[key] = value
                            txtRecordsLock.unlock()
                        }
                    }
                }
            }
            
            if line.contains("can be reached at") {
                if let hostRange = line.range(of: "at "), let portRange = line.range(of: ":5959") ?? line.range(of: ":\\d+", options: .regularExpression) {
                    let hostStart = hostRange.upperBound
                    let hostEnd = portRange.lowerBound
                    resolvedHostname = String(line[hostStart..<hostEnd])
                }
            }
        }

        // dns-sd often emits the "can be reached at" line before the TXT
        // record line. The old code decided immediately, missed the TXT `ip=`,
        // then fell back to dns-sd -G. Parse the whole chunk first so the
        // advertised IP wins deterministically.
        txtRecordsLock.lock()
        let txtIP = resolvedTXTRecords[name]?["ip"]
        let txt = resolvedTXTRecords[name]
        txtRecordsLock.unlock()

        if let txt = txt {
            Self.log("  TXT: \(txt)")
        }

        if let ip = txtIP, !ip.isEmpty, ip != "Unknown" {
            Self.log("✅ Using IP from TXT record: \(ip)")
            addDiscoveredPeer(name: name, ip: ip)
        } else if let resolvedHostname {
            Self.log("Resolved \(name) -> host: \(resolvedHostname)")
            lookupIP(for: name, hostname: resolvedHostname)
        }
    }
    
    private func lookupIP(for name: String, hostname: String) {
        // Skip if already looking up this name
        lookupLock.lock()
        if lookupProcesses[name] != nil || lookupCompleted.contains(name) {
            lookupLock.unlock()
            return
        }
        lookupLock.unlock()
        
        // Use dns-sd -G to lookup IPv4 address
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-G", "v4", hostname]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            
            // Check if already completed
            self.lookupLock.lock()
            if self.lookupCompleted.contains(name) {
                self.lookupLock.unlock()
                return
            }
            self.lookupLock.unlock()
            
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let output = String(data: data, encoding: .utf8) else { return }
            
            // Parse IP from output
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                // Look for IPv4 address pattern
                if let match = line.range(of: "\\d+\\.\\d+\\.\\d+\\.\\d+", options: .regularExpression) {
                    let ip = String(line[match])
                    
                    // Mark as completed FIRST
                    self.lookupLock.lock()
                    if self.lookupCompleted.contains(name) {
                        self.lookupLock.unlock()
                        return
                    }
                    self.lookupCompleted.insert(name)
                    self.lookupLock.unlock()
                    
                    // Clean up
                    self.cleanupLookup(name: name)
                    
                    // Add the discovered peer
                    self.addDiscoveredPeer(name: name, ip: ip)
                    return
                }
            }
        }
        
        do {
            lookupLock.lock()
            lookupProcesses[name] = process
            lookupPipes[name] = pipe
            lookupLock.unlock()
            
            try process.run()
            
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.cleanupLookup(name: name)
            }
        } catch {
            lookupLock.lock()
            lookupProcesses.removeValue(forKey: name)
            lookupPipes.removeValue(forKey: name)
            lookupLock.unlock()
            Self.log("❌ Failed to lookup IP for \(hostname): \(error)")
        }
    }
    
    private func cleanupLookup(name: String) {
        lookupLock.lock()
        
        // Remove handler before terminating
        lookupPipes[name]?.fileHandleForReading.readabilityHandler = nil
        
        // Terminate process if still running
        if let process = lookupProcesses[name], process.isRunning {
            process.terminate()
        }
        
        lookupPipes.removeValue(forKey: name)
        lookupProcesses.removeValue(forKey: name)
        
        lookupLock.unlock()
    }
    
    private func addDiscoveredPeer(name: String, ip: String) {
        // If it's localhost (self), use actual LAN IP
        var actualIP = ip
        if ip == "127.0.0.1" || ip == "::1" {
            actualIP = localInfo.ipAddress
        }
        
        let isSelf = name == advertisedName
        
        // Get TXT record if available (thread-safe)
        txtRecordsLock.lock()
        let txt = resolvedTXTRecords[name]
        txtRecordsLock.unlock()
        
        // For self, use our detailed local info
        let peer: PeerInfo
        if isSelf {
            Self.log("✅ Found self: \(name) at \(actualIP)")
            peer = localInfo
        } else {
            // Use TXT record data if available, otherwise "Unknown"
            let modelName = txt?["model"] ?? "TidalDrift Peer"
            let osVersion = txt?["os"] ?? "macOS"
            let userName = txt?["user"] ?? name.replacingOccurrences(of: "-", with: " ")
            let version = txt?["version"] ?? "1.0"
            
            Self.log("✅ Discovered peer: \(name) at \(actualIP)")
            Self.log("   Model: \(modelName), OS: \(osVersion), User: \(userName)")
            
            peer = PeerInfo(
                peerId: txt?["peerId"],
                hostname: name,
                ipAddress: actualIP,
                modelName: modelName,
                modelIdentifier: txt?["modelId"] ?? "",
                processorInfo: txt?["cpu"] ?? "",
                memoryGB: Int(txt?["mem"] ?? "0") ?? 0,
                macOSVersion: osVersion,
                userName: userName,
                uptimeHours: Int(txt?["uptime"] ?? "0") ?? 0,
                tidalDriftVersion: version,
                screenSharingEnabled: txt?["screen"] == "1",
                fileSharingEnabled: txt?["file"] == "1",
                tidalDriftName: txt?["tdname"]
            )
        }
        
        DispatchQueue.main.async {
            // Always notify network discovery to mark as TidalDrift peer
            // (even for self - this ensures the red outline shows)
            self.notifyNetworkDiscovery(peer: peer)
            
            if !isSelf {
                self.discoveredPeers[actualIP] = peer
                self.peerLastSeen[actualIP] = Date()
            }
            
            // Clean up TXT record cache (thread-safe)
            self.txtRecordsLock.lock()
            self.resolvedTXTRecords.removeValue(forKey: name)
            self.txtRecordsLock.unlock()
            
            // Clean up lookup completion tracking
            self.lookupLock.lock()
            self.lookupCompleted.remove(name)
            self.lookupLock.unlock()
        }
    }
    
    private func processBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                let isSelf = name == advertisedName
                Self.log("Discovered service: '\(name)'\(isSelf ? " (self)" : "")")
                
                // Extract TXT record if available
                if case .bonjour(let txtRecord) = result.metadata {
                    self.resolveAndAddPeer(name: name, type: type, domain: domain, txtRecord: txtRecord)
                } else {
                    // Try to resolve anyway
                    self.resolveAndAddPeer(name: name, type: type, domain: domain, txtRecord: nil)
                }
            }
        }
    }
    
    private func resolveAndAddPeer(name: String, type: String, domain: String, txtRecord: NWTXTRecord?) {
        // Create a temporary connection to resolve the IP address
        let endpoint = NWEndpoint.service(name: name, type: type, domain: domain, interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connectionId = UUID()
        
        // Store connection to prevent premature deallocation
        nwConnectionsLock.lock()
        activeNWConnections[connectionId] = connection
        nwConnectionsLock.unlock()
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   case .hostPort(let host, _) = path.remoteEndpoint {
                    
                    var ipAddress = ""
                    switch host {
                    case .ipv4(let addr): ipAddress = "\(addr)"
                    case .ipv6(let addr): ipAddress = "\(addr)"
                    case .name(let hostname, _): ipAddress = hostname
                    @unknown default: break
                    }
                    
                    // Clean IP
                    if let percentIndex = ipAddress.firstIndex(of: "%") {
                        ipAddress = String(ipAddress[..<percentIndex])
                    }
                    
                    if !ipAddress.isEmpty {
                        self?.addPeer(name: name, ip: ipAddress, txt: txtRecord)
                    }
                }
                self?.cleanupNWConnection(id: connectionId)
            case .failed:
                self?.cleanupNWConnection(id: connectionId)
            case .cancelled:
                self?.nwConnectionsLock.lock()
                self?.activeNWConnections.removeValue(forKey: connectionId)
                self?.nwConnectionsLock.unlock()
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        // Timeout after 5 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.cleanupNWConnection(id: connectionId)
        }
    }
    
    private func cleanupNWConnection(id: UUID) {
        nwConnectionsLock.lock()
        if let connection = activeNWConnections[id] {
            connection.cancel()
        }
        nwConnectionsLock.unlock()
    }
    
    private func addPeer(name: String, ip: String, txt: NWTXTRecord?) {
        let peer = PeerInfo(
            peerId: txt?["peerId"],
            hostname: name,
            ipAddress: ip,
            modelName: txt?["model"] ?? "Unknown",
            modelIdentifier: txt?["modelId"] ?? "Unknown",
            processorInfo: txt?["cpu"] ?? "Unknown",
            memoryGB: Int(txt?["mem"] ?? "0") ?? 0,
            macOSVersion: txt?["os"] ?? "Unknown",
            userName: txt?["user"] ?? "Unknown",
            uptimeHours: Int(txt?["uptime"] ?? "0") ?? 0,
            tidalDriftVersion: txt?["version"] ?? "1.0",
            screenSharingEnabled: txt?["screen"] == "1",
            fileSharingEnabled: txt?["file"] == "1",
            tidalDriftName: txt?["tdname"]
        )
        
        DispatchQueue.main.async {
            self.discoveredPeers[ip] = peer
            self.peerLastSeen[ip] = Date()
            self.notifyNetworkDiscovery(peer: peer)
            Self.log("✅ Updated peer '\(name)' at \(ip)")
        }
    }
    
    private func notifyNetworkDiscovery(peer: PeerInfo) {
        // Map back to the unified NetworkDiscoveryService
        NetworkDiscoveryService.shared.markAsTidalDriftPeer(
            hostname: peer.hostname,
            peerInfo: peer
        )
    }
    
    // MARK: - System Info Helpers
    
    private static func getModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model)
        
        // Check for specific model identifiers
        if modelString.contains("MacBookPro") { return "MacBook Pro" }
        if modelString.contains("MacBookAir") { return "MacBook Air" }
        if modelString.contains("iMac") { return "iMac" }
        if modelString.contains("Macmini") { return "Mac mini" }
        if modelString.contains("MacPro") { return "Mac Pro" }
        if modelString.contains("MacStudio") { return "Mac Studio" }
        
        // Apple Silicon Macs use "MacXX,Y" format
        // Mac14,x = MacBook Pro (M2/M2 Pro/M2 Max), Mac mini (M2), MacBook Air (M2)
        // Mac15,x = MacBook Pro (M3/M3 Pro/M3 Max), MacBook Air (M3), iMac (M3)
        // Mac16,x = MacBook Pro (M4/M4 Pro/M4 Max), Mac mini (M4)
        // Mac17,x = MacBook Pro (M5?), etc.
        if modelString.hasPrefix("Mac") {
            // Try to determine type from system info
            if let productName = getProductName() {
                return productName
            }
            // Fallback based on common patterns
            return "Mac"
        }
        
        return modelString
    }
    
    /// Try to get the marketing product name from IOKit
    private static func getProductName() -> String? {
        var size = 0
        if sysctlbyname("hw.product", nil, &size, nil, 0) == 0 {
            var product = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.product", &product, &size, nil, 0) == 0 {
                let name = String(cString: product)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }
    
    private static func getModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
    
    private static func getProcessorInfo() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var cpu = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &cpu, &size, nil, 0)
        let fullString = String(cString: cpu)
        
        if fullString.isEmpty {
            var size2 = 0
            sysctlbyname("hw.machine", nil, &size2, nil, 0)
            var machine = [CChar](repeating: 0, count: size2)
            sysctlbyname("hw.machine", &machine, &size2, nil, 0)
            let machineStr = String(cString: machine)
            if machineStr.contains("arm64") { return "Apple Silicon" }
        }
        return fullString.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "").trimmingCharacters(in: .whitespaces)
    }
    
    private static func getMemoryGB() -> Int {
        var size: size_t = MemoryLayout<Int64>.size
        var memSize: Int64 = 0
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        return Int(memSize / (1024 * 1024 * 1024))
    }
    
    private static func getMacOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static func getUptimeHours() -> Int {
        let uptime = ProcessInfo.processInfo.systemUptime
        return Int(uptime / 3600)
    }
}

// MARK: - NetServiceDelegate
extension TidalDriftPeerService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("🎉🎉🎉 DELEGATE CALLBACK: netServiceDidPublish for \(sender.name) on port \(sender.port)")
        Self.log("✅ NetService published: \(sender.name) on port \(sender.port)")
        DispatchQueue.main.async {
            self.isAdvertising = true
        }
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode]?.intValue ?? -1
        let errorDomain = errorDict[NetService.errorDomain]?.intValue ?? -1
        print("❌❌❌ DELEGATE CALLBACK: didNotPublish code=\(errorCode) domain=\(errorDomain)")
        Self.log("❌ NetService failed to publish: code=\(errorCode) domain=\(errorDomain)")
        DispatchQueue.main.async {
            self.isAdvertising = false
        }
    }
    
    func netServiceDidStop(_ sender: NetService) {
        print("🛑 DELEGATE CALLBACK: netServiceDidStop")
        Self.log("NetService stopped")
    }
    
    func netServiceWillPublish(_ sender: NetService) {
        print("📢 DELEGATE CALLBACK: netServiceWillPublish")
        Self.log("NetService will publish: \(sender.name)")
    }
}

// MARK: - NetServiceBrowserDelegate
extension TidalDriftPeerService: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("🔎🔎🔎 NetServiceBrowserWillSearch")
        Self.log("NetServiceBrowser will search")
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("🔎🔎🔎 FOUND SERVICE: \(service.name)")
        Self.log("🔎 Discovered service: '\(service.name)' type: \(service.type)")
        
        // Note: For single-computer testing, we don't skip ourselves
        let isSelf = service.name == advertisedName
        if isSelf {
            Self.log("(This is our own service)")
        }
        
        // Resolve the service to get IP address and TXT record
        service.delegate = self
        service.resolve(withTimeout: 10.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Self.log("Service removed: \(service.name)")
        // Could remove from discoveredPeers here if needed
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode]?.intValue ?? -1
        Self.log("❌ NetServiceBrowser failed to search: code=\(errorCode)")
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        Self.log("NetServiceBrowser stopped searching")
    }
    
    // NetService resolution
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else {
            Self.log("Resolved \(sender.name) but no addresses found")
            return
        }
        
        // Extract IP address from the first address
        var ipAddress = ""
        for addressData in addresses {
            addressData.withUnsafeBytes { ptr in
                let sockaddr = ptr.load(as: sockaddr.self)
                if sockaddr.sa_family == UInt8(AF_INET) {
                    // IPv4
                    let sockaddr_in = ptr.load(as: sockaddr_in.self)
                    var addr = sockaddr_in.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        ipAddress = String(cString: buffer)
                    }
                }
            }
            if !ipAddress.isEmpty { break }
        }
        
        guard !ipAddress.isEmpty else {
            Self.log("Could not extract IP for \(sender.name)")
            return
        }
        
        // Parse TXT record
        var txtValues: [String: String] = [:]
        if let txtData = sender.txtRecordData() {
            let txtDict = NetService.dictionary(fromTXTRecord: txtData)
            for (key, value) in txtDict {
                if let str = String(data: value, encoding: .utf8) {
                    txtValues[key] = str
                }
            }
        }
        
        Self.log("✅ Resolved \(sender.name) -> \(ipAddress)")
        
        let peer = PeerInfo(
            peerId: txtValues["peerId"],
            hostname: sender.name,
            ipAddress: ipAddress,
            modelName: txtValues["model"] ?? "Unknown",
            modelIdentifier: txtValues["modelId"] ?? "Unknown",
            processorInfo: txtValues["cpu"] ?? "Unknown",
            memoryGB: Int(txtValues["mem"] ?? "0") ?? 0,
            macOSVersion: txtValues["os"] ?? "Unknown",
            userName: txtValues["user"] ?? "Unknown",
            uptimeHours: Int(txtValues["uptime"] ?? "0") ?? 0,
            tidalDriftVersion: txtValues["version"] ?? "1.0",
            screenSharingEnabled: txtValues["screen"] == "1",
            fileSharingEnabled: txtValues["file"] == "1",
            tidalDriftName: txtValues["tdname"]
        )
        
        DispatchQueue.main.async {
            self.discoveredPeers[ipAddress] = peer
            self.peerLastSeen[ipAddress] = Date()
            self.notifyNetworkDiscovery(peer: peer)
        }
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        let errorCode = errorDict[NetService.errorCode]?.intValue ?? -1
        Self.log("❌ Failed to resolve \(sender.name): code=\(errorCode)")
    }
}

