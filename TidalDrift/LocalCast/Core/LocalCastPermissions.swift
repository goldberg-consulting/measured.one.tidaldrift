import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices
import CoreGraphics
import OSLog

@MainActor
class LocalCastPermissions: ObservableObject {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "Permissions")

    @Published var screenCaptureGranted = false
    @Published var accessibilityGranted = false

    var allPermissionsGranted: Bool {
        screenCaptureGranted && accessibilityGranted
    }

    /// Passive check -- reads current permission state without triggering any prompts.
    func checkPermissions() async {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Request screen capture permission. Triggers the system dialog the first time.
    /// If already denied, opens System Settings and polls for up to 30s.
    func requestScreenCaptureIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenCaptureGranted = true
            return true
        }
        
        let granted = CGRequestScreenCaptureAccess()
        screenCaptureGranted = granted
        if granted { return true }
        
        logger.warning("Screen Recording not granted after request — opening System Settings")
        openScreenCapturePreferences()
        return false
    }
    
    /// Waits for screen capture to be granted (polls every 1s, up to maxWait seconds).
    /// Call this after opening System Settings so the user can grant permission.
    func waitForScreenCaptureGrant(maxWait: TimeInterval = 30) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if CGPreflightScreenCaptureAccess() {
                screenCaptureGranted = true
                logger.info("Screen Recording permission granted!")
                return true
            }
        }
        return false
    }

    func openScreenCapturePreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
