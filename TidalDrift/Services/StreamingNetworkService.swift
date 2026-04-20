import Foundation
import Network
import Combine
import OSLog

/// Represents a remote app available for streaming from another machine
struct RemoteStreamableApp: Identifiable, Hashable, Codable {
    let id: String  // Unique ID: hostIP-bundleId
    let name: String
    let bundleIdentifier: String
    let windowCount: Int
    let hostName: String
    let hostIP: String
    let port: UInt16
    
    static func == (lhs: RemoteStreamableApp, rhs: RemoteStreamableApp) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Represents a remote host advertising streaming apps
struct StreamingHost: Identifiable, Hashable {
    let id: String  // IP address
    let name: String
    let ipAddress: String
    let port: UInt16
    var apps: [RemoteStreamableApp]
    
    static func == (lhs: StreamingHost, rhs: StreamingHost) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Service for advertising and discovering streaming apps via Bonjour
@MainActor
class StreamingNetworkService: ObservableObject, @unchecked Sendable {
    static let shared = StreamingNetworkService()
    private let logger = Logger(subsystem: "com.tidaldrift", category: "Streaming")
    
    // Bonjour service type for TidalDrift streaming
    private let serviceType = "_tidalstream._tcp"
    private let serviceDomain = "local."
    private let streamingPort: UInt16 = 5901
    
    // Store active connections to prevent premature deallocation
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()
    
    // Advertising
    @Published var isHosting = false
    @Published var hostedApps: [String] = []  // Bundle IDs of apps being shared
    private var listener: NWListener?
    private var advertiser: NWListener?
    
    // Discovery
    @Published var isDiscovering = false
    @Published var discoveredHosts: [StreamingHost] = []
    @Published var allRemoteApps: [RemoteStreamableApp] = []
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    
    private let queue = DispatchQueue(label: "com.tidaldrift.streaming", qos: .userInitiated)
    
    private init() {}
    
    nonisolated private func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
    
    // MARK: - Hosting (Advertising your apps)
    
    /// Start advertising available apps on the network
    func startHosting(apps: [StreamableApp]) {
        log("🎬 ========== START HOSTING CALLED ==========")
        log("🎬 Current isHosting: \(isHosting)")
        log("🎬 Apps count: \(apps.count)")
        
        guard !isHosting else { 
            log("🎬 Already hosting, skipping")
            return 
        }
        
        log("🎬 Starting hosting with \(apps.count) apps...")
        
        // Convert to shareable format
        hostedApps = apps.compactMap { $0.bundleIdentifier }
        log("🎬 Hosted apps bundle IDs: \(hostedApps.prefix(5))...")
        
        // Set hosting to true immediately for UI feedback
        isHosting = true
        log("🎬 Set isHosting = true")
        
        do {
            // Create listener for incoming connections
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            
            log("🎬 Creating NWListener on port \(streamingPort)...")
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: streamingPort))
            log("🎬 NWListener created successfully")
            
            // Set up TXT record with app info
            let txtData = createTXTRecord(for: apps)
            
            listener?.service = NWListener.Service(
                name: NetworkUtils.computerName,
                type: serviceType,
                domain: nil,
                txtRecord: txtData
            )
            log("🎬 Service configured: \(serviceType) in \(serviceDomain)")
            
            listener?.stateUpdateHandler = { [weak self] state in
                self?.log("🎬 Listener state changed: \(state)")
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isHosting = true
                        self?.log("🎬 ✅ Streaming host ready, advertising \(apps.count) apps")
                    case .failed(let error):
                        self?.log("🎬 ❌ Streaming host failed: \(error)")
                        self?.isHosting = false
                    case .cancelled:
                        self?.log("🎬 Streaming host cancelled")
                        self?.isHosting = false
                    case .waiting(let error):
                        self?.log("🎬 Streaming host waiting: \(error)")
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.log("🎬 New connection received!")
                self?.handleIncomingConnection(connection)
            }
            
            log("🎬 Starting listener...")
            listener?.start(queue: queue)
            log("🎬 Listener start() called")
            
        } catch {
            log("🎬 ❌ Failed to start streaming host: \(error)")
            isHosting = false
            hostedApps = []
        }
        
        log("🎬 ========== END START HOSTING ==========")
    }
    
    /// Stop advertising
    func stopHosting() {
        listener?.cancel()
        listener = nil
        isHosting = false
        hostedApps = []
    }
    
    /// Update the list of hosted apps
    func updateHostedApps(_ apps: [StreamableApp]) {
        if isHosting {
            stopHosting()
            startHosting(apps: apps)
        }
    }
    
    private func createTXTRecord(for apps: [StreamableApp]) -> NWTXTRecord {
        var record = NWTXTRecord()
        
        // Add computer name
        record["name"] = NetworkUtils.computerName
        
        // Add app count
        record["appCount"] = "\(apps.count)"
        
        // Add app info (limited to fit in TXT record)
        for (index, app) in apps.prefix(10).enumerated() {
            record["app\(index)"] = "\(app.name)|\(app.bundleIdentifier ?? "unknown")|\(app.windows.count)"
        }
        
        return record
    }
    
    nonisolated private func handleIncomingConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .ready:
                self?.receiveData(on: connection)
            case .failed(let error):
                self?.logger.warning("Incoming connection failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    nonisolated private func receiveData(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleRequest(data, on: connection)
            }
            if !isComplete && error == nil {
                self?.receiveData(on: connection)
            }
        }
    }
    
    nonisolated private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        
        switch request {
        case "LIST_APPS":
            // Return list of available apps
            Task { @MainActor in
                let apps = AppStreamingService.shared.availableApps
                let response = apps.map { app in
                    ["name": app.name, 
                     "bundleId": app.bundleIdentifier ?? "", 
                     "windows": app.windows.count] as [String : Any]
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: response) {
                    connection.send(content: jsonData, completion: .contentProcessed { _ in })
                }
            }
            
        case "RESTART_SCREEN_SHARING":
            // Remote request to restart local Screen Sharing service
            // This fixes the "not permitted" macOS bug
            Task {
                #if DEBUG
                print("🔧 Remote request to restart Screen Sharing")
                #endif
                
                let success = await ScreenShareConnectionService.shared.restartLocalScreenSharing()
                
                let response = success ? "OK" : "FAILED"
                let responseData = Data(response.utf8)
                connection.send(content: responseData, completion: .contentProcessed { _ in })
                
                #if DEBUG
                print("🔧 Screen Sharing restart: \(success ? "success" : "failed")")
                #endif
            }
            
        case "PING":
            // Simple health check
            let response = Data("PONG".utf8)
            connection.send(content: response, completion: .contentProcessed { _ in })
            
        default:
            #if DEBUG
            print("🔍 Unknown request: \(request)")
            #endif
        }
    }
    
    // MARK: - Discovery (Finding remote apps)
    
    /// Start discovering streaming hosts on the network
    func startDiscovery() {
        guard !isDiscovering else { 
            #if DEBUG
            print("🔍 Already discovering, skipping")
            #endif
            return 
        }
        
        #if DEBUG
        print("🔍 Starting discovery...")
        #endif
        
        // Set discovering to true immediately for UI feedback
        isDiscovering = true
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: serviceDomain), using: parameters)
        
        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isDiscovering = true
                    #if DEBUG
                    print("🔍 Streaming discovery started")
                    #endif
                case .failed(let error):
                    #if DEBUG
                    print("🔍 Streaming discovery failed: \(error)")
                    #endif
                    self?.isDiscovering = false
                default:
                    break
                }
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleDiscoveryResults(results)
            }
        }
        
        browser?.start(queue: queue)
    }
    
    /// Stop discovery
    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isDiscovering = false
        
        // Close all connections
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
    }
    
    /// Refresh discovery
    func refreshDiscovery() {
        stopDiscovery()
        discoveredHosts = []
        allRemoteApps = []
        startDiscovery()
    }
    
    private func handleDiscoveryResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                #if DEBUG
                print("🔍 Found streaming host: \(name) (\(type).\(domain))")
                #endif
                resolveAndConnect(result: result, serviceName: name)
            default:
                break
            }
        }
    }
    
    private func resolveAndConnect(result: NWBrowser.Result, serviceName: String) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection = connection else { return }
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint {
                    let ipAddress = self?.extractIP(from: host) ?? "unknown"
                    
                    Task { @MainActor in
                        if case .bonjour(let txtRecord) = result.metadata {
                            self?.processDiscoveredHost(
                                name: serviceName,
                                ipAddress: ipAddress,
                                port: port.rawValue,
                                txtRecord: txtRecord
                            )
                        }
                    }
                }
                
                let request = "LIST_APPS".data(using: .utf8)!
                connection.send(content: request, completion: .contentProcessed { _ in })
                
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                    if let data = data {
                        Task { @MainActor in
                            self?.processAppListResponse(data, from: serviceName)
                        }
                    }
                }
                
            case .failed(let error):
                self?.logger.warning("Failed to connect to \(serviceName): \(error.localizedDescription)")
            default:
                break
            }
        }
        
        connections[serviceName] = connection
        connection.start(queue: queue)
    }
    
    nonisolated private func extractIP(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            return "\(addr)"
        case .name(let name, _):
            return name
        @unknown default:
            return "unknown"
        }
    }
    
    private func processDiscoveredHost(name: String, ipAddress: String, port: UInt16, txtRecord: NWTXTRecord) {
        // Skip if this is our own machine
        if isOwnMachine(ipAddress: ipAddress) { return }
        
        var apps: [RemoteStreamableApp] = []
        
        // Parse app info from TXT record
        let appCountStr = txtRecord["appCount"] ?? "0"
        let appCount = Int(appCountStr) ?? 0
        
        for i in 0..<appCount {
            if let appInfo = txtRecord["app\(i)"] {
                let parts = appInfo.split(separator: "|")
                if parts.count >= 3 {
                    let appName = String(parts[0])
                    let bundleId = String(parts[1])
                    let windowCount = Int(parts[2]) ?? 0
                    
                    let app = RemoteStreamableApp(
                        id: "\(ipAddress)-\(bundleId)",
                        name: appName,
                        bundleIdentifier: bundleId,
                        windowCount: windowCount,
                        hostName: name,
                        hostIP: ipAddress,
                        port: port
                    )
                    apps.append(app)
                }
            }
        }
        
        // Update or add host
        if let index = discoveredHosts.firstIndex(where: { $0.ipAddress == ipAddress }) {
            discoveredHosts[index].apps = apps
        } else {
            let host = StreamingHost(
                id: ipAddress,
                name: name,
                ipAddress: ipAddress,
                port: port,
                apps: apps
            )
            discoveredHosts.append(host)
        }
        
        // Update flat list of all apps
        updateAllRemoteApps()
        
        #if DEBUG
        print("🔍 Discovered host: \(name) at \(ipAddress) with \(apps.count) apps")
        #endif
    }
    
    private func processAppListResponse(_ data: Data, from hostName: String) {
        Task { @MainActor in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            
            // Find the host
            guard let hostIndex = discoveredHosts.firstIndex(where: { $0.name == hostName }) else {
                return
            }
            
            var updatedApps: [RemoteStreamableApp] = []
            let host = discoveredHosts[hostIndex]
            
            for appInfo in json {
                if let name = appInfo["name"] as? String,
                   let bundleId = appInfo["bundleId"] as? String,
                   let windows = appInfo["windows"] as? Int {
                    let app = RemoteStreamableApp(
                        id: "\(host.ipAddress)-\(bundleId)",
                        name: name,
                        bundleIdentifier: bundleId,
                        windowCount: windows,
                        hostName: host.name,
                        hostIP: host.ipAddress,
                        port: host.port
                    )
                    updatedApps.append(app)
                }
            }
            
            discoveredHosts[hostIndex].apps = updatedApps
            updateAllRemoteApps()
        }
    }
    
    private func updateAllRemoteApps() {
        allRemoteApps = discoveredHosts.flatMap { $0.apps }
    }
    
    private func isOwnMachine(ipAddress: String) -> Bool {
        // Get local IPs
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                          &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                let localIP = String(cString: hostname)
                if localIP == ipAddress {
                    return true
                }
            }
        }
        return false
    }
    
    // MARK: - Connecting to Remote Apps
    
    /// Connect to view a remote app (opens screen sharing focused on that app)
    func connectToRemoteApp(_ app: RemoteStreamableApp) {
        // For now, open standard screen sharing to the remote machine
        // The remote machine should bring the app to front
        let vncURL = "vnc://\(app.hostIP)"
        if let url = URL(string: vncURL) {
            NSWorkspace.shared.open(url)
        }
        
        // Send request to bring app to front on remote machine
        sendBringToFrontRequest(app: app)
    }
    
    private func sendBringToFrontRequest(app: RemoteStreamableApp) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(app.hostIP),
            port: NWEndpoint.Port(integerLiteral: app.port)
        )
        
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connectionId = UUID()
        
        // Store connection to prevent premature deallocation
        connectionsLock.lock()
        activeConnections[connectionId] = connection
        connectionsLock.unlock()
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let request = "FOCUS|\(app.bundleIdentifier)".data(using: .utf8)!
                connection.send(content: request, completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in
                        self?.cleanupConnection(id: connectionId)
                    }
                })
            case .failed:
                Task { @MainActor in
                    self?.cleanupConnection(id: connectionId)
                }
            case .cancelled:
                Task { @MainActor in
                    self?.cleanupConnection(id: connectionId)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    private func cleanupConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = activeConnections[id] {
            connection.cancel()
        }
        connectionsLock.unlock()
    }
}

import AppKit

