import SwiftUI
import AppKit
import OSLog
import UserNotifications

private let menuBarLogger = Logger(subsystem: "com.tidaldrift", category: "MenuBar")

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

    // MARK: - Status item + popover (manual, replaces SwiftUI MenuBarExtra)

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarLogger.info("applicationDidFinishLaunching")
        configureAppearance()
        setupStatusItem()

        UNUserNotificationCenter.current().delegate = self

        // Load initial data
        AppState.shared.loadTrustedDevices()
        AppState.shared.loadConnectionHistory()
        
        // Defer network operations to avoid blocking app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
        NetworkDiscoveryService.shared.stopBrowsing()
        TidalDriftPeerService.shared.stopAdvertising()
        TidalDriftPeerService.shared.stopDiscovery()
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
        if let window = notification.object as? NSWindow {
            if window === onboardingWindow {
                onboardingWindow = nil
            } else if window === settingsWindow {
                settingsWindow = nil
            }
        }
    }
    
    private func configureAppearance() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    // MARK: - Status item + popover

    /// Creates the menu-bar status item (the "TD" icon) and the popover that
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
            // Accept both primary clicks (toggle the popover) and, if we ever
            // need it in the future, right-clicks for a context menu.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            menuBarLogger.info("setupStatusItem: button configured")
        } else {
            menuBarLogger.warning("setupStatusItem: no button on status item")
        }
        self.statusItem = item
        menuBarLogger.info("setupStatusItem: done")

        let popover = NSPopover()
        popover.behavior = .transient  // auto-closes when the user clicks outside
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 520)

        let host = NSHostingController(
            rootView: MenuBarView().environmentObject(AppState.shared)
        )
        host.view.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        popover.contentViewController = host
        self.popover = popover
    }

    /// Toggle the popover shown under the status item. When the popover
    /// becomes key we also pin the app as an accessory so child windows
    /// (onboarding, settings, the Metal viewer) can gain focus.
    /// Toggle the popover shown under the status item. `.transient` behavior
    /// handles dismissal when the user clicks anywhere outside the popover;
    /// clicking the status item itself while the popover is visible is
    /// routed to us by AppKit, which calls `toggleMenu` a second time — we
    /// explicitly close in that case so the icon acts as an on/off toggle.
    @objc func toggleMenu(_ sender: Any?) {
        menuBarLogger.info("toggleMenu fired")
        guard let button = statusItem?.button, let popover = popover else {
            menuBarLogger.warning("toggleMenu: missing button or popover")
            return
        }
        if popover.isShown {
            menuBarLogger.info("toggleMenu: closing popover")
            popover.performClose(sender)
            return
        }
        menuBarLogger.info("toggleMenu: opening popover")
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
