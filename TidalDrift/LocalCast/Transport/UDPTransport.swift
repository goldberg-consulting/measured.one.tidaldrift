import Foundation
import Network
import CryptoKit
import OSLog

protocol UDPTransportDelegate: AnyObject {
    func udpTransport(_ transport: UDPTransport, didReceivePacket packet: LocalCastPacket, from endpoint: NWEndpoint)
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection)
}

extension UDPTransportDelegate {
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection) {}
}

// Fragment header for large packets
// Format: [frameId: UInt32][fragmentIndex: UInt16][totalFragments: UInt16][payloadLength: UInt16]
private struct FragmentHeader {
    static let size = 10  // 4 + 2 + 2 + 2
    let frameId: UInt32
    let fragmentIndex: UInt16
    let totalFragments: UInt16
    let payloadLength: UInt16
    
    func serialize() -> Data {
        var data = Data(capacity: FragmentHeader.size)
        var fid = frameId.bigEndian
        var fidx = fragmentIndex.bigEndian
        var ftotal = totalFragments.bigEndian
        var plen = payloadLength.bigEndian
        data.append(Data(bytes: &fid, count: 4))
        data.append(Data(bytes: &fidx, count: 2))
        data.append(Data(bytes: &ftotal, count: 2))
        data.append(Data(bytes: &plen, count: 2))
        return data
    }
    
    static func deserialize(_ data: Data) -> FragmentHeader? {
        guard data.count >= size else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> FragmentHeader? in
            guard let b = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let fid = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            let fidx = UInt16(b[4]) << 8 | UInt16(b[5])
            let ftotal = UInt16(b[6]) << 8 | UInt16(b[7])
            let plen = UInt16(b[8]) << 8 | UInt16(b[9])
            return FragmentHeader(frameId: fid, fragmentIndex: fidx, totalFragments: ftotal, payloadLength: plen)
        }
    }
}

class UDPTransport {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "UDPTransport")
    weak var delegate: UDPTransportDelegate?
    
    /// When set, all outgoing packets are encrypted and incoming packets are decrypted.
    /// Auth handshake packets travel in plaintext (prefix 0x00) before this is set.
    /// Protected by `sessionKeyLock`.
    private var _sessionKey: SymmetricKey?
    private let sessionKeyLock = NSLock()
    
    var sessionKey: SymmetricKey? {
        get { sessionKeyLock.lock(); defer { sessionKeyLock.unlock() }; return _sessionKey }
        set { sessionKeyLock.lock(); _sessionKey = newValue; sessionKeyLock.unlock() }
    }
    
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:] // Key by endpoint description for reliable lookup
    private var incomingConnections: [String: NWConnection] = [:] // Connections from clients (for host to reply on)
    private let queue = DispatchQueue(label: "com.tidaldrift.localcast.udp", qos: .userInteractive)
    private let connectionsLock = NSLock()
    
    // Fragmentation constants
    private let maxPayloadSize = 1400 // Larger payload per fragment (fits in 1500-byte ethernet MTU with IP/UDP headers)
    private var frameCounter: UInt32 = 0 // Protected by fragmentLock
    
    // Fragment reassembly
    private var fragmentBuffers: [UInt32: [UInt16: Data]] = [:] // frameId -> [fragmentIndex -> data]
    private var fragmentCounts: [UInt32: UInt16] = [:] // frameId -> totalFragments
    private let fragmentLock = NSLock()
    private var oldestBufferedFrameId: UInt32 = 0
    
    // Safety limits for fragment reassembly
    // Quality-focused encoding at 4K can produce keyframes of 2-5 MB.
    // At 1390 bytes/fragment, a 5 MB frame needs ~3,600 fragments.
    private let maxTotalFragments: UInt16 = 5000  // ~7 MB max per frame
    private let maxBufferedFrames = 120           // Allow more in-flight frames for high-throughput
    
    var localPort: UInt16? {
        listener?.port?.rawValue
    }
    
    /// Configure UDP parameters optimized for high-throughput streaming.
    private func configuredUDPParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Use .userInteractive service class to signal the OS this is latency-sensitive traffic.
        params.serviceClass = .interactiveVideo
        return params
    }
    
    func startListening(port: UInt16) throws {
        let params = configuredUDPParameters()
        
        let nwPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port {
                    self?.logger.info("UDP transport listening on port \(port.rawValue)")
                }
            case .failed(let error):
                self?.logger.error("UDP listener failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }
        
        listener?.start(queue: queue)
    }
    
    private func handleIncomingConnection(_ connection: NWConnection) {
        let endpointKey = describeEndpoint(connection.endpoint)
        
        connectionsLock.lock()
        incomingConnections[endpointKey] = connection
        connectionsLock.unlock()
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.logger.info("Client connected: \(endpointKey)")
                self.receive(on: connection, endpointKey: endpointKey)
                self.delegate?.udpTransport(self, clientDidConnect: connection.endpoint, connection: connection)
            case .failed(let error):
                self.logger.error("UDP connection failed: \(error.localizedDescription)")
                self.removeConnection(endpointKey: endpointKey)
            case .cancelled:
                self.removeConnection(endpointKey: endpointKey)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    func stopListening() {
        listener?.cancel()
        listener = nil
        
        connectionsLock.lock()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        incomingConnections.values.forEach { $0.cancel() }
        incomingConnections.removeAll()
        connectionsLock.unlock()
    }
    
    private let statsLock = NSLock()
    private var _sendCount = 0
    private var _receiveCount = 0
    
    /// Send packet using a specific connection (for replying on incoming connections)
    func send(packet: LocalCastPacket, on connection: NWConnection) {
        let raw = packet.serialize()
        statsLock.lock()
        _sendCount += 1
        let count = _sendCount
        statsLock.unlock()
        
        // Encrypt or wrap with plaintext flag
        let data: Data
        if let key = sessionKey {
            guard let encrypted = SessionCrypto.encrypt(raw, using: key) else {
                logger.error("Failed to encrypt packet of type \(packet.type.rawValue)")
                return
            }
            data = encrypted
        } else {
            data = SessionCrypto.wrapPlaintext(raw)
        }
        
        // Log non-video packets (input events, heartbeats, etc.)
        if packet.type != .videoFrame {
            print("📡 UDPTransport.send(on:): \(packet.type) #\(count), \(data.count) bytes, conn state: \(connection.state)")
        }
        
        // Warn if connection not ready
        if connection.state != .ready {
            if packet.type == .inputEvent {
                print("⚠️ UDPTransport: Connection NOT READY for input! State: \(connection.state)")
            }
        }
        
        // Check if we need to fragment
        if data.count > maxPayloadSize {
            sendFragmented(data: data, on: connection)
        } else {
            // Small packet, send directly with a "no fragment" header
            var noFragmentData = Data()
            let header = FragmentHeader(frameId: 0, fragmentIndex: 0, totalFragments: 1, payloadLength: UInt16(data.count))
            noFragmentData.append(header.serialize())
            noFragmentData.append(data)
            
            let packetType = packet.type // Capture for closure
            connection.send(content: noFragmentData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.logger.error("UDP send error: \(error.localizedDescription)")
                    print("❌ UDPTransport: Send error for \(packetType): \(error.localizedDescription)")
                } else if packetType == .inputEvent {
                    print("✅ UDPTransport: Input packet sent successfully")
                }
            })
        }
    }
    
    private func sendFragmented(data: Data, on connection: NWConnection) {
        fragmentLock.lock()
        frameCounter += 1
        let frameId = frameCounter
        fragmentLock.unlock()
        
        let payloadSize = maxPayloadSize - FragmentHeader.size
        let totalFragments = UInt16((data.count + payloadSize - 1) / payloadSize)
        
        for i in 0..<Int(totalFragments) {
            let start = i * payloadSize
            let end = min(start + payloadSize, data.count)
            let fragmentPayload = data[start..<end]
            
            let header = FragmentHeader(
                frameId: frameId,
                fragmentIndex: UInt16(i),
                totalFragments: totalFragments,
                payloadLength: UInt16(fragmentPayload.count)
            )
            
            var fragmentData = Data()
            fragmentData.append(header.serialize())
            fragmentData.append(fragmentPayload)
            
            connection.send(content: fragmentData, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.logger.error("UDP fragment send error: \(error.localizedDescription)")
                }
            })
        }
        
        if totalFragments > 1 {
            logger.debug("Sent \(totalFragments) fragments for frame \(frameId) (\(data.count) bytes)")
        }
    }
    
    func send(packet: LocalCastPacket, to endpoint: NWEndpoint) {
        let endpointKey = describeEndpoint(endpoint)
        
        // Verbose logging for input events
        if packet.type == .inputEvent {
            print("📡 UDPTransport.send(to:): Sending INPUT to \(endpointKey)")
        }
        
        connectionsLock.lock()
        // First check if we have an incoming connection from this endpoint (prefer this for replies)
        if let incomingConn = incomingConnections[endpointKey] {
            connectionsLock.unlock()
            if packet.type == .inputEvent {
                print("   Using INCOMING connection, state: \(incomingConn.state)")
            }
            send(packet: packet, on: incomingConn)
            return
        }
        
        // Otherwise use or create outgoing connection
        var connection: NWConnection
        var isNewConnection = false
        if let existing = connections[endpointKey] {
            connection = existing
            connectionsLock.unlock()
            if packet.type == .inputEvent {
                print("   Using EXISTING outgoing connection, state: \(connection.state)")
            }
        } else {
            connectionsLock.unlock()
            isNewConnection = true
            
            connection = NWConnection(to: endpoint, using: configuredUDPParameters())
            setupOutgoingConnection(connection, endpointKey: endpointKey)
            
            connectionsLock.lock()
            connections[endpointKey] = connection
            connectionsLock.unlock()
            
            if packet.type == .inputEvent {
                print("   Created NEW outgoing connection, state: \(connection.state)")
            }
        }
        
        // For input events on new connections, wait briefly for connection to be ready
        if packet.type == .inputEvent && isNewConnection {
            // Give the connection a moment to establish
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if packet.type == .inputEvent {
                    print("   Delayed send, connection state now: \(connection.state)")
                }
                self?.send(packet: packet, on: connection)
            }
        } else {
            send(packet: packet, on: connection)
        }
    }
    
    private func setupOutgoingConnection(_ connection: NWConnection, endpointKey: String) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection, endpointKey: endpointKey)
            case .failed(let error):
                self?.logger.error("UDP outgoing connection failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    private func receive(on connection: NWConnection, endpointKey: String) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data {
                self.handleReceivedData(data, from: connection.endpoint)
            }
            
            if error == nil && connection.state == .ready {
                self.receive(on: connection, endpointKey: endpointKey)
            }
        }
    }
    
    private func handleReceivedData(_ data: Data, from endpoint: NWEndpoint) {
        statsLock.lock()
        _receiveCount += 1
        let count = _receiveCount
        statsLock.unlock()
        
        if count <= 10 || count % 500 == 0 {
            print("📨 UDPTransport: handleReceivedData #\(count), \(data.count) bytes from \(describeEndpoint(endpoint))")
        }
        
        // Parse fragment header
        guard let header = FragmentHeader.deserialize(data) else {
            // Try parsing as raw packet (for backwards compatibility)
            if let packet = decryptAndParse(data) {
                if packet.type != .videoFrame {
                    print("📨 UDPTransport: Received \(packet.type) packet (raw, no fragment header)")
                }
                if packet.type == .inputEvent {
                    print("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            } else {
                print("⚠️ UDPTransport: Could not parse received data (\(data.count) bytes)")
            }
            return
        }
        
        let payload = data.dropFirst(FragmentHeader.size)
        
        // Single fragment (no reassembly needed)
        if header.totalFragments == 1 {
            if let packet = decryptAndParse(Data(payload)) {
                // Log non-video packets
                if packet.type != .videoFrame {
                    print("📨 UDPTransport: Received \(packet.type) packet #\(count), payload: \(packet.payload.count) bytes")
                }
                if packet.type == .inputEvent {
                    print("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            } else {
                print("⚠️ UDPTransport: Could not parse packet from payload (\(payload.count) bytes)")
            }
            return
        }
        
        // Multi-fragment: store and reassemble
        fragmentLock.lock()
        
        // Reject obviously bogus fragment counts (DoS protection)
        guard header.totalFragments > 0 && header.totalFragments <= maxTotalFragments else {
            fragmentLock.unlock()
            if header.totalFragments > maxTotalFragments {
                logger.warning("⚠️ Frame \(header.frameId) has \(header.totalFragments) fragments (limit: \(self.maxTotalFragments)) — dropped. Frame too large for UDP transport.")
            }
            return
        }
        
        // Initialize buffer for this frame if needed
        if fragmentBuffers[header.frameId] == nil {
            fragmentBuffers[header.frameId] = [:]
            fragmentCounts[header.frameId] = header.totalFragments
            
            if oldestBufferedFrameId == 0 { oldestBufferedFrameId = header.frameId }
            
            while fragmentBuffers.count > maxBufferedFrames {
                fragmentBuffers.removeValue(forKey: oldestBufferedFrameId)
                fragmentCounts.removeValue(forKey: oldestBufferedFrameId)
                oldestBufferedFrameId += 1
                while !fragmentBuffers.isEmpty && fragmentBuffers[oldestBufferedFrameId] == nil {
                    oldestBufferedFrameId += 1
                }
            }
        }
        
        // Store this fragment
        fragmentBuffers[header.frameId]?[header.fragmentIndex] = Data(payload)
        
        // Check if we have all fragments
        let received = fragmentBuffers[header.frameId]?.count ?? 0
        let total = Int(fragmentCounts[header.frameId] ?? 0)
        
        if received == total {
            // Reassemble
            var fullData = Data()
            for i in 0..<UInt16(total) {
                if let fragmentData = fragmentBuffers[header.frameId]?[i] {
                    fullData.append(fragmentData)
                }
            }
            
            // Clean up
            fragmentBuffers.removeValue(forKey: header.frameId)
            fragmentCounts.removeValue(forKey: header.frameId)
            fragmentLock.unlock()
            
            // Parse and deliver (decrypt if needed)
            if let packet = decryptAndParse(fullData) {
                logger.debug("Reassembled frame \(header.frameId): \(fullData.count) bytes from \(total) fragments")
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            }
        } else {
            fragmentLock.unlock()
        }
    }
    
    /// Strip the encryption/plaintext prefix and decrypt if needed, then parse.
    private func decryptAndParse(_ data: Data) -> LocalCastPacket? {
        guard !data.isEmpty else { return nil }
        
        if data[0] == SessionCrypto.encryptedFlag {
            // Encrypted payload — need session key
            guard let key = sessionKey else {
                logger.warning("Received encrypted packet but no session key set")
                return nil
            }
            guard let decrypted = SessionCrypto.decrypt(data, using: key) else {
                logger.warning("Failed to decrypt packet (\(data.count) bytes)")
                return nil
            }
            return LocalCastPacket.deserialize(decrypted)
        } else if data[0] == SessionCrypto.plaintextFlag {
            // Plaintext (auth handshake)
            guard let unwrapped = SessionCrypto.unwrapPlaintext(data) else { return nil }
            return LocalCastPacket.deserialize(unwrapped)
        } else {
            // Legacy/raw packet (no prefix) — backwards compat
            return LocalCastPacket.deserialize(data)
        }
    }
    
    private func removeConnection(endpointKey: String) {
        connectionsLock.lock()
        connections.removeValue(forKey: endpointKey)
        incomingConnections.removeValue(forKey: endpointKey)
        connectionsLock.unlock()
    }
    
    private func describeEndpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "\(endpoint)"
        }
    }
}

