import Foundation
import ScreenCaptureKit

// MARK: - Shareable app enumeration
//
// Split from HostSession.swift to keep that file under the SwiftLint
// file-length limit. Pure content enumeration; no session state.

extension HostSession {
    /// Enumerate apps that have at least one visible, titled, reasonably-sized
    /// on-screen window. Shared by the client-driven app list and the host-side
    /// share picker in the menu bar. Requires Screen Recording permission.
    static func enumerateShareableApps() async throws -> [RemoteAppInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // System/background bundle ID prefixes to exclude
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

        var appDict: [pid_t: (app: SCRunningApplication, windows: [SCWindow])] = [:]
        for window in content.windows {
            guard let app = window.owningApplication else { continue }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { continue }
            if excludedBundlePrefixes.contains(where: { app.bundleIdentifier.hasPrefix($0) }) { continue }
            guard window.isOnScreen else { continue }
            guard window.frame.width >= 100 && window.frame.height >= 50 else { continue }
            guard let title = window.title, !title.isEmpty else { continue }

            if appDict[app.processID] == nil {
                appDict[app.processID] = (app: app, windows: [])
            }
            appDict[app.processID]?.windows.append(window)
        }

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
            guard !windows.isEmpty else { continue }
            guard !data.app.applicationName.isEmpty else { continue }
            apps.append(RemoteAppInfo(
                processID: pid,
                name: data.app.applicationName,
                bundleIdentifier: data.app.bundleIdentifier,
                windows: windows
            ))
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps
    }
}
