import Foundation
import Combine
import Network
import AppKit
import CoreGraphics
import OSLog

// MARK: - Architecture
//
// TidalCast uses a two-tier architecture:
//
// Tier 1 — Full Desktop (VNC):
//   macOS built-in Screen Sharing via vnc:// handles full-desktop viewing.
//   No custom video pipeline needed; Apple provides encoding, compression,
//   input forwarding, clipboard sync, and authentication natively.
//   Initiated by ScreenShareConnectionService.connect(to:).
//
// Tier 2 — App/Window Streaming (custom):
//   Uses ScreenCaptureKit to capture a single window or app on the host,
//   VideoToolbox H.264 encoding, UDP transport, Metal rendering on the client.
//   The client sees the remote app in a native-feeling NSWindow.
//   Initiated by connectSystemScreenShare(to:), which opens VNC for the
//   desktop AND a control channel for app enumeration / targeted capture.
//
// The LocalCast transport (UDP + PacketProtocol) is retained for Tier 2 only.

@MainActor
protocol LocalCastServiceDelegate: AnyObject {
    func localCastDidStartHosting()
    func localCastDidStopHosting()
    func localCastDidConnect(to device: DiscoveredDevice)
    func localCastDidDisconnect(from device: DiscoveredDevice, reason: LocalCastDisconnectReason)
    func localCastDidReceiveStats(_ stats: LocalCastStats)
}

enum LocalCastDisconnectReason {
    case userInitiated
    case connectionLost
    case remoteEnded
    case error(String)
}

struct LocalCastStats {
    let latencyMs: Double
    let fps: Int
    let bitrateMbps: Double
}

struct LocalCastConnection: Identifiable {
    let id: UUID
    let device: DiscoveredDevice
    let startTime: Date
    var clientName: String { device.name }
}

@MainActor
class LocalCastService: ObservableObject {
    static let shared = LocalCastService()
    let logger = Logger(subsystem: "com.tidaldrift", category: "LocalCastService")

    @Published var isHosting = false
    @Published var activeConnections: [LocalCastConnection] = []
    @Published var currentStats: LocalCastStats?
    
    /// Whether authentication is active for the current hosting session.
    @Published var isAuthEnabled = false
    
    /// Live-adjustable streaming quality. Changes are pushed to the active
    /// host session immediately via Combine observation.
    let streamingTuning = StreamingTuning()

    weak var delegate: LocalCastServiceDelegate?
    var configuration: LocalCastConfiguration = .default

    private var hostSession: HostSession?
    private var tuningSubscription: AnyCancellable?
    private var advertisementProcess: Process?
    private let serviceType = "_tidaldrift-cast._udp"
    
    /// Strong references to active viewer window controllers so they (and their
    /// input-capture event monitors) survive for the lifetime of the window.
    private var activeViewerControllers: [LocalCastViewerWindowController] = []

    
    
    private init() {
        // Observe tuning changes and forward to the active host session.
        // Debounce to 50ms so rapid slider drags don't flood the encoder.
        tuningSubscription = streamingTuning.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // objectWillChange fires *before* the value changes,
                // so dispatch async to read the new values.
                Task { @MainActor in
                    self.applyTuningToHostSession()
                }
            }
    }
    
    /// Push current tuning values to the active host session.
    private func applyTuningToHostSession() {
        guard isHosting, let session = hostSession else { return }
        session.updateStreamingQuality(streamingTuning)
    }

    // MARK: - Host Mode

    func startHosting(display: CGDirectDisplayID? = nil) async throws {
        try await startHosting(target: .fullDisplay)
    }

    func startHostingWindow(windowID: CGWindowID, windowTitle: String) async throws {
        try await startHosting(target: .window(windowID, title: windowTitle))
    }

    func startHostingApp(processID: pid_t, appName: String) async throws {
        try await startHosting(target: .app(processID, name: appName))
    }

    private func startHosting(target: HostCaptureTarget) async throws {
        let permissions = LocalCastPermissions()

        if !permissions.requestScreenCaptureIfNeeded() {
            logger.info("Screen Recording denied -- waiting for user to grant in System Settings")
            let granted = await permissions.waitForScreenCaptureGrant(maxWait: 30)
            if !granted {
                throw LocalCastError.permissionDenied(.screenCapture)
            }
        }

        await permissions.checkPermissions()
        if !permissions.accessibilityGranted {
            logger.warning("Accessibility permission not granted -- input forwarding disabled")
            permissions.requestAccessibilityPermission()
        }
        
        // Sync security settings from UserDefaults (set by LocalCastSettingsView)
        let defaults = UserDefaults.standard
        configuration.requireAuthentication = defaults.object(forKey: "localCastRequireAuth") as? Bool ?? true
        configuration.inputRateLimit = defaults.object(forKey: "localCastInputRateLimit") as? Int ?? 120

        // Read the host password for auth (Keychain first, legacy UserDefaults fallback)
        let hostPassword: String?
        if configuration.requireAuthentication {
            let stored = LocalCastPasswordStore.load() ?? ""
            hostPassword = stored.isEmpty ? nil : stored
            self.isAuthEnabled = hostPassword != nil
            if hostPassword == nil {
                logger.warning("🔐 Auth enabled but no host password set — auth will be skipped")
            } else {
                logger.info("🔐 Auth enabled with host password")
            }
        } else {
            hostPassword = nil
            self.isAuthEnabled = false
        }
        
        // Sync initial tuning from the configuration preset
        streamingTuning.syncFrom(configuration)
        
        let session = HostSession(configuration: configuration, password: hostPassword)
        try await session.start(target: target)

        advertiseLocalCast(port: LocalCastConfiguration.hostPort)

        self.hostSession = session
        self.isHosting = true
        delegate?.localCastDidStartHosting()
        logger.info("Hosting started")
    }

    func stopHosting() {
        guard isHosting else { return }
        self.isHosting = false
        self.isAuthEnabled = false
        stopAdvertisement()

        let session = self.hostSession
        self.hostSession = nil
        Task {
            await session?.stop()
        }

        delegate?.localCastDidStopHosting()
        logger.info("Hosting stopped")
    }

    private func advertiseLocalCast(port: UInt16) {
        let displayName = NetworkUtils.sanitizedComputerName
        stopAdvertisement()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        let codec = configuration.codec == .hevc ? "hevc" : "h264"
        let ip = NetworkUtils.getLocalIPAddress() ?? ""
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        process.arguments = [
            "-R", displayName, serviceType, "local.", "\(port)",
            "version=\(appVersion)",
            "codec=\(codec)",
            "fps=\(configuration.targetFrameRate)",
            "ip=\(ip)",
            "auth=\(configuration.requireAuthentication ? "1" : "0")"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            self.advertisementProcess = process
            logger.info("LocalCast advertised: \(displayName) on port \(port) [\(codec), \(self.configuration.targetFrameRate)fps, ip=\(ip)]")
        } catch {
            logger.error("Failed to start Bonjour advertisement: \(error.localizedDescription)")
        }
    }

    private func stopAdvertisement() {
        if let process = advertisementProcess, process.isRunning {
            process.terminate()
        }
        advertisementProcess = nil
    }

    // MARK: - Client Mode

    func connect(to device: DiscoveredDevice, password: String? = nil) async throws -> LocalCastViewerWindowController {
        logger.info("Connecting to \(device.name)")
        
        // If no password was provided, try to auto-fill from saved credentials
        var resolvedPassword = password
        if resolvedPassword == nil || resolvedPassword?.isEmpty == true {
            if let creds = try? KeychainService.shared.getCredential(for: device.stableId) {
                resolvedPassword = creds.password
                logger.info("🔐 Using saved credentials for \(device.name)")
            }
        }
        
        let session = ClientSession(device: device)
        try await session.connect(password: resolvedPassword)
        let controller = LocalCastViewerWindowController(device: device, session: session)
        
        // Retain the controller so its NSEvent monitors (input capture) stay alive
        // for the lifetime of the window. Without this, ARC deallocates the controller
        // as soon as the caller's local variable goes out of scope, killing all input.
        activeViewerControllers.append(controller)
        controller.onClose = { [weak self] closedController in
            self?.activeViewerControllers.removeAll { $0 === closedController }
        }
        
        return controller
    }

    // MARK: - System Screen Share + App Control
    
    /// Strong references to active app control panels.
    private var activeControlPanels: [AppControlPanelController] = []
    
    /// Opens macOS Screen Sharing.app (VNC) for the video stream AND
    /// attempts to establish a TidalDrift control channel for remote app
    /// management. VNC always opens; the App Control panel is shown only
    /// if the control channel connects successfully.
    func connectSystemScreenShare(to device: DiscoveredDevice, password: String? = nil) async throws -> AppControlPanelController {
        logger.info("System Screen Share + App Control for \(device.name)")
        
        // 1. Always open macOS Screen Sharing.app via VNC (Tier 1)
        do {
            try await ScreenShareConnectionService.shared.connect(to: device)
            logger.info("Opened Screen Sharing.app for \(device.name)")
        } catch {
            logger.warning("VNC connection failed: \(error.localizedDescription)")
        }
        
        // If the host is not advertising LocalCast, fail fast with a clear
        // message instead of timing out and implying a firewall block.
        guard device.supportsLocalCast else {
            let reason = "Remote Mac is not advertising LocalCast on port \(LocalCastConfiguration.hostPort). Enable LocalCast Hosting on the host Mac first."
            logger.warning("App Control unavailable for \(device.name): \(reason)")
            throw LocalCastError.connectionFailed(reason)
        }
        
        // 2. Establish a TidalDrift control channel for app enumeration (Tier 2)
        var resolvedPassword = password
        if resolvedPassword == nil || resolvedPassword?.isEmpty == true {
            if let creds = try? KeychainService.shared.getCredential(for: device.stableId) {
                resolvedPassword = creds.password
                logger.info("🔐 Using saved credentials for control channel to \(device.name)")
            }
        }
        
        let session = ClientSession(device: device)
        try await session.connect(password: resolvedPassword)
        
        // 3. Show the floating app control panel
        let controller = AppControlPanelController(device: device, session: session)
        
        activeControlPanels.append(controller)
        controller.onClose = { [weak self] closed in
            self?.activeControlPanels.removeAll { $0 === closed }
        }
        
        return controller
    }
    
    func disconnect(from device: DiscoveredDevice) {
        activeConnections.removeAll { $0.device.id == device.id }
    }

    // MARK: - Discovery

    func supportsLocalCast(_ device: DiscoveredDevice) -> Bool {
        device.supportsLocalCast
    }

    func localCastEndpoint(for device: DiscoveredDevice) -> NWEndpoint? {
        device.localCastEndpoint
    }
}

enum LocalCastError: LocalizedError {
    case permissionDenied(Permission)
    case connectionFailed(String)
    case encoderInitializationFailed
    case decoderInitializationFailed
    case noDisplayAvailable
    case hostNotReady

    enum Permission {
        case screenCapture
        case accessibility
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied(.screenCapture):
            return "Screen recording permission required. Open System Settings > Privacy & Security > Screen Recording and enable TidalDrift."
        case .permissionDenied(.accessibility):
            return "Accessibility permission required for input control. Open System Settings > Privacy & Security > Accessibility and enable TidalDrift."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .encoderInitializationFailed:
            return "Failed to initialize video encoder"
        case .decoderInitializationFailed:
            return "Failed to initialize video decoder"
        case .noDisplayAvailable:
            return "No display available to share"
        case .hostNotReady:
            return "Remote Mac is not ready to share"
        }
    }
}

// MARK: - Secure Password Storage

/// Stores the LocalCast host password in the Keychain instead of UserDefaults.
/// Falls back to reading (and migrating) the legacy UserDefaults key.
enum LocalCastPasswordStore {
    private static let service = "com.tidaldrift.localcast"
    private static let account = "hostPassword"
    private static let legacyKey = "localCastHostPassword"
    
    static func save(_ password: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        
        if !password.isEmpty {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        
        // Clear the legacy UserDefaults entry
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
    
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        
        // Migrate from legacy UserDefaults
        if let legacy = UserDefaults.standard.string(forKey: legacyKey), !legacy.isEmpty {
            save(legacy)
            return legacy
        }
        return nil
    }
}
