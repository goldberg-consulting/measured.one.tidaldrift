import Foundation
import Network
import CryptoKit
import OSLog

/// Debug-only console logging for the realtime LocalCast pipeline.
///
/// The capture, encode, transport, decode, and input-injection paths run on
/// latency-sensitive queues at up to the stream frame rate. Plain `print`
/// performs synchronous stdio on those queues, which shows up as sustained
/// CPU and stutter under load. Routing those diagnostics through this helper
/// keeps them in DEBUG builds while compiling them (and the cost of building
/// their interpolated strings) entirely out of release.
@inline(__always)
func lcDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

protocol UDPTransportDelegate: AnyObject {
    func udpTransport(_ transport: UDPTransport, didReceivePacket packet: LocalCastPacket, from endpoint: NWEndpoint)
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection)
    /// Called when reassembly abandons one or more incomplete frames because a
    /// newer frame superseded them (i.e. at least one fragment was lost). The
    /// receiver can use this to request recovery (e.g. a keyframe).
    func udpTransportDidLoseFrames(_ transport: UDPTransport)
}

extension UDPTransportDelegate {
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection) {}
    func udpTransportDidLoseFrames(_ transport: UDPTransport) {}
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
    private var frameDroppable: [UInt32: Bool] = [:]   // frameId -> droppable (video) vs reliable (tile)
    private let fragmentLock = NSLock()

    // Drop-to-newest reassembly. The sender's frameId increments per frame, so a
    // frame still missing fragments once newer frames are arriving will never
    // complete. Rather than buffer a long backlog (latency) or wait out the
    // straggler, abandon frames that fall behind the newest by more than this
    // window and treat any abandoned-incomplete frame as a loss.
    var dropToNewestEnabled = UserDefaults.standard.object(forKey: "localCastDropToNewest") as? Bool ?? true
    private var highestFrameId: UInt32 = 0
    private let inFlightFrameWindow: UInt32 = 4
    
    // Safety limits for fragment reassembly
    // Quality-focused encoding at 4K can produce keyframes of 2-5 MB.
    // At 1390 bytes/fragment, a 5 MB frame needs ~3,600 fragments.
    private let maxTotalFragments: UInt16 = 5000  // ~7 MB max per frame
    private let maxBufferedFrames = 120           // Allow more in-flight frames for high-throughput

    // Paced fragment sending.
    // A keyframe is hundreds of fragments. Handing them all to the network
    // stack in one tight loop overruns the Wi-Fi uplink, which sheds ~13% of
    // the burst (measured) — and losing a single fragment makes the whole
    // frame undecodable, since there is no FEC or retransmit. Draining large
    // frames in small bursts with a short gap keeps the in-flight queue under
    // the uplink's instantaneous capacity and largely removes that loss.
    private let pacingFragmentThreshold = 12   // frames at/below this go out unpaced
    private let pacingBatchSize = 16           // fragments per paced burst
    private let pacingGapMicros = 700          // gap between bursts (~256 Mbps ceiling)
    private let paceQueue = DispatchQueue(label: "com.tidaldrift.localcast.sendpace", qos: .userInteractive)

    // Forward error correction (XOR parity). When enabled (host/sender side),
    // each block of `fecBlockSize` video data fragments gets one parity fragment
    // = XOR of the block's payloads (zero-padded to the fragment payload size).
    // The receiver can reconstruct exactly one lost data fragment per block
    // without a retransmit. Parity reuses the 10-byte fragment header with the
    // high bit of `fragmentIndex` set, so the wire format is unchanged for peers
    // that don't understand FEC (they simply ignore parity, since it's kept in a
    // separate buffer and never counted toward frame completion). Recovery on
    // the receiver is always attempted; only the sender's parity emission is
    // gated by the toggle.
    var fecEnabled = UserDefaults.standard.object(forKey: "localCastFEC") as? Bool ?? false
    private let fecBlockSize = 16
    private static let fecParityFlag: UInt16 = 0x8000
    private var parityBuffers: [UInt32: [UInt16: Data]] = [:] // frameId -> blockIndex -> parity payload
    private var _fecRecovered = 0  // guarded by fragmentLock
    
    var localPort: UInt16? {
        listener?.port?.rawValue
    }
    
    /// Configure UDP parameters optimized for high-throughput streaming.
    private func configuredUDPParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        // Use .userInteractive service class to signal the OS this is latency-sensitive traffic.
        params.serviceClass = .interactiveVideo
        // Pin to IPv4. LocalCast clients resolve hosts to IPv4 addresses
        // (ConnectionResolver uses AF_INET), but NWListener can otherwise bind
        // IPv6-only, leaving the host unreachable on IPv4 — the client's
        // heartbeats get no reply ("no response from host"). Forcing v4 keeps
        // the listener and the client on the same family.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
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
            lcDebug("📡 UDPTransport.send(on:): \(packet.type) #\(count), \(data.count) bytes, conn state: \(connection.state)")
        }
        
        // Warn if connection not ready
        if connection.state != .ready {
            if packet.type == .inputEvent {
                lcDebug("⚠️ UDPTransport: Connection NOT READY for input! State: \(connection.state)")
            }
        }
        
        // Check if we need to fragment. Only video frames are "droppable" by the
        // receiver's drop-to-newest reassembly; tiles and control packets must
        // be delivered whole (a lost tile is healed by periodic refresh instead).
        if data.count > maxPayloadSize {
            sendFragmented(data: data, on: connection, droppable: packet.type == .videoFrame)
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
                    lcDebug("❌ UDPTransport: Send error for \(packetType): \(error.localizedDescription)")
                } else if packetType == .inputEvent {
                    lcDebug("✅ UDPTransport: Input packet sent successfully")
                }
            })
        }
    }
    
    /// Top bit of the wire frameId marks a frame as droppable (video). The
    /// receiver's drop-to-newest reassembly only discards droppable frames; the
    /// remaining 31 bits are the frame counter (wraps after ~414 days at 60fps).
    static let droppableFrameFlag: UInt32 = 0x8000_0000

    private func sendFragmented(data: Data, on connection: NWConnection, droppable: Bool) {
        fragmentLock.lock()
        frameCounter += 1
        let frameId = (frameCounter & ~Self.droppableFrameFlag) | (droppable ? Self.droppableFrameFlag : 0)
        fragmentLock.unlock()
        
        let payloadSize = maxPayloadSize - FragmentHeader.size
        let totalFragments = UInt16((data.count + payloadSize - 1) / payloadSize)
        
        var fragments: [Data] = []
        fragments.reserveCapacity(Int(totalFragments))
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
            fragments.append(fragmentData)
        }

        // Optionally interleave one XOR parity fragment after each block of data
        // fragments, so the receiver can recover a single lost fragment per block.
        var sendList = fragments
        if fecEnabled && droppable && totalFragments > 1 {
            sendList = []
            sendList.reserveCapacity(fragments.count + fragments.count / fecBlockSize + 1)
            var index = 0
            var blockIndex: UInt16 = 0
            while index < fragments.count {
                let blockEnd = min(index + fecBlockSize, fragments.count)
                for j in index..<blockEnd { sendList.append(fragments[j]) }

                let parityPayload = xorParity(of: data, fragmentRange: index..<blockEnd, payloadSize: payloadSize)
                let parityHeader = FragmentHeader(
                    frameId: frameId,
                    fragmentIndex: Self.fecParityFlag | blockIndex,
                    totalFragments: totalFragments,
                    payloadLength: UInt16(parityPayload.count)
                )
                var parityData = Data()
                parityData.append(parityHeader.serialize())
                parityData.append(parityPayload)
                sendList.append(parityData)

                index = blockEnd
                blockIndex += 1
            }
        }

        // Small frames go out immediately; pacing them would only add latency
        // and they are too small to overrun the uplink.
        if totalFragments <= pacingFragmentThreshold {
            for fragment in sendList {
                connection.send(content: fragment, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        self?.logger.error("UDP fragment send error: \(error.localizedDescription)")
                    }
                })
            }
            return
        }
        
        // Large frames: drain in small bursts so the uplink isn't overrun.
        paceFragments(sendList, on: connection, frameId: frameId)
    }

    /// Number of fragments recovered via FEC since the last call; resets the
    /// counter. Read once per second by the client for the stats HUD.
    func takeFECRecovered() -> Int {
        fragmentLock.lock(); defer { fragmentLock.unlock() }
        let v = _fecRecovered
        _fecRecovered = 0
        return v
    }

    /// XOR of the given data fragments (each zero-padded to `payloadSize`),
    /// forming the parity payload for one FEC block.
    private func xorParity(of data: Data, fragmentRange: Range<Int>, payloadSize: Int) -> Data {
        var parity = [UInt8](repeating: 0, count: payloadSize)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buf.count
            for i in fragmentRange {
                let start = i * payloadSize
                guard start < count else { continue }
                let end = min(start + payloadSize, count)
                var k = 0
                var p = start
                while p < end {
                    parity[k] ^= base[p]
                    k += 1
                    p += 1
                }
            }
        }
        return Data(parity)
    }
    
    /// Drain a frame's fragments in small bursts separated by a short gap,
    /// keeping the instantaneous send rate under the uplink's capacity so the
    /// burst isn't partially dropped. Runs on `paceQueue` off the encoder's
    /// callback queue.
    private func paceFragments(_ fragments: [Data], on connection: NWConnection, frameId: UInt32) {
        let total = fragments.count
        let batchSize = pacingBatchSize
        let gap = DispatchTimeInterval.microseconds(pacingGapMicros)
        
        func drain(from start: Int) {
            let end = min(start + batchSize, total)
            for i in start..<end {
                connection.send(content: fragments[i], completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        self?.logger.error("UDP fragment send error: \(error.localizedDescription)")
                    }
                })
            }
            if end < total {
                paceQueue.asyncAfter(deadline: .now() + gap) { drain(from: end) }
            } else {
                logger.debug("Paced \(total) fragments for frame \(frameId)")
            }
        }
        
        paceQueue.async { drain(from: 0) }
    }
    
    func send(packet: LocalCastPacket, to endpoint: NWEndpoint) {
        let endpointKey = describeEndpoint(endpoint)
        
        // Verbose logging for input events
        if packet.type == .inputEvent {
            lcDebug("📡 UDPTransport.send(to:): Sending INPUT to \(endpointKey)")
        }
        
        connectionsLock.lock()
        // First check if we have an incoming connection from this endpoint (prefer this for replies)
        if let incomingConn = incomingConnections[endpointKey] {
            connectionsLock.unlock()
            if packet.type == .inputEvent {
                lcDebug("   Using INCOMING connection, state: \(incomingConn.state)")
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
                lcDebug("   Using EXISTING outgoing connection, state: \(connection.state)")
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
                lcDebug("   Created NEW outgoing connection, state: \(connection.state)")
            }
        }
        
        // For input events on new connections, wait briefly for connection to be ready
        if packet.type == .inputEvent && isNewConnection {
            // Give the connection a moment to establish
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if packet.type == .inputEvent {
                    lcDebug("   Delayed send, connection state now: \(connection.state)")
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
            lcDebug("📨 UDPTransport: handleReceivedData #\(count), \(data.count) bytes from \(describeEndpoint(endpoint))")
        }
        
        // Parse fragment header
        guard let header = FragmentHeader.deserialize(data) else {
            // Try parsing as raw packet (for backwards compatibility)
            if let packet = decryptAndParse(data) {
                if packet.type != .videoFrame {
                    lcDebug("📨 UDPTransport: Received \(packet.type) packet (raw, no fragment header)")
                }
                if packet.type == .inputEvent {
                    lcDebug("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            } else {
                lcDebug("⚠️ UDPTransport: Could not parse received data (\(data.count) bytes)")
            }
            return
        }
        
        let payload = data.dropFirst(FragmentHeader.size)
        
        // Single fragment (no reassembly needed)
        if header.totalFragments == 1 {
            if let packet = decryptAndParse(Data(payload)) {
                // Log non-video packets
                if packet.type != .videoFrame {
                    lcDebug("📨 UDPTransport: Received \(packet.type) packet #\(count), payload: \(packet.payload.count) bytes")
                }
                if packet.type == .inputEvent {
                    lcDebug("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            } else {
                lcDebug("⚠️ UDPTransport: Could not parse packet from payload (\(payload.count) bytes)")
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
        
        // The top frameId bit marks a droppable (video) frame; the low 31 bits
        // are the real id. Drop-to-newest only applies to droppable frames so
        // tiles (and other reliable packets) are never discarded as "stale".
        let droppable = (header.frameId & Self.droppableFrameFlag) != 0
        let realFrameId = header.frameId & ~Self.droppableFrameFlag

        // Drop-to-newest: a droppable frame that fell behind the newest by more
        // than the in-flight window will never complete (its siblings were
        // pruned), so ignore a late fragment instead of resurrecting it.
        if dropToNewestEnabled, droppable,
           highestFrameId > inFlightFrameWindow,
           realFrameId < highestFrameId - inFlightFrameWindow {
            fragmentLock.unlock()
            return
        }

        // Initialize buffers for this frame if needed (header.totalFragments is
        // the data fragment count, carried on both data and parity fragments).
        if fragmentBuffers[realFrameId] == nil {
            fragmentBuffers[realFrameId] = [:]
            fragmentCounts[realFrameId] = header.totalFragments
            frameDroppable[realFrameId] = droppable
        }

        if droppable, realFrameId > highestFrameId {
            highestFrameId = realFrameId
        }

        // A parity fragment (high bit of fragmentIndex set) goes into a separate
        // buffer so it never counts toward frame completion; a data fragment is
        // stored normally. Either way, attempt FEC recovery on the affected
        // block, which can fill in a single missing data fragment.
        if (header.fragmentIndex & Self.fecParityFlag) != 0 {
            let blockIndex = header.fragmentIndex & ~Self.fecParityFlag
            if parityBuffers[realFrameId] == nil { parityBuffers[realFrameId] = [:] }
            parityBuffers[realFrameId]?[blockIndex] = Data(payload)
            recoverBlock(realFrameId, blockIndex: blockIndex, totalFragments: Int(header.totalFragments))
        } else {
            fragmentBuffers[realFrameId]?[header.fragmentIndex] = Data(payload)
            recoverBlock(realFrameId, blockIndex: header.fragmentIndex / UInt16(fecBlockSize), totalFragments: Int(header.totalFragments))
        }

        // Prune droppable frames that fell behind the newest. A pruned-but-
        // incomplete frame is a lost frame worth signalling for recovery. Tiles
        // (non-droppable) are kept; a lost tile is healed by periodic refresh.
        var lostIncomplete = false
        if dropToNewestEnabled, highestFrameId > inFlightFrameWindow {
            let cutoff = highestFrameId - inFlightFrameWindow
            for (fid, frags) in fragmentBuffers where fid < cutoff && (frameDroppable[fid] ?? true) {
                if frags.count < Int(fragmentCounts[fid] ?? 0) { lostIncomplete = true }
                fragmentBuffers.removeValue(forKey: fid)
                fragmentCounts.removeValue(forKey: fid)
                frameDroppable.removeValue(forKey: fid)
                parityBuffers.removeValue(forKey: fid)
            }
        }

        // Memory backstop (covers never-completing tiles and the drop-to-newest
        // off case): evict the oldest buffered frame if we exceed the cap.
        while fragmentBuffers.count > maxBufferedFrames, let oldest = fragmentBuffers.keys.min() {
            fragmentBuffers.removeValue(forKey: oldest)
            fragmentCounts.removeValue(forKey: oldest)
            frameDroppable.removeValue(forKey: oldest)
            parityBuffers.removeValue(forKey: oldest)
        }
        
        // Check if we have all fragments
        let received = fragmentBuffers[realFrameId]?.count ?? 0
        let total = Int(fragmentCounts[realFrameId] ?? 0)
        
        if total > 0, received == total {
            // Reassemble
            var fullData = Data()
            for i in 0..<UInt16(total) {
                if let fragmentData = fragmentBuffers[realFrameId]?[i] {
                    fullData.append(fragmentData)
                }
            }
            
            // Clean up
            fragmentBuffers.removeValue(forKey: realFrameId)
            fragmentCounts.removeValue(forKey: realFrameId)
            frameDroppable.removeValue(forKey: realFrameId)
            parityBuffers.removeValue(forKey: realFrameId)
            fragmentLock.unlock()
            
            // Parse and deliver (decrypt if needed)
            if let packet = decryptAndParse(fullData) {
                logger.debug("Reassembled frame \(realFrameId): \(fullData.count) bytes from \(total) fragments")
                delegate?.udpTransport(self, didReceivePacket: packet, from: endpoint)
            }
        } else {
            fragmentLock.unlock()
        }

        if lostIncomplete {
            delegate?.udpTransportDidLoseFrames(self)
        }
    }
    
    /// Reconstruct a single missing data fragment in `blockIndex` from its XOR
    /// parity. Must be called with `fragmentLock` held. Recovers only when the
    /// block has exactly one missing data fragment and parity is present, and
    /// never the frame's last (short) fragment whose length can't be inferred.
    private func recoverBlock(_ frameId: UInt32, blockIndex: UInt16, totalFragments: Int) {
        guard totalFragments > 0,
              let parity = parityBuffers[frameId]?[blockIndex],
              var frags = fragmentBuffers[frameId] else { return }

        let payloadSize = maxPayloadSize - FragmentHeader.size
        let blockStart = Int(blockIndex) * fecBlockSize
        guard blockStart < totalFragments else { return }
        let blockEnd = min(blockStart + fecBlockSize, totalFragments)
        let lastFrameIndex = totalFragments - 1

        var missing = -1
        for i in blockStart..<blockEnd where frags[UInt16(i)] == nil {
            if missing >= 0 { return }            // more than one missing: XOR can't recover
            missing = i
        }
        guard missing >= 0 else { return }        // nothing missing
        guard missing != lastFrameIndex else { return }  // unknown length; skip

        // recovered = parity XOR (present data fragments, each padded to payloadSize)
        var recovered = [UInt8](repeating: 0, count: payloadSize)
        parity.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for k in 0..<min(b.count, payloadSize) { recovered[k] ^= b[k] }
        }
        for i in blockStart..<blockEnd where i != missing {
            guard let frag = frags[UInt16(i)] else { return }
            frag.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for k in 0..<min(b.count, payloadSize) { recovered[k] ^= b[k] }
            }
        }

        frags[UInt16(missing)] = Data(recovered)
        fragmentBuffers[frameId] = frags
        _fecRecovered += 1
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

