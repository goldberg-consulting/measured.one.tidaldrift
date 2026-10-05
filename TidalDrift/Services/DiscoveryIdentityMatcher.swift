import Foundation

/// Remembered adapter addresses are connection candidates, not device identity.
/// In particular, DHCP can assign a former address to a different computer.
enum DiscoveryIdentityMatcher {
    static func matchingKey(in cache: [String: DiscoveredDevice], for incoming: DiscoveredDevice) -> String? {
        let peerID = DiscoveredDevice.normalizedIdentityComponent(incoming.peerId)
        let compatible = cache.filter { _, existing in
            guard let peerID, let existingID = DiscoveredDevice.normalizedIdentityComponent(existing.peerId) else { return true }
            return peerID == existingID
        }
        if let peerID,
           let match = compatible.first(where: { DiscoveredDevice.normalizedIdentityComponent($0.value.peerId) == peerID }) {
            return match.key
        }

        if let hostname = DiscoveredDevice.normalizedHostname(incoming.hostname) {
            let matches = compatible.filter { DiscoveredDevice.normalizedHostname($0.value.hostname) == hostname }
            if matches.count == 1 { return matches.first?.key }
            if matches.count > 1 { return nil }
        }

        guard NetworkUtils.isValidIPAddress(incoming.ipAddress) else { return nil }
        let matches = compatible.filter { _, existing in
            guard existing.ipAddress == incoming.ipAddress else { return false }
            let sameName = !incoming.name.isEmpty &&
                existing.name.caseInsensitiveCompare(incoming.name) == .orderedSame
            // A raw subnet scan has no host identity yet. It can be enriched
            // only while it has no peer identity, trust, or credential reference.
            let anonymous = existing.name.hasPrefix("Mac at ") &&
                DiscoveredDevice.normalizedIdentityComponent(existing.peerId) == nil &&
                !existing.isTrusted && existing.savedCredentialRef == nil
            if anonymous { return true }
            if let existingHost = DiscoveredDevice.normalizedHostname(existing.hostname),
               let incomingHost = DiscoveredDevice.normalizedHostname(incoming.hostname),
               existingHost != incomingHost { return false }
            return sameName
        }
        return matches.count == 1 ? matches.first?.key : nil
    }
}
