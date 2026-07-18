import Foundation

extension TidalDriftTestRunner {
    func testPeerIdentityStableAcrossIPChange() async -> (Bool, String) {
        let peerId = "peer-\(UUID().uuidString)"
        let first = DiscoveredDevice(
            name: "Studio Mac",
            hostname: "studio-mac.local",
            ipAddress: "192.168.1.20",
            peerId: peerId
        )
        let second = DiscoveredDevice(
            name: "Studio Mac",
            hostname: "studio-mac.local",
            ipAddress: "192.168.1.87",
            peerId: peerId
        )

        guard first.discoveryKey == second.discoveryKey else {
            return (false, "Peer discovery key changed across IPs: \(first.discoveryKey) vs \(second.discoveryKey)")
        }
        guard first.identityKey == second.identityKey else {
            return (false, "Peer identity key changed across IPs: \(first.identityKey) vs \(second.identityKey)")
        }
        guard first.identityKey == "peer:\(peerId.lowercased())" else {
            return (false, "Peer identity key did not use peer ID: \(first.identityKey)")
        }
        guard first.credentialAliases.contains("host:studio-mac.local") else {
            return (false, "Hostname alias missing from credential aliases: \(first.credentialAliases)")
        }
        guard first.credentialAliases.first == first.identityKey else {
            return (false, "Canonical alias is not the identity key: \(first.credentialAliases)")
        }
        return (true, "Peer ID keys secrets across IP changes, hostname retained as alias")
    }

    func testHostnameIdentityFallback() async -> (Bool, String) {
        let first = DiscoveredDevice(
            name: "Office Mac",
            hostname: "Office-Mac",
            ipAddress: "10.0.0.10"
        )
        let second = DiscoveredDevice(
            name: "Office Mac",
            hostname: "office-mac.local",
            ipAddress: "10.0.0.42"
        )

        guard first.identityKey == second.identityKey else {
            return (false, "Hostname identity changed across IPs: \(first.identityKey) vs \(second.identityKey)")
        }
        guard first.identityKey == "host:office-mac.local" else {
            return (false, "Hostname identity did not normalize to .local: \(first.identityKey)")
        }
        return (true, "Hostname fallback normalizes and ignores IP changes")
    }

    func testLegacyStableIdRemainsAvailable() async -> (Bool, String) {
        let device = DiscoveredDevice(
            name: "Legacy Mac",
            hostname: "legacy-mac.local",
            ipAddress: "192.168.50.12"
        )

        guard device.stableId == "legacy-mac_192.168.50.12" else {
            return (false, "Legacy stableId changed unexpectedly: \(device.stableId)")
        }
        guard device.identityKey != device.stableId else {
            return (false, "New identity key still matches legacy stableId")
        }
        return (true, "Legacy stableId remains available for migration")
    }
}
