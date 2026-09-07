import Foundation

/// Frames UTF-8 helper output across pipe reads and bounds incomplete-line memory.
/// All mutable state is protected by `lock`, including concurrent append calls.
final class DiscoveryLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var discardingLine = false
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int = 16_384) {
        self.maximumLineBytes = max(maximumLineBytes, 1)
    }

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                if !discardingLine, let line = String(data: pending, encoding: .utf8) {
                    lines.append(line.trimmingCharacters(in: .newlines))
                }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if pending.count < maximumLineBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        return lines
    }
}

enum BonjourParsing {
    static func normalizedServiceName(_ name: String) -> String {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasSuffix(".") { normalized.removeLast() }
        if normalized.hasSuffix(".local") { normalized = String(normalized.dropLast(6)) }
        return normalized
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Match complete service names only; a short name must not match another Mac's prefix.
    static func localCastNameMatches(_ name: String, deviceName: String, hostname: String) -> Bool {
        let normalized = normalizedServiceName(name)
        guard !normalized.isEmpty else { return false }
        return normalizedServiceName(deviceName) == normalized || normalizedServiceName(hostname) == normalized
    }

}
