import Foundation
import AppKit
import ScreenCaptureKit
import Combine

/// Represents a running application that can be streamed
struct StreamableApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let windows: [StreamableWindow]
    
    static func == (lhs: StreamableApp, rhs: StreamableApp) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Represents a window that can be streamed
struct StreamableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool
    
    static func == (lhs: StreamableWindow, rhs: StreamableWindow) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Service for app-specific streaming functionality
/// This is an EXPERIMENTAL feature that allows streaming individual apps instead of the full desktop
@MainActor
class AppStreamingService: ObservableObject {
    static let shared = AppStreamingService()
    
    @Published var availableApps: [StreamableApp] = []
    @Published var isLoading = false
    @Published var selectedApp: StreamableApp?
    @Published var selectedWindow: StreamableWindow?
    @Published var errorMessage: String?
    @Published var isExperimentalEnabled = false
    
    private var streamConfiguration: SCStreamConfiguration?
    private var stream: SCStream?
    private var contentFilter: SCContentFilter?
    
    private init() {
        // Check if experimental features are enabled
        isExperimentalEnabled = UserDefaults.standard.bool(forKey: "experimentalAppStreaming")
    }
    
    /// Refreshes the list of available apps that can be streamed
    func refreshAvailableApps() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // Get shareable content using ScreenCaptureKit
            // Include off-screen windows too so minimized apps show up
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            
            // Group windows by application
            var appDict: [pid_t: (app: SCRunningApplication, windows: [SCWindow])] = [:]
            
            // System UI elements to skip (not useful for streaming)
            let systemUIBundleIds = [
                "com.apple.dock",
                "com.apple.WindowManager", 
                "com.apple.controlcenter",
                "com.apple.notificationcenterui",
                "com.apple.Spotlight",
                "com.apple.SystemUIServer"
            ]
            
            for window in content.windows {
                guard let app = window.owningApplication else { continue }
                
                let bundleId = app.bundleIdentifier
                
                // Skip TidalDrift itself
                if bundleId == Bundle.main.bundleIdentifier { continue }
                
                // Skip system UI elements (not useful apps)
                if systemUIBundleIds.contains(bundleId) { continue }
                
                // Skip windows with no title and tiny size (likely system decorations)
                if window.title == nil && window.frame.width < 50 && window.frame.height < 50 {
                    continue
                }
                
                if appDict[app.processID] == nil {
                    appDict[app.processID] = (app: app, windows: [])
                }
                appDict[app.processID]?.windows.append(window)
            }
            
            // Convert to StreamableApp objects
            var apps: [StreamableApp] = []
            for (pid, data) in appDict {
                let icon = getAppIcon(for: data.app.bundleIdentifier)
                let windows = data.windows.map { window in
                    StreamableWindow(
                        id: window.windowID,
                        title: window.title ?? "Untitled Window",
                        bounds: window.frame,
                        isOnScreen: window.isOnScreen
                    )
                }
                
                apps.append(StreamableApp(
                    id: pid,
                    name: data.app.applicationName,
                    bundleIdentifier: data.app.bundleIdentifier,
                    icon: icon,
                    windows: windows
                ))
            }
            
            // Sort by name
            availableApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            
            // If empty, provide helpful message
            if availableApps.isEmpty {
                errorMessage = "No apps with windows found. Try opening some applications."
            }
            
        } catch let error as NSError {
            // Check for specific permission error
            if error.domain == "com.apple.ScreenCaptureKit.SCStreamError" || 
               error.localizedDescription.contains("permission") {
                errorMessage = "Screen Recording permission required. Check System Settings → Privacy & Security → Screen Recording"
            } else {
                errorMessage = "Failed to get available apps: \(error.localizedDescription)"
            }
            #if DEBUG
            print("AppStreamingService error: \(error)")
            #endif
        }
        
        isLoading = false
    }
    
    /// Gets the app icon for a bundle identifier
    private func getAppIcon(for bundleId: String?) -> NSImage? {
        guard let bundleId = bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    
    /// Selects an app for streaming
    func selectApp(_ app: StreamableApp) {
        selectedApp = app
        selectedWindow = app.windows.first
    }
    
    /// Selects a specific window for streaming
    func selectWindow(_ window: StreamableWindow) {
        selectedWindow = window
    }
    
    /// Generates a VNC URL for app-specific streaming (experimental)
    /// Note: Standard VNC doesn't support app-specific streaming, this would require
    /// a custom server implementation or using Apple's Remote Desktop protocol extensions
    func getStreamingInfo() -> (url: String, note: String)? {
        guard let app = selectedApp else { return nil }
        
        // Get local IP
        guard let localIP = getLocalIPAddress() else {
            return nil
        }
        
        // This is a conceptual URL - real implementation would need custom protocol
        let note = """
        App-Specific Streaming is experimental.
        
        Standard VNC streams the entire desktop. To stream just "\(app.name)":
        
        Option 1: Use the built-in Screen Sharing with "Window" mode
        Option 2: Share via FaceTime/iMessage for single apps
        Option 3: Use a custom streaming solution
        
        For now, connecting will open standard screen sharing.
        """
        
        return (url: "vnc://\(localIP)", note: note)
    }
    
    /// Opens the selected app for the remote user to see
    func bringAppToFront() {
        guard let app = selectedApp,
              let runningApp = NSRunningApplication(processIdentifier: app.id) else {
            return
        }
        runningApp.activate(options: [.activateIgnoringOtherApps])
    }
    
    /// Attempts to start app-specific streaming using LocalCast
    /// This uses the existing LocalCast infrastructure for real streaming
    @Published var isStreaming = false
    @Published var streamingError: String?
    
    func startCapture() async throws {
        guard let app = selectedApp else {
            throw StreamingError.noAppSelected
        }
        
        print("🪟 AppStreaming: Starting stream for '\(app.name)'")
        
        // Determine what to stream - window or app
        if let window = selectedWindow {
            // Stream specific window
            print("🪟 AppStreaming: Streaming window '\(window.title)' (ID: \(window.id))")
            try await LocalCastService.shared.startHostingWindow(
                windowID: window.id,
                windowTitle: window.title
            )
        } else {
            // Stream entire app
            print("🪟 AppStreaming: Streaming app '\(app.name)' (PID: \(app.id))")
            try await LocalCastService.shared.startHostingApp(
                processID: app.id,
                appName: app.name
            )
        }
        
        isStreaming = true
        streamingError = nil
        print("🪟 AppStreaming: ✅ Stream started successfully!")
    }
    
    /// Stops the current capture/streaming
    func stopCapture() async {
        print("🪟 AppStreaming: Stopping stream...")
        
        // Stop LocalCast hosting
        await MainActor.run {
            LocalCastService.shared.stopHosting()
        }
        
        isStreaming = false
        stream = nil
        contentFilter = nil
        
        print("🪟 AppStreaming: Stream stopped")
    }
    
    /// Toggles experimental feature
    func setExperimentalEnabled(_ enabled: Bool) {
        print("🧪 Toggling experimental app streaming: \(enabled)")
        isExperimentalEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "experimentalAppStreaming")
        UserDefaults.standard.synchronize() // Force save immediately
        
        // Notify others if needed or start/stop services
        if enabled {
            Task {
                await refreshAvailableApps()
            }
        }
    }
    
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        return address
    }
}

enum StreamingError: LocalizedError {
    case noAppSelected
    case appNotFound
    case captureNotSupported
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .noAppSelected:
            return "No app selected for streaming"
        case .appNotFound:
            return "Selected app is no longer running"
        case .captureNotSupported:
            return "Screen capture is not supported on this system"
        case .permissionDenied:
            return "Screen recording permission is required"
        }
    }
}

