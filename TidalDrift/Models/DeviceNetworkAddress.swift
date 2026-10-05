import Foundation

/// The remote adapter type is advertised by its owner, never inferred from en0/en1.
struct DeviceNetworkAddress: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case wifi, ethernet, other
        var label: String {
            switch self {
            case .wifi: return "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .other: return "Network"
            }
        }
    }
    let address: String
    let kind: Kind

    /// Keep the entire DNS-SD TXT string below its 255-byte limit.
    static func txtValue(_ addresses: [Self]) -> String {
        var value = ""
        for endpoint in addresses {
            let item = "\(endpoint.address)|\(endpoint.kind.rawValue)"
            let next = value.isEmpty ? item : value + "," + item
            guard next.utf8.count <= 240 else { break }
            value = next
        }
        return value
    }

    static func fromTXT(_ value: String?) -> [Self]? {
        guard let value else { return nil }
        var seen = Set<String>()
        return value.split(separator: ",").prefix(16).compactMap { item in
            let parts = item.split(separator: "|")
            guard parts.count == 2 else { return nil }
            let address = String(parts[0])
            guard NetworkUtils.isValidIPAddress(address), seen.insert(address).inserted else { return nil }
            return Self(address: address, kind: Kind(rawValue: String(parts[1])) ?? .other)
        }
    }
}
