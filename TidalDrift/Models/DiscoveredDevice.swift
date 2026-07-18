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
    var peerId: String?
    
    /// Display name: prefer the peer's custom TidalDrift name, fall back to discovered name
    var displayName: String {
        if let tdName = peerTidalDriftName, !tdName.isEmpty {
            return tdName
        }
        return name
    }
    
    /// Stable identifier based on name + IP for legacy credential migration.
    var stableId: String {
        "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))_\(ipAddress)"
    }

    /// Stable device identity for credentials and Wake-on-LAN metadata.
    ///
    /// Priority: TidalDrift peer ID > user-assigned credential ref >
    /// normalized hostname > this cache entry's UUID. The peer ID is a
    /// persisted per-install UUID advertised in the Bonjour TXT record; it is
    /// the only component that survives IP rotation, multi-NIC duplication,
    /// and hostname renames together, so it wins whenever present. It used to
    /// be gated on `isTrusted`, but nothing ever set that flag, so secrets
    /// keyed off the hostname in practice; hostnames flap (unresolved at
    /// rediscovery, Bonjour instance name vs real hostname, renames), which
    /// is what kept unseating saved logins. mDNS hostnames are no more
    /// authenticated than peer IDs, so the gate bought no security either.
    var identityKey: String {
        if let peerId = Self.normalizedIdentityComponent(peerId) {
            return "peer:\(peerId)"
        }

        if let credentialRef = Self.normalizedIdentityComponent(savedCredentialRef) {
            return "manual:\(credentialRef)"
        }

        if let hostname = Self.normalizedHostname(hostname) {
            return "host:\(hostname)"
        }

        return "manual:\(id.uuidString.lowercased())"
    }

    /// Stable key for discovery cache merges. Same as the secrets key now
    /// that the peer ID leads both.
    var discoveryKey: String {
        identityKey
    }

    /// Every key this computer's secrets may live under, canonical first.
    /// Credential and Wake-on-LAN lookups walk these so a value saved under
    /// an older identity (hostname before the peer ID was learned, a manual
    /// ref, the legacy name_ip stableId) is still found and can be migrated
    /// to the canonical key.
    var credentialAliases: [String] {
        var aliases = [identityKey]
        if let credentialRef = Self.normalizedIdentityComponent(savedCredentialRef) {
            aliases.append("manual:\(credentialRef)")
        }
        if let hostname = Self.normalizedHostname(hostname) {
            aliases.append("host:\(hostname)")
        }
        aliases.append("manual:\(id.uuidString.lowercased())")
        aliases.append(stableId)
        var seen = Set<String>()
        return aliases.filter { seen.insert($0).inserted }
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
         peerTidalDriftName: String? = nil,
         peerId: String? = nil) {
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
        self.peerId = peerId
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
        if peerId == TidalDriftPeerService.localPeerId {
            return true
        }

        let localIPs = Set(NetworkUtils.getAllIPAddresses().values)
        if localIPs.contains(ipAddress) {
            return true
        }

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

    static func normalizedHostname(_ value: String?) -> String? {
        guard var hostname = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !hostname.isEmpty,
              hostname != "unknown",
              hostname != "resolving..." else {
            return nil
        }

        hostname = hostname.replacingOccurrences(of: ".local.", with: ".local")
        hostname = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if hostname.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return nil
        }
        return hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
    }

    static func normalizedIdentityComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty,
              value != "unknown",
              value != "resolving..." else {
            return nil
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        let normalized = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(normalized)
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
