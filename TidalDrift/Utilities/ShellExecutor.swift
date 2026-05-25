import Foundation

struct ShellExecutor {
    
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
    
    @discardableResult
    static func execute(_ command: String, arguments: [String] = []) -> (output: String, exitCode: Int32) {
        let task = Process()
        let pipe = Pipe()
        let outputLock = NSLock()
        var outputData = Data()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        
        if !arguments.isEmpty {
            let fullCommand = ([command] + arguments).joined(separator: " ")
            task.arguments = ["-c", fullCommand]
        }
        
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            outputData.append(data)
            outputLock.unlock()
        }

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (output: "Failed to execute: \(error.localizedDescription)", exitCode: -1)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.availableData
        outputLock.lock()
        outputData.append(remaining)
        let data = outputData
        outputLock.unlock()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return (output: output.trimmingCharacters(in: .whitespacesAndNewlines), exitCode: task.terminationStatus)
    }

    @discardableResult
    static func execute(executable: String, arguments: [String]) -> (output: String, exitCode: Int32) {
        let task = Process()
        let pipe = Pipe()
        let outputLock = NSLock()
        var outputData = Data()

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
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
            task.waitUntilExit()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (output: "Failed to execute: \(error.localizedDescription)", exitCode: -1)
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.availableData
        outputLock.lock()
        outputData.append(remaining)
        let data = outputData
        outputLock.unlock()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output: output.trimmingCharacters(in: .whitespacesAndNewlines), exitCode: task.terminationStatus)
    }
    
    static func executeAsync(_ command: String, completion: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = execute(command)
            DispatchQueue.main.async {
                completion(result.output, result.exitCode)
            }
        }
    }
    
    
    static func checkCommandExists(_ command: String) -> Bool {
        // Sanitize command name to prevent injection
        let safeCommand = sanitizeForShell(command)
        guard !safeCommand.isEmpty else { return false }
        let result = execute("which \(safeCommand)")
        return result.exitCode == 0 && !result.output.isEmpty
    }
    
    static func getSystemVersion() -> String {
        let result = execute("sw_vers -productVersion")
        return result.output
    }
    
    static func getHostname() -> String {
        let result = execute("hostname")
        return result.output
    }
    
    static func ping(_ host: String, count: Int = 1, timeout: Int = 2) -> Bool {
        // Validate host to prevent command injection
        guard isValidIPAddress(host) || isValidHostname(host) else {
            return false
        }
        let safeHost = sanitizeForShell(host)
        let result = execute("ping -c \(count) -t \(timeout) \(safeHost)")
        return result.exitCode == 0
    }
    
    static func openSystemPreference(_ pane: String) {
        // Sanitize pane name
        let safePane = sanitizeForShell(pane)
        guard !safePane.isEmpty else { return }
        execute("open 'x-apple.systempreferences:\(safePane)'")
    }
}
