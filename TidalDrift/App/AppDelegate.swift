import SwiftUI
import AppKit
import OSLog
import UserNotifications

private let menuBarLogger = Logger(subsystem: "com.tidaldrift", category: "MenuBar")

private final class MenuStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Manual entry point. We used to launch via `@main struct TidalDriftApp: App`
// with a SwiftUI `MenuBarExtra`, but `MenuBarExtra(.window)` has a bug on
// macOS 14+/15+/26+ where the status item renders, is accessibility-enabled,
// and reports `enabled: true`, yet clicks (both synthetic `AXPress` and real
// CGEvent mouse-downs on the pixel coordinates of the item) never open the
// popover. Reproduced on 26.3.1 and reported in the wild across 14.x/15.x.
// Owning the NSStatusItem + NSPopover directly in AppDelegate bypasses the
// broken SwiftUI path while keeping the rest of the UI (MenuBarView) fully
// SwiftUI via NSHostingController.
@main
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {

    /// Traditional AppKit entry point. Equivalent to Info.plist
    /// `LSUIElement=true` via `setActivationPolicy(.accessory)`, which keeps
    /// the app out of the Dock and the global menu bar but allows NSStatusItem
    /// registration. Invoked because of the `@main` attribute on the class.
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - Status item + panel (manual, replaces SwiftUI MenuBarExtra)
    //
    // We went through a few iterations here:
    //   1. SwiftUI `MenuBarExtra(.window)` — broken on macOS 14+, clicks
    //      never opened the popover.
    //   2. Manual NSStatusItem + NSPopover — clicks worked, but NSPopover's
    //      preferredEdge is a preference, not a mandate. On multi-monitor
    //      setups and occasionally when NSHostingController reports a bogus
    //      fitting size on first render, AppKit falls back to `.maxY` and
    //      the popover appears *above* the status item — off-screen, since
    //      the status item is at the top of the screen. The symptom the
    //      user sees is "the top of the dropdown is above the menu bar and
    //      I can't see it."
    //   3. Manual NSStatusItem + borderless NSPanel (current). Full control
    //      over positioning; the window never flips to above the anchor.

    private var statusItem: NSStatusItem?
    private var menuPanel: NSPanel?
    private var localMenuPanelMonitor: Any?
    private var globalMenuPanelMonitor: Any?

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var permissionRepairWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarLogger.info("applicationDidFinishLaunching")
        configureAppearance()
        setupStatusItem()

        UNUserNotificationCenter.current().delegate = self

        // Load initial data
        AppState.shared.loadTrustedDevices()
        AppState.shared.loadConnectionHistory()

        // Start network services right away. We intentionally do NOT reset TCC
        // permissions or run shell commands on launch — those used to block
        // the main thread for ~1-2s per launch and revoke Screen Recording on
        // every version upgrade. Permission repair is now an explicit action
        // surfaced in Settings > Troubleshooting.
        startNetworkServices()

        // Show onboarding on first launch
        if !AppState.shared.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.showOnboarding()
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOnboarding),
            name: .showOnboarding, object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideMenuPanel()
        NotificationCenter.default.removeObserver(self)
        NetworkDiscoveryService.shared.stopBrowsing()
        TidalDriftPeerService.shared.stopAdvertising()
        TidalDriftPeerService.shared.stopDiscovery()
        LocalCastService.shared.stopHosting()
        DeviceDetailWindowManager.shared.closeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Dock icon clicked -- no main window to show, just activate the app.
    /// The menu bar popover is the primary UI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return false
    }

    // MARK: - Dock Drop (files dragged onto Dock icon)

    func application(_ sender: NSApplication, open urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        DropPickerWindowManager.shared.show(fileURLs: fileURLs)
    }

    // MARK: - Onboarding

    @objc private func handleShowOnboarding() {
        showOnboarding()
    }

    func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = onboardingWindow {
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let onboardingView = OnboardingContainerView()
            .environmentObject(AppState.shared)

        let hostingView = NSHostingView(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidalDrift Setup"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    // MARK: - Settings Window

    /// Entry point for the in-app Settings button and the Cmd+, menu item.
    /// Dispatched directly (MenuBarView calls `(NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)`)
    /// rather than via `NSApp.sendAction` so SwiftUI can't intercept
    /// `showSettingsWindow:` and open a phantom Settings scene on macOS
    /// Sonoma+ — that phantom window becomes key and silently blocks all
    /// subsequent menu-bar clicks, making the app appear frozen.
    @objc func showSettingsWindow(_ sender: Any?) {
        showSettings()
    }

    /// Legacy alias kept for older macOS selector dispatch (Cmd+, on macOS
    /// versions that still look up `showPreferencesWindow:` first).
    @objc func showPreferencesWindow(_ sender: Any?) {
        showSettings()
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = settingsWindow {
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            existing.level = .floating
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(AppState.shared)

        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        // The menu panel uses `orderOut`, not `close`, so it never posts
        // willCloseNotification. Monitor cleanup happens in `hideMenuPanel`.
        if let window = notification.object as? NSWindow {
            if window === onboardingWindow {
                onboardingWindow = nil
            } else if window === settingsWindow {
                settingsWindow = nil
            } else if window === permissionRepairWindow {
                permissionRepairWindow = nil
            }
        }
    }

    private func configureAppearance() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    // MARK: - Status item + panel

    /// Content size of the menu panel. Matches the SwiftUI view's natural
    /// bounds; the popover mis-sized when we let NSHostingController
    /// compute it, so we just pin it.
    private static let menuPanelSize = NSSize(width: 360, height: 520)

    /// Creates the menu-bar status item (the "TD" icon) and the panel that
    /// hosts `MenuBarView`. Called once from `applicationDidFinishLaunching`.
    private func setupStatusItem() {
        menuBarLogger.info("setupStatusItem: starting")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "TD"
            button.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            button.toolTip = "TidalDrift"
            button.target = self
            button.action = #selector(toggleMenu(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            menuBarLogger.info("setupStatusItem: button configured")
        } else {
            menuBarLogger.warning("setupStatusItem: no button on status item")
        }
        self.statusItem = item

        // Borderless floating panel to host MenuBarView. We deliberately
        // build this up front (not lazily on first click) so the SwiftUI
        // content view has time to layout before the first show.
        let panel = MenuStatusPanel(
            contentRect: NSRect(origin: .zero, size: Self.menuPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self

        // Rounded corners on the panel's content background so the SwiftUI
        // view's edges don't look square against the transparent panel.
        let host = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(AppState.shared)
                .frame(width: Self.menuPanelSize.width, height: Self.menuPanelSize.height)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        host.view.frame = NSRect(origin: .zero, size: Self.menuPanelSize)
        panel.contentViewController = host

        self.menuPanel = panel
        menuBarLogger.info("setupStatusItem: done")
    }

    /// Primary click handler for the status item. Acts as an on/off toggle
    /// for the menu panel. Dismissal when the user clicks outside is handled
    /// by a local/global event monitor installed while the panel is visible.
    ///
    /// We intentionally do NOT call `NSApp.activate(ignoringOtherApps:)` here.
    /// For a menu-bar accessory app, activating the whole app causes the
    /// previously-key window in another app to relinquish key state, which
    /// triggers AppKit deactivation cascades and reorders windows behind the
    /// scenes. Combined with our outside-click monitor, that produced the
    /// "menu opens but controls don't respond / app appears frozen" behavior.
    @objc func toggleMenu(_ sender: Any?) {
        menuBarLogger.info("toggleMenu fired")
        guard let panel = menuPanel, let button = statusItem?.button else {
            menuBarLogger.warning("toggleMenu: missing panel or button")
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusContextMenu()
            return
        }
        if panel.isVisible {
            menuBarLogger.info("toggleMenu: closing panel")
            hideMenuPanel()
            return
        }
        menuBarLogger.info("toggleMenu: opening panel")
        positionMenuPanel(panel, below: button)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func showStatusContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open TidalDrift", action: #selector(openMenuFromContextMenu(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TidalDrift", action: #selector(requestQuit(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
    }

    @objc private func openMenuFromContextMenu(_ sender: Any?) {
        guard let panel = menuPanel, let button = statusItem?.button else { return }
        positionMenuPanel(panel, below: button)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    @objc func requestQuit(_ sender: Any?) {
        hideMenuPanel()
        DispatchQueue.main.async {
            NSApp.terminate(sender)
        }
    }

    /// Position the panel directly below the status item, horizontally
    /// centered under it, clamped to the screen's visible frame so the
    /// right edge never falls off-screen. This is the whole point of
    /// going from NSPopover → NSPanel: AppKit will never flip us above.
    private func positionMenuPanel(_ panel: NSWindow, below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.frame)
        let screenFrame = (buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first!).visibleFrame

        let panelHeight = min(Self.menuPanelSize.height, max(240, screenFrame.height - 16))
        let panelSize = NSSize(width: Self.menuPanelSize.width, height: panelHeight)
        if panel.frame.size != panelSize {
            panel.setContentSize(panelSize)
        }
        var origin = NSPoint(
            x: buttonFrameInScreen.midX - panelSize.width / 2,
            // In AppKit coords (origin bottom-left), "below" the button is
            // a SMALLER y. The button is at the top of the screen, so we
            // subtract the panel height from the button's bottom edge.
            y: buttonFrameInScreen.minY - panelSize.height - 4
        )
        // Clamp so we don't overrun the right edge of the screen.
        let maxX = screenFrame.maxX - panelSize.width - 8
        if origin.x > maxX { origin.x = maxX }
        let minX = screenFrame.minX + 8
        if origin.x < minX { origin.x = minX }
        let maxY = screenFrame.maxY - panelSize.height - 8
        if origin.y > maxY { origin.y = maxY }
        let minY = screenFrame.minY + 8
        if origin.y < minY { origin.y = minY }

        panel.setFrameOrigin(origin)
    }

    @objc func hideMenuPanel() {
        menuPanel?.orderOut(nil)
        removeOutsideClickMonitor()
    }

    /// Hides the menu panel, then runs `action` on the next main-queue turn.
    /// Does not call `NSApp.activate` — activating the accessory app from menu
    /// actions was leaving the TD status item unclickable after Metal stream
    /// and permission flows.
    func runAfterMenuDismissed(_ action: @escaping () -> Void) {
        hideMenuPanel()
        DispatchQueue.main.async(execute: action)
    }

    /// Run a modal `NSAlert` after activating TidalDrift. Without activation,
    /// the alert window appears behind whatever app was last in front and the
    /// `runModal()` call blocks the main thread on a dialog the user cannot
    /// see — the canonical "menu bar froze" symptom.
    private func presentModalAlert(_ configure: (NSAlert) -> Void) -> NSApplication.ModalResponse {
        hideMenuPanel()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        configure(alert)
        alert.window.level = .modalPanel
        return alert.runModal()
    }

    func showMetalStreamUnavailableAlert() {
        DispatchQueue.main.async { [weak self] in
            _ = self?.presentModalAlert { alert in
                alert.messageText = "Metal Stream Unavailable"
                alert.informativeText = "Could not connect to the remote Metal streaming host. Make sure TidalDrift is running on the remote Mac with Metal Streaming hosting enabled."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
            }
        }
    }

    func showMetalStreamingPermissionAlert(message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let response = self.presentModalAlert { alert in
                alert.messageText = "Metal Streaming Permission Required"
                alert.informativeText = message + "\n\nGrant Screen Recording to host Metal streams, and Accessibility to accept remote input control from clients."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Screen Recording Settings")
                alert.addButton(withTitle: "Open Accessibility Settings")
                alert.addButton(withTitle: "Cancel")
            }
            switch response {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            default:
                break
            }
        }
    }

    /// Close the panel when the user clicks anywhere outside it.
    ///
    /// We keep the monitor surface area as small as possible. The local
    /// monitor only handles the Escape key — never mouse events — because a
    /// local monitor that decides whether to swallow a mouse event has to
    /// run before AppKit dispatches that event to the SwiftUI control under
    /// the cursor, and any bug in our hit-test there blocks button clicks.
    /// Outside-clicks (in other apps or on our status item) are handled by
    /// the global monitor.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()

        localMenuPanelMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            // Escape closes the panel.
            if event.keyCode == 53 {
                self?.scheduleHideMenuPanel()
                return nil
            }
            return event
        }

        globalMenuPanelMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return }
            // Status-item clicks are handled only by `toggleMenu`. If we also
            // hide here and set a "ignore next click" flag, a missed action
            // delivery leaves TD stuck until the user clicks twice.
            if self.eventIsInsideStatusItem(event) {
                return
            }
            self.scheduleHideMenuPanel()
        }
    }

    /// Hide the panel on the next run-loop tick to avoid closing the window
    /// synchronously inside an AppKit event handler — that re-entry was a
    /// likely cause of the apparent freeze where the panel would open and
    /// SwiftUI controls would stop responding.
    private func scheduleHideMenuPanel() {
        DispatchQueue.main.async { [weak self] in
            self?.hideMenuPanel()
        }
    }

    private func eventIsInsideStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return false }
        let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        return buttonFrame.contains(screenPoint)
    }

    private func removeOutsideClickMonitor() {
        if let monitor = localMenuPanelMonitor {
            NSEvent.removeMonitor(monitor)
            localMenuPanelMonitor = nil
        }
        if let monitor = globalMenuPanelMonitor {
            NSEvent.removeMonitor(monitor)
            globalMenuPanelMonitor = nil
        }
    }

    private func startNetworkServices() {
        // Defer slightly so the status bar item paints and AppState finishes
        // its first run-loop init before any background sockets fire.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NetworkDiscoveryService.shared.startBrowsing()
            TidalDriftPeerService.shared.startAdvertising()
            TidalDriftPeerService.shared.startDiscovery()
            _ = TidalDropService.shared

            if UserDefaults.standard.bool(forKey: "localCastAutoHost") {
                Task {
                    do {
                        try await LocalCastService.shared.startHosting()
                    } catch {
                        print("LocalCast: Auto-host failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Public entry point for the Troubleshooting view's "Repair Permissions"
    /// button. Shows the same window the previous build opened on launch, but
    /// only on explicit user request.
    @objc func showPermissionRepairFromMenu(_ sender: Any?) {
        showPermissionRepairWindow(message: nil)
    }

    func showPermissionRepairWindow(message: String? = nil) {
        if let existing = permissionRepairWindow {
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = VStack(alignment: .leading, spacing: 12) {
            Text("TidalDrift Permissions")
                .font(.title2)
                .fontWeight(.bold)
            Text("This build reset TidalDrift’s macOS permissions so Screen Recording, Local Network, Accessibility, and Input Monitoring can be granted to the installed app.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PermissionDiagnosticView()
        }
        .padding(20)
        .frame(width: 620, height: 680)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TidalDrift Permissions"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionRepairWindow = window
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
