import Foundation
import Network
import CryptoKit
import OSLog
import Combine
import CoreMedia
import CoreVideo

protocol ClientSessionDelegate: AnyObject {
    func clientSession(_ session: ClientSession, didDisconnectWithReason reason: String)
    func clientSession(_ session: ClientSession, didUpdateResolution size: CGSize)
    func clientSession(_ session: ClientSession, didReceiveAppList apps: [RemoteAppInfo])
    func clientSession(_ session: ClientSession, didReceiveStreamResponse response: StreamResponse)
}

// Default implementations for optional delegate methods
extension ClientSessionDelegate {
    func clientSession(_ session: ClientSession, didReceiveAppList apps: [RemoteAppInfo]) {}
    func clientSession(_ session: ClientSession, didReceiveStreamResponse response: StreamResponse) {}
}

    /// Connection phase for diagnostics
    enum ConnectionPhase: String {
        case resolving = "Resolving host..."
        case connecting = "Connecting..."
        case authenticating = "Authenticating..."
        case waitingForVideo = "Connected — waiting for video..."
        case streaming = "Streaming"
        case noRoute = "Cannot reach host — check that both Macs are on the same network"
        case firewallBlocked = "No response from host — check Firewall settings on the host Mac (System Settings → Network → Firewall)"
        case videoTimeout = "Connected but no video — host may not have Screen Recording permission"
        case disconnected = "Disconnected"
        case authFailed = "Authentication failed — wrong password"
    }
    
class ClientSession: ObservableObject, UDPTransportDelegate, VideoDecoderDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ClientSession")
    
    private let transport = UDPTransport()
    private let decoder = VideoDecoder()
    var renderer: MetalRenderer?
    weak var delegate: ClientSessionDelegate?
    
    private var remoteResolution: CGSize?
    
    @Published var stats: LocalCastStats?
    @Published var isConnected = false
    @Published var connectionStatus: String = "Connecting..."
    @Published var connectionPhase: ConnectionPhase = .connecting
    @Published var remoteApps: [RemoteAppInfo] = []
    @Published var isLoadingApps = false
    
    /// When true, mouse/keyboard events in the viewer are forwarded to the host
    /// and consumed locally. When false, the viewer is view-only.
    @Published var inputCaptureEnabled: Bool = true
    
    /// Set by the viewer's SwiftUI layer when an overlay panel (app picker,
    /// quality controls) is open. Event monitors pass through events to SwiftUI
    /// instead of forwarding them to the remote host.
    @Published var isOverlayActive: Bool = false
    
    /// Human-readable name of the current streaming target.
    @Published var streamingTargetName: String = "Full Display"
    
    private let device: DiscoveredDevice
    private var hostEndpoint: NWEndpoint?
    private var heartbeatTimer: Timer?
    private var lastHeartbeatResponse: Date?
    private var frameCount: Int = 0
    private var lastStatsUpdate: Date = Date()
    private var connectionStartTime: Date?
    private var diagnosticTimer: Timer?
    private var heartbeatsSent: Int = 0
    private var heartbeatsReceived: Int = 0
    
    /// Timeout for app list request; cancelled when response received.
    private var appListTimeoutWorkItem: DispatchWorkItem?
    
    /// True after an app list request timed out (control channel unreachable or host not responding).
    @Published var appListLoadFailed: Bool = false
    
    /// True when timeout likely indicates host-side auth is required (not a blocked port).
    @Published var appListAuthRequiredHint: Bool = false
    
    /// True when we received at least one app list response (even if empty). Lets UI distinguish "port blocked" from "host sent 0 apps".
    @Published var appListResponseReceived: Bool = false
    
    // MARK: - Auth
    
    /// Password for authentication. Nil = no auth required.
    private var password: String?
    
    /// Our 32-byte nonce used during the auth handshake.
    private var clientNonce: Data?
    
    /// Whether we're currently waiting for auth to complete.
    @Published var isAuthenticating = false
    
    /// Auth error message, if any.
    @Published var authError: String?
    
    init(device: DiscoveredDevice) {
        self.device = device
        transport.delegate = self
        decoder.delegate = self
    }
    
    func connect(password: String? = nil) async throws {
        self.password = password
        connectionStartTime = Date()
        
        logger.info("Connecting to LocalCast host '\(self.device.name)'...")
        await MainActor.run {
            self.connectionPhase = .resolving
            self.connectionStatus = "Resolving \(self.device.name)..."
        }
        
        // Use ConnectionResolver to get the best address (hostname-first strategy)
        // This handles stale IPs and DHCP changes automatically
        let resolvedAddress: String
        do {
            let resolved = try await ConnectionResolver.shared.resolve(
                device: device,
                strategy: .hostnameFirst,
                timeout: 8.0
            )
            resolvedAddress = resolved.address
            logger.info("LocalCast: Resolved to \(resolved.address) via \(resolved.method.rawValue)")
        } catch {
            // Fall back to cached IP if resolution fails
            resolvedAddress = self.device.ipAddress
            logger.warning("LocalCast: Resolution failed, using cached IP: \(self.device.ipAddress)")
        }
        
        await MainActor.run {
            self.connectionPhase = .connecting
            self.connectionStatus = "Connecting to \(self.device.name)..."
        }
        
        // Store the host endpoint with resolved address (port from config so it can be changed if blocked)
        let port = NWEndpoint.Port(rawValue: LocalCastConfiguration.hostPort)!
        hostEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedAddress), port: port)
        logger.info("LocalCast: Host endpoint set to \(resolvedAddress):\(LocalCastConfiguration.hostPort)")
        
        // NOTE: We do NOT start a listener on the client side.
        // Video frames arrive on the OUTGOING connection we create when sending
        // heartbeats. Starting an unnecessary listener could trigger macOS firewall
        // prompts on the client machine and adds complexity.
        
        if let password = password, !password.isEmpty {
            // Auth required — start the handshake instead of heartbeat
            await MainActor.run {
                self.isAuthenticating = true
                self.connectionPhase = .authenticating
                self.connectionStatus = "Authenticating..."
            }
            sendAuthRequest()
        } else {
            // No auth — go straight to heartbeat + keyframes
            startPostAuthFlow()
        }
        
        // Start diagnostic timer to detect connection issues
        DispatchQueue.main.async { [weak self] in
            self?.startDiagnosticTimer()
        }
    }
    
    /// Begin the normal post-auth flow: heartbeat + keyframe requests.
    private func startPostAuthFlow() {
        DispatchQueue.main.async { [weak self] in
            self?.startHeartbeat()
        }
        
        // Request keyframes aggressively to ensure host receives one and the
        // initial keyframe (with SPS/PPS) arrives at the client intact.
        // Stagger requests to survive transient packet loss.
        for delay in [0.1, 0.5, 1.0, 2.0, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isConnected else { return }
                self.requestKeyFrame()
            }
        }
    }
    
    /// Monitor connection progress and provide diagnostics.
    private static let maxDiagnosticDuration: TimeInterval = 60
    
    @MainActor
    private func startDiagnosticTimer() {
        diagnosticTimer?.invalidate()
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let startTime = self.connectionStartTime else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            
            if self.isConnected || elapsed > Self.maxDiagnosticDuration {
                self.diagnosticTimer?.invalidate()
                self.diagnosticTimer = nil
                return
            }
            
            if self.heartbeatsReceived == 0 {
                if elapsed > 6.0 {
                    self.connectionPhase = .firewallBlocked
                    self.connectionStatus = ConnectionPhase.firewallBlocked.rawValue
                    self.logger.warning("⚠️ No heartbeat responses after \(Int(elapsed))s — likely firewall issue on host")
                }
            } else {
                if elapsed > 10.0 {
                    self.connectionPhase = .videoTimeout
                    self.connectionStatus = ConnectionPhase.videoTimeout.rawValue
                    self.logger.warning("⚠️ Heartbeats OK but no video after \(Int(elapsed))s")
                    self.requestKeyFrame()
                }
            }
        }
    }
    
    // MARK: - Auth Handshake (Client Side)
    
    /// Step 1: generate clientNonce and send authRequest.
    private func sendAuthRequest() {
        guard let endpoint = hostEndpoint else { return }
        
        let nonce = SessionCrypto.generateNonce()
        self.clientNonce = nonce
        
        let packet = LocalCastPacket(
            type: .authRequest,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: nonce
        )
        transport.send(packet: packet, to: endpoint)
        logger.info("🔐 Sent authRequest with 32-byte nonce")
    }
    
    /// Step 2: handle authChallenge from host.
    private func handleAuthChallenge(payload: Data) {
        guard payload.count > 32 else {
            logger.warning("🔐 authChallenge too short (\(payload.count) bytes)")
            return
        }
        guard let password = password, let clientNonce = clientNonce else {
            logger.warning("🔐 authChallenge received but no password or nonce stored")
            return
        }
        
        // Extract hostNonce (first 32 bytes) and encrypted session key (rest)
        let hostNonce = payload.prefix(32)
        let encryptedSessionKey = Data(payload.dropFirst(32))
        
        // Derive pairingKey from password + nonces
        let pairingKey = SessionCrypto.derivePairingKey(password: password, clientNonce: clientNonce, hostNonce: Data(hostNonce))
        
        // Decrypt the session key
        guard let sessionKeyData = SessionCrypto.decrypt(encryptedSessionKey, using: pairingKey) else {
            logger.warning("🔐 Failed to decrypt session key — wrong password?")
            DispatchQueue.main.async { [weak self] in
                self?.authError = "Authentication failed — wrong password"
                self?.isAuthenticating = false
                self?.connectionStatus = "Auth failed"
            }
            return
        }
        
        let sessionKey = SessionCrypto.importKey(sessionKeyData)
        
        // Send proof: encrypt "AUTH-OK" with the session key
        guard let proof = SessionCrypto.encrypt(Data("AUTH-OK".utf8), using: sessionKey) else {
            logger.error("🔐 Failed to create auth proof")
            return
        }
        
        // Store the session key temporarily (we'll set it on transport after authSuccess)
        self.pendingSessionKey = sessionKey
        
        guard let endpoint = hostEndpoint else { return }
        let packet = LocalCastPacket(
            type: .authComplete,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: proof
        )
        transport.send(packet: packet, to: endpoint)
        logger.info("🔐 Sent authComplete proof")
    }
    
    /// Temporary storage for session key between authChallenge and authSuccess.
    private var pendingSessionKey: SymmetricKey?
    
    /// Step 3: handle authSuccess from host — enable encryption and start streaming.
    private func handleAuthSuccess(payload: Data) {
        guard let sessionKey = pendingSessionKey else {
            logger.warning("🔐 authSuccess received but no pending session key")
            return
        }
        
        // Enable encryption on the transport
        transport.sessionKey = sessionKey
        pendingSessionKey = nil
        
        logger.info("🔐 ✅ Authenticated — encryption enabled")
        
        DispatchQueue.main.async { [weak self] in
            self?.isAuthenticating = false
            self?.authError = nil
            self?.connectionStatus = "Authenticated"
        }
        
        // Start the normal post-auth flow
        startPostAuthFlow()
    }
    
    deinit {
        heartbeatTimer?.invalidate()
        diagnosticTimer?.invalidate()
        transport.stopListening()
        decoder.invalidate()
    }
    
    func disconnect() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
        transport.stopListening()
        decoder.invalidate()
        isConnected = false
        connectionPhase = .disconnected
        connectionStatus = "Disconnected"
        logger.info("Disconnected from LocalCast host")
    }
    
    private var inputSendCount = 0
    
    func sendInput(_ input: InputInjector.RemoteInput) {
        guard let endpoint = hostEndpoint else {
            print("[INPUT-DIAG] ❌ SEND BLOCKED: no host endpoint set!")
            return
        }
        
        inputSendCount += 1
        
        // Log ALL mouse clicks/keys, and moves periodically
        let shouldLog: Bool
        switch input {
        case .mouseDown, .mouseUp, .keyDown, .keyUp:
            shouldLog = true
        default:
            shouldLog = inputSendCount <= 5 || inputSendCount % 100 == 0
        }
        
        if shouldLog {
            print("[INPUT-DIAG] 📤 SENDING input #\(self.inputSendCount) → \(endpoint)")
            print("[INPUT-DIAG]    \(String(describing: input))")
        }
        
        let payload = input.serialize()
        let packet = LocalCastPacket(
            type: .inputEvent,
            sequenceNumber: UInt32(inputSendCount),
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: payload
        )
        
        if shouldLog {
            print("[INPUT-DIAG]    payload: \(payload.count) bytes, seq: \(inputSendCount)")
        }
        
        transport.send(packet: packet, to: endpoint)
    }
    
    /// Ask the host to resize the streamed window to match the viewer dimensions.
    func sendWindowResize(width: Double, height: Double) {
        guard let endpoint = hostEndpoint else { return }
        
        var data = Data()
        var w = width.bitPattern.bigEndian
        var h = height.bitPattern.bigEndian
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { data.append(contentsOf: $0) }
        
        let packet = LocalCastPacket(
            type: .windowResize,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: data
        )
        transport.send(packet: packet, to: endpoint)
        logger.info("📐 Sent window resize request: \(width)x\(height)")
    }
    
    func requestKeyFrame() {
        guard let endpoint = hostEndpoint else { return }
        let packet = LocalCastPacket(
            type: .keyframeRequest,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data()
        )
        transport.send(packet: packet, to: endpoint)
        logger.info("Requested keyframe from host")
    }
    
    // MARK: - Remote App Streaming
    
    private static let appListTimeoutSeconds: TimeInterval = 8
    
    /// Request list of available apps from the host. If no response within timeout, clears loading and sets appListLoadFailed.
    func requestAppList() {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot request app list - no host endpoint")
            return
        }
        
        appListTimeoutWorkItem?.cancel()
        appListLoadFailed = false
        appListAuthRequiredHint = false
        // appListResponseReceived stays true so we can show "host sent 0 apps" vs "no response" until next request
        
        print("📋 ClientSession: Requesting app list from host...")
        
        DispatchQueue.main.async { [weak self] in
            self?.isLoadingApps = true
        }
        
        let packet = LocalCastPacket(
            type: .appListRequest,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data()
        )
        transport.send(packet: packet, to: endpoint)
        
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isLoadingApps {
                    self.isLoadingApps = false
                    let hasPassword = !(self.password?.isEmpty ?? true)
                    let localCastAdvertised = self.device.supportsLocalCast
                    let likelyAuthRequired =
                        (self.device.localCastAuthRequired == true) ||
                        (localCastAdvertised && !hasPassword && self.heartbeatsReceived == 0)
                    self.appListAuthRequiredHint = likelyAuthRequired
                    self.appListLoadFailed = !likelyAuthRequired
                    if likelyAuthRequired {
                        self.logger.warning("App list request timed out — host likely requires LocalCast password")
                    } else {
                        self.logger.warning("App list request timed out — host may not have LocalCast on or port \(LocalCastConfiguration.hostPort) may be blocked")
                    }
                }
            }
        }
        appListTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appListTimeoutSeconds, execute: work)
    }
    
    /// Request to stream a specific window
    func requestStreamWindow(windowID: UInt32, windowTitle: String) {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot request stream - no host endpoint")
            return
        }
        
        print("🎬 ClientSession: Requesting window stream: '\(windowTitle)' (ID: \(windowID))")
        streamingTargetName = windowTitle
        
        let request = StreamRequest(
            type: .window,
            processID: nil,
            windowID: windowID,
            appName: windowTitle
        )
        
        sendStreamRequest(request, to: endpoint)
    }
    
    /// Request to stream a specific app (all its windows)
    func requestStreamApp(processID: Int32, appName: String) {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot request stream - no host endpoint")
            return
        }
        
        print("🎬 ClientSession: Requesting app stream: '\(appName)' (PID: \(processID))")
        streamingTargetName = appName
        
        let request = StreamRequest(
            type: .app,
            processID: processID,
            windowID: nil,
            appName: appName
        )
        
        sendStreamRequest(request, to: endpoint)
    }
    
    /// Request to stream the full display
    func requestStreamFullDisplay() {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot request stream - no host endpoint")
            return
        }
        
        print("🎬 ClientSession: Requesting full display stream")
        streamingTargetName = "Full Display"
        
        let request = StreamRequest(
            type: .fullDisplay,
            processID: nil,
            windowID: nil,
            appName: "Full Display"
        )
        
        sendStreamRequest(request, to: endpoint)
    }
    
    /// Ask the host to bring a specific app to the foreground (without switching capture).
    /// Used in System Screen Share mode so the VNC view shows the desired app.
    func requestFocusApp(processID: pid_t, appName: String) {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot focus app - no host endpoint")
            return
        }
        
        struct FocusRequest: Encodable {
            let processID: pid_t
            let appName: String?
        }
        
        do {
            let payload = try JSONEncoder().encode(FocusRequest(processID: processID, appName: appName))
            let packet = LocalCastPacket(
                type: .focusAppRequest,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )
            transport.send(packet: packet, to: endpoint)
            print("🎯 ClientSession: Sent focus request for '\(appName)' (PID \(processID))")
        } catch {
            print("❌ ClientSession: Failed to encode focus request: \(error)")
        }
    }
    
    // MARK: - App Isolation (VNC single-app mode)
    
    /// Ask the host to hide all apps except one, so VNC shows a single-app view.
    func requestIsolateApp(processID: pid_t, appName: String) {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot isolate app - no host endpoint")
            return
        }
        
        struct IsolateRequest: Encodable {
            let processID: pid_t
            let appName: String?
        }
        
        do {
            let payload = try JSONEncoder().encode(IsolateRequest(processID: processID, appName: appName))
            let packet = LocalCastPacket(
                type: .isolateAppRequest,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )
            transport.send(packet: packet, to: endpoint)
            print("🔒 ClientSession: Sent isolate request for '\(appName)' (PID \(processID))")
        } catch {
            print("❌ ClientSession: Failed to encode isolate request: \(error)")
        }
    }
    
    /// Ask the host to unhide all apps that were hidden by a previous isolate request.
    func requestRestoreApps() {
        guard let endpoint = hostEndpoint else {
            print("❌ ClientSession: Cannot restore apps - no host endpoint")
            return
        }
        
        let packet = LocalCastPacket(
            type: .restoreAppsRequest,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data()
        )
        transport.send(packet: packet, to: endpoint)
        print("🔓 ClientSession: Sent restore apps request")
    }
    
    /// Send streaming quality tuning to the host so it can adjust encoder/capture.
    func sendQualityUpdate(_ tuning: StreamingTuning) {
        guard let endpoint = hostEndpoint else { return }
        do {
            let payload = try JSONEncoder().encode(tuning.toPayload())
            let packet = LocalCastPacket(
                type: .qualityUpdate,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )
            transport.send(packet: packet, to: endpoint)
        } catch {
            print("❌ ClientSession: Failed to encode quality update: \(error)")
        }
    }
    
    private func sendStreamRequest(_ request: StreamRequest, to endpoint: NWEndpoint) {
        do {
            let payload = try JSONEncoder().encode(request)
            print("🎬 ClientSession: Sending stream request packet")
            print("   Type: \(request.type)")
            print("   ProcessID: \(request.processID ?? -1)")
            print("   WindowID: \(request.windowID ?? 0)")
            print("   AppName: \(request.appName ?? "nil")")
            print("   Payload size: \(payload.count) bytes")
            print("   Endpoint: \(endpoint)")
            
            let packet = LocalCastPacket(
                type: .streamAppRequest,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )
            transport.send(packet: packet, to: endpoint)
            print("🎬 ClientSession: Stream request packet sent ✓")
        } catch {
            print("❌ ClientSession: Failed to encode stream request: \(error)")
        }
    }
    
    @MainActor
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
        // Send first heartbeat immediately
        sendHeartbeat()
    }
    
    private func sendHeartbeat() {
        guard let endpoint = hostEndpoint else { return }
        heartbeatsSent += 1
        let heartbeat = LocalCastPacket(
            type: .heartbeat,
            sequenceNumber: UInt32(heartbeatsSent),
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data()
        )
        transport.send(packet: heartbeat, to: endpoint)
    }
    
    // MARK: - UDPTransportDelegate
    
    func udpTransport(_ transport: UDPTransport, didReceivePacket packet: LocalCastPacket, from endpoint: NWEndpoint) {
        switch packet.type {
        case .videoFrame:
            frameCount += 1
            if frameCount == 1 || frameCount % 60 == 0 {
                print("📦 ClientSession: Received video frame #\(frameCount), size: \(packet.payload.count) bytes")
            }
            decoder.decode(packet.payload)
            
            // Update connected state on first frame
            if !isConnected {
                DispatchQueue.main.async { [weak self] in
                    self?.isConnected = true
                    self?.connectionPhase = .streaming
                    self?.connectionStatus = "Streaming"
                    self?.logger.info("LocalCast: First video frame received - connected!")
                }
            }
            
            // Update stats every second
            let now = Date()
            if now.timeIntervalSince(lastStatsUpdate) >= 1.0 {
                let fps = frameCount
                frameCount = 0
                lastStatsUpdate = now
                
                DispatchQueue.main.async { [weak self] in
                    self?.stats = LocalCastStats(
                        latencyMs: 0,
                        fps: fps,
                        bitrateMbps: 0
                    )
                }
            }
            
        case .heartbeat:
            // Pong received - calculate latency
            lastHeartbeatResponse = Date()
            heartbeatsReceived += 1
            if !isConnected {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.connectionPhase == .connecting || self.connectionPhase == .firewallBlocked {
                        self.connectionPhase = .waitingForVideo
                        self.connectionStatus = ConnectionPhase.waitingForVideo.rawValue
                        self.logger.info("✅ Heartbeat response received — UDP path is open, waiting for video")
                    }
                }
            }
            
        case .stats:
            // Update UI stats from host
            break
            
        case .appListResponse:
            // Host sent us a list of available apps
            print("📋 ClientSession: Received app list response (\(packet.payload.count) bytes)")
            handleAppListResponse(packet.payload)
            
        case .streamAppResponse:
            // Host confirmed stream started (or failed)
            print("🎬 ClientSession: Received stream response")
            handleStreamResponse(packet.payload)
            
        case .authChallenge:
            handleAuthChallenge(payload: packet.payload)
            
        case .authSuccess:
            handleAuthSuccess(payload: packet.payload)
            
        default:
            print("❓ ClientSession: Received unknown packet type: \(packet.type)")
        }
    }
    
    private func handleAppListResponse(_ payload: Data) {
        appListTimeoutWorkItem?.cancel()
        appListTimeoutWorkItem = nil
        
        guard payload.count < 512_000 else {
            print("❌ ClientSession: App list payload too large (\(payload.count) bytes), ignoring")
            DispatchQueue.main.async { [weak self] in
                self?.isLoadingApps = false
            }
            return
        }
        do {
            let apps = try JSONDecoder().decode([RemoteAppInfo].self, from: payload)
            print("📋 ClientSession: Decoded \(apps.count) remote apps")
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.remoteApps = apps
                self.isLoadingApps = false
                self.appListLoadFailed = false
                self.appListAuthRequiredHint = false
                self.appListResponseReceived = true
                self.delegate?.clientSession(self, didReceiveAppList: apps)
            }
        } catch {
            print("❌ ClientSession: Failed to decode app list: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.isLoadingApps = false
                self?.appListAuthRequiredHint = false
                self?.appListResponseReceived = true
            }
        }
    }
    
    private func handleStreamResponse(_ payload: Data) {
        do {
            let response = try JSONDecoder().decode(StreamResponse.self, from: payload)
            print("🎬 ClientSession: Stream response - success: \(response.success), target: \(response.streamingTarget ?? "none")")
            
            if response.success {
                // Reset decoder state so it picks up the new SPS/PPS from the switched stream.
                // Without this, stale parameter sets can cause decode failures or green frames.
                print("🎬 ClientSession: Resetting decoder for new stream")
                decoder.invalidate()
                
                // Request a keyframe to ensure we get fresh SPS/PPS + IDR
                requestKeyFrame()
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.clientSession(self, didReceiveStreamResponse: response)
                
                if response.success {
                    self.streamingTargetName = response.streamingTarget ?? "Full Display"
                    self.connectionStatus = "Streaming: \(self.streamingTargetName)"
                }
            }
        } catch {
            print("❌ ClientSession: Failed to decode stream response: \(error)")
        }
    }
    
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection) {
        // Not used on client side
    }
    
    // MARK: - VideoDecoderDelegate
    
    func videoDecoder(_ decoder: VideoDecoder, didDecode imageBuffer: CVImageBuffer) {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let size = CGSize(width: width, height: height)
        
        if remoteResolution == nil || remoteResolution != size {
            remoteResolution = size
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.clientSession(self, didUpdateResolution: size)
            }
        }
        
        // IMPORTANT: Update renderer synchronously (or at least within the same callback scope)
        // to prevent VideoToolbox from recycling the buffer before we create the Metal texture.
        // The renderer's update method creates a Metal texture which retains the buffer contents.
        self.renderer?.update(with: imageBuffer)
    }
}

