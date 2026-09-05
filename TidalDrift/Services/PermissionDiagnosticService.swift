import Foundation
import ScreenCaptureKit
import AppKit

/// Comprehensive permission diagnostic and repair service
class PermissionDiagnosticService: ObservableObject {
    static let shared = PermissionDiagnosticService()
    
    // MARK: - Published Status
    
    @Published var screenSharingServiceRunning: Bool = false
    @Published var screenSharingPortOpen: Bool = false
    @Published var screenRecordingGranted: Bool = false
    @Published var localNetworkGranted: Bool = false
    @Published var lastDiagnostic: DiagnosticResult?
    @Published var isRunningDiagnostic: Bool = false
    
    // Hostname configuration
    @Published var computerName: String = ""
    @Published var localHostname: String = ""
    @Published var bonjourDomain: String = "local"
    @Published var wideAreaBonjourEnabled: Bool = false
    @Published var dynamicGlobalHostname: String?
    
    private init() {}
    
    // MARK: - Diagnostic Result
    
    struct DiagnosticResult {
        let timestamp: Date
        var issues: [Issue]
        var recommendations: [String]
        
        struct Issue {
            let category: Category
            let severity: Severity
            let description: String
            let fix: String?
            
            enum Category: String {
                case screenSharing = "Screen Sharing Service"
                case screenRecording = "Screen Recording Permission"
                case localNetwork = "Local Network Access"
                case appSignature = "App Signature"
            }
            
            enum Severity {
                case critical, warning, info
            }
        }
        
        var hasCriticalIssues: Bool {
            issues.contains { $0.severity == .critical }
        }
        
        var hasWarnings: Bool {
            issues.contains { $0.severity == .warning }
        }
    }
    
    // MARK: - Run Full Diagnostic
    
    @MainActor
    func runFullDiagnostic() async -> DiagnosticResult {
        isRunningDiagnostic = true
        defer { isRunningDiagnostic = false }
        
        var issues: [DiagnosticResult.Issue] = []
        var recommendations: [String] = []
        
        // Check 1: Screen Sharing Service
        let serviceStatus = await checkScreenSharingService()
        screenSharingServiceRunning = serviceStatus.isRunning
        screenSharingPortOpen = serviceStatus.portOpen
        
        if !serviceStatus.isRunning {
            issues.append(.init(
                category: .screenSharing,
                severity: .critical,
                description: "Screen Sharing service is not running",
                fix: "Enable in System Settings → General → Sharing → Screen Sharing"
            ))
        } else if !serviceStatus.portOpen {
            issues.append(.init(
                category: .screenSharing,
                severity: .warning,
                description: "Screen Sharing service is running but port 5900 is not listening",
                fix: "Try restarting the Screen Sharing service"
            ))
        }
        
        // Check 2: Screen Recording Permission (TCC)
        let screenRecording = await checkScreenRecordingPermission()
        screenRecordingGranted = screenRecording.granted
        
        if !screenRecording.granted {
            issues.append(.init(
                category: .screenRecording,
                severity: screenRecording.denied ? .critical : .warning,
                description: screenRecording.denied 
                    ? "Screen Recording permission was denied"
                    : "Screen Recording permission not yet granted",
                fix: "Go to System Settings → Privacy & Security → Screen Recording → Enable TidalDrift"
            ))
        }
        
        // Check 3: App Signature Status
        let signatureStatus = checkAppSignature()
        if !signatureStatus.isValid {
            issues.append(.init(
                category: .appSignature,
                severity: .warning,
                description: "App signature may have changed since permissions were granted",
                fix: "Reset permissions and re-grant after rebuilding"
            ))
        }
        
        // Check 4: Multiple TidalDrift installations
        let duplicates = findDuplicateInstallations()
        if duplicates.count > 1 {
            issues.append(.init(
                category: .appSignature,
                severity: .warning,
                description: "Found \(duplicates.count) TidalDrift installations - may cause permission confusion",
                fix: "Use Settings → Maintenance to remove duplicates"
            ))
        }
        
        // Generate recommendations
        if issues.isEmpty {
            recommendations.append("✅ All permissions are correctly configured!")
        } else {
            if issues.contains(where: { $0.category == .screenRecording }) {
                recommendations.append("After granting Screen Recording, quit and restart TidalDrift")
            }
            if issues.contains(where: { $0.category == .screenSharing }) {
                recommendations.append("Use the 'Fix Screen Sharing' button to enable the service")
            }
        }
        
        let result = DiagnosticResult(
            timestamp: Date(),
            issues: issues,
            recommendations: recommendations
        )
        
        lastDiagnostic = result
        return result
    }
    
    // MARK: - Individual Checks
    
    private func checkScreenSharingService() async -> (isRunning: Bool, portOpen: Bool) {
        // Check if service is running
        // ShellExecutor drains the pipe as the child writes; `launchctl print`
        // output comfortably exceeds the 64 KB pipe buffer.
        let serviceRunning = await Task.detached(priority: .utility) {
            let result = ShellExecutor.execute(
                executable: "/bin/launchctl", arguments: ["print", "system/com.apple.screensharing"])
            return result.output.contains("state = running")
        }.value
        
        // Check if port 5900 is listening
        let portOpen = await Task.detached(priority: .utility) {
            let result = ShellExecutor.execute(
                executable: "/usr/sbin/lsof", arguments: ["-i", ":5900", "-sTCP:LISTEN"])
            return result.exitCode == 0 && !result.output.isEmpty
        }.value
        
        return (serviceRunning, portOpen)
    }
    
    private func checkScreenRecordingPermission() async -> (granted: Bool, denied: Bool) {
        // Use preflight to check WITHOUT triggering a system prompt
        // This is available on macOS 10.15+
        let granted = CGPreflightScreenCaptureAccess()
        
        if granted {
            return (true, false)
        }
        
        // If preflight fails, we return false. 
        // We don't try to trigger the prompt here; we let the user do it 
        // by clicking 'Open System Settings' or by the app actually trying to capture.
        return (false, false)
    }
    
    private func checkAppSignature() -> (isValid: Bool, identifier: String?) {
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            return (false, nil)
        }
        
        let result = ShellExecutor.execute(executable: "/usr/bin/codesign", arguments: ["-dv", bundlePath])
        let output = result.output
        let isValid = result.exitCode == 0
        
        var identifier: String?
        if let range = output.range(of: "Identifier=") {
            let start = output[range.upperBound...]
            if let end = start.firstIndex(of: "\n") {
                identifier = String(start[..<end])
            }
        }
        
        return (isValid, identifier)
    }
    
    private func findDuplicateInstallations() -> [URL] {
        let searchPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Downloads"
        ]
        
        var installations: [URL] = []
        let fm = FileManager.default
        
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                for item in contents {
                    if item.lastPathComponent.hasPrefix("TidalDrift") && item.lastPathComponent.hasSuffix(".app") {
                        installations.append(item)
                    }
                }
            }
        }
        
        return installations
    }
    
    // MARK: - Hostname & Bonjour Configuration
    
    struct HostnameConfig {
        var computerName: String
        var localHostname: String
        var hostname: String? // Dynamic global hostname
        var bonjourDomains: [String]
        var wideAreaEnabled: Bool
    }
    
    /// Check current hostname and Bonjour configuration
    func checkHostnameConfiguration() -> HostnameConfig {
        // Get Computer Name
        let computerNameResult = ShellExecutor.execute(executable: "/usr/sbin/scutil", arguments: ["--get", "ComputerName"])
        let computerName = computerNameResult.exitCode == 0 ? computerNameResult.output : ""
        
        // Get Local Hostname (.local domain)
        let localHostnameResult = ShellExecutor.execute(executable: "/usr/sbin/scutil", arguments: ["--get", "LocalHostName"])
        let localHostname = localHostnameResult.exitCode == 0 ? localHostnameResult.output : ""
        
        // Get HostName (dynamic global hostname)
        let hostnameResult = ShellExecutor.execute(executable: "/usr/sbin/scutil", arguments: ["--get", "HostName"])
        let hostname = hostnameResult.exitCode == 0 ? hostnameResult.output : nil
        
        // Check for Wide-Area Bonjour configuration
        let wideAreaResult = ShellExecutor.execute(
            executable: "/usr/bin/defaults", arguments: ["read", "/Library/Preferences/com.apple.mDNSResponder"])
        let wideAreaEnabled = !wideAreaResult.output.isEmpty && wideAreaResult.exitCode == 0
        
        // Get Bonjour registration domains
        var bonjourDomains = ["local"]
        // Check for additional domains from mDNS config
        if wideAreaEnabled {
            // Parse mDNSResponder config for additional domains
            let lines = wideAreaResult.output.split(separator: "\n")
            for line in lines {
                if line.contains("RegistrationDomains") || line.contains("BrowseDomains") {
                    // Extract domain names
                    if let range = line.range(of: "\"(.+?)\"", options: .regularExpression) {
                        let domain = String(line[range]).replacingOccurrences(of: "\"", with: "")
                        if !domain.isEmpty && !bonjourDomains.contains(domain) {
                            bonjourDomains.append(domain)
                        }
                    }
                }
            }
        }
        
        // Update published properties
        DispatchQueue.main.async {
            self.computerName = computerName
            self.localHostname = localHostname
            self.dynamicGlobalHostname = hostname
            self.wideAreaBonjourEnabled = wideAreaEnabled
            self.bonjourDomain = bonjourDomains.first ?? "local"
        }
        
        return HostnameConfig(
            computerName: computerName,
            localHostname: localHostname,
            hostname: hostname,
            bonjourDomains: bonjourDomains,
            wideAreaEnabled: wideAreaEnabled
        )
    }
    
    /// Open Sharing settings to edit hostname
    func openHostnameSettings() {
        if #available(macOS 13.0, *) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sharing") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    
    // MARK: - Fix Actions
    
    /// Reset all TidalDrift TCC permissions (requires app restart)
    func resetAllPermissions() async -> Bool {
        let result = ShellExecutor.execute(executable: "/usr/bin/tccutil", arguments: ["reset", "All", "com.goldbergconsulting.tidaldrift"])
        return result.exitCode == 0
    }
    
    /// Reset just Screen Recording permission
    func resetScreenRecordingPermission() async -> Bool {
        let result = ShellExecutor.execute(executable: "/usr/bin/tccutil", arguments: ["reset", "ScreenCapture", "com.goldbergconsulting.tidaldrift"])
        return result.exitCode == 0
    }
    
    /// Kickstart the Screen Sharing service via the admin-prompted path.
    func kickstartScreenSharing() async -> Bool {
        await SharingConfigurationService.shared.restartScreenSharing()
    }
    
    /// Open Screen Recording settings directly
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Open Screen Sharing settings directly
    func openScreenSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing?Services_ScreenSharing") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Request screen recording permission by triggering the prompt
    func requestScreenRecordingPermission() async {
        // The only way to trigger the prompt is to actually try to capture
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            // Expected - will trigger the permission prompt
        }
    }
}

// MARK: - Why Permissions Are "Sticky"

/*
 UNDERSTANDING macOS PERMISSION BEHAVIOR:
 
 1. TCC (Transparency, Consent, Control) Database
    - Stores app permissions keyed by CODE SIGNATURE, not just bundle ID
    - When you rebuild an app, the signature changes
    - macOS may see the rebuilt app as a "new" app
    - Old permission entries become orphaned
 
 2. Permission Caching
    - macOS caches permission decisions in memory
    - Changes don't take effect until:
      a) The app quits completely (not just closes window)
      b) Sometimes requires logout/login
      c) In rare cases, requires reboot
 
 3. Multiple App Bundles
    - If you have TidalDrift.app, TidalDrift 2.app, etc.
    - Each has its own permission entry
    - Granting permission to wrong one has no effect
 
 4. Sandbox vs Non-Sandbox
    - Sandboxed apps have different permission requirements
    - Switching sandbox status invalidates previous permissions
 
 SOLUTIONS:
 
 a) For Development:
    - Use: tccutil reset ScreenCapture com.goldbergconsulting.tidaldrift
    - Quit and restart the app
    - Grant permission when prompted
 
 b) For Production:
    - Sign with a stable Developer ID
    - Permissions persist across updates
    - Use proper entitlements
 
 c) Quick Fixes:
    - Quit all TidalDrift instances: pkill -f TidalDrift
    - Reset permission: tccutil reset ScreenCapture com.goldbergconsulting.tidaldrift
    - Restart app and grant when prompted
*/

