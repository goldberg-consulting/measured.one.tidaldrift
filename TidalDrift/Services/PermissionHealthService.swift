import Foundation

/// Simple permission reset service - no detection, just fixes
class PermissionHealthService: ObservableObject {
    static let shared = PermissionHealthService()
    private static let bundleIdentifier = "com.goldbergconsulting.tidaldrift"
    private static let lastPermissionResetBuildKey = "lastPermissionResetBuild"

    @Published var isResetting: Bool = false
    @Published var lastResetResult: ResetResult?

    private init() {}

    private var currentBuildKey: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version)-\(build)"
    }

    struct ResetResult {
        let timestamp: Date
        let screenSharingRestarted: Bool
        let screenRecordingReset: Bool
        let localNetworkReset: Bool
        let accessibilityReset: Bool
        let inputMonitoringReset: Bool
        let message: String
    }

    // MARK: - Single Fix Button

    /// Reset all permissions that tend to get stuck
    @MainActor
    func fixAllPermissions() async -> ResetResult {
        isResetting = true
        defer { isResetting = false }

        print("🔧 PermissionHealthService: Starting permission fix...")

        var screenSharingOK = false
        var screenRecordingOK = false
        var localNetworkOK = false
        var accessibilityOK = false
        var inputMonitoringOK = false
        var messages: [String] = []

        // 1. Restart Screen Sharing service (doesn't require quit)
        screenSharingOK = await restartScreenSharing()
        if screenSharingOK {
            messages.append("✅ Screen Sharing service restarted")
        } else {
            messages.append("⚠️ Screen Sharing restart needs admin approval")
        }

        // 2. Reset Screen Recording permission (will require re-grant)
        screenRecordingOK = await resetScreenRecording()
        if screenRecordingOK {
            messages.append("✅ Screen Recording permission reset - please re-grant if prompted")
        } else {
            messages.append("⚠️ Screen Recording reset failed")
        }

        // 3. Reset Local Network permission
        localNetworkOK = resetLocalNetwork()
        if localNetworkOK {
            messages.append("✅ Local Network permission reset")
        } else {
            messages.append("⚠️ Local Network reset failed")
        }

        accessibilityOK = resetAccessibility()
        messages.append(accessibilityOK ? "✅ Accessibility permission reset" : "⚠️ Accessibility reset failed")

        inputMonitoringOK = resetInputMonitoring()
        messages.append(inputMonitoringOK ? "✅ Input Monitoring permission reset" : "⚠️ Input Monitoring reset failed")

        let result = ResetResult(
            timestamp: Date(),
            screenSharingRestarted: screenSharingOK,
            screenRecordingReset: screenRecordingOK,
            localNetworkReset: localNetworkOK,
            accessibilityReset: accessibilityOK,
            inputMonitoringReset: inputMonitoringOK,
            message: messages.joined(separator: "\n")
        )

        lastResetResult = result
        print("🔧 PermissionHealthService: Fix complete - \(messages)")

        return result
    }

    // MARK: - Individual Fixes

    /// Restart Screen Sharing without needing app restart
    func restartScreenSharing() async -> Bool {
        let result = ShellExecutor.execute("""
            osascript -e 'do shell script "launchctl kickstart -k system/com.apple.screensharing" with administrator privileges' 2>&1
        """)
        return result.exitCode == 0
    }

    /// Reset Screen Recording TCC entry
    @MainActor
    func resetScreenRecording() async -> Bool {
        isResetting = true
        defer { isResetting = false }

        let result = ShellExecutor.execute("tccutil reset ScreenCapture \(Self.bundleIdentifier) 2>&1")

        let success = result.exitCode == 0
        if success {
            lastResetResult = ResetResult(
                timestamp: Date(),
                screenSharingRestarted: false,
                screenRecordingReset: true,
                localNetworkReset: false,
                accessibilityReset: false,
                inputMonitoringReset: false,
                message: "✅ Screen Recording permission reset. Please restart the app and grant permission when prompted."
            )
        }
        return success
    }

    /// Reset Local Network TCC entry
    func resetLocalNetwork() -> Bool {
        let result = ShellExecutor.execute("tccutil reset LocalNetwork \(Self.bundleIdentifier) 2>&1")
        return result.exitCode == 0
    }

    func resetAccessibility() -> Bool {
        let result = ShellExecutor.execute("tccutil reset Accessibility \(Self.bundleIdentifier) 2>&1")
        return result.exitCode == 0
    }

    func resetInputMonitoring() -> Bool {
        let result = ShellExecutor.execute("tccutil reset ListenEvent \(Self.bundleIdentifier) 2>&1")
        return result.exitCode == 0
    }

    @MainActor
    func resetTCCPermissionsForCurrentBuildIfNeeded() async -> ResetResult? {
        let buildKey = currentBuildKey
        guard UserDefaults.standard.string(forKey: Self.lastPermissionResetBuildKey) != buildKey else {
            return nil
        }

        isResetting = true
        defer { isResetting = false }

        let screenRecordingOK = await resetScreenRecording()
        let localNetworkOK = resetLocalNetwork()
        let accessibilityOK = resetAccessibility()
        let inputMonitoringOK = resetInputMonitoring()
        let messages = [
            screenRecordingOK ? "✅ Screen Recording permission reset" : "⚠️ Screen Recording reset failed",
            localNetworkOK ? "✅ Local Network permission reset" : "⚠️ Local Network reset failed",
            accessibilityOK ? "✅ Accessibility permission reset" : "⚠️ Accessibility reset failed",
            inputMonitoringOK ? "✅ Input Monitoring permission reset" : "⚠️ Input Monitoring reset failed"
        ]

        let result = ResetResult(
            timestamp: Date(),
            screenSharingRestarted: false,
            screenRecordingReset: screenRecordingOK,
            localNetworkReset: localNetworkOK,
            accessibilityReset: accessibilityOK,
            inputMonitoringReset: inputMonitoringOK,
            message: messages.joined(separator: "\n")
        )
        lastResetResult = result
        UserDefaults.standard.set(buildKey, forKey: Self.lastPermissionResetBuildKey)
        return result
    }

    /// Just restart Screen Sharing (quick fix for connection issues)
    @MainActor
    func quickFixScreenSharing() async -> Bool {
        isResetting = true
        defer { isResetting = false }

        print("🔧 Quick fix: Restarting Screen Sharing service...")
        return await restartScreenSharing()
    }
}
