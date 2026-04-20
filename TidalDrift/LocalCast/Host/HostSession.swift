import Foundation
import CoreMedia
import CryptoKit
import OSLog
import Network
import ScreenCaptureKit

/// Capture target for hosting.
/// In the TidalCast architecture, full-desktop sharing uses VNC (Tier 1);
/// this enum drives Tier 2 (app/window streaming via ScreenCaptureKit).
enum HostCaptureTarget {
    case fullDisplay
    case window(CGWindowID, title: String)
    case app(pid_t, name: String)
}

class HostSession: ScreenCaptureManagerDelegate, VideoEncoderDelegate, UDPTransportDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "HostSession")
    
    private let captureManager = ScreenCaptureManager()
    private let encoder = VideoEncoder()
    private let inputInjector = InputInjector()
    private let transport = UDPTransport()
    
    private let configuration: LocalCastConfiguration
    private var isRunning = false
    private var sequenceNumber: UInt32 = 0
    
    // MARK: - Auth state machine
    
    private enum AuthState {
        case waitingForAuth
        case authenticated
    }
    
    private var authState: AuthState = .waitingForAuth
    
    /// The session key shared with the authenticated client (AES-256-GCM).
    private var sessionKey: SymmetricKey?
    
    /// Host password used for HKDF key derivation (never sent over the wire).
    private var hostPassword: String?
    
    /// Our 32-byte nonce used during the auth handshake.
    private var hostNonce: Data?
    
    /// Client's 32-byte nonce received in authRequest.
    private var clientNonce: Data?
    
    // MARK: - Rate limiter
    
    private var inputRateLimiter: InputRateLimiter?
    
    /// Current capture target
    private(set) var captureTarget: HostCaptureTarget = .fullDisplay
    
    /// PID of the application being streamed (for window resize via Accessibility)
    private var targetPID: pid_t?
    
    // Store both the endpoint and the connection for proper bidirectional communication
    private var clientEndpoint: NWEndpoint?
    private var clientConnection: NWConnection?
    
    /// True when the client is on the same machine (127.0.0.1 or local IP).
    /// On loopback, input injection is skipped because CGEvent.post() moves the
    /// real cursor, which yanks it out of the viewer window creating a feedback loop.
    private var isLoopbackConnection = false
    
    deinit {
        transport.stopListening()
        encoder.invalidate()
        inputInjector.restoreApps()
    }
    
    init(configuration: LocalCastConfiguration, password: String? = nil) {
        self.configuration = configuration
        captureManager.delegate = self
        encoder.delegate = self
        transport.delegate = self
        
        // Configure auth
        if configuration.requireAuthentication, let password = password, !password.isEmpty {
            self.hostPassword = password
            self.sessionKey = SessionCrypto.generateSessionKey()
            self.authState = .waitingForAuth
            logger.info("🔐 Auth enabled — waiting for client")
        } else {
            // No auth required — go straight to authenticated
            self.authState = .authenticated
            logger.info("🔓 Auth disabled — accepting all connections")
        }
        
        // Configure rate limiter
        if configuration.inputRateLimit > 0 {
            inputRateLimiter = InputRateLimiter(maxPerSecond: configuration.inputRateLimit)
            logger.info("⏱️ Input rate limit: \(configuration.inputRateLimit) events/sec")
        }
    }
    
    /// Start hosting with full display capture (default)
    func start() async throws {
        try await start(target: .fullDisplay)
    }
    
    /// Start hosting with a specific capture target (window or app)
    func start(target: HostCaptureTarget) async throws {
        guard !isRunning else {
            logger.info("Host session already running, skipping start")
            return
        }
        
        self.captureTarget = target
        logger.info("Starting host session with target: \(String(describing: target))")
        
        // Check and log accessibility permission status (but don't prompt repeatedly)
        if inputInjector.hasAccessibilityPermission {
            logger.info("✅ Accessibility permission granted - input forwarding will work")
        } else {
            logger.warning("⚠️ Accessibility permission NOT granted - input forwarding will NOT work!")
            logger.info("💡 Go to System Settings > Privacy & Security > Accessibility and enable TidalDrift")
            // Only log the warning - don't automatically open System Settings to avoid permission loops
            // User can manually grant permission via System Settings
        }
        
        // Start UDP transport first
        do {
            try transport.startListening(port: LocalCastConfiguration.hostPort)
            logger.info("✅ UDP transport listening on port \(LocalCastConfiguration.hostPort)")
        } catch {
            logger.error("❌ Failed to start UDP transport: \(error.localizedDescription)")
            throw error
        }
        
        do {
            switch target {
            case .fullDisplay:
                try await startFullDisplayCapture()
                
            case .window(let windowID, let title):
                logger.info("🪟 Starting window capture: '\(title)' (ID: \(windowID))")
                try await startWindowCapture(windowID: windowID)
                
            case .app(let processID, let name):
                logger.info("📱 Starting app capture: '\(name)' (PID: \(processID))")
                try await startAppCapture(processID: processID)
            }
            
            // Update input injector with capture bounds for proper coordinate mapping
            updateInputBounds()
            
            logger.info("✅ Capture started")
        } catch {
            logger.error("❌ Failed to start capture: \(error.localizedDescription)")
            transport.stopListening()
            throw error
        }
        
        isRunning = true
        logger.info("✅ Host session started successfully - listening on port \(LocalCastConfiguration.hostPort)")
    }
    
    /// Update the input injector with the current capture bounds
    private func updateInputBounds() {
        inputInjector.captureBounds = captureManager.captureBounds
        
        if let bounds = captureManager.captureBounds {
            logger.info("🎯 Input bounds set to: \(NSStringFromRect(bounds))")
        } else {
            logger.info("🎯 Input bounds set to full screen")
        }
    }
    
    /// Start full display capture (original behavior)
    private func startFullDisplayCapture() async throws {
        targetPID = nil  // No window to resize in full display mode
        let displayID = CGMainDisplayID()
        logger.info("Using display ID: \(displayID)")
        
        // Get display mode for native resolution info
        let mode = CGDisplayCopyDisplayMode(displayID)
        let nativeWidth = mode?.pixelWidth ?? CGDisplayPixelsWide(displayID)
        let nativeHeight = mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
        
        // Cap resolution based on quality preset (ultra=3840, high=2560, etc.)
        let maxDimension = configuration.maxCaptureDimension
        let scale: Double
        if nativeWidth > maxDimension || nativeHeight > maxDimension {
            scale = Double(maxDimension) / Double(max(nativeWidth, nativeHeight))
        } else {
            scale = 1.0
        }
        
        // Round to even numbers (required for video encoding)
        let width = Int(Double(nativeWidth) * scale) & ~1
        let height = Int(Double(nativeHeight) * scale) & ~1
        
        logger.info("🚀 LocalCast: Capturing at \(width)x\(height) (native: \(nativeWidth)x\(nativeHeight), scale: \(String(format: "%.2f", scale)))")
        
        encoder.setup(
            width: width,
            height: height,
            codec: configuration.codec,
            bitrateMbps: configuration.bitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        logger.info("✅ Video encoder configured: \(self.configuration.codec.rawValue), \(self.configuration.bitrateMbps)Mbps, \(self.configuration.targetFrameRate)fps, quality=\(self.configuration.encoderQuality)")
        
        try await captureManager.startCapture(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: configuration.targetFrameRate
        )
    }
    
    /// Start window-specific capture
    private func startWindowCapture(windowID: CGWindowID) async throws {
        // Look up the owning PID so we can resize the window later via Accessibility
        if let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
           let info = infoList.first,
           let pid = info[kCGWindowOwnerPID as String] as? pid_t {
            targetPID = pid
            logger.info("📐 Stored target PID \(pid) for window resize")
        }
        
        // Pre-create encoder with placeholder dimensions so the very first
        // frames don't get silently dropped. The encoder auto-reconfigures
        // when it receives frames at the actual Retina capture resolution.
        encoder.setup(
            width: 1920,
            height: 1080,
            codec: configuration.codec,
            bitrateMbps: configuration.bitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        encoder.forceKeyFrame()
        
        try await captureManager.startWindowCapture(
            windowID: windowID,
            frameRate: configuration.targetFrameRate,
            maxDimension: configuration.maxCaptureDimension
        )
    }
    
    /// Start app-specific capture
    private func startAppCapture(processID: pid_t) async throws {
        targetPID = processID
        
        // Pre-create encoder with placeholder dimensions (auto-reconfigures
        // to actual Retina resolution on first frame).
        encoder.setup(
            width: 1920,
            height: 1080,
            codec: configuration.codec,
            bitrateMbps: configuration.bitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        encoder.forceKeyFrame()
        
        try await captureManager.startAppCapture(
            processID: processID,
            frameRate: configuration.targetFrameRate,
            maxDimension: configuration.maxCaptureDimension
        )
    }
    
    // MARK: - Live Quality Tuning
    
    /// Apply live streaming quality changes from a `StreamingTuning` snapshot.
    /// Updates the encoder in-place (no session recreation) and adjusts the
    /// capture frame rate via `SCStream.updateConfiguration()`.
    func updateStreamingQuality(_ tuning: StreamingTuning) {
        guard isRunning else {
            logger.info("updateStreamingQuality: session not running, skipping")
            return
        }
        
        let fps = tuning.effectiveFps
        let bitrate = tuning.effectiveBitrateMbps
        let quality = tuning.effectiveEncoderQuality
        let kfi = tuning.effectiveKeyframeInterval
        
        logger.info("Applying live quality: \(bitrate)Mbps, \(fps)fps, q=\(quality), kfi=\(kfi)s")
        
        // Update encoder properties in-place (no session teardown)
        encoder.updateLiveParameters(
            bitrateMbps: bitrate,
            fps: fps,
            quality: quality,
            keyframeIntervalSeconds: kfi
        )
        
        // Update capture frame rate
        Task {
            await captureManager.updateFrameRate(fps)
        }
    }
    
    func stop() async {
        guard isRunning else { return }
        
        await captureManager.stopCapture()
        encoder.invalidate()
        transport.stopListening()
        
        // Clear input bounds
        inputInjector.captureBounds = nil
        
        clientConnection = nil
        clientEndpoint = nil
        isRunning = false
        logger.info("Host session stopped")
    }
    
    func handleRemoteInput(_ input: InputInjector.RemoteInput) {
        inputInjector.inject(input)
    }
    
    // MARK: - ScreenCaptureManagerDelegate
    
    func screenCaptureManager(_ manager: ScreenCaptureManager, didOutput sampleBuffer: CMSampleBuffer) {
        encoder.encode(sampleBuffer)
    }
    
    func screenCaptureManager(_ manager: ScreenCaptureManager, didFailWithError error: Error) {
        logger.error("Capture failure: \(error.localizedDescription)")
    }
    
    // MARK: - VideoEncoderDelegate
    
    func videoEncoder(_ encoder: VideoEncoder, didOutput packet: Data, isKeyFrame: Bool, timestamp: CMTime) {
        // Prefer using the stored connection for reliable delivery
        guard clientConnection != nil || clientEndpoint != nil else { return }
        
        sequenceNumber += 1
        let castPacket = LocalCastPacket(
            type: .videoFrame,
            sequenceNumber: sequenceNumber,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: packet
        )
        
        // Use the connection directly if available, otherwise fall back to endpoint
        if let connection = clientConnection {
            transport.send(packet: castPacket, on: connection)
        } else if let endpoint = clientEndpoint {
            transport.send(packet: castPacket, to: endpoint)
        }
    }
    
    // MARK: - UDPTransportDelegate
    
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection) {
        // Store the connection from the client for reliable bidirectional communication
        clientConnection = connection
        clientEndpoint = endpoint
        
        // Detect loopback: check if client IP is localhost or our own IP
        isLoopbackConnection = Self.isLocalEndpoint(endpoint)
        
        let localIP = NetworkUtils.getLocalIPAddress() ?? "unknown"
        logger.info("LocalCast: Client connected from \(String(describing: endpoint)) (loopback: \(self.isLoopbackConnection))")
        print("[INPUT-DIAG] 🔌 CLIENT CONNECTED from \(endpoint)")
        print("[INPUT-DIAG]    isLoopback=\(isLoopbackConnection), localIP=\(localIP)")
        print("[INPUT-DIAG]    Accessibility=\(inputInjector.hasAccessibilityPermission)")
        if isLoopbackConnection {
            print("[INPUT-DIAG] ⚠️ LOOPBACK DETECTED — all input injection will be SKIPPED")
        }
        
        // Force an initial keyframe immediately so the client decoder can sync.
        // On cross-machine networks, large keyframes may not survive UDP fragmentation
        // on the first attempt. Send multiple keyframe requests with delays to increase
        // the probability of at least one arriving intact.
        encoder.forceKeyFrame()
        
        // Stagger additional keyframe requests
        for delay in [0.3, 0.8, 1.5, 3.0] {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.encoder.forceKeyFrame()
                self.logger.info("🔑 Sending retry keyframe at +\(delay)s")
            }
        }
    }
    
    /// Check if an endpoint is a loopback/local address
    private static func isLocalEndpoint(_ endpoint: NWEndpoint) -> Bool {
        let desc = String(describing: endpoint)
        if desc.contains("127.0.0.1") || desc.contains("::1") { return true }
        // Also check if it matches our own LAN IP
        if let localIP = NetworkUtils.getLocalIPAddress(), desc.contains(localIP) { return true }
        return false
    }
    
    private var receivedInputCount: UInt64 = 0
    
    func udpTransport(_ transport: UDPTransport, didReceivePacket packet: LocalCastPacket, from endpoint: NWEndpoint) {
        // Update client endpoint if not already set
        if clientEndpoint == nil {
            clientEndpoint = endpoint
            logger.info("LocalCast: Client connected from \(String(describing: endpoint))")
            print("🔌 HostSession: Client connected from \(endpoint)")
        }
        
        // --- Auth gate ---
        // While waiting for auth, only auth packets are allowed through.
        if authState == .waitingForAuth {
            switch packet.type {
            case .authRequest:
                handleAuthRequest(payload: packet.payload, from: endpoint)
                return
            case .authComplete:
                handleAuthComplete(payload: packet.payload, from: endpoint)
                return
            default:
                // Drop all non-auth packets until authenticated
                return
            }
        }
        
        // Post-auth: still handle authRequest for potential re-auth
        if packet.type == .authRequest {
            handleAuthRequest(payload: packet.payload, from: endpoint)
            return
        }
        if packet.type == .authComplete {
            handleAuthComplete(payload: packet.payload, from: endpoint)
            return
        }
        
        switch packet.type {
        case .inputEvent:
            receivedInputCount += 1
            
            // Rate limit check
            if let limiter = inputRateLimiter, !limiter.shouldAllow() {
                if receivedInputCount % 100 == 0 {
                    print("[INPUT-DIAG] ⚠️ RATE LIMITED: dropped input #\(receivedInputCount)")
                }
                return
            }
            
            if let input = InputInjector.RemoteInput.deserialize(packet.payload) {
                // Log clicks/keys always, moves periodically
                let isSignificant: Bool
                switch input {
                case .mouseDown, .mouseUp, .keyDown, .keyUp:
                    isSignificant = true
                default:
                    isSignificant = receivedInputCount <= 5 || receivedInputCount % 200 == 0
                }
                
                if isSignificant {
                    print("[INPUT-DIAG] 📥 RECEIVED input #\(receivedInputCount) from \(endpoint): \(input)")
                    print("[INPUT-DIAG]    isLoopback=\(isLoopbackConnection), hasAccessibility=\(inputInjector.hasAccessibilityPermission)")
                }
                
                if isLoopbackConnection {
                    if isSignificant {
                        print("[INPUT-DIAG] ⛔ BLOCKED: loopback connection — injection skipped to prevent cursor feedback")
                    }
                } else {
                    if isSignificant {
                        print("[INPUT-DIAG] ✅ INJECTING input #\(receivedInputCount)")
                    }
                    inputInjector.inject(input)
                }
            } else {
                print("[INPUT-DIAG] ❌ DESERIALIZE FAILED: input #\(receivedInputCount), payload: \(packet.payload.count) bytes, first byte: \(packet.payload.first ?? 0)")
            }
            
        case .heartbeat:
            // Respond with heartbeat (pong)
            let pong = LocalCastPacket(type: .heartbeat, sequenceNumber: 0, timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970, payload: Data())
            transport.send(packet: pong, to: endpoint)
            
        case .keyframeRequest:
            // Client requested a keyframe
            logger.info("🔑 LocalCast: Received keyframe request from client")
            print("🔑 HostSession: Received keyframe request")
            encoder.forceKeyFrame()
            
        case .appListRequest:
            // Client wants to know what apps are available to stream
            print("📋 HostSession: Received app list request from client")
            Task {
                await handleAppListRequest(replyTo: endpoint)
            }
            
        case .streamAppRequest:
            // Client wants to stream a specific app/window
            print("🎬 HostSession: Received stream request from client")
            Task {
                await handleStreamRequest(payload: packet.payload, replyTo: endpoint)
            }
            
        case .windowResize:
            handleWindowResize(payload: packet.payload)
            
        case .focusAppRequest:
            handleFocusAppRequest(payload: packet.payload)
            
        case .isolateAppRequest:
            handleIsolateAppRequest(payload: packet.payload)
            
        case .restoreAppsRequest:
            handleRestoreAppsRequest()
            
        case .qualityUpdate:
            handleQualityUpdate(payload: packet.payload)
            
        default:
            print("❓ HostSession: Received unknown packet type: \(packet.type)")
        }
    }
    
    // MARK: - App List & Stream Request Handling
    
    /// Gather available apps and send to client
    private func handleAppListRequest(replyTo endpoint: NWEndpoint) async {
        print("📋 HostSession: Gathering available apps...")
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            
            // System/background bundle ID prefixes and exact matches to exclude
            let excludedBundlePrefixes = [
                "com.apple.dock",
                "com.apple.WindowManager",
                "com.apple.controlcenter",
                "com.apple.notificationcenterui",
                "com.apple.Spotlight",
                "com.apple.SystemUIServer",
                "com.apple.loginwindow",
                "com.apple.finder.SharedFileList",
                "com.apple.universalcontrol",
                "com.apple.AirPlayUIAgent",
                "com.apple.accessibility",
                "com.apple.TextInputMenuAgent",
                "com.apple.TextInputSwitcher",
                "com.apple.CoreLocationAgent",
                "com.apple.ViewBridgeAuxiliary",
                "com.apple.BKAgentService",
                "com.apple.cloudd",
                "com.apple.inputmethod",
                "com.apple.ScreenTimeWidgetExtension"
            ]
            
            // Group windows by application -- only include on-screen windows
            var appDict: [pid_t: (app: SCRunningApplication, windows: [SCWindow])] = [:]
            
            for window in content.windows {
                guard let app = window.owningApplication else { continue }
                
                // Skip TidalDrift itself
                if app.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
                
                // Skip system/background apps
                if excludedBundlePrefixes.contains(where: { app.bundleIdentifier.hasPrefix($0) }) { continue }
                
                // Only include windows that are on-screen and reasonably sized
                guard window.isOnScreen else { continue }
                guard window.frame.width >= 100 && window.frame.height >= 50 else { continue }
                
                // Require a title (windows without titles are usually invisible/system)
                guard let title = window.title, !title.isEmpty else { continue }
                
                if appDict[app.processID] == nil {
                    appDict[app.processID] = (app: app, windows: [])
                }
                appDict[app.processID]?.windows.append(window)
            }
            
            // Convert to RemoteAppInfo -- only include apps that have at least one visible window
            var apps: [RemoteAppInfo] = []
            for (pid, data) in appDict {
                let windows = data.windows.map { window in
                    RemoteWindowInfo(
                        windowID: window.windowID,
                        title: window.title ?? "Untitled",
                        width: Int(window.frame.width),
                        height: Int(window.frame.height),
                        isOnScreen: window.isOnScreen
                    )
                }
                
                // Skip apps with no visible windows
                guard !windows.isEmpty else { continue }
                
                // Skip apps with empty names (background agents)
                guard !data.app.applicationName.isEmpty else { continue }
                
                apps.append(RemoteAppInfo(
                    processID: pid,
                    name: data.app.applicationName,
                    bundleIdentifier: data.app.bundleIdentifier,
                    windows: windows
                ))
            }
            
            // Sort by name
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            print("📋 HostSession: Found \(apps.count) streamable apps")
            
            // Encode and send
            let encoder = JSONEncoder()
            let payload = try encoder.encode(apps)
            
            let packet = LocalCastPacket(
                type: .appListResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )
            
            transport.send(packet: packet, to: endpoint)
            print("📋 HostSession: Sent app list to client (\(payload.count) bytes)")
            
        } catch {
            logger.warning("Failed to get app list: \(error.localizedDescription) — sending empty list so client can stop loading")
            print("❌ HostSession: Failed to get app list: \(error)")
            // Always send a response so the client can clear isLoadingApps (e.g. Screen Recording denied on host)
            let emptyPayload = (try? JSONEncoder().encode([RemoteAppInfo]())) ?? Data()
            let packet = LocalCastPacket(
                type: .appListResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: emptyPayload
            )
            transport.send(packet: packet, to: endpoint)
        }
    }
    
    /// Handle a request to stream a specific app/window
    private func handleStreamRequest(payload: Data, replyTo endpoint: NWEndpoint) async {
        print("🎬 HostSession: Processing stream request...")
        print("🎬 HostSession: Payload size: \(payload.count) bytes")
        
        do {
            // Cap payload size to prevent memory exhaustion from malicious packets
            guard payload.count < 64_000 else {
                throw LocalCastError.connectionFailed("Stream request payload too large (\(payload.count) bytes)")
            }
            let decoder = JSONDecoder()
            let request = try decoder.decode(StreamRequest.self, from: payload)
            
            print("🎬 HostSession: Stream request decoded:")
            print("   Type: \(request.type)")
            print("   ProcessID: \(request.processID ?? -1)")
            print("   WindowID: \(request.windowID ?? 0)")
            print("   AppName: \(request.appName ?? "nil")")
            
            // Stop any existing capture
            if isRunning {
                print("🎬 HostSession: Stopping existing capture...")
                await captureManager.stopCapture()
                encoder.invalidate()
                isRunning = false
                print("🎬 HostSession: Existing capture stopped")
            }
            
            // Start the requested capture
            print("🎬 HostSession: Starting new capture...")
            switch request.type {
            case .fullDisplay:
                print("🎬 HostSession: Starting FULL DISPLAY capture")
                try await startFullDisplayCapture()
                captureTarget = .fullDisplay
                
            case .window:
                guard let windowID = request.windowID else {
                    print("❌ HostSession: No window ID in request!")
                    throw LocalCastError.connectionFailed("No window ID provided")
                }
                let title = request.appName ?? "Window"
                print("🎬 HostSession: Starting WINDOW capture: '\(title)' (ID: \(windowID))")
                try await startWindowCapture(windowID: CGWindowID(windowID))
                captureTarget = .window(CGWindowID(windowID), title: title)
                
            case .app:
                guard let processID = request.processID else {
                    print("❌ HostSession: No process ID in request!")
                    throw LocalCastError.connectionFailed("No process ID provided")
                }
                let name = request.appName ?? "App"
                print("🎬 HostSession: Starting APP capture: '\(name)' (PID: \(processID))")
                try await startAppCapture(processID: processID)
                captureTarget = .app(processID, name: name)
            }
            
            updateInputBounds()
            isRunning = true
            
            // Force a keyframe so the client decoder can sync to the new stream.
            // The encoder was already primed with forceKeyFrame() before capture started,
            // but send another just in case frames slipped through.
            encoder.forceKeyFrame()
            print("🎬 HostSession: ✅ New capture running, keyframe forced")
            
            // Send success response
            let response = StreamResponse(
                success: true,
                message: "Streaming started",
                streamingTarget: request.appName ?? "Display"
            )
            let responsePayload = try JSONEncoder().encode(response)
            
            let packet = LocalCastPacket(
                type: .streamAppResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: responsePayload
            )
            transport.send(packet: packet, to: endpoint)
            
            print("🎬 HostSession: ✅ Started streaming '\(request.appName ?? "Display")'")
            print("🎬 HostSession: Response sent to client")
            
        } catch {
            print("❌ HostSession: Stream request failed: \(error.localizedDescription)")
            
            // Try to recover by falling back to full display capture
            print("🔄 HostSession: Recovering -- falling back to full display capture")
            do {
                try await startFullDisplayCapture()
                captureTarget = .fullDisplay
                updateInputBounds()
                isRunning = true
                encoder.forceKeyFrame()
                print("🔄 HostSession: ✅ Recovered to full display")
            } catch {
                print("❌ HostSession: Recovery also failed: \(error.localizedDescription)")
            }
            
            // Send error response to client
            let response = StreamResponse(
                success: false,
                message: error.localizedDescription,
                streamingTarget: nil
            )
            if let responsePayload = try? JSONEncoder().encode(response) {
                let packet = LocalCastPacket(
                    type: .streamAppResponse,
                    sequenceNumber: 0,
                    timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                    payload: responsePayload
                )
                transport.send(packet: packet, to: endpoint)
            }
        }
    }
    
    // MARK: - Auth Handshake (Host Side)
    
    /// Handle authRequest from client: generate hostNonce, derive pairingKey, encrypt sessionKey, reply with authChallenge.
    private func handleAuthRequest(payload: Data, from endpoint: NWEndpoint) {
        guard payload.count == 32 else {
            logger.warning("🔐 authRequest: bad nonce length (\(payload.count))")
            return
        }
        guard let password = hostPassword, let sessionKey = sessionKey else {
            logger.warning("🔐 authRequest received but no password/session key (auth disabled?)")
            return
        }
        
        // Store client nonce
        clientNonce = payload
        
        // Generate our nonce
        let hNonce = SessionCrypto.generateNonce()
        hostNonce = hNonce
        
        // Derive pairing key from password + nonces
        let pairingKey = SessionCrypto.derivePairingKey(password: password, clientNonce: payload, hostNonce: hNonce)
        
        // Encrypt the real session key with the pairing key
        let sessionKeyData = SessionCrypto.exportKey(sessionKey)
        guard let encryptedSessionKey = SessionCrypto.encrypt(sessionKeyData, using: pairingKey) else {
            logger.error("🔐 Failed to encrypt session key for authChallenge")
            return
        }
        
        // Build challenge payload: hostNonce (32) + encryptedSessionKey
        var challengePayload = Data()
        challengePayload.append(hNonce)
        challengePayload.append(encryptedSessionKey)
        
        let challenge = LocalCastPacket(
            type: .authChallenge,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: challengePayload
        )
        transport.send(packet: challenge, to: endpoint)
        logger.info("🔐 Sent authChallenge to client (\(challengePayload.count) bytes)")
    }
    
    /// Handle authComplete from client: verify proof, activate encryption, send authSuccess.
    private func handleAuthComplete(payload: Data, from endpoint: NWEndpoint) {
        guard let sessionKey = sessionKey else { return }
        
        // The client sends AES-GCM(sessionKey, "AUTH-OK") as proof it derived the correct key.
        guard let proof = SessionCrypto.decrypt(payload, using: sessionKey) else {
            logger.warning("🔐 authComplete: decryption failed — wrong PIN?")
            return
        }
        
        guard String(data: proof, encoding: .utf8) == "AUTH-OK" else {
            logger.warning("🔐 authComplete: proof mismatch")
            return
        }
        
        // Auth succeeded — enable encryption on the transport
        authState = .authenticated
        transport.sessionKey = sessionKey
        logger.info("🔐 ✅ Client authenticated — encryption enabled")
        
        // Send authSuccess (encrypted with session key now that transport has the key)
        let successPacket = LocalCastPacket(
            type: .authSuccess,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data("AUTH-SUCCESS".utf8)
        )
        transport.send(packet: successPacket, to: endpoint)
        
        // Force a keyframe so the client can start decoding
        encoder.forceKeyFrame()
    }
    
    // MARK: - Window Resize
    
    private func handleWindowResize(payload: Data) {
        guard payload.count >= 16 else { return }
        
        let width = Double(bitPattern: payload.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        let height = Double(bitPattern: payload.subdata(in: 8..<16).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        
        switch captureTarget {
        case .fullDisplay:
            // Nothing to resize in full display mode
            return
        case .window, .app:
            break
        }
        
        guard let pid = targetPID else {
            logger.warning("📐 Resize requested but no target PID stored")
            return
        }
        
        if isLoopbackConnection {
            // On loopback, resizing would fight with the user's own window.
            print("📐 HostSession: Loopback — skipping remote resize")
            return
        }
        
        logger.info("📐 Resizing remote window (PID \(pid)) to \(Int(width))x\(Int(height))")
        inputInjector.resizeWindow(pid: pid, to: CGSize(width: width, height: height))
    }
    
    // MARK: - Focus App
    
    /// Bring a remote app to the foreground. Payload is a JSON-encoded FocusRequest.
    private func handleFocusAppRequest(payload: Data) {
        struct FocusRequest: Decodable {
            let processID: pid_t
            let appName: String?
        }
        
        guard let request = try? JSONDecoder().decode(FocusRequest.self, from: payload) else {
            logger.warning("focusAppRequest: could not decode payload")
            return
        }
        
        logger.info("🎯 Focus request: '\(request.appName ?? "PID \(request.processID)")' (PID \(request.processID))")
        inputInjector.focusApp(pid: request.processID)
    }
    
    // MARK: - App Isolation (VNC single-app mode)
    
    private func handleIsolateAppRequest(payload: Data) {
        struct IsolateRequest: Decodable {
            let processID: pid_t
            let appName: String?
        }
        
        guard let request = try? JSONDecoder().decode(IsolateRequest.self, from: payload) else {
            logger.warning("isolateAppRequest: could not decode payload")
            return
        }
        
        logger.info("🔒 Isolate request: '\(request.appName ?? "PID \(request.processID)")' (PID \(request.processID))")
        inputInjector.isolateApp(pid: request.processID)
    }
    
    private func handleRestoreAppsRequest() {
        logger.info("🔓 Restore apps request")
        inputInjector.restoreApps()
    }
    
    private func handleQualityUpdate(payload: Data) {
        guard let update = try? JSONDecoder().decode(QualityUpdatePayload.self, from: payload) else {
            logger.warning("qualityUpdate: could not decode payload")
            return
        }
        let tuning = StreamingTuning()
        tuning.apply(update)
        logger.info("🎚️ Quality update from client: q=\(update.quality), fps=\(tuning.effectiveFps), bitrate=\(tuning.effectiveBitrateMbps)Mbps")
        updateStreamingQuality(tuning)
    }
    
}
