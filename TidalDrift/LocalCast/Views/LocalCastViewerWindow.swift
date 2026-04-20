import SwiftUI
import MetalKit
import Combine

class LocalCastViewerWindowController: NSWindowController, ClientSessionDelegate {
    private let device: DiscoveredDevice
    private let clientSession: ClientSession
    private var localMonitors: [Any] = []
    private var remoteResolution: CGSize = CGSize(width: 1280, height: 720)
    
    /// Called when the window is closed so the owner can release its strong reference.
    var onClose: ((LocalCastViewerWindowController) -> Void)?
    
    init(device: DiscoveredDevice, session: ClientSession) {
        print("🎮 LocalCastViewerWindowController: INIT START for \(device.name)")
        NSLog("🎮 LocalCastViewerWindowController: INIT START for %@", device.name)
        
        self.device = device
        self.clientSession = session
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(device.name) - LocalCast"
        window.isReleasedWhenClosed = false
        window.center()
        window.acceptsMouseMovedEvents = true
        
        // Set up Metal view
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false // Need this for sampling in shader
        
        // Wrap in hosting view with overlay
        let contentView = LocalCastContentView(
            mtkView: mtkView,
            session: session,
            tuning: LocalCastService.shared.streamingTuning
        )
        window.contentView = NSHostingView(rootView: contentView)
        
        super.init(window: window)
        
        window.delegate = self
        session.renderer = MetalRenderer(mtkView: mtkView)
        session.delegate = self
        
        print("🎮 LocalCastViewerWindowController: Calling setupInputCapture()...")
        NSLog("🎮 LocalCastViewerWindowController: Calling setupInputCapture()...")
        
        // Set up input capture
        setupInputCapture()
        
        print("🎮 LocalCastViewerWindowController: INIT COMPLETE ✓")
        NSLog("🎮 LocalCastViewerWindowController: INIT COMPLETE ✓")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    // MARK: - ClientSessionDelegate
    
    func clientSession(_ session: ClientSession, didDisconnectWithReason reason: String) {
        // Handle disconnect if needed
    }
    
    func clientSession(_ session: ClientSession, didUpdateResolution size: CGSize) {
        self.remoteResolution = size
        
        DispatchQueue.main.async {
            guard let window = self.window else { return }
            
            // Adjust window aspect ratio or size if needed
            // For now, let's just update the internal resolution for coordinate mapping
            print("🌊 LocalCast: Remote resolution updated to \(size.width)x\(size.height)")
            
            // If the window is still the default size, maybe resize it to fit the remote screen (scaled down if too big)
            if window.frame.width == 1280 && window.frame.height == 720 {
                let screenFrame = NSScreen.main?.visibleFrame ?? .zero
                let maxWidth = screenFrame.width * 0.8
                let maxHeight = screenFrame.height * 0.8
                
                let scale = min(maxWidth / size.width, maxHeight / size.height, 1.0)
                let newWidth = size.width * scale
                let newHeight = size.height * scale
                
                let newFrame = NSRect(
                    x: window.frame.origin.x,
                    y: window.frame.origin.y,
                    width: newWidth,
                    height: newHeight
                )
                window.setFrame(newFrame, display: true, animate: true)
            }
        }
    }
    
    private let toolbarRegionHeight: CGFloat = 55
    private let bottomBarRegionHeight: CGFloat = 32
    
    private var diagCount = 0
    
    private func setupInputCapture() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
        
        let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self = self else { return event }
            guard let window = self.window else { return event }
            
            let isOurs = event.window == window
            self.diagCount += 1
            if self.diagCount <= 20 || self.diagCount % 500 == 0 {
                NSLog("🖱️ MONITOR #%d: type=%ld ours=%d capture=%d overlay=%d",
                      self.diagCount, event.type.rawValue, isOurs ? 1 : 0,
                      self.clientSession.inputCaptureEnabled ? 1 : 0,
                      self.clientSession.isOverlayActive ? 1 : 0)
            }
            
            guard isOurs else { return event }
            guard self.clientSession.inputCaptureEnabled else { return event }
            if self.clientSession.isOverlayActive { return event }
            
            guard let contentView = window.contentView else { return event }
            let contentHeight = contentView.frame.height
            let y = event.locationInWindow.y
            
            let isInToolbar = y > (contentHeight - self.toolbarRegionHeight)
            let isInBottomBar = y < self.bottomBarRegionHeight
            if isInToolbar || isInBottomBar {
                if self.diagCount <= 20 { NSLog("🖱️ PASS-THROUGH: toolbar=%d bottomBar=%d y=%.0f h=%.0f", isInToolbar ? 1 : 0, isInBottomBar ? 1 : 0, y, contentHeight) }
                return event
            }
            
            let point = contentView.convert(event.locationInWindow, from: nil)
            self.handleMouseEvent(event, at: point)
            if self.diagCount <= 20 { NSLog("🖱️ FORWARDED to remote at (%.2f, %.2f)", point.x / contentView.frame.width, point.y / contentView.frame.height) }
            return nil
        }
        
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            guard let window = self.window else { return event }
            guard event.window == window else { return event }
            
            // Cmd+Shift+I toggles input capture
            if event.type == .keyDown,
               event.modifierFlags.contains(.command),
               event.modifierFlags.contains(.shift),
               event.keyCode == 34 {
                DispatchQueue.main.async {
                    self.clientSession.inputCaptureEnabled.toggle()
                }
                return nil
            }
            
            guard self.clientSession.inputCaptureEnabled else { return event }
            if self.clientSession.isOverlayActive { return event }
            
            self.handleKeyEvent(event)
            return nil
        }
        
        localMonitors.append(mouseMonitor as Any)
        localMonitors.append(keyMonitor as Any)
    }
    
    private func handleMouseEvent(_ event: NSEvent, at point: NSPoint) {
        guard let window = self.window, let contentView = window.contentView else { return }
        
        let contentRect = contentView.frame
        guard point.x >= 0 && point.x <= contentRect.width &&
              point.y >= 0 && point.y <= contentRect.height else { return }
        
        let relativeX = point.x / contentRect.width
        let relativeY: Double
        if contentView.isFlipped {
            relativeY = point.y / contentRect.height
        } else {
            relativeY = 1.0 - (point.y / contentRect.height)
        }
        
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            clientSession.sendInput(.mouseMove(x: relativeX, y: relativeY))
        case .leftMouseDown:
            clientSession.sendInput(.mouseDown(button: 0, x: relativeX, y: relativeY))
        case .leftMouseUp:
            clientSession.sendInput(.mouseUp(button: 0, x: relativeX, y: relativeY))
        case .rightMouseDown:
            clientSession.sendInput(.mouseDown(button: 1, x: relativeX, y: relativeY))
        case .rightMouseUp:
            clientSession.sendInput(.mouseUp(button: 1, x: relativeX, y: relativeY))
        case .scrollWheel:
            clientSession.sendInput(.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY))
        default:
            break
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.rawValue
        
        switch event.type {
        case .keyDown:
            clientSession.sendInput(.keyDown(keyCode: keyCode, modifiers: UInt64(modifiers)))
        case .keyUp:
            clientSession.sendInput(.keyUp(keyCode: keyCode, modifiers: UInt64(modifiers)))
        case .flagsChanged:
            clientSession.sendInput(.keyDown(keyCode: keyCode, modifiers: UInt64(modifiers)))
        default:
            break
        }
    }
    
    deinit {
        for monitor in localMonitors {
            NSEvent.removeMonitor(monitor)
        }
        localMonitors.removeAll()
        clientSession.disconnect()
    }
    
    override func close() {
        for monitor in localMonitors {
            NSEvent.removeMonitor(monitor)
        }
        localMonitors.removeAll()
        clientSession.disconnect()
        onClose?(self)
        onClose = nil
        super.close()
    }
    
    // MARK: - Viewer → Remote Window Resize
    
    private func sendViewerSize() {
        guard let contentView = window?.contentView else { return }
        let size = contentView.frame.size
        guard size.width > 0 && size.height > 0 else { return }
        print("📐 Viewer content resized to \(size.width)x\(size.height) — forwarding to host")
        clientSession.sendWindowResize(width: size.width, height: size.height)
    }
}

// MARK: - NSWindowDelegate (resize sync)

extension LocalCastViewerWindowController: NSWindowDelegate {
    /// Fires at the end of a drag-to-resize.
    func windowDidEndLiveResize(_ notification: Notification) {
        sendViewerSize()
    }
    
    /// Fires for non-drag resizes (double-click title bar, Stage Manager tile, etc.).
    func windowDidResize(_ notification: Notification) {
        guard let window = self.window, !window.inLiveResize else { return }
        sendViewerSize()
    }
}

struct LocalCastContentView: View {
    let mtkView: MTKView
    @ObservedObject var session: ClientSession
    @ObservedObject var tuning: StreamingTuning
    @AppStorage("showLatencyOverlay") var showOverlay = false
    @State private var toolbarExpanded = false
    @State private var showAppPicker = false
    @State private var showQualityPanel = false
    @State private var selectedRemoteApp: RemoteAppInfo?
    
    var body: some View {
        ZStack {
            MetalViewRepresentable(mtkView: mtkView)
            
            if !session.isConnected {
                connectionStatusOverlay
            }
            
            // Top edge: collapsible toolbar
            VStack(spacing: 0) {
                if toolbarExpanded {
                    HStack {
                        Button {
                            if session.remoteApps.isEmpty {
                                session.requestAppList()
                            }
                            showAppPicker.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "square.stack.3d.up")
                                Text("Apps")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        
                        CompactQualitySlider(tuning: tuning, isLive: true)
                        
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showQualityPanel.toggle()
                            }
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .help("Quality Controls")
                        
                        Button {
                            session.inputCaptureEnabled.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: session.inputCaptureEnabled ? "keyboard.fill" : "keyboard")
                                Text(session.inputCaptureEnabled ? "Control" : "View Only")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(session.inputCaptureEnabled ? .blue : .gray)
                        .help("Toggle remote input (⌘⇧I)")
                        
                        Spacer()
                        
                        if showOverlay {
                            LocalCastStatsOverlay(stats: session.stats)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toolbarExpanded.toggle()
                    }
                    if !toolbarExpanded {
                        showAppPicker = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: toolbarExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 48, height: 20)
                    .background(.white.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                
                Spacer()
            }
            .background(alignment: .top) {
                if toolbarExpanded {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(height: 48)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            
            // App picker panel
            if showAppPicker {
                RemoteAppPickerView(
                    session: session,
                    isPresented: $showAppPicker,
                    selectedApp: $selectedRemoteApp
                )
            }
            
            // Quality control panel
            if showQualityPanel {
                VStack(spacing: 0) {
                    HStack {
                        Text("Quality Controls")
                            .font(.headline)
                        Spacer()
                        Button {
                            withAnimation { showQualityPanel = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()
                    
                    Divider()
                    
                    ScrollView {
                        StreamingQualityControlView(tuning: tuning, isLive: true)
                            .padding()
                    }
                }
                .frame(idealWidth: 400, maxHeight: 500)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 20)
                .padding(40)
            }
            
            // Bottom status bar
            VStack {
                Spacer()
                bottomStatusBar
            }
        }
        .onChange(of: showAppPicker) { _ in syncOverlayState() }
        .onChange(of: showQualityPanel) { _ in syncOverlayState() }
        .onReceive(tuning.objectWillChange.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)) { _ in
            DispatchQueue.main.async {
                session.sendQualityUpdate(tuning)
            }
        }
    }
    
    private func syncOverlayState() {
        session.isOverlayActive = showAppPicker || showQualityPanel
    }
    
    @ViewBuilder
    private var bottomStatusBar: some View {
        HStack(spacing: 10) {
            Button {
                if session.remoteApps.isEmpty {
                    session.requestAppList()
                }
                showAppPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.streamingTargetName == "Full Display" ? "display" : "app.fill")
                        .font(.caption)
                    Text(session.streamingTargetName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: 1, height: 12)
            
            Button {
                session.inputCaptureEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.inputCaptureEnabled ? "keyboard.fill" : "keyboard")
                        .font(.caption)
                    Text(session.inputCaptureEnabled ? "Remote Control" : "View Only")
                        .font(.system(size: 11))
                }
                .foregroundStyle(session.inputCaptureEnabled ? .white : .white.opacity(0.5))
            }
            .buttonStyle(.plain)
            
            Text("⌘⇧I")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(.bottom, 8)
    }
}

/// View for picking which remote app to stream
struct RemoteAppPickerView: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool
    @Binding var selectedApp: RemoteAppInfo?
    @State private var expandedAppID: Int32?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Remote Apps")
                    .font(.headline)
                Spacer()
                
                Button {
                    session.requestAppList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(session.isLoadingApps)
                
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()
            
            Divider()
            
            if session.isLoadingApps {
                VStack {
                    ProgressView()
                    Text("Loading apps...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.remoteApps.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No apps available")
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        session.requestAppList()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Full display option
                        Button {
                            session.requestStreamFullDisplay()
                            isPresented = false
                        } label: {
                            HStack {
                                Image(systemName: "display")
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(.blue)
                                Text("Full Display")
                                    .fontWeight(.medium)
                                Spacer()
                                Image(systemName: "play.circle")
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.blue.opacity(0.1))
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // App list
                        ForEach(session.remoteApps, id: \.processID) { app in
                            RemoteAppRowView(
                                app: app,
                                isExpanded: expandedAppID == app.processID,
                                onTap: {
                                    withAnimation {
                                        if expandedAppID == app.processID {
                                            expandedAppID = nil
                                        } else {
                                            expandedAppID = app.processID
                                        }
                                    }
                                },
                                onFocusApp: {
                                    session.requestFocusApp(processID: app.processID, appName: app.name)
                                },
                                onStreamApp: {
                                    session.requestStreamApp(processID: app.processID, appName: app.name)
                                    isPresented = false
                                },
                                onStreamWindow: { window in
                                    session.requestStreamWindow(windowID: window.windowID, windowTitle: "\(app.name) - \(window.title)")
                                    isPresented = false
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 320, height: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .padding(40)
    }
}

struct RemoteAppRowView: View {
    let app: RemoteAppInfo
    let isExpanded: Bool
    let onTap: () -> Void
    let onFocusApp: (() -> Void)?
    let onStreamApp: () -> Void
    let onStreamWindow: (RemoteWindowInfo) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // App row
            Button(action: onTap) {
                HStack {
                    // App icon placeholder
                    Image(systemName: "app.fill")
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.secondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .fontWeight(.medium)
                        Text("\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Focus button (bring to front on host)
                    if let onFocus = onFocusApp {
                        Button {
                            onFocus()
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.borderless)
                        .help("Bring to front on remote Mac")
                    }
                    
                    // Stream whole app button
                    Button {
                        onStreamApp()
                    } label: {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Stream entire app")
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Expanded window list
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(app.windows, id: \.windowID) { window in
                        Button {
                            onStreamWindow(window)
                        } label: {
                            HStack {
                                Image(systemName: window.isOnScreen ? "macwindow" : "macwindow.badge.plus")
                                    .frame(width: 24)
                                    .foregroundStyle(window.isOnScreen ? .primary : .secondary)
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(window.title)
                                        .lineLimit(1)
                                    Text("\(window.width) × \(window.height)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "play.circle")
                                    .foregroundStyle(.green)
                            }
                            .padding(.horizontal)
                            .padding(.leading, 24)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05))
                    }
                }
            }
        }
    }
}

extension LocalCastContentView {
    @ViewBuilder
    var connectionStatusOverlay: some View {
        VStack(spacing: 16) {
            // Phase icon
            Group {
                switch session.connectionPhase {
                case .resolving, .connecting:
                    ProgressView()
                        .scaleEffect(1.5)
                case .authenticating:
                    Image(systemName: "lock.shield")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                case .waitingForVideo:
                    ProgressView()
                        .scaleEffect(1.5)
                case .firewallBlocked:
                    Image(systemName: "flame.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                case .videoTimeout:
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                case .noRoute:
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                default:
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(session.connectionPhase.rawValue)
                .font(.system(.body, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            
            // Extra guidance for firewall issues
            if session.connectionPhase == .firewallBlocked {
                VStack(spacing: 8) {
                    Text("On the host Mac, open:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("System Settings → Network → Firewall")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("Either turn off the firewall or add TidalDrift to the allowed apps list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 4)
            }
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 400)
    }
}

struct MetalViewRepresentable: NSViewRepresentable {
    let mtkView: MTKView
    
    func makeNSView(context: Context) -> MTKView {
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

struct LocalCastStatsOverlay: View {
    let stats: LocalCastStats?
    
    var body: some View {
        if let stats = stats {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(stats.latencyMs))ms")
                    .font(.system(.caption, design: .monospaced))
                Text("\(stats.fps) fps")
                    .font(.system(.caption, design: .monospaced))
                Text("\(String(format: "%.1f", stats.bitrateMbps)) Mbps")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

