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
    /// `wasAuthenticated` is true only when the packet arrived encrypted and
    /// was decrypted under the session key. Delegates must require it for
    /// security-sensitive packets once a session key exists.
    func udpTransport(_ transport: UDPTransport, didReceivePacket packet: LocalCastPacket, wasAuthenticated: Bool, from endpoint: NWEndpoint)
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection)
    /// Called when reassembly abandons one or more incomplete frames because a
    /// newer frame superseded them (i.e. at least one fragment was lost). The
    /// receiver can use this to request recovery (e.g. a keyframe).
    func udpTransportDidLoseFrames(_ transport: UDPTransport)
    /// Called when a droppable (video) frame would exceed the receiver's
    /// fragment cap at the current payload size, so the sender dropped it
    /// instead of emitting a frame that would be rejected wholesale at
    /// reassembly. The host should reduce encode load (bitrate, then
    /// resolution) so keyframes fit. The transport rate-limits this signal.
    func udpTransportFrameExceededCapacity(_ transport: UDPTransport, fragments: Int, limit: Int)
}

extension UDPTransportDelegate {
    func udpTransport(_ transport: UDPTransport, clientDidConnect endpoint: NWEndpoint, connection: NWConnection) {}
    func udpTransportDidLoseFrames(_ transport: UDPTransport) {}
    func udpTransportFrameExceededCapacity(_ transport: UDPTransport, fragments: Int, limit: Int) {}
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
    static let defaultPayloadSize = 1400 // Fits a 1500-byte ethernet MTU with IP/UDP headers
    static let jumboPayloadSize = 8900   // Fits a 9000-byte jumbo MTU with IP/UDP headers
    /// Per-fragment payload ceiling. Read once per frame in sendFragmented so a
    /// live change only takes effect on the next frame boundary. Guarded by
    /// fragmentLock.
    private var _maxPayloadSize = UDPTransport.defaultPayloadSize
    private var maxPayloadSize: Int {
        fragmentLock.lock(); defer { fragmentLock.unlock() }; return _maxPayloadSize
    }
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
    static let defaultInFlightFrameWindow: UInt32 = 4
    static let fastLANInFlightFrameWindow: UInt32 = 16
    /// Reassembly slack before drop-to-newest prunes a frame. Widened in Fast
    /// LAN so a brief receiver stall during a burst does not manufacture a loss.
    /// Read only on the transport queue under fragmentLock.
    private var inFlightFrameWindow: UInt32 = UDPTransport.defaultInFlightFrameWindow
    
    // Safety limits for fragment reassembly
    // Quality-focused encoding at 4K can produce keyframes of 2-5 MB.
    // At 1390 bytes/fragment, a 5 MB frame needs ~3,600 fragments.
    private let maxTotalFragments: UInt16 = 5000  // ~7 MB max per frame
    private let maxBufferedFrames = 120           // Allow more in-flight frames for high-throughput

    // Over-capacity signal rate limiting. A droppable frame whose fragment
    // count exceeds maxTotalFragments is rejected wholesale by the receiver, so
    // the sender drops it and asks the host to reduce encode load. sendFragmented
    // runs on the encoder callback queue, so guard the last-signal time so the
    // host is notified at most a few times per second.
    private var lastOverCapacitySignal = Date.distantPast
    private let overCapacityLock = NSLock()
    private static let overCapacityMinInterval: TimeInterval = 0.3

    // Paced fragment sending.
    // A keyframe is hundreds of fragments. Handing them all to the network
    // stack in one tight loop overruns the Wi-Fi uplink, which sheds ~13% of
    // the burst (measured) — and losing a single fragment makes the whole
    // frame undecodable, since there is no FEC or retransmit. Draining large
    // frames in small bursts with a short gap keeps the in-flight queue under
    // the uplink's instantaneous capacity and largely removes that loss.
    private let pacingFragmentThreshold = 12   // frames at/below this go out unpaced
    private let pacingBatchSize = 16           // fragments per paced burst
    private let pacingGapBaseMicros = 700      // base gap between bursts (~256 Mbps ceiling)
    private let paceQueue = DispatchQueue(label: "com.tidaldrift.localcast.sendpace", qos: .userInteractive)

    // Adaptive pacing. The client reports drops once per second; drops mean
    // the uplink is shedding our bursts, so widen the inter-burst gap (slower,
    // safer sends). A sustained run of clean ticks narrows the gap back toward
    // the base. Loopback connections skip pacing entirely (no uplink to
    // overrun, and the gaps only add latency).
    private var _pacingBypassed = false        // guarded by pacingLock
    private var _fastLANEnabled = false        // guarded by pacingLock
    private var pacingGapScale = 1.0           // guarded by pacingLock
    private var pacingCleanTicks = 0           // guarded by pacingLock
    private let pacingLock = NSLock()

    /// Read on the encoder callback queue in sendFragmented. Guarded by pacingLock.
    private var fastLANEnabled: Bool {
        pacingLock.lock(); defer { pacingLock.unlock() }; return _fastLANEnabled
    }

    /// Apply transport-level Fast LAN behavior. Pacing and the reassembly window
    /// flip live; the jumbo payload size takes effect on the next sent frame.
    /// `jumbo` is gated by the caller (explicit Fast LAN only) because it only
    /// works when the path supports a 9000-byte MTU.
    func setFastLAN(_ enabled: Bool, jumbo: Bool) {
        pacingLock.lock()
        _fastLANEnabled = enabled
        // Enabling Fast LAN drops pacing, so clear any widened gap from a prior
        // congested period; otherwise it would be frozen and carried into the
        // resilient window after a later revert.
        if enabled {
            pacingGapScale = 1.0
            pacingCleanTicks = 0
        }
        pacingLock.unlock()

        fragmentLock.lock()
        inFlightFrameWindow = enabled ? Self.fastLANInFlightFrameWindow : Self.defaultInFlightFrameWindow
        _maxPayloadSize = (enabled && jumbo) ? Self.jumboPayloadSize : Self.defaultPayloadSize
        fragmentLock.unlock()
    }

    /// Largest keyframe, in bytes, that fits under the receiver fragment cap at
    /// the current payload size, with headroom. Drives the encoder's Fast LAN
    /// DataRateLimits so a keyframe never produces more than maxTotalFragments
    /// data fragments (which the receiver would reject, stalling the stream).
    func keyframeByteCeiling() -> Int {
        fragmentLock.lock(); defer { fragmentLock.unlock() }
        let effectivePayload = _maxPayloadSize - FragmentHeader.size
        return Int(0.7 * Double(Int(maxTotalFragments) * effectivePayload))
    }

    /// Written on the transport queue (client changes), read on the encoder
    /// callback queue in sendFragmented.
    var pacingBypassed: Bool {
        get { pacingLock.lock(); defer { pacingLock.unlock() }; return _pacingBypassed }
        set { pacingLock.lock(); _pacingBypassed = newValue; pacingLock.unlock() }
    }
    private static let pacingMaxScale = 4.0
    private static let pacingIncreaseStep = 0.5
    private static let pacingDecreaseStep = 0.25
    private static let pacingCleanTicksNeeded = 3

    /// Feed one per-second client telemetry tick into the pacing controller.
    func notePacingTelemetry(droppedPerSec: Int) {
        pacingLock.lock()
        defer { pacingLock.unlock() }
        // Fast LAN never paces, so widening the gap in response to receiver-side
        // drops would have no effect except to re-arm a stale scale if the link
        // later falls back to resilient. Leave the scale at its baseline.
        if _fastLANEnabled { return }
        if droppedPerSec > 0 {
            pacingCleanTicks = 0
            pacingGapScale = min(Self.pacingMaxScale, pacingGapScale + Self.pacingIncreaseStep)
        } else {
            pacingCleanTicks += 1
            if pacingCleanTicks >= Self.pacingCleanTicksNeeded, pacingGapScale > 1.0 {
                pacingGapScale = max(1.0, pacingGapScale - Self.pacingDecreaseStep)
            }
        }
    }

    private var currentPacingGapMicros: Int {
        pacingLock.lock()
        defer { pacingLock.unlock() }
        return Int(Double(pacingGapBaseMicros) * pacingGapScale)
    }

    // Forward error correction. When enabled (host/sender side), each block of
    // `fecBlockSize` video data fragments gets two parity fragments:
    //   P = XOR(data[i])
    //   Q = XOR((i + 1) * data[i]) over GF(256)
    // The receiver can reconstruct up to two lost data fragments per block
    // without a retransmit. Parity reuses the 10-byte fragment header: high bit
    // of `fragmentIndex` marks parity and the next bit marks Q parity, so the
    // base header stays unchanged.
    var fecEnabled = UserDefaults.standard.object(forKey: "localCastFEC") as? Bool ?? false
    private let fecBlockSize = 16
    private static let fecParityFlag: UInt16 = 0x8000
    private static let fecQParityFlag: UInt16 = 0x4000
    private var parityBuffers: [UInt32: [UInt16: Data]] = [:] // P parity: frameId -> blockIndex -> payload
    private var qParityBuffers: [UInt32: [UInt16: Data]] = [:] // Q parity: frameId -> blockIndex -> payload
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
    
    /// Send packet using a specific connection (for replying on incoming connections).
    /// `forcePlaintext` bypasses session-key encryption; use it only for handshake
    /// retransmits, where the peer may not have installed the key yet and a keyed
    /// peer will simply drop the duplicate.
    func send(packet: LocalCastPacket, on connection: NWConnection, forcePlaintext: Bool = false) {
        let raw = packet.serialize()
        statsLock.lock()
        _sendCount += 1
        let count = _sendCount
        statsLock.unlock()

        // Encrypt or wrap with plaintext flag
        let data: Data
        if let key = sessionKey, !forcePlaintext {
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
        let currentMaxPayload = _maxPayloadSize
        fragmentLock.unlock()
        
        let payloadSize = currentMaxPayload - FragmentHeader.size
        let totalFragmentCount = (data.count + payloadSize - 1) / payloadSize

        // A droppable (video) frame whose data-fragment count exceeds the
        // receiver's cap is rejected at reassembly (the receiver guards against
        // totalFragments > maxTotalFragments), so the decoder never gets it.
        // Emitting it wastes the uplink and only adds congestion, and a keyframe
        // that never arrives stalls the stream ("connected but no video"). Drop
        // it here and signal the host to reduce encode load so the next keyframe
        // fits. Computed from the current payload size, so the threshold is
        // correct under both default and jumbo MTUs.
        if droppable && totalFragmentCount > Int(maxTotalFragments) {
            signalOverCapacity(fragments: totalFragmentCount, limit: Int(maxTotalFragments))
            return
        }

        let totalFragments = UInt16(totalFragmentCount)

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

        // Optionally interleave two parity fragments after each block of data
        // fragments, so the receiver can recover up to two lost fragments per
        // block without a retransmit.
        var sendList = fragments
        if fecEnabled && droppable && totalFragments > 1 {
            sendList = []
            sendList.reserveCapacity(fragments.count + (fragments.count / fecBlockSize + 1) * 2)
            var index = 0
            var blockIndex: UInt16 = 0
            while index < fragments.count {
                let blockEnd = min(index + fecBlockSize, fragments.count)
                for j in index..<blockEnd { sendList.append(fragments[j]) }

                let parity = fecParity(of: data, fragmentRange: index..<blockEnd, payloadSize: payloadSize)
                let pHeader = FragmentHeader(
                    frameId: frameId,
                    fragmentIndex: Self.fecParityFlag | blockIndex,
                    totalFragments: totalFragments,
                    payloadLength: UInt16(parity.p.count)
                )
                var pData = Data()
                pData.append(pHeader.serialize())
                pData.append(parity.p)
                sendList.append(pData)

                let qHeader = FragmentHeader(
                    frameId: frameId,
                    fragmentIndex: Self.fecParityFlag | Self.fecQParityFlag | blockIndex,
                    totalFragments: totalFragments,
                    payloadLength: UInt16(parity.q.count)
                )
                var qData = Data()
                qData.append(qHeader.serialize())
                qData.append(parity.q)
                sendList.append(qData)

                index = blockEnd
                blockIndex += 1
            }
        }

        // Small frames go out immediately; pacing them would only add latency
        // and they are too small to overrun the uplink. Fast LAN and loopback
        // skip pacing entirely.
        if pacingBypassed || fastLANEnabled || totalFragments <= pacingFragmentThreshold {
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

    /// Notify the host that a video frame exceeded the receiver's fragment cap,
    /// rate-limited so a run of oversized keyframes produces at most a few
    /// signals per second. Runs on the encoder callback queue.
    private func signalOverCapacity(fragments: Int, limit: Int) {
        overCapacityLock.lock()
        let now = Date()
        let shouldSignal = now.timeIntervalSince(lastOverCapacitySignal) >= Self.overCapacityMinInterval
        if shouldSignal { lastOverCapacitySignal = now }
        overCapacityLock.unlock()
        guard shouldSignal else { return }
        logger.warning("⚠️ Dropped over-capacity video frame: \(fragments) fragments > limit \(limit). Signalling host to reduce encode load.")
        delegate?.udpTransportFrameExceededCapacity(self, fragments: fragments, limit: limit)
    }

    /// Number of fragments recovered via FEC since the last call; resets the
    /// counter. Read once per second by the client for the stats HUD.
    func takeFECRecovered() -> Int {
        fragmentLock.lock(); defer { fragmentLock.unlock() }
        let v = _fecRecovered
        _fecRecovered = 0
        return v
    }

    /// P/Q parity of the given data fragments (each zero-padded to
    /// `payloadSize`), forming the FEC payloads for one block.
    private func fecParity(of data: Data, fragmentRange: Range<Int>, payloadSize: Int) -> (p: Data, q: Data) {
        var pParity = [UInt8](repeating: 0, count: payloadSize)
        var qParity = [UInt8](repeating: 0, count: payloadSize)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = buf.count
            for i in fragmentRange {
                let start = i * payloadSize
                guard start < count else { continue }
                let end = min(start + payloadSize, count)
                let coefficient = UInt8((i - fragmentRange.lowerBound) + 1)
                var k = 0
                var p = start
                while p < end {
                    let byte = base[p]
                    pParity[k] ^= byte
                    qParity[k] ^= Self.gfMul(coefficient, byte)
                    k += 1
                    p += 1
                }
            }
        }
        return (Data(pParity), Data(qParity))
    }
    
    /// Drain a frame's fragments in small bursts separated by a short gap,
    /// keeping the instantaneous send rate under the uplink's capacity so the
    /// burst isn't partially dropped. Runs on `paceQueue` off the encoder's
    /// callback queue.
    private func paceFragments(_ fragments: [Data], on connection: NWConnection, frameId: UInt32) {
        let total = fragments.count
        let batchSize = pacingBatchSize
        let gap = DispatchTimeInterval.microseconds(currentPacingGapMicros)
        
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
    
    func send(packet: LocalCastPacket, to endpoint: NWEndpoint, forcePlaintext: Bool = false) {
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
            send(packet: packet, on: incomingConn, forcePlaintext: forcePlaintext)
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
                self?.send(packet: packet, on: connection, forcePlaintext: forcePlaintext)
            }
        } else {
            send(packet: packet, on: connection, forcePlaintext: forcePlaintext)
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
            if let (packet, wasAuthenticated) = decryptAndParse(data) {
                if packet.type != .videoFrame {
                    lcDebug("📨 UDPTransport: Received \(packet.type) packet (raw, no fragment header)")
                }
                if packet.type == .inputEvent {
                    lcDebug("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, wasAuthenticated: wasAuthenticated, from: endpoint)
            } else {
                lcDebug("⚠️ UDPTransport: Could not parse received data (\(data.count) bytes)")
            }
            return
        }
        
        let payload = data.dropFirst(FragmentHeader.size)
        
        // Single fragment (no reassembly needed)
        if header.totalFragments == 1 {
            if let (packet, wasAuthenticated) = decryptAndParse(Data(payload)) {
                // Log non-video packets
                if packet.type != .videoFrame {
                    lcDebug("📨 UDPTransport: Received \(packet.type) packet #\(count), payload: \(packet.payload.count) bytes")
                }
                if packet.type == .inputEvent {
                    lcDebug("🎮 UDPTransport: *** INPUT EVENT RECEIVED *** from \(describeEndpoint(endpoint))")
                }
                delegate?.udpTransport(self, didReceivePacket: packet, wasAuthenticated: wasAuthenticated, from: endpoint)
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
            let isQParity = (header.fragmentIndex & Self.fecQParityFlag) != 0
            let blockIndex = header.fragmentIndex & ~(Self.fecParityFlag | Self.fecQParityFlag)
            if isQParity {
                if qParityBuffers[realFrameId] == nil { qParityBuffers[realFrameId] = [:] }
                qParityBuffers[realFrameId]?[blockIndex] = Data(payload)
            } else {
                if parityBuffers[realFrameId] == nil { parityBuffers[realFrameId] = [:] }
                parityBuffers[realFrameId]?[blockIndex] = Data(payload)
            }
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
                qParityBuffers.removeValue(forKey: fid)
            }
        }

        // Memory backstop (covers never-completing tiles and the drop-to-newest
        // off case): evict the oldest buffered frame if we exceed the cap.
        while fragmentBuffers.count > maxBufferedFrames, let oldest = fragmentBuffers.keys.min() {
            fragmentBuffers.removeValue(forKey: oldest)
            fragmentCounts.removeValue(forKey: oldest)
            frameDroppable.removeValue(forKey: oldest)
            parityBuffers.removeValue(forKey: oldest)
            qParityBuffers.removeValue(forKey: oldest)
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
            qParityBuffers.removeValue(forKey: realFrameId)
            fragmentLock.unlock()
            
            // Parse and deliver (decrypt if needed)
            if let (packet, wasAuthenticated) = decryptAndParse(fullData) {
                logger.debug("Reassembled frame \(realFrameId): \(fullData.count) bytes from \(total) fragments")
                delegate?.udpTransport(self, didReceivePacket: packet, wasAuthenticated: wasAuthenticated, from: endpoint)
            }
        } else {
            fragmentLock.unlock()
        }

        if lostIncomplete {
            delegate?.udpTransportDidLoseFrames(self)
        }
    }
    
    /// Reconstruct up to two missing data fragments in `blockIndex` from P/Q
    /// parity. Must be called with `fragmentLock` held. We still skip the
    /// frame's last (short) fragment because its exact payload length is not in
    /// the frame metadata; all earlier fragments are full-sized.
    private func recoverBlock(_ frameId: UInt32, blockIndex: UInt16, totalFragments: Int) {
        guard totalFragments > 0,
              let pParity = parityBuffers[frameId]?[blockIndex],
              var frags = fragmentBuffers[frameId] else { return }

        let blockStart = Int(blockIndex) * fecBlockSize
        guard blockStart < totalFragments else { return }
        let blockEnd = min(blockStart + fecBlockSize, totalFragments)
        let lastFrameIndex = totalFragments - 1

        // The P parity is always padded to the sender's payload size, so its
        // length is the exact reference even when host and client run different
        // MTUs (e.g. a jumbo host and a default-payload client).
        let payloadSize = pParity.count

        var missing: [Int] = []
        for i in blockStart..<blockEnd where frags[UInt16(i)] == nil {
            missing.append(i)
        }
        guard !missing.isEmpty else { return }
        guard missing.count <= 2 else { return }
        guard !missing.contains(lastFrameIndex) else { return }

        if missing.count == 1 {
            var recovered = [UInt8](repeating: 0, count: payloadSize)
            pParity.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for k in 0..<min(b.count, payloadSize) { recovered[k] ^= b[k] }
            }
            for i in blockStart..<blockEnd where i != missing[0] {
                guard let frag = frags[UInt16(i)] else { return }
                xorInto(&recovered, fragment: frag, payloadSize: payloadSize)
            }
            frags[UInt16(missing[0])] = Data(recovered)
            fragmentBuffers[frameId] = frags
            _fecRecovered += 1
            return
        }

        guard let qParity = qParityBuffers[frameId]?[blockIndex] else { return }
        let missingA = missing[0]
        let missingB = missing[1]
        let coeffA = UInt8((missingA - blockStart) + 1)
        let coeffB = UInt8((missingB - blockStart) + 1)
        let denom = coeffA ^ coeffB
        guard denom != 0 else { return }
        let invDenom = Self.gfInv(denom)

        var pSyndrome = [UInt8](repeating: 0, count: payloadSize)
        var qSyndrome = [UInt8](repeating: 0, count: payloadSize)
        pParity.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for k in 0..<min(b.count, payloadSize) { pSyndrome[k] ^= b[k] }
        }
        qParity.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for k in 0..<min(b.count, payloadSize) { qSyndrome[k] ^= b[k] }
        }
        for i in blockStart..<blockEnd where i != missingA && i != missingB {
            guard let frag = frags[UInt16(i)] else { return }
            let coeff = UInt8((i - blockStart) + 1)
            frag.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                let n = min(b.count, payloadSize)
                for k in 0..<n {
                    let byte = b[k]
                    pSyndrome[k] ^= byte
                    qSyndrome[k] ^= Self.gfMul(coeff, byte)
                }
            }
        }

        var recoveredA = [UInt8](repeating: 0, count: payloadSize)
        var recoveredB = [UInt8](repeating: 0, count: payloadSize)
        for k in 0..<payloadSize {
            let rhs = qSyndrome[k] ^ Self.gfMul(coeffB, pSyndrome[k])
            let a = Self.gfMul(rhs, invDenom)
            recoveredA[k] = a
            recoveredB[k] = pSyndrome[k] ^ a
        }

        frags[UInt16(missingA)] = Data(recoveredA)
        frags[UInt16(missingB)] = Data(recoveredB)
        fragmentBuffers[frameId] = frags
        _fecRecovered += 2
    }

    private func xorInto(_ target: inout [UInt8], fragment: Data, payloadSize: Int) {
        fragment.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for k in 0..<min(b.count, payloadSize) { target[k] ^= b[k] }
        }
    }

    /// GF(256) multiply with primitive polynomial 0x11d (represented as 0x1d
    /// after the high bit is shifted out).
    private static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a
        var b = b
        var p: UInt8 = 0
        for _ in 0..<8 {
            if (b & 1) != 0 { p ^= a }
            let hi = (a & 0x80) != 0
            a <<= 1
            if hi { a ^= 0x1d }
            b >>= 1
        }
        return p
    }

    private static func gfInv(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        var result: UInt8 = 1
        for _ in 0..<254 {
            result = gfMul(result, a)
        }
        return result
    }

    /// Strip the encryption/plaintext prefix and decrypt if needed, then parse.
    /// `wasAuthenticated` is true only when the packet was decrypted under the
    /// session key. Once a session key is established, plaintext is rejected;
    /// plaintext is accepted only before key establishment (the auth handshake
    /// phase, or sessions that never set a key).
    private func decryptAndParse(_ data: Data) -> (packet: LocalCastPacket, wasAuthenticated: Bool)? {
        guard !data.isEmpty else { return nil }
        let key = sessionKey
        
        if data[0] == SessionCrypto.encryptedFlag {
            // Encrypted payload — need session key
            guard let key = key else {
                logger.warning("Received encrypted packet but no session key set")
                return nil
            }
            guard let decrypted = SessionCrypto.decrypt(data, using: key) else {
                logger.warning("Failed to decrypt packet (\(data.count) bytes)")
                return nil
            }
            guard let packet = LocalCastPacket.deserialize(decrypted) else { return nil }
            return (packet, true)
        }
        
        guard key == nil else {
            logger.warning("Rejected non-encrypted packet after session key establishment")
            return nil
        }
        guard data[0] == SessionCrypto.plaintextFlag,
              let unwrapped = SessionCrypto.unwrapPlaintext(data),
              let packet = LocalCastPacket.deserialize(unwrapped) else { return nil }
        return (packet, false)
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

