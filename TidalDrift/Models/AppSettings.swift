import Foundation

struct AppSettings: Codable, Equatable {
    var launchAtLogin: Bool
    var scanIntervalSeconds: Int
    var showNotifications: Bool
    var useBiometrics: Bool
    var enableConnectionLogging: Bool
    var showMenuBarIcon: Bool
    var autoConnectTrustedDevices: Bool
    var peerDiscoveryEnabled: Bool
    var sshDiscoveryEnabled: Bool
    var showExperimentalFeatures: Bool
    var theme: AppTheme
    
    // Wake-on-LAN settings
    var wakeOnLANEnabled: Bool
    var wakeOnLANPort: Int
    var wakeOnLANRetries: Int
    var autoWakeBeforeConnect: Bool
    
    // TidalDrop settings
    var tidalDropDestination: String
    var tidalDropDestinationBookmark: Data?
    
    // Bonjour display name (persists across IP changes)
    var tidalDriftDisplayName: String
    
    init(launchAtLogin: Bool = false,
         scanIntervalSeconds: Int = 30,
         showNotifications: Bool = true,
         useBiometrics: Bool = false,
         enableConnectionLogging: Bool = true,
         showMenuBarIcon: Bool = true,
         autoConnectTrustedDevices: Bool = false,
         peerDiscoveryEnabled: Bool = true,
         sshDiscoveryEnabled: Bool = true,
         showExperimentalFeatures: Bool = false,
         theme: AppTheme = .system,
         wakeOnLANEnabled: Bool = true,
         wakeOnLANPort: Int = 9,
         wakeOnLANRetries: Int = 3,
         autoWakeBeforeConnect: Bool = true,
         tidalDropDestination: String = "",
         tidalDropDestinationBookmark: Data? = nil,
         tidalDriftDisplayName: String = "") {
        self.launchAtLogin = launchAtLogin
        self.scanIntervalSeconds = scanIntervalSeconds
        self.showNotifications = showNotifications
        self.useBiometrics = useBiometrics
        self.enableConnectionLogging = enableConnectionLogging
        self.showMenuBarIcon = showMenuBarIcon
        self.autoConnectTrustedDevices = autoConnectTrustedDevices
        self.peerDiscoveryEnabled = peerDiscoveryEnabled
        self.sshDiscoveryEnabled = sshDiscoveryEnabled
        self.showExperimentalFeatures = showExperimentalFeatures
        self.theme = theme
        self.wakeOnLANEnabled = wakeOnLANEnabled
        self.wakeOnLANPort = wakeOnLANPort
        self.wakeOnLANRetries = wakeOnLANRetries
        self.autoWakeBeforeConnect = autoWakeBeforeConnect
        self.tidalDropDestination = tidalDropDestination
        self.tidalDropDestinationBookmark = tidalDropDestinationBookmark
        self.tidalDriftDisplayName = tidalDriftDisplayName
    }
    
    /// Returns the TidalDrop destination folder, defaulting to ~/Public/Drop Box
    var tidalDropFolder: URL {
        if let data = tidalDropDestinationBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), !isStale {
                return url
            }
        }

        if tidalDropDestination.isEmpty {
            // Default to Public Drop Box which is standard for incoming files
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Public")
                .appendingPathComponent("Drop Box")
        }
        return URL(fileURLWithPath: tidalDropDestination)
    }
    
    enum AppTheme: String, Codable, CaseIterable {
        case system
        case light
        case dark
        
        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }
    
    static var `default`: AppSettings {
        AppSettings()
    }
}

extension AppSettings {
    var scanInterval: TimeInterval {
        TimeInterval(scanIntervalSeconds)
    }
    
    static let scanIntervalOptions: [Int] = [15, 30, 60, 120, 300]
    
    static func scanIntervalDisplayName(for seconds: Int) -> String {
        switch seconds {
        case 15: return "15 seconds"
        case 30: return "30 seconds"
        case 60: return "1 minute"
        case 120: return "2 minutes"
        case 300: return "5 minutes"
        default: return "\(seconds) seconds"
        }
    }
    
    // Wake-on-LAN options
    static let wolPortOptions: [Int] = [7, 9]
    
    static func wolPortDisplayName(for port: Int) -> String {
        switch port {
        case 7: return "Port 7 (Echo)"
        case 9: return "Port 9 (Discard) - Default"
        default: return "Port \(port)"
        }
    }
    
    static let wolRetryOptions: [Int] = [1, 3, 5, 10]
}
