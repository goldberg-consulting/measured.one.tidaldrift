import Foundation

struct ShellExecutor {

    typealias Result = (output: String, exitCode: Int32)

    /// Default wall-clock limit for a child process. Callers that expect a
    /// long-running child pass their own.
    static let defaultTimeout: TimeInterval = 30

    /// Environment handed to every child. PATH is pinned to system
    /// directories so tools referenced by bare name (`osascript`, `tccutil`,
    /// `arp`) cannot be shadowed by a user-writable PATH entry, and the
    /// login shell's rc files are never sourced (`zsh -f`).
    private static let childEnvironment: [String: String] = {
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }()

    // MARK: - Input Sanitization

    /// Sanitize input to prevent shell injection attacks
    private static func sanitizeForShell(_ input: String) -> String {
        // Only allow alphanumeric, dots, hyphens, underscores, and colons
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        return input.unicodeScalars.filter { allowedCharacters.contains($0) }.map { String($0) }.joined()
    }

    /// Validate IP address format
    private static func isValidIPAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }

    /// Validate hostname format
    private static func isValidHostname(_ hostname: String) -> Bool {
        let pattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)*$"
        return hostname.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Execution

    /// Run `command` through `/bin/zsh -f -c`. Only for scripts that need
    /// shell syntax (pipes, loops). Anything carrying untrusted or
    /// privileged arguments should use `execute(executable:arguments:)`.
    @discardableResult
    static func execute(_ command: String, timeout: TimeInterval = defaultTimeout) -> Result {
        run(executable: "/bin/zsh", arguments: ["-f", "-c", command], timeout: timeout)
    }

    /// Run an executable at an absolute path with argv passed through
    /// unchanged; no shell is involved.
    @discardableResult
    static func execute(executable: String, arguments: [String], timeout: TimeInterval = defaultTimeout) -> Result {
        run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Spawns the child, drains stdout+stderr on a readability handler (so a
    /// chatty child never blocks on a full pipe), and terminates it if it
    /// outlives `timeout`. A timed-out child reports exit code -1.
    private static func run(executable: String, arguments: [String], timeout: TimeInterval) -> Result {
        let task = Process()
        let pipe = Pipe()
        let outputLock = NSLock()
        var outputData = Data()

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.environment = childEnvironment
        task.standardOutput = pipe
        task.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            outputData.append(data)
            outputLock.unlock()
        }

        do {
            try task.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (output: "Failed to execute: \(error.localizedDescription)", exitCode: -1)
        }

        let timedOut = AtomicFlag(false)
        let watchdog = DispatchWorkItem {
            guard task.isRunning else { return }
            timedOut.value = true
            task.terminate()
            // SIGTERM can be ignored; give it a moment, then SIGKILL.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()

        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.availableData
        outputLock.lock()
        outputData.append(remaining)
        let data = outputData
        outputLock.unlock()
        let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return (output: output, exitCode: timedOut.value ? -1 : task.terminationStatus)
    }

    static func executeAsync(_ command: String, completion: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(command)
            DispatchQueue.main.async {
                completion(result.output, result.exitCode)
            }
        }
    }

    /// Run an AppleScript snippet with `/usr/bin/osascript`. The script is
    /// passed as argv, never through a shell.
    @discardableResult
    static func osascript(_ script: String, timeout: TimeInterval = 120) -> Result {
        execute(executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: timeout)
    }

    static func checkCommandExists(_ command: String) -> Bool {
        // Sanitize command name to prevent injection
        let safeCommand = sanitizeForShell(command)
        guard !safeCommand.isEmpty else { return false }
        let result = execute(executable: "/usr/bin/which", arguments: [safeCommand])
        return result.exitCode == 0 && !result.output.isEmpty
    }

    static func getSystemVersion() -> String {
        execute(executable: "/usr/bin/sw_vers", arguments: ["-productVersion"]).output
    }

    static func getHostname() -> String {
        execute(executable: "/bin/hostname", arguments: []).output
    }

    static func ping(_ host: String, count: Int = 1, timeout: Int = 2) -> Bool {
        // Validate host to prevent command injection
        guard isValidIPAddress(host) || isValidHostname(host) else {
            return false
        }
        let safeHost = sanitizeForShell(host)
        let result = execute(
            executable: "/sbin/ping",
            arguments: ["-c", "\(count)", "-t", "\(timeout)", safeHost],
            timeout: TimeInterval(count * (timeout + 1) + 5))
        return result.exitCode == 0
    }

    static func openSystemPreference(_ pane: String) {
        // Sanitize pane name
        let safePane = sanitizeForShell(pane)
        guard !safePane.isEmpty else { return }
        execute(executable: "/usr/bin/open", arguments: ["x-apple.systempreferences:\(safePane)"])
    }
}
