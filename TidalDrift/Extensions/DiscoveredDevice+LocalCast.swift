import Foundation
import Network

extension DiscoveredDevice {
    /// Whether this device advertises LocalCast support
    var supportsLocalCast: Bool {
        services.contains(.localCast)
    }
    
    /// The LocalCast-specific endpoint (if available)
    var localCastEndpoint: NWEndpoint? {
        NWEndpoint.hostPort(host: NWEndpoint.Host(ipAddress), port: NWEndpoint.Port(rawValue: LocalCastConfiguration.hostPort)!)
    }
}

struct LocalCastCapabilities: Codable {
    let version: Int
    let supportedCodecs: [LocalCastConfiguration.Codec]
    let maxResolution: CGSize
}





