import Foundation

/// Permission repair service. All `tccutil`/`osascript` invocations run on a
/// background queue; `@Published` UI state is updated back on the main actor.
///
/// IMPORTANT: This service must NEVER be invoked automatically on launch.
/// `tccutil reset` revokes permissions, which forces the user to re-grant
/// Screen Recording, Local Network, etc. on every version upgrade. All entry
/// points here are explicit user actions ("Repair Permissions" in Settings).
@MainActor
class PermissionHealthService: ObservableObject {
    static let shared = PermissionHealthService()
    private static let bundleIdentifier = "com.goldbergconsulting.tidaldrift"

    @Published var isResetting: Bool = false
    @Published var lastResetResult: ResetResult?

    private init() {}

    struct ResetResult {
        let timestamp: Date
        let screenSharingRestarted: Bool
        let screenRecordingReset: Bool
        let localNetworkReset: Bool
        let accessibilityReset: Bool
        let inputMonitoringReset: Bool
        let message: String
    }

    // MARK: - User-initiated repair

    /// Reset all TidalDrift TCC permissions. Runs `tccutil` on a background
    /// queue so the main thread stays responsive.
    func fixAllPermissions() async -> ResetResult {
        isResetting = true
        defer { isResetting = false }

        let bundle = Self.bundleIdentifier
        let result: ResetResult = await Task.detached(priority: .userInitiated) {
            let screenRecordingOK = Self.runTccReset(service: "ScreenCapture", bundle: bundle)
            let localNetworkOK = Self.runTccReset(service: "LocalNetwork", bundle: bundle)
            let accessibilityOK = Self.runTccReset(service: "Accessibility", bundle: bundle)
            let inputMonitoringOK = Self.runTccReset(service: "ListenEvent", bundle: bundle)

            let messages = [
                screenRecordingOK ? "✅ Screen Recording permission reset" : "⚠️ Screen Recording reset failed",
                localNetworkOK ? "✅ Local Network permission reset" : "⚠️ Local Network reset failed",
                accessibilityOK ? "✅ Accessibility permission reset" : "⚠️ Accessibility reset failed",
                inputMonitoringOK ? "✅ Input Monitoring permission reset" : "⚠️ Input Monitoring reset failed"
            ]

            return ResetResult(
                timestamp: Date(),
                screenSharingRestarted: false,
                screenRecordingReset: screenRecordingOK,
                localNetworkReset: localNetworkOK,
                accessibilityReset: accessibilityOK,
                inputMonitoringReset: inputMonitoringOK,
                message: messages.joined(separator: "\n")
            )
        }.value

        lastResetResult = result
        return result
    }

    /// Reset just Screen Recording. Background queue.
    func resetScreenRecording() async -> Bool {
        isResetting = true
        defer { isResetting = false }

        let bundle = Self.bundleIdentifier
        let success: Bool = await Task.detached(priority: .userInitiated) {
            Self.runTccReset(service: "ScreenCapture", bundle: bundle)
        }.value

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

    /// Restart Screen Sharing via launchctl (prompts for admin password).
    /// Background queue so the prompt doesn't appear to "freeze" the app.
    func restartScreenSharing() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let result = ShellExecutor.execute("""
                osascript -e 'do shell script "launchctl kickstart -k system/com.apple.screensharing" with administrator privileges' 2>&1
            """)
            return result.exitCode == 0
        }.value
    }

    func resetLocalNetwork() -> Bool {
        Self.runTccReset(service: "LocalNetwork", bundle: Self.bundleIdentifier)
    }

    func resetAccessibility() -> Bool {
        Self.runTccReset(service: "Accessibility", bundle: Self.bundleIdentifier)
    }

    func resetInputMonitoring() -> Bool {
        Self.runTccReset(service: "ListenEvent", bundle: Self.bundleIdentifier)
    }

    /// Just restart Screen Sharing (quick fix for connection issues).
    func quickFixScreenSharing() async -> Bool {
        isResetting = true
        defer { isResetting = false }
        return await restartScreenSharing()
    }

    // MARK: - Helpers

    /// Non-actor-isolated helper so it can run inside `Task.detached`. We pass
    /// the bundle id explicitly rather than touching `Self` so this never
    /// hops back to the main actor.
    nonisolated private static func runTccReset(service: String, bundle: String) -> Bool {
        // The bundle id and service name are both compile-time constants from
        // our own code, so command injection isn't a concern here.
        let result = ShellExecutor.execute("tccutil reset \(service) \(bundle) 2>&1")
        return result.exitCode == 0
    }
}
