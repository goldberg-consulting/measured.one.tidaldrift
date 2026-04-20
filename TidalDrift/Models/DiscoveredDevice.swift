import Foundation

struct DiscoveredDevice: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hostname: String
    var ipAddress: String
    var services: Set<ServiceType>
    var lastSeen: Date
    var isTrusted: Bool
    var savedCredentialRef: String?
    var port: Int
    
    /// Advertised LocalCast auth requirement from Bonjour TXT (`auth=1/0`).
    /// nil means unknown (older hosts or unresolved TXT).
    var localCastAuthRequired: Bool?
    
    // TidalDrift peer info (if running on remote machine)
    var isTidalDriftPeer: Bool
    var peerModelName: String?
    var peerModelIdentifier: String?
    var peerProcessorInfo: String?
    var peerMemoryGB: Int?
    var peerMacOSVersion: String?
    var peerUserName: String?
    var peerUptimeHours: Int?
    var peerTidalDriftName: String?
    
    /// Display name: prefer the peer's custom TidalDrift name, fall back to discovered name
    var displayName: String {
        if let tdName = peerTidalDriftName, !tdName.isEmpty {
            return tdName
        }
        return name
    }
    
    /// Stable identifier based on name + IP for credential storage
    var stableId: String {
        "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))_\(ipAddress)"
    }
    
    init(id: UUID = UUID(),
         name: String,
         hostname: String,
         ipAddress: String,
         services: Set<ServiceType> = [],
         lastSeen: Date = Date(),
         isTrusted: Bool = false,
         savedCredentialRef: String? = nil,
         port: Int = 5900,
         localCastAuthRequired: Bool? = nil,
         isTidalDriftPeer: Bool = false,
         peerModelName: String? = nil,
         peerModelIdentifier: String? = nil,
         peerProcessorInfo: String? = nil,
         peerMemoryGB: Int? = nil,
         peerMacOSVersion: String? = nil,
         peerUserName: String? = nil,
         peerUptimeHours: Int? = nil,
         peerTidalDriftName: String? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.services = services
        self.lastSeen = lastSeen
        self.isTrusted = isTrusted
        self.savedCredentialRef = savedCredentialRef
        self.port = port
        self.localCastAuthRequired = localCastAuthRequired
        self.isTidalDriftPeer = isTidalDriftPeer
        self.peerModelName = peerModelName
        self.peerModelIdentifier = peerModelIdentifier
        self.peerProcessorInfo = peerProcessorInfo
        self.peerMemoryGB = peerMemoryGB
        self.peerMacOSVersion = peerMacOSVersion
        self.peerUserName = peerUserName
        self.peerUptimeHours = peerUptimeHours
        self.peerTidalDriftName = peerTidalDriftName
    }
    
    enum ServiceType: String, Codable, CaseIterable {
        case screenSharing = "_rfb._tcp."
        case fileSharing = "_smb._tcp."
        case afp = "_afpovertcp._tcp."
        case ssh = "_ssh._tcp."
        case tidalDrift = "_tidaldrift._tcp."
        case tidalDrop = "_tidaldrop._tcp."
        case localCast = "_tidaldrift-cast._udp."
        
        var displayName: String {
            switch self {
            case .screenSharing: return "Screen Sharing"
            case .fileSharing: return "File Sharing"
            case .afp: return "AFP"
            case .ssh: return "SSH"
            case .tidalDrift: return "TidalDrift"
            case .tidalDrop: return "TidalDrop"
            case .localCast: return "LocalCast"
            }
        }
        
        var icon: String {
            switch self {
            case .screenSharing: return "rectangle.on.rectangle"
            case .fileSharing: return "folder"
            case .afp: return "externaldrive.connected.to.line.below"
            case .ssh: return "terminal"
            case .tidalDrift: return "wave.3.right"
            case .tidalDrop: return "arrow.down.doc"
            case .localCast: return "bolt.fill"
            }
        }
    }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    
    /// Seconds since this device was last seen. Use this to avoid
    /// creating multiple Date() objects across the status properties.
    private var age: TimeInterval { Date().timeIntervalSince(lastSeen) }
    
    var isOnline: Bool { age < 60 }
    
    /// Check if this device is the current Mac (by IP address)
    var isCurrentDevice: Bool {
        guard let localIP = NetworkUtils.getLocalIPAddress() else { return false }
        return ipAddress == localIP
    }
    
    /// Device hasn't been seen in 24+ hours
    var isStale: Bool { age > 24 * 60 * 60 }
    
    /// Device was seen in this session (within the last 5 minutes)
    var isRecentlyConfirmed: Bool { age < 5 * 60 }
    
    var statusText: String {
        if isOnline {
            return "Online"
        } else {
            return "Last seen \(Self.relativeFormatter.localizedString(for: lastSeen, relativeTo: Date()))"
        }
    }
    
    var lastSeenText: String {
        let interval = age
        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
    
    var deviceIcon: String {
        let lowercaseName = name.lowercased()
        if lowercaseName.contains("imac") {
            return "desktopcomputer"
        } else if lowercaseName.contains("macbook") {
            return "laptopcomputer"
        } else if lowercaseName.contains("mac mini") {
            return "macmini"
        } else if lowercaseName.contains("mac pro") {
            return "macpro.gen3"
        } else if lowercaseName.contains("mac studio") {
            return "macstudio"
        }
        return "desktopcomputer"
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

extension DiscoveredDevice {
    static var preview: DiscoveredDevice {
        DiscoveredDevice(
            name: "iMac Office",
            hostname: "imac-office.local",
            ipAddress: "192.168.1.101",
            services: [.screenSharing, .fileSharing],
            lastSeen: Date(),
            isTrusted: true
        )
    }
    
    static var previewList: [DiscoveredDevice] {
        [
            DiscoveredDevice(name: "iMac Office", hostname: "imac.local", ipAddress: "192.168.1.101", services: [.screenSharing, .fileSharing]),
            DiscoveredDevice(name: "Mac Mini Server", hostname: "mini.local", ipAddress: "192.168.1.102", services: [.screenSharing, .fileSharing]),
            DiscoveredDevice(name: "MacBook Air", hostname: "air.local", ipAddress: "192.168.1.103", services: [.screenSharing], lastSeen: Date().addingTimeInterval(-120)),
            DiscoveredDevice(name: "Mac Pro Studio", hostname: "pro.local", ipAddress: "192.168.1.104", services: [.screenSharing, .fileSharing, .afp])
        ]
    }
}
