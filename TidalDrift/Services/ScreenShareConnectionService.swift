import Foundation
import AppKit
import Network
import OSLog

enum ConnectionError: LocalizedError {
    case invalidAddress
    case connectionFailed
    case authenticationFailed
    case timeout
    case scriptError(String)
    case screenSharingNotPermitted(String) // The "sticky" macOS bug
    case remoteServiceDown
    case resolutionFailed(String)
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Invalid IP address or hostname"
        case .connectionFailed:
            return "Failed to establish connection"
        case .authenticationFailed:
            return "Authentication failed"
        case .timeout:
            return "Connection timed out"
        case .scriptError(let message):
            return "Script error: \(message)"
        case .screenSharingNotPermitted(let ip):
            return "Screen Sharing not permitted on \(ip). The remote machine needs to restart its Screen Sharing service."
        case .remoteServiceDown:
            return "Remote Screen Sharing service is not running"
        case .resolutionFailed(let reason):
            return "Could not resolve device address: \(reason)"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .screenSharingNotPermitted:
            return """
            This is a known macOS bug. To fix:
            
            ON THE REMOTE MACHINE:
            1. System Settings → General → Sharing
            2. Turn OFF Screen Sharing
            3. Wait 5 seconds
            4. Turn ON Screen Sharing
            
            Or if TidalDrift is running there, use "Fix Remote" button.
            """
        case .remoteServiceDown:
            return "Enable Screen Sharing on the remote machine in System Settings → General → Sharing"
        case .resolutionFailed:
            return "The device may have changed IP address or be offline. Try refreshing the device list."
        default:
            return nil
        }
    }
}

enum ScreenShareMode {
    case control
    case observe
}

class ScreenShareConnectionService: @unchecked Sendable {
    static let shared = ScreenShareConnectionService()
    
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ScreenShareConnection")
    
    // Store active connections to prevent premature deallocation
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionsLock = NSLock()
    
    private init() {}
    
    func connect(to device: DiscoveredDevice, mode: ScreenShareMode = .control, username: String? = nil, password: String? = nil) async throws {
        logger.info("🔌 Connecting to '\(device.name)'...")
        
        // Step 1: Resolve the best address using hostname-first strategy
        // This handles stale IPs and DHCP changes automatically
        let resolved: ConnectionResolver.ResolvedAddress
        do {
            resolved = try await ConnectionResolver.shared.resolve(
                device: device,
                strategy: .ipFirst,
                timeout: 5.0
            )
            logger.info("🔌 Resolved address: \(resolved.address) via \(resolved.method.rawValue)")
        } catch let error as ConnectionResolver.ResolutionError {
            logger.error("🔌 Resolution failed: \(error.localizedDescription)")
            throw ConnectionError.resolutionFailed(error.localizedDescription)
        }
        
        // Step 2: Connect using the resolved address
        if let username = username, !username.isEmpty,
           let password = password, !password.isEmpty {
            try await connectWithCredentials(to: resolved.address, port: resolved.port, username: username, password: password)
        } else {
            // Always use the resolved IP for the VNC URL. Using a .local hostname
            // re-introduces mDNS ambiguity (two Macs with similar names can cause
            // Screen Sharing to connect to the local machine instead of the remote).
            let connectionAddress = resolved.address
            logger.info("🔌 Using resolved IP for VNC URL: \(resolved.address)")
            
            let urlString: String
            if let username = username, !username.isEmpty {
                let escapedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
                urlString = "vnc://\(escapedUser)@\(connectionAddress):\(resolved.port)"
            } else {
                urlString = "vnc://\(connectionAddress):\(resolved.port)"
            }
            
            guard let url = URL(string: urlString) else {
                throw ConnectionError.invalidAddress
            }
            
            logger.info("🔌 Opening VNC URL: \(urlString.replacingOccurrences(of: "vnc://", with: "vnc://[redacted]@").components(separatedBy: "@").last ?? "...")")
            
            let success = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            
            if !success {
                throw ConnectionError.connectionFailed
            }
        }
    }
    
    /// Connect using AppleScript to pass credentials directly to Screen Sharing
    /// - Parameters:
    ///   - address: IP address or hostname.local
    ///   - port: VNC port (typically 5900)
    ///   - username: Username for authentication
    ///   - password: Password for authentication
    private func connectWithCredentials(to address: String, port: Int, username: String, password: String) async throws {
        // Validate address format to prevent injection
        guard isValidAddress(address) else {
            throw ConnectionError.invalidAddress
        }
        
        // Escape special characters for AppleScript string
        let escapedUsername = escapeForAppleScript(username)
        let escapedPassword = escapeForAppleScript(password)
        
        // Build VNC URL with properly escaped credentials
        let vncURL = "vnc://\(escapedUsername):\(escapedPassword)@\(address):\(port)"
        
        logger.info("🔌 Connecting with credentials to \(address):\(port)")
        
        // Use AppleScript to open the connection
        let script = """
        tell application "Screen Sharing"
            activate
            open location "\(vncURL)"
        end tell
        """
        
        let result = await MainActor.run { () -> (Bool, String?) in
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    return (false, error[NSAppleScript.errorMessage] as? String)
                }
                return (true, nil)
            }
            return (false, "Failed to create AppleScript")
        }
        
        if !result.0 {
            logger.warning("🔌 AppleScript connection failed, falling back to URL method")
            // Fall back to URL method (without password - macOS will prompt)
            let escapedUsernameForURL = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            let urlString = "vnc://\(escapedUsernameForURL)@\(address):\(port)"
            guard let url = URL(string: urlString) else {
                throw ConnectionError.invalidAddress
            }
            
            let success = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            
            if !success {
                throw ConnectionError.connectionFailed
            }
        }
    }
    
    /// Validate address format (IP or hostname)
    private func isValidAddress(_ address: String) -> Bool {
        // Allow .local hostnames
        if address.hasSuffix(".local") {
            // Basic hostname validation - alphanumeric, hyphens, dots
            let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
            return address.unicodeScalars.allSatisfy { validChars.contains($0) }
        }
        
        // IP address validation
        return isValidIPAddress(address)
    }
    
    /// Validate IP address format
    private func isValidIPAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }
    
    /// Escape string for safe use in AppleScript
    private func escapeForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
    
    func connectWithScreenSharingApp(to device: DiscoveredDevice) throws {
        let screenSharingPath = "/System/Library/CoreServices/Applications/Screen Sharing.app"
        let screenSharingURL = URL(fileURLWithPath: screenSharingPath)
        
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [device.ipAddress]
        
        NSWorkspace.shared.openApplication(at: screenSharingURL, configuration: configuration) { _, _ in
            // Connection handled by Screen Sharing app
        }
    }
    
    func connectToFileShare(device: DiscoveredDevice, username: String? = nil) async throws {
        // Check if already mounted
        if let mountedURL = findMountedShare(for: device) {
            logger.info("📁 File Share: Already mounted at \(mountedURL.path), opening in Finder")
            await MainActor.run {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mountedURL.path)
            }
            return
        }
        
        // Resolve address using hostname-first strategy
        let resolved: ConnectionResolver.ResolvedAddress
        do {
            resolved = try await ConnectionResolver.shared.resolve(
                device: device,
                strategy: .ipFirst,
                timeout: 5.0
            )
        } catch let error as ConnectionResolver.ResolutionError {
            throw ConnectionError.resolutionFailed(error.localizedDescription)
        }
        
        // Use hostname.local for SMB if available (better for macOS file sharing)
        let connectionAddress: String
        if let hostname = resolved.hostname, resolved.method == .mDNSHostname {
            let cleanHost = hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
            connectionAddress = cleanHost
        } else {
            connectionAddress = resolved.address
        }
        
        let urlString: String
        if let username = username {
            let escapedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            urlString = "smb://\(escapedUser)@\(connectionAddress)"
        } else {
            urlString = "smb://\(connectionAddress)"
        }
        
        logger.info("📁 Connecting to file share: \(connectionAddress)")
        
        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidAddress
        }
        
        let success = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        
        if !success {
            throw ConnectionError.connectionFailed
        }
    }
    
    func connectToAFP(device: DiscoveredDevice, username: String? = nil) async throws {
        // Check if already mounted
        if let mountedURL = findMountedShare(for: device) {
            logger.info("📁 AFP: Already mounted at \(mountedURL.path), opening in Finder")
            await MainActor.run {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: mountedURL.path)
            }
            return
        }
        
        // Resolve address using hostname-first strategy
        let resolved: ConnectionResolver.ResolvedAddress
        do {
            resolved = try await ConnectionResolver.shared.resolve(
                device: device,
                strategy: .ipFirst,
                timeout: 5.0
            )
        } catch let error as ConnectionResolver.ResolutionError {
            throw ConnectionError.resolutionFailed(error.localizedDescription)
        }
        
        // Use hostname.local for AFP if available
        let connectionAddress: String
        if let hostname = resolved.hostname, resolved.method == .mDNSHostname {
            let cleanHost = hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
            connectionAddress = cleanHost
        } else {
            connectionAddress = resolved.address
        }
        
        let urlString: String
        if let username = username {
            let escapedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            urlString = "afp://\(escapedUser)@\(connectionAddress)"
        } else {
            urlString = "afp://\(connectionAddress)"
        }
        
        logger.info("📁 Connecting to AFP share: \(connectionAddress)")
        
        guard let url = URL(string: urlString) else {
            throw ConnectionError.invalidAddress
        }
        
        let success = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        
        if !success {
            throw ConnectionError.connectionFailed
        }
    }
    
    /// Finds a mounted network share that belongs to the target device
    private func findMountedShare(for device: DiscoveredDevice) -> URL? {
        let volumesPath = URL(fileURLWithPath: "/Volumes")
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: volumesPath,
            includingPropertiesForKeys: [.volumeIsRemovableKey, .volumeURLForRemountingKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        
        // Look for network volumes that might match the device
        for volumeURL in contents {
            // Check if it's a network volume
            if let remountURL = try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
               let host = remountURL.host {
                // Match by IP address or hostname
                let hostLower = host.lowercased()
                let deviceHost = device.hostname.lowercased().replacingOccurrences(of: ".local", with: "")
                let deviceName = device.name.lowercased()
                
                if host == device.ipAddress ||
                   hostLower == deviceHost ||
                   hostLower.contains(deviceName) ||
                   deviceName.contains(hostLower) {
                    return volumeURL
                }
            }
        }
        
        return nil
    }
    
    func connectToSSH(device: DiscoveredDevice, username: String? = nil) {
        let user = username ?? NSUserName()
        
        logger.info("🔌 SSH: Preparing connection to '\(device.name)'")
        
        // Use async task to resolve address
        Task {
            let host: String
            do {
                // Try to resolve using hostname-first strategy
                let resolved = try await ConnectionResolver.shared.resolve(
                    device: device,
                    strategy: .ipFirst,
                    timeout: 5.0
                )
                // Use hostname.local for SSH if available (more reliable)
                if let hostname = resolved.hostname, resolved.method == .mDNSHostname {
                    host = hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
                } else {
                    host = resolved.address
                }
                logger.info("🔌 SSH: Resolved host: \(host)")
            } catch {
                // Fall back to cached IP
                host = device.ipAddress
                logger.warning("🔌 SSH: Resolution failed, using cached IP: \(host)")
            }
            
            // Guard against invalid host
            guard !host.isEmpty, host != "Unknown", host != "Resolving..." else {
                logger.error("❌ SSH: Invalid host address: \(host)")
                return
            }
            
            guard Self.isSafeSSHComponent(user),
                  Self.isSafeSSHComponent(host) else {
                logger.error("❌ SSH: Rejected unsafe SSH target")
                return
            }

            let target = "\(user)@\(host)"
            let sshCommand = [
                "ssh",
                "-o",
                "StrictHostKeyChecking=accept-new",
                Self.shellSingleQuoted(target)
            ].joined(separator: " ")
            
            let appleScript = """
            tell application "Terminal"
                activate
                set newWindow to do script "\(Self.appleScriptEscaped(sshCommand))"
                set current settings of newWindow to settings set "Basic"
            end tell
            """
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            
            do {
                try process.run()
                logger.info("✅ SSH: Terminal launched for \(user)@\(host)")
            } catch {
                logger.error("❌ SSH: Failed to launch Terminal: \(error)")
                
                // Fallback: try opening terminal URL
                await MainActor.run {
                    var components = URLComponents()
                    components.scheme = "ssh"
                    components.user = user
                    components.host = host
                    if let url = components.url {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private static func isSafeSSHComponent(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+\-@]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    /// Test connection to a specific address and port
    func testConnection(to ipAddress: String, port: Int = 5900) async -> Bool {
        return await ConnectionResolver.shared.testConnection(address: ipAddress, port: port, timeout: 5.0)
    }
    
    /// Test connection to a device using smart resolution
    func testConnectionToDevice(_ device: DiscoveredDevice) async -> Bool {
        do {
            _ = try await ConnectionResolver.shared.resolve(
                device: device,
                strategy: .ipFirst,
                timeout: 5.0
            )
            // If we successfully resolved, the device is reachable
            return true
        } catch {
            logger.warning("🔌 Connection test failed for '\(device.name)': \(error.localizedDescription)")
            return false
        }
    }
    
    private func cleanupConnection(id: UUID) {
        connectionsLock.lock()
        if let connection = activeConnections[id] {
            connection.cancel()
        }
        connectionsLock.unlock()
    }
    
    // MARK: - Remote Screen Sharing Fix
    
    /// Restart the local Screen Sharing service (fixes "not permitted" error)
    /// This can be called locally or triggered remotely by another TidalDrift instance
    func restartLocalScreenSharing() async -> Bool {
        // Method 1: Try AppleScript (works without admin for toggle)
        let toggleScript = """
        tell application "System Preferences"
            reveal anchor "Services_ScreenSharing" of pane id "com.apple.preferences.sharing"
            activate
        end tell
        
        delay 0.5
        
        tell application "System Events"
            tell process "System Preferences"
                -- Find and toggle Screen Sharing
                try
                    set screenSharingRow to row 1 of table 1 of scroll area 1 of group 1 of window 1
                    set checkboxElement to checkbox 1 of screenSharingRow
                    
                    -- Toggle off then on
                    if value of checkboxElement is 1 then
                        click checkboxElement
                        delay 1
                        click checkboxElement
                    end if
                end try
            end tell
        end tell
        
        tell application "System Preferences" to quit
        """
        
        // Method 2: Use launchctl (may need sudo)
        let launchctlCommands = [
            "launchctl bootout system/com.apple.screensharing 2>/dev/null; sleep 1; launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null",
            "sudo launchctl kickstart -k system/com.apple.screensharing 2>/dev/null"
        ]
        
        // Try AppleScript first (user-friendly)
        var error: NSDictionary?
        if let script = NSAppleScript(source: toggleScript) {
            script.executeAndReturnError(&error)
            if error == nil {
                // Wait a moment for the service to restart
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return true
            }
        }
        
        // Fall back to launchctl
        for cmd in launchctlCommands {
            let result = ShellExecutor.execute(cmd)
            if result.exitCode == 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return true
            }
        }
        
        return false
    }
    
    /// Request a remote TidalDrift peer to restart its Screen Sharing service
    func requestRemoteScreenSharingRestart(ipAddress: String) async -> Bool {
        // Connect to the remote TidalDrift's control port
        let port: UInt16 = 5901 // TidalDrift's streaming port
        
        return await withCheckedContinuation { continuation in
            let host = NWEndpoint.Host(ipAddress)
            let portEndpoint = NWEndpoint.Port(rawValue: port)!
            let connection = NWConnection(host: host, port: portEndpoint, using: .tcp)
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
                    
                    // Send the restart command
                    let command = "RESTART_SCREEN_SHARING\n"
                    let data = Data(command.utf8)
                    
                    connection.send(content: data, completion: .contentProcessed { error in
                        guard !didResume.value else { return }
                        didResume.value = true
                        self?.cleanupConnection(id: connectionId)
                        
                        if error == nil {
                            continuation.resume(returning: true)
                        } else {
                            continuation.resume(returning: false)
                        }
                    })
                    
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
            
            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard !didResume.value else { return }
                didResume.value = true
                self?.cleanupConnection(id: connectionId)
                continuation.resume(returning: false)
            }
        }
    }
    
    /// Check if the "not permitted" error is happening
    func diagnoseScreenSharingError(for ipAddress: String) async -> ConnectionError? {
        // First check if port is even open
        let portOpen = await testConnection(to: ipAddress, port: 5900)
        
        if !portOpen {
            return .remoteServiceDown
        }
        
        // Try to do a VNC handshake to see if we get rejected
        // The "not permitted" error happens at the protocol level, not connection level
        // For now, we can't easily detect it programmatically before attempting
        // but we can check if TidalDrift is running on that machine
        
        let tidalDriftRunning = await testConnection(to: ipAddress, port: 5901)
        
        if !tidalDriftRunning {
            // TidalDrift not running, can't remotely fix
            return nil
        }
        
        return nil
    }
}
