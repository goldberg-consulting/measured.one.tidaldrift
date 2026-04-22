import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSWindowDelegate {
    
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureAppearance()
        installSettingsMenuItem()
        
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
    
    /// Add Cmd+, for Settings since we removed the SwiftUI Settings scene.
    private func installSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        let insertIndex = appMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? appMenu.items.count
        appMenu.insertItem(settingsItem, at: insertIndex)
        appMenu.insertItem(.separator(), at: insertIndex)
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
