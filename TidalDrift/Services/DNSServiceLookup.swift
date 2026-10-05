import Foundation
import OSLog

/// Bounded subprocess lookup used by Bonjour discovery on its resolver queue.
func runDnsSdLookup(name: String, type: String, domain: String, timeout: TimeInterval, maxLines: Int, logger: Logger) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
    process.arguments = ["-L", name, type, domain]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let outputLock = NSLock()
    var outputData = Data()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil; return }
        outputLock.lock()
        outputData.append(data)
        outputLock.unlock()
    }
    process.terminationHandler = { _ in
        finished.signal()
    }
    do {
        try process.run()
    } catch {
        logger.warning("dns-sd -L failed to start for \(name): \(error.localizedDescription)")
        return ""
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let remaining = pipe.fileHandleForReading.availableData
    outputLock.lock()
    outputData.append(remaining)
    let data = outputData
    outputLock.unlock()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output
        .split(separator: "\n")
        .prefix(maxLines)
        .joined(separator: "\n")
}

