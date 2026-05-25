import Foundation
import Combine
import AppKit
import Network
import os.log

private let logger = Logger(subsystem: "com.tidaldrift", category: "SharingConfig")

class SharingConfigurationService: ObservableObject, @unchecked Sendable {
    static let shared = SharingConfigurationService()
    
    @Published var screenSharingEnabled: Bool = false
    @Published var fileSharingEnabled: Bool = false
    @Published var remoteLoginEnabled: Bool = false
    
    // Store active connections to prevent premature deallocation
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()
    
    private init() {
        Task {
            await refreshStatus()
        }
    }
    
    /// Run a Process without blocking the Swift concurrency thread pool.
    /// Uses `terminationHandler` instead of `waitUntilExit()`.
    private func runProcess(_ executablePath: String, arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executablePath)
            task.arguments = arguments
            
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            let resumed = AtomicFlag(false)
            task.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if resumed.compareAndSwap(expected: false, desired: true) {
                    continuation.resume(returning: (output, process.terminationStatus))
                }
            }
            
            do {
                try task.run()
            } catch {
                if resumed.compareAndSwap(expected: false, desired: true) {
                    continuation.resume(returning: ("", -1))
                }
            }
        }
    }
    
    @MainActor
    func refreshStatus() async {
        screenSharingEnabled = await isScreenSharingEnabled()
        fileSharingEnabled = await isFileSharingEnabled()
        remoteLoginEnabled = await isRemoteLoginEnabled()
    }
    
    func isScreenSharingEnabled() async -> Bool {
        let result = await runProcess("/bin/launchctl", arguments: ["print", "system/com.apple.screensharing"])
        if result.exitCode == 0 { return true }
        return await checkLocalPort(5900)
    }
    
    /// Helper to check if a local port is open (with proper connection lifetime management)
    private func checkLocalPort(_ portNumber: UInt16, timeout: TimeInterval = 0.3) async -> Bool {
        return await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host("127.0.0.1")
            let port = NWEndpoint.Port(rawValue: portNumber)!
            let connection = NWConnection(host: host, port: port, using: .tcp)
            let connectionId = UUID()
            
            // Store connection to prevent premature deallocation
            self.connectionsLock.lock()
            self.activeConnections[connectionId] = connection
            self.connectionsLock.unlock()
            
            let didResume = AtomicFlag()
            
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !didResume.value else { return }
                    didResume.value = true
                    self?.cleanupConnection(id: connectionId)
                    continuation.resume(returning: true)
                case .failed:
                    guard !didResume.value else { return }
                    didResume.value = true
                    self?.cleanupConnection(id: connectionId)
                    continuation.resume(returning: false)
                case .cancelled:
                    self?.connectionsLock.lock()
                    self?.activeConnections.removeValue(forKey: connectionId)
                    self?.connectionsLock.unlock()
                    
                    guard !didResume.value else { return }
                    didResume.value = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            // Timeout for localhost
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !didResume.value else { return }
                didResume.value = true
                self?.cleanupConnection(id: connectionId)
                continuation.resume(returning: false)
            }
        }
    }
    
    private func cleanupConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = activeConnections[id] {
            connection.cancel()
        }
        connectionsLock.unlock()
    }
    
    func isFileSharingEnabled() async -> Bool {
        let result = await runProcess("/bin/launchctl", arguments: ["print", "system/com.apple.smbd"])
        if result.exitCode == 0 { return true }
        return await checkLocalPort(445)
    }
    
    func isRemoteLoginEnabled() async -> Bool {
        logger.info("Checking Remote Login status...")
        
        // Method 1: Check by testing local port 22
        let portCheck = await checkLocalPort(22, timeout: 0.5)
        
        if portCheck {
            logger.info("Result: SSH ENABLED (port check passed)")
            return true
        }
        
        let result = await runProcess("/bin/launchctl", arguments: ["list"])
        let launchctlCheck = result.output.contains("com.openssh.sshd")
        logger.info("Result: SSH \(launchctlCheck ? "ENABLED" : "DISABLED") (launchctl fallback)")
        return launchctlCheck
    }
    
    func isFirewallEnabled() async -> Bool {
        let result = await runProcess("/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getglobalstate"])
        return result.output.lowercased().contains("enabled")
    }
    
    func isFirewallBlockingAll() async -> Bool {
        let result = await runProcess("/usr/libexec/ApplicationFirewall/socketfilterfw", arguments: ["--getblockall"])
        return result.output.lowercased().contains("enabled")
    }

    func isTidalDriftAllowedThroughFirewall() async -> Bool {
        let appPath = Bundle.main.bundlePath
        let result = await runProcess(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--listapps"]
        )
        let output = result.output.lowercased()
        return output.contains(appPath.lowercased()) &&
            (output.contains("allow incoming connections") || output.contains("allow"))
    }

    func allowTidalDriftThroughFirewall() async -> Bool {
        let appPath = Bundle.main.bundlePath
        guard FileManager.default.fileExists(atPath: appPath) else {
            logger.error("Firewall exception failed: app path does not exist: \(appPath)")
            return false
        }

        let escapedPath = Self.shellEscaped(appPath)
        let command = """
        /usr/libexec/ApplicationFirewall/socketfilterfw --add \(escapedPath); \
        /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp \(escapedPath)
        """
        let script = """
        do shell script "\(Self.appleScriptEscaped(command))" with administrator privileges
        """
        return await runAppleScript(script)
    }
    
    // MARK: - Toggle Sharing Services
    
    /// Ensure screen sharing is enabled - quick fix for connection issues
    func ensureScreenSharingEnabled() async -> Bool {
        // First check if it's already enabled
        let isEnabled = await isScreenSharingEnabled()
        if isEnabled {
            return true
        }
        
        // Try to enable it
        return await toggleScreenSharing(enable: true)
    }
    
    /// Quick fix: restart screen sharing service
    func restartScreenSharing() async -> Bool {
        // Disable then enable to restart the service
        let script = """
        do shell script "launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null; launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist" with administrator privileges
        """
        let result = await runAppleScript(script)
        
        // Refresh status after
        await refreshStatus()
        return result
    }
    
    func toggleScreenSharing(enable: Bool) async -> Bool {
        let script: String
        if enable {
            script = """
            do shell script "launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist" with administrator privileges
            """
        } else {
            script = """
            do shell script "launchctl unload -w /System/Library/LaunchDaemons/com.apple.screensharing.plist" with administrator privileges
            """
        }
        
        let result = await runAppleScript(script)
        await refreshStatus()
        return result
    }
    
    func toggleFileSharing(enable: Bool) async -> Bool {
        let script: String
        if enable {
            script = """
            do shell script "launchctl load -w /System/Library/LaunchDaemons/com.apple.smbd.plist" with administrator privileges
            """
        } else {
            script = """
            do shell script "launchctl unload -w /System/Library/LaunchDaemons/com.apple.smbd.plist" with administrator privileges
            """
        }
        
        return await runAppleScript(script)
    }
    
    func toggleRemoteLogin(enable: Bool) async -> Bool {
        let screenshareUser = UserDefaults.standard.string(forKey: "screenShareUsername")
        
        logger.info("toggleRemoteLogin called - enable: \(enable), user: \(screenshareUser ?? "none")")
        
        // Check current state first
        let currentState = await isRemoteLoginEnabled()
        logger.info("Current SSH state: \(currentState)")
        
        // Use launchctl approach instead of systemsetup (which requires Full Disk Access)
        let script: String
        
        if enable {
            // Enable SSH using launchctl bootstrap
            var command = "launchctl bootout system/com.openssh.sshd 2>/dev/null; launchctl enable system/com.openssh.sshd; launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"
            
            // Also add user to SSH access group if specified
            // Sanitize username to prevent command injection
            if let user = screenshareUser {
                let sanitizedUser = user.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                if !sanitizedUser.isEmpty && sanitizedUser == user {
                    command += " && dseditgroup -o edit -a '\(sanitizedUser)' -t user com.apple.access_ssh 2>/dev/null"
                }
            }
            
            script = """
            do shell script "\(command)" with administrator privileges
            """
        } else {
            // Disable SSH using launchctl bootout
            script = """
            do shell script "launchctl bootout system/com.openssh.sshd" with administrator privileges
            """
        }
        
        logger.info("Executing Remote Login configuration via launchctl...")
        let result = await runAppleScript(script)
        
        if result {
            logger.info("Remote Login launchctl command SUCCESS")
        } else {
            logger.error("Remote Login launchctl command FAILURE (user cancelled or error)")
        }
        
        // Wait a moment for system to settle
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Verify the new state
        let newState = await isRemoteLoginEnabled()
        logger.info("New SSH state after command: \(newState)")
        
        if enable && !newState {
            logger.warning("SSH was supposed to be enabled but port 22 is not responding - may be timing issue")
        }
        
        await refreshStatus()
        return result
    }
    
    func authorizeUserForSSH(username: String) async -> Bool {
        // Sanitize username to prevent command injection
        // Only allow alphanumeric, underscore, hyphen (valid macOS username chars)
        let sanitizedUsername = username.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !sanitizedUsername.isEmpty, sanitizedUsername == username else {
            logger.error("Invalid username rejected: contains unsafe characters")
            return false
        }
        
        let script = """
        do shell script "dseditgroup -o edit -a '\(sanitizedUsername)' -t user com.apple.access_ssh" with administrator privileges
        """
        return await runAppleScript(script)
    }
    
    private func runAppleScript(_ source: String) async -> Bool {
        logger.info("Running AppleScript: \(source.prefix(150))...")
        let result = await runProcess("/usr/bin/osascript", arguments: ["-e", source])
        
        logger.info("osascript exit code: \(result.exitCode)")
        if !result.output.isEmpty {
            logger.info("osascript output: \(result.output, privacy: .public)")
        }
        
        return result.exitCode == 0
    }
    
    /// Public method to execute arbitrary AppleScript (for user creation, etc.)
    func executeAppleScript(_ source: String) async -> Bool {
        return await runAppleScript(source)
    }
    
    // MARK: - Open Settings
    
    func openScreenSharingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.sharing?Services_ScreenSharing")!
        NSWorkspace.shared.open(url)
    }
    
    func openFileSharingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.sharing?Services_PersonalFileSharing")!
        NSWorkspace.shared.open(url)
    }
    
    func openFirewallSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall")!
        NSWorkspace.shared.open(url)
    }
    
    func openSharingPreferences() {
        if #available(macOS 13.0, *) {
            let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!
            NSWorkspace.shared.open(url)
        } else {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.sharing")!
            NSWorkspace.shared.open(url)
        }
    }
    
    func getComputerName() -> String {
        return NetworkUtils.computerName
    }
    
    func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    addresses.append(String(cString: hostname))
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return addresses
    }

    private static func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
