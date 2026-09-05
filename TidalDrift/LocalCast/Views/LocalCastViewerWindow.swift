import SwiftUI
import MetalKit
import Combine

class LocalCastViewerWindowController: NSWindowController, ClientSessionDelegate {
    private let device: DiscoveredDevice
    private let clientSession: ClientSession
    private var localMonitors: [Any] = []
    private let keyboardTap = RemoteKeyboardTap()
    private var keyboardTapActive = false
    /// Modifiers forwarded as pressed by the NSEvent fallback path and not yet
    /// forwarded as released. The monitor only sees events for this window, so
    /// a release after Cmd+Tab or after capture is toggled off never arrives;
    /// these are released explicitly at those points.
    private var fallbackHeldModifiers: Set<UInt16> = []
    private var cancellables = Set<AnyCancellable>()
    private var remoteResolution: CGSize = CGSize(width: 1280, height: 720)
    private var hasSizedToRemote = false
    private var didCleanup = false
    
    /// Called when the window is closed so the owner can release its strong reference.
    var onClose: ((LocalCastViewerWindowController) -> Void)?
    
    init(device: DiscoveredDevice, session: ClientSession) {
        lcDebug("🎮 LocalCastViewerWindowController: INIT START for \(device.name)")
        
        self.device = device
        self.clientSession = session
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.title = "\(device.name) - LocalCast"
        window.isReleasedWhenClosed = false
        window.center()
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.titlebarAppearsTransparent = true
        
        // Set up Metal view
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false // Need this for sampling in shader
        
        // Wrap in hosting view with overlay
        let contentView = LocalCastContentView(
            mtkView: mtkView,
            session: session,
            tuning: LocalCastService.shared.streamingTuning,
            overlayFrames: overlayFrameStore
        )
        window.contentView = NSHostingView(rootView: contentView)
        
        super.init(window: window)
        
        window.delegate = self
        session.renderer = MetalRenderer(mtkView: mtkView)
        session.delegate = self
        
        lcDebug("🎮 LocalCastViewerWindowController: Calling setupInputCapture()...")
        
        // Set up input capture
        setupInputCapture()
        
        lcDebug("🎮 LocalCastViewerWindowController: INIT COMPLETE ✓")
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
            lcDebug("🌊 LocalCast: Remote resolution updated to \(size.width)x\(size.height)")
            
            // Size the viewer to the remote screen once, on the first
            // resolution we learn. Keyed off a flag rather than "is the window
            // still 1280x720": with the host now rebuilding capture whenever
            // the streamed window resizes, a viewer that happened to be at the
            // default size could be resized here, forward that size to the
            // host, and get resized again by the resulting resolution change.
            if !self.hasSizedToRemote {
                self.hasSizedToRemote = true
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
    
    /// Frames of the viewer's own overlay controls, in content-view
    /// coordinates, reported by SwiftUI via preference so the mouse monitor
    /// can pass clicks through to them instead of forwarding to the host.
    private let overlayFrameStore = ViewerOverlayFrames()
    private var overlayFrames: [CGRect] { overlayFrameStore.frames }
    
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
                lcDebug("🖱️ MONITOR #\(self.diagCount): type=\(event.type.rawValue) ours=\(isOurs) capture=\(self.clientSession.inputCaptureEnabled) overlay=\(self.clientSession.isOverlayActive)")
            }
            
            guard isOurs else { return event }
            guard self.clientSession.inputCaptureEnabled else { return event }
            if self.clientSession.isOverlayActive { return event }
            
            guard let contentView = window.contentView else { return event }
            
            // Let clicks on the viewer's own controls (top chevron, bottom
            // status capsule) reach them; everything else on the surface is
            // remote input. Hit-testing the reported control frames rather
            // than fixed top/bottom bands matters in full screen, where a
            // band would swallow clicks meant for the remote menu bar and Dock.
            let pointInContent = contentView.convert(event.locationInWindow, from: nil)
            if event.type != .scrollWheel,
               self.overlayFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(pointInContent) }) {
                if self.diagCount <= 20 { lcDebug("🖱️ PASS-THROUGH: viewer control at \(NSStringFromPoint(pointInContent))") }
                return event
            }
            
            // Normalize against the Metal view's own surface, which is where the
            // video is actually drawn. With a full-size content view + transparent
            // titlebar, SwiftUI insets the Metal view by the top safe area in
            // windowed mode, so mapping against the hosting view left a vertical
            // offset that disappeared in full screen. Fall back to the hosting
            // view only if the renderer is not available yet.
            let point: NSPoint
            let videoRect: CGRect
            let mapFlipped: Bool
            if let renderer = self.clientSession.renderer, renderer.viewSize.width > 0 {
                point = renderer.viewPoint(fromWindowPoint: event.locationInWindow)
                videoRect = renderer.videoRect
                mapFlipped = renderer.isViewFlipped
            } else {
                point = contentView.convert(event.locationInWindow, from: nil)
                videoRect = MetalRenderer.aspectFitRect(
                    source: self.remoteResolution, in: contentView.frame.size)
                mapFlipped = contentView.isFlipped
            }
            self.handleMouseEvent(
                event,
                at: point,
                videoRect: videoRect,
                contentViewIsFlipped: mapFlipped
            )
            if self.diagCount <= 20 { lcDebug("🖱️ FORWARDED to remote in video rect \(NSStringFromRect(videoRect)) flipped=\(mapFlipped)") }
            return nil
        }
        
        localMonitors.append(mouseMonitor as Any)
        setupKeyboardCapture()
    }

    /// Keyboard: prefer a CGEventTap so system shortcuts (Cmd+Space, Cmd+Tab,
    /// Mission Control, screenshot combos) forward to the host instead of being
    /// swallowed locally. Falls back to an NSEvent monitor (ordinary keys only)
    /// if the tap can't be created (e.g. Accessibility not granted).
    private func setupKeyboardCapture() {
        keyboardTap.shouldCapture = { [weak self] in
            guard let self, let window = self.window else { return false }
            return window.isKeyWindow
                && self.clientSession.inputCaptureEnabled
                && !self.clientSession.isOverlayActive
        }
        keyboardTap.onToggleCapture = { [weak self] in
            DispatchQueue.main.async { self?.clientSession.inputCaptureEnabled.toggle() }
        }
        keyboardTap.onKey = { [weak self] keyCode, modifiers, down in
            guard let self else { return }
            if down {
                self.clientSession.sendInput(.keyDown(keyCode: keyCode, modifiers: modifiers))
            } else {
                self.clientSession.sendInput(.keyUp(keyCode: keyCode, modifiers: modifiers))
            }
        }
        keyboardTapActive = keyboardTap.start()

        // Capture toggled off (hotkey or HUD button): whatever is held on the
        // host would otherwise stay latched until the session ends.
        clientSession.$inputCaptureEnabled
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.releaseHeldModifiers() }
            .store(in: &cancellables)

        guard !keyboardTapActive else { return }

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
        localMonitors.append(keyMonitor as Any)
    }
    
    private func handleMouseEvent(
        _ event: NSEvent,
        at point: NSPoint,
        videoRect: CGRect,
        contentViewIsFlipped: Bool
    ) {
        guard videoRect.width > 0, videoRect.height > 0 else { return }

        // Scroll carries deltas, not a position; forward it regardless of where
        // the cursor is (even over the letterbox bars). The precise flag rides
        // along so the host injects pixels for trackpads and lines for a
        // physical wheel; without it a wheel notch was injected as ~1 pixel.
        if event.type == .scrollWheel {
            clientSession.sendInput(.scroll(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas
            ))
            return
        }

        let rawX = (point.x - videoRect.minX) / videoRect.width
        let yFromBottom = (point.y - videoRect.minY) / videoRect.height
        // The remote expects top-left origin (y down). NSHostingView is usually
        // flipped, so its converted point is already top-origin. When it is not
        // flipped, convert from AppKit's bottom-origin coordinates.
        let rawY = contentViewIsFlipped ? yFromBottom : (1.0 - yFromBottom)
        // Clamp into [0,1] rather than dropping clicks in the letterbox bars, so
        // a mouse-up that lands on a bar can't leave a stuck button on the host.
        let relativeX = min(max(rawX, 0), 1)
        let relativeY = min(max(rawY, 0), 1)

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
        default:
            break
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = event.keyCode
        // Keep only the standard, device-independent modifier bits (shift,
        // control, option, command, caps lock). Their raw values line up with
        // CGEventFlags on the host; passing the full rawValue can include
        // device-dependent low bits that set spurious flags.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        
        switch event.type {
        case .keyDown:
            clientSession.sendInput(.keyDown(keyCode: keyCode, modifiers: UInt64(modifiers)))
        case .keyUp:
            clientSession.sendInput(.keyUp(keyCode: keyCode, modifiers: UInt64(modifiers)))
        case .flagsChanged:
            // One event type covers both press and release, so the direction
            // comes from whether this key's own bit survives in the new flag
            // set. Sending a key-down for the release latched the modifier on
            // the host and made the keyboard look dead.
            let flags = CGEventFlags(rawValue: UInt64(modifiers))
            guard let isDown = ModifierKey.isPress(keyCode: keyCode, flags: flags) else { break }
            if isDown {
                fallbackHeldModifiers.insert(keyCode)
                clientSession.sendInput(.keyDown(keyCode: keyCode, modifiers: UInt64(modifiers)))
            } else {
                fallbackHeldModifiers.remove(keyCode)
                clientSession.sendInput(.keyUp(keyCode: keyCode, modifiers: UInt64(modifiers)))
            }
        default:
            break
        }
    }

    /// Send a release for every modifier either keyboard path reported as
    /// pressed. Called when capture disengages for any reason.
    private func releaseHeldModifiers() {
        keyboardTap.releaseHeldModifiers()
        let stuck = fallbackHeldModifiers
        fallbackHeldModifiers.removeAll()
        for keyCode in stuck {
            clientSession.sendInput(.keyUp(keyCode: keyCode, modifiers: 0))
        }
    }
    
    deinit {
        cleanup()
    }

    private func cleanup() {
        guard !didCleanup else { return }
        didCleanup = true

        cancellables.removeAll()
        releaseHeldModifiers()
        keyboardTap.stop()
        keyboardTapActive = false
        pendingViewerSizeSend?.cancel()
        pendingViewerSizeSend = nil
        for monitor in localMonitors {
            NSEvent.removeMonitor(monitor)
        }
        localMonitors.removeAll()
        clientSession.disconnect()
        // The renderer owns the MTKView, its CAMetalLayer, the texture cache
        // and the last decoded frames; the session outlives this window.
        clientSession.renderer = nil
        onClose?(self)
        onClose = nil
    }

    override func close() {
        cleanup()
        super.close()
    }
    
    // MARK: - Viewer → Remote Window Resize
    
    /// Coalesces the resize notifications a full-screen transition or a Stage
    /// Manager tile fires in quick succession. Each one that reaches the host
    /// resizes the remote window and rebuilds its capture, so sending the
    /// intermediate sizes costs a keyframe apiece for geometry that is already
    /// stale by the time it arrives.
    private var pendingViewerSizeSend: DispatchWorkItem?

    private func sendViewerSize() {
        pendingViewerSizeSend?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let contentView = self.window?.contentView else { return }
            let size = contentView.frame.size
            guard size.width > 0 && size.height > 0 else { return }
            lcDebug("📐 Viewer content resized to \(size.width)x\(size.height) — forwarding to host")
            self.clientSession.sendWindowResize(width: size.width, height: size.height)
        }
        pendingViewerSizeSend = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Recompute the render pause from the window's actual state. This used to
    /// be driven only by occlusion notifications, so a full-screen transition,
    /// a Space switch, or another app covering the viewer could leave the
    /// display link paused after the viewer came back: frames kept arriving and
    /// decoding but nothing was ever presented, and the stream looked frozen.
    /// Every event that can change visibility funnels through here instead.
    private func syncRenderPause() {
        guard let window = self.window else { return }
        let visible = !window.isMiniaturized
            && (window.occlusionState.contains(.visible) || window.isKeyWindow || window.isMainWindow)
        clientSession.renderer?.setPaused(!visible, reason: .notVisible)
    }
}

// MARK: - NSWindowDelegate (resize sync)

extension LocalCastViewerWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cleanup()
    }

    /// Fires at the end of a drag-to-resize.
    func windowDidEndLiveResize(_ notification: Notification) {
        sendViewerSize()
    }
    
    /// Fires for non-drag resizes (double-click title bar, Stage Manager tile, etc.).
    func windowDidResize(_ notification: Notification) {
        guard let window = self.window, !window.inLiveResize else { return }
        sendViewerSize()
    }

    /// Pause the Metal display link while the viewer cannot be seen
    /// (miniaturized, fully covered, or on another Space). Rendering an
    /// invisible window burned GPU/CPU at the display refresh rate.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncRenderPause()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        syncRenderPause()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        syncRenderPause()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        keyboardTap.setEnabled(true)
        syncRenderPause()
    }

    /// Losing key (Cmd+Tab, clicking another window) means no release for a
    /// held modifier will reach either keyboard path. Let the host go, and
    /// stop the session-wide tap from touching every keystroke meant for
    /// other apps.
    func windowDidResignKey(_ notification: Notification) {
        releaseHeldModifiers()
        keyboardTap.setEnabled(false)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        syncRenderPause()
    }

    /// Full screen changes the surface size and can move the window to another
    /// Space, either of which can leave the pause state stale. Ask for a
    /// keyframe too so the first full-screen frame is a clean one rather than a
    /// delta against whatever the drawable held.
    func windowDidEnterFullScreen(_ notification: Notification) {
        syncRenderPause()
        clientSession.requestKeyFrame()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        syncRenderPause()
        clientSession.requestKeyFrame()
    }

    /// Moving between displays changes the refresh rate the jitter buffer paces
    /// against.
    func windowDidChangeScreen(_ notification: Notification) {
        clientSession.renderer?.refreshDisplayLink()
        syncRenderPause()
    }
}

/// Main-thread mailbox for overlay control frames. SwiftUI writes it from
/// `onPreferenceChange`; the window controller's mouse monitor reads it.
final class ViewerOverlayFrames {
    var frames: [CGRect] = []
}

private struct OverlayFramePreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Reports this view's frame (hosting-view coordinates) as a pass-through
    /// region for the viewer's mouse monitor.
    func reportOverlayFrame() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OverlayFramePreferenceKey.self,
                    value: [proxy.frame(in: .global)]
                )
            }
        )
    }
}

struct LocalCastContentView: View {
    let mtkView: MTKView
    @ObservedObject var session: ClientSession
    @ObservedObject var tuning: StreamingTuning
    let overlayFrames: ViewerOverlayFrames
    @State private var showControlsPanel = false
    @State private var controlsTab: LocalCastControlsPanel.Tab = .quality
    
    var body: some View {
        ZStack {
            MetalViewRepresentable(mtkView: mtkView)
            
            if !session.isConnected {
                connectionStatusOverlay
            }
            
            // Top edge: the chevron opens the tabbed Stream Controls popup
            // directly. No intermediate toolbar/submenu step; everything
            // (quality, apps, stats) lives in one tabbed panel.
            VStack(spacing: 0) {
                Button {
                    if !showControlsPanel, session.remoteApps.isEmpty {
                        session.requestAppList()
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControlsPanel.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showControlsPanel ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 48, height: 20)
                    .background(.white.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .reportOverlayFrame()
                .padding(.bottom, 4)
                .help("Stream controls (quality, apps, info)")
                
                Spacer()
            }

            // Unified, tabbed controls panel (Quality / Apps / Info).
            // Live stats moved out of the floating top-right readout and into
            // the panel's Info tab; the video surface stays chrome-free.
            if showControlsPanel {
                LocalCastControlsPanel(
                    session: session,
                    tuning: tuning,
                    selectedTab: $controlsTab,
                    isPresented: $showControlsPanel
                )
            }

            // Bottom status bar
            VStack {
                Spacer()
                bottomStatusBar
            }
        }
        .onPreferenceChange(OverlayFramePreferenceKey.self) { frames in
            overlayFrames.frames = frames
        }
        .onChange(of: showControlsPanel) { _ in syncOverlayState() }
        .onReceive(tuning.objectWillChange.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)) { _ in
            DispatchQueue.main.async {
                session.sendQualityUpdate(tuning)
            }
        }
    }
    
    private func syncOverlayState() {
        session.isOverlayActive = showControlsPanel
    }
    
    @ViewBuilder
    private var bottomStatusBar: some View {
        HStack(spacing: 10) {
            Button {
                if session.remoteApps.isEmpty {
                    session.requestAppList()
                }
                controlsTab = .apps
                withAnimation(.easeInOut(duration: 0.2)) { showControlsPanel = true }
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
        .reportOverlayFrame()
        .padding(.bottom, 8)
    }
}

// Unified, tabbed controls panel for the LocalCast viewer. Replaces the
// separate floating quality and app-picker menus so all stream controls live
// behind one button: Quality, Apps, and Info (stats + shortcuts).

struct LocalCastControlsPanel: View {
    enum Tab: Hashable { case quality, apps, info }

    @ObservedObject var session: ClientSession
    @ObservedObject var tuning: StreamingTuning
    @Binding var selectedTab: Tab
    @Binding var isPresented: Bool
    @State private var expandedAppID: Int32?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stream Controls")
                    .font(.headline)
                Spacer()
                if selectedTab == .apps {
                    Button {
                        session.requestAppList()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isLoadingApps)
                }
                Button {
                    withAnimation { isPresented = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Picker("", selection: $selectedTab) {
                Text("Quality").tag(Tab.quality)
                Text("Apps").tag(Tab.apps)
                Text("Info").tag(Tab.info)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .quality: qualityTab
                case .apps: appsTab
                case .info: infoTab
                }
            }
        }
        .frame(width: 360, height: 460)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .padding(40)
    }

    private var qualityTab: some View {
        ScrollView {
            StreamingQualityControlView(tuning: tuning, isLive: true)
                .padding()
        }
    }

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LocalCastStatsOverlay(stats: session.stats)
                VStack(alignment: .leading, spacing: 6) {
                    Label("⌘⇧I toggles remote control", systemImage: "keyboard")
                    Label("System shortcuts (⌘Space, ⌘Tab, screenshots) are sent to the remote Mac while Control is on", systemImage: "command")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private var appsTab: some View {
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

                    ForEach(session.remoteApps, id: \.processID) { app in
                        RemoteAppRowView(
                            app: app,
                            isExpanded: expandedAppID == app.processID,
                            onTap: {
                                withAnimation {
                                    expandedAppID = (expandedAppID == app.processID) ? nil : app.processID
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
                case .waking:
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 36))
                        .foregroundStyle(.teal)
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
            VStack(alignment: .leading, spacing: 2) {
                row("Resolution", stats.resolution.width > 0
                    ? "\(Int(stats.resolution.width))×\(Int(stats.resolution.height))" : "—")
                row("Codec", stats.codec)
                row("Mode", stats.mode)
                row("Rate", "\(stats.fps)/s")
                row("Bitrate", String(format: "%.1f Mbps", stats.bitrateMbps))
                row("Latency", "\(Int(stats.latencyMs)) ms")
                row("Dropped", "\(stats.droppedPerSec)/s",
                    warn: stats.droppedPerSec > 0)
                row("Recovered", "\(stats.fecRecoveredPerSec)/s")
                row("Buffer", "\(stats.bufferDepth)")
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(warn ? .orange : .primary)
            Spacer(minLength: 0)
        }
    }
}

