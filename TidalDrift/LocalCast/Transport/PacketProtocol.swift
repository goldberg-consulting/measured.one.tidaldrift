import Foundation
import Network

struct LocalCastPacket {
    enum PacketType: UInt8 {
        case videoFrame = 1
        case inputEvent = 2
        case heartbeat = 3
        case stats = 4
        case keyframeRequest = 5
        case config = 6
        case appListRequest = 7      // Client requests list of streamable apps
        case appListResponse = 8     // Host sends list of streamable apps
        case streamAppRequest = 9    // Client requests to stream a specific app/window
        case streamAppResponse = 10  // Host confirms streaming started
        case windowResize = 11       // Client requests host to resize the streamed window
        case authRequest = 12        // Client sends 32-byte clientNonce
        case authChallenge = 13      // Host sends 32-byte hostNonce + encrypted session key
        case authComplete = 14       // Client sends proof encrypted with session key
        case authSuccess = 15        // Host confirms auth, encrypted with session key
        case focusAppRequest = 16    // Client asks host to bring an app to the foreground
        case isolateAppRequest = 17   // Client asks host to hide all apps except one (for VNC single-app view)
        case restoreAppsRequest = 18  // Client asks host to unhide previously isolated apps
        case qualityUpdate = 19       // Client sends streaming quality tuning snapshot to host
    }
    
    static let headerSize = 13 // 1 (type) + 4 (seq) + 8 (timestamp)
    
    let type: PacketType
    let sequenceNumber: UInt32
    let timestamp: TimeInterval
    let payload: Data
    
    func serialize() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(type.rawValue)
        
        var seq = sequenceNumber.bigEndian
        data.append(Data(bytes: &seq, count: 4))
        
        var ts = timestamp.bitPattern.bigEndian
        data.append(Data(bytes: &ts, count: 8))
        
        data.append(payload)
        return data
    }
    
    static func deserialize(_ data: Data) -> LocalCastPacket? {
        guard data.count >= headerSize else { return nil }
        
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> LocalCastPacket? in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            guard let packetType = PacketType(rawValue: base[0]) else { return nil }
            
            let seq = UInt32(base[1]) << 24 | UInt32(base[2]) << 16 | UInt32(base[3]) << 8 | UInt32(base[4])
            let tsBits = UInt64(base[5]) << 56 | UInt64(base[6]) << 48 | UInt64(base[7]) << 40 | UInt64(base[8]) << 32
                       | UInt64(base[9]) << 24 | UInt64(base[10]) << 16 | UInt64(base[11]) << 8 | UInt64(base[12])
            let ts = Double(bitPattern: tsBits)
            
            let payload = data.dropFirst(headerSize)
            return LocalCastPacket(type: packetType, sequenceNumber: seq, timestamp: ts, payload: Data(payload))
        }
    }
}
