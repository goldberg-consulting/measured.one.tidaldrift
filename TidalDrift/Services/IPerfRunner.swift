import Foundation
import Darwin

/// Runs the bundled helper directly (never through a shell). File-backed output avoids
/// pipe deadlocks; each process is bounded and reaped on completion or cancellation.
@MainActor
final class IPerfRunner {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    private let process = Process()
    private let directory: URL
    private let outputURL: URL
    private let errorURL: URL
    private let output: FileHandle
    private let errors: FileHandle

    static func executable() throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iperf3")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        throw Failure.message("The network-test helper is missing. Install a complete TidalDrift build on both Macs.")
    }

    init(executable: URL, arguments: [String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tidaldrift-iperf-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        outputURL = directory.appendingPathComponent("output")
        errorURL = directory.appendingPathComponent("error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        output = try FileHandle(forWritingTo: outputURL)
        errors = try FileHandle(forWritingTo: errorURL)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // Keep readiness text predictable regardless of the user's locale.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        do { try process.run() } catch {
            try? output.close()
            try? errors.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() {
        if process.isRunning {
            // SIGKILL also handles helpers stuck in a socket operation; wait reaps the child.
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? output.close()
        try? errors.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func waitForServer() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: outputURL),
               String(data: data, encoding: .utf8)?.contains("Server listening on") == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.message("The peer could not start its network-test helper. Another test may be running.")
    }

    func result(timeout: Duration = .seconds(15)) async throws -> Data {
        defer { stop() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.message("The network test timed out.") }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let data = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            // Parse iperf's structured error first; never interpret missing results as loss.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["error"] as? String { throw Failure.message("Network test: \(message)") }
            throw Failure.message("The network-test helper stopped unexpectedly. Check that both Macs have the current app.")
        }
        return data
    }

    struct Measurement: Sendable {
        let mbps: Double
        let udp: UDPStatistics?
    }

    struct UDPStatistics: Sendable {
        let senderMbps: Double
        let lossPercent: Double
        let jitterMs: Double
    }

    /// Both normal and reverse tests use receiver statistics. Sender-side UDP loss
    /// is always zero and would hide the exact failure this test is meant to detect.
    static func parse(_ data: Data, udp: Bool) throws -> Measurement {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.message("Invalid network-test response.")
        }
        if let error = root["error"] as? String { throw Failure.message("Network test: \(error)") }
        guard let end = root["end"] as? [String: Any],
              let received = end["sum_received"] as? [String: Any],
              let bits = received["bits_per_second"] as? Double, bits.isFinite, bits >= 0,
              let seconds = received["seconds"] as? Double, seconds.isFinite, seconds > 0 else {
            throw Failure.message("The peer returned an incomplete network measurement. Update both Macs.")
        }
        if udp {
            guard let sent = end["sum_sent"] as? [String: Any],
                  let senderBits = sent["bits_per_second"] as? Double, senderBits.isFinite, senderBits > 0,
                  let senderSeconds = sent["seconds"] as? Double, senderSeconds.isFinite, senderSeconds > 0 else {
                throw Failure.message("The peer did not return a measured UDP sending rate.")
            }
            guard let packets = received["packets"] as? Double, packets > 0,
                  let loss = received["lost_percent"] as? Double, loss.isFinite, (0...100).contains(loss),
                  let jitter = received["jitter_ms"] as? Double, jitter.isFinite, jitter >= 0 else {
                throw Failure.message("The peer did not return valid UDP receiver statistics.")
            }
            return Measurement(mbps: bits / 1_000_000, udp: UDPStatistics(
                senderMbps: senderBits / 1_000_000, lossPercent: loss, jitterMs: jitter))
        }
        return Measurement(mbps: bits / 1_000_000, udp: nil)
    }

    static func clientArguments(host: String, localAddress: String, port: UInt16,
                                reverse: Bool, udpRateMbps: Double? = nil) -> [String] {
        var arguments = ["-4", "-c", host, "-B", localAddress, "-p", String(port), "-J", "-t", "5",
                         "--connect-timeout", "3000", "--rcv-timeout", "5000"]
        if reverse { arguments.append("-R") }
        if let rate = udpRateMbps {
            arguments += ["-u", "-b", String(Int(rate * 1_000_000)), "-l", "1400"]
        } else {
            arguments += ["-O", "1"]
        }
        return arguments
    }
}
