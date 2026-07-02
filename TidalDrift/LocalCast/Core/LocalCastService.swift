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
    // Verification fields for the live HUD: what is actually being streamed,
    // so settings changes (resolution, codec, region-aware) are observable.
    var resolution: CGSize = .zero
    var codec: String = "—"
    var mode: String = "—"          // "Full-frame", "Region tiles", or "Mixed"
    var droppedPerSec: Int = 0
    var bufferDepth: Int = 0
    var fecRecoveredPerSec: Int = 0
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

    /// Human-readable name of what this host is currently sharing
    /// ("Entire Desktop" or an app/window name). Drives the menu-bar label.
    @Published var shareTargetName = "Entire Desktop"
    
    /// Live-adjustable streaming quality. Changes are pushed to the active
    /// host session immediately via Combine observation.
    let streamingTuning = StreamingTuning()

    weak var delegate: LocalCastServiceDelegate?
    var configuration: LocalCastConfiguration = .default

    private var hostSession: HostSession?
    private var currentHostTarget: HostCaptureTarget = .fullDisplay
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
                    self.streamingTuning.saveToDefaults()
                    self.applyTuningToHostSession()
                }
            }

        observeWake()
    }

    /// Restart hosting after system wake. Sleep kills the UDP listener and
    /// orphans the dns-sd registration while `isHosting` stays true, so a
    /// woken host looked like it was hosting but could not accept a viewer.
    /// This is what made lid-closed (Wake on Demand) connections fail even
    /// after the Mac itself woke: the client's knock woke the machine, but
    /// TidalDrift never came back up on port 5904. The peer-discovery service
    /// already re-advertises on wake; this does the same for LocalCast.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isHosting else { return }
                self.logger.info("⏰ Woke from sleep — restarting LocalCast hosting and advertisement")
                await self.restartHostingToApplySettings()
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

    /// Per-window hosting: share a single window.
    func startHostingWindow(windowID: CGWindowID, windowTitle: String) async throws {
        try await startHosting(target: .window(windowID, title: windowTitle))
    }

    /// Per-app hosting: share a single app.
    func startHostingApp(processID: pid_t, appName: String) async throws {
        try await startHosting(target: .app(processID, name: appName))
    }

    // MARK: - Host-side share target selection

    /// Apps on this Mac that can be shared (have a visible, titled window).
    /// Requires Screen Recording permission; returns [] if denied.
    func listShareableApps() async -> [RemoteAppInfo] {
        (try? await HostSession.enumerateShareableApps()) ?? []
    }

    /// Share the entire desktop. Starts hosting if not already running, otherwise
    /// retargets the live stream.
    func shareEntireDesktop() async {
        await setShareTarget(.fullDisplay, name: "Entire Desktop")
    }

    /// Share a single app. Starts hosting if not already running, otherwise
    /// retargets the live stream.
    func shareApp(processID: pid_t, appName: String) async {
        await setShareTarget(.app(processID, name: appName), name: appName)
    }

    /// Share a single window.
    func shareWindow(windowID: CGWindowID, windowTitle: String) async {
        await setShareTarget(.window(windowID, title: windowTitle), name: windowTitle)
    }

    private func setShareTarget(_ target: HostCaptureTarget, name: String) async {
        if isHosting, let session = hostSession {
            currentHostTarget = target
            await session.retarget(to: target)
            shareTargetName = name
        } else {
            do {
                try await startHosting(target: target)
                shareTargetName = name
            } catch {
                logger.error("Failed to start hosting for share target: \(error.localizedDescription)")
            }
        }
    }

    private func startHosting(target: HostCaptureTarget) async throws {
        currentHostTarget = target
        let permissions = LocalCastPermissions()

        if !(await permissions.requestScreenCaptureIfNeeded()) {
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
        
        reloadConfigurationFromDefaults()

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
        
        // Use saved live tuning if the user has tuned it; otherwise initialize
        // from the quality preset. This keeps restart-to-apply from resetting
        // the slider/overrides back to "auto".
        if !streamingTuning.loadFromDefaults() {
            streamingTuning.syncFrom(configuration)
        }
        
        let session = HostSession(configuration: configuration, password: hostPassword)
        // When the client picks a window/app, keep our restart target in sync so
        // a later resolution/codec restart keeps streaming the same target.
        session.onClientRetarget = { [weak self] newTarget, name in
            Task { @MainActor in
                guard let self else { return }
                self.currentHostTarget = newTarget
                self.shareTargetName = name
            }
        }
        try await session.start(target: target)

        advertiseLocalCast(port: LocalCastConfiguration.hostPort, authEnabled: hostPassword != nil)

        self.hostSession = session
        self.isHosting = true
        delegate?.localCastDidStartHosting()
        logger.info("Hosting started")
    }

    /// Reload every setting that affects a new capture/encoder/transport
    /// session. These values are edited via `@AppStorage` in
    /// LocalCastSettingsView; keeping this in one place prevents "settings say
    /// 1080p/H.264 but the stream is still 4K/HEVC" mismatches.
    private func reloadConfigurationFromDefaults() {
        let defaults = UserDefaults.standard

        if let presetRaw = defaults.string(forKey: "localCastQuality"),
           let preset = LocalCastConfiguration.QualityPreset(rawValue: presetRaw) {
            configuration.qualityPreset = preset
        }
        if let codecRaw = defaults.string(forKey: "localCastCodec"),
           let codec = LocalCastConfiguration.Codec(rawValue: codecRaw) {
            configuration.codec = codec
        }

        configuration.requireAuthentication = defaults.object(forKey: "localCastRequireAuth") as? Bool ?? true
        configuration.inputRateLimit = defaults.object(forKey: "localCastInputRateLimit") as? Int ?? 120
        configuration.adaptiveQuality = defaults.object(forKey: "localCastAdaptive") as? Bool ?? true
        configuration.maxDimensionOverride = defaults.object(forKey: "localCastMaxDimension") as? Int ?? 0
        configuration.regionAware = defaults.object(forKey: "localCastRegionAware") as? Bool ?? false
        configuration.forwardErrorCorrection = defaults.object(forKey: "localCastFEC") as? Bool ?? false
        configuration.captureCursor = defaults.object(forKey: "localCastCaptureCursor") as? Bool ?? false
        configuration.thermalThrottle = defaults.object(forKey: "localCastThermalThrottle") as? Bool ?? true
        if let profileRaw = defaults.string(forKey: "localCastTransportProfile"),
           let profile = LocalCastConfiguration.TransportProfile(rawValue: profileRaw) {
            configuration.transportProfile = profile
        }
    }

    /// Apply settings that can change without recreating the capture/encoder
    /// session. Codec/resolution still require restart; resilience toggles should
    /// not.
    func applyLiveResilienceSettingsFromDefaults() {
        reloadConfigurationFromDefaults()
        hostSession?.updateRuntimeConfiguration(configuration)
    }

    /// Restart the active host session with the same share target, reloading all
    /// non-live settings first (codec, resolution cap, region-aware, FEC, etc.).
    /// Live bitrate/fps tuning still flows through `StreamingTuning`.
    func restartHostingToApplySettings() async {
        guard isHosting else { return }
        let target = currentHostTarget
        let name = shareTargetName
        streamingTuning.saveToDefaults()

        // Stop synchronously before re-binding the UDP listener. The public
        // stopHosting() is intentionally fire-and-forget for UI responsiveness,
        // but a settings restart immediately starts a new listener on the same
        // port (5904). If the old listener is still closing, clients see a
        // transient "host can't be reached".
        let oldSession = hostSession
        isHosting = false
        isAuthEnabled = false
        stopAdvertisement()
        hostSession = nil
        await oldSession?.stop()
        delegate?.localCastDidStopHosting()

        do {
            try await startHosting(target: target)
            shareTargetName = name
        } catch {
            logger.error("Failed to restart hosting with updated settings: \(error.localizedDescription)")
        }
    }

    func stopHosting() {
        guard isHosting else { return }
        self.isHosting = false
        self.isAuthEnabled = false
        self.shareTargetName = "Entire Desktop"
        stopAdvertisement()

        let session = self.hostSession
        self.hostSession = nil
        Task {
            await session?.stop()
        }

        delegate?.localCastDidStopHosting()
        logger.info("Hosting stopped")
    }

    private func advertiseLocalCast(port: UInt16, authEnabled: Bool) {
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
            "auth=\(authEnabled ? "1" : "0")"
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

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
        
        // Only send a password when the host advertises LocalCast auth. Saved
        // VNC credentials are not necessarily the LocalCast host password, and
        // sending them to an auth-disabled host makes the client wait forever
        // for an auth challenge that will never arrive.
        var resolvedPassword = device.localCastAuthRequired == false ? nil : password
        if device.localCastAuthRequired == true && (resolvedPassword == nil || resolvedPassword?.isEmpty == true) {
            // Run the auth-gated keychain read off the main thread so the
            // biometric prompt does not freeze the UI. The active app is
            // activated first so the system dialog appears in front.
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            let creds = await Task.detached(priority: .userInitiated) {
                try? KeychainService.shared.getCredential(for: device)
            }.value
            if let creds {
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

    // MARK: - System Screen Share + App Control (dormant)
    //
    // The previous `connectSystemScreenShare(to:)` opened macOS Screen
    // Sharing.app AND a TidalDrift control channel for per-app enumeration.
    // That two-tier hybrid produced most of the race conditions and
    // misleading "firewall blocked" errors we saw in practice. The new
    // design keeps VNC (via ScreenShareConnectionService.connect) and the
    // Metal viewer (via connect(to:)) as two independent entry points;
    // there is no longer a combined mode.

    /// Strong references to active app control panels so their sessions/windows
    /// stay alive for the lifetime of the panel.
    private var activeControlPanels: [AppControlPanelController] = []

    /// "Best of both worlds": open macOS Screen Sharing (VNC) for the picture
    /// and a floating App Control panel over our control channel to focus /
    /// isolate a single remote app. Isolate hides the host's other apps so the
    /// Screen Sharing view shows just the chosen app.
    @discardableResult
    func openAppControl(for device: DiscoveredDevice, password: String? = nil) async throws -> AppControlPanelController {
        // Pixels come from macOS Screen Sharing.
        try? await ScreenShareConnectionService.shared.connect(to: device)

        // App control rides the LocalCast control channel (port 5904), so the
        // host needs LocalCast hosting on. Resolve auth the same way as connect.
        var resolvedPassword = device.localCastAuthRequired == false ? nil : password
        if device.localCastAuthRequired == true && (resolvedPassword?.isEmpty ?? true) {
            let creds = await Task.detached(priority: .userInitiated) {
                try? KeychainService.shared.getCredential(for: device)
            }.value
            resolvedPassword = creds?.password
        }

        let session = ClientSession(device: device)
        try await session.connect(password: resolvedPassword)

        let controller = AppControlPanelController(device: device, session: session)
        activeControlPanels.append(controller)
        controller.onClose = { [weak self] closed in
            self?.activeControlPanels.removeAll { $0 === closed }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        session.requestAppList()
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
