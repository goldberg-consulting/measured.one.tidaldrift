import Foundation
import Network
import OSLog
import Security

/// Peer-to-peer UDP bandwidth + latency test.
///
/// Uses the same transport family as LocalCast (UDP / IPv4) so the numbers
/// reflect what streaming actually experiences, including packet loss that TCP
/// would hide behind retransmits. Every instance runs a lightweight responder;
/// an initiator runs three phases against a chosen peer:
///   1. Latency  — ping/pong round trips (RTT + jitter)
///   2. Download — the peer blasts a burst to us (throughput + loss)
///   3. Upload   — we blast a burst to the peer, which reports what it received
///
/// This is deliberately separate from `UDPTransport` (no fragmentation,
/// encryption, or LocalCast packet types) so it can run without a streaming
/// session and measure the raw link.
final class SpeedTestService {
    static let shared = SpeedTestService()
    static let port: UInt16 = 5905

    private let logger = Logger(subsystem: "com.tidaldrift", category: "SpeedTest")
    private let queue = DispatchQueue(label: "com.tidaldrift.speedtest", qos: .userInitiated)

    /// Wire format. A burst is only ever sent to a source that has completed a
    /// ping/pong round trip: the pong carries a per-source token that must be
    /// echoed in `downloadRequest` and `uploadStart`. Without that, a 7-byte
    /// datagram with a forged source address turned the responder into a
    /// 30 MB amplifier aimed at whatever address the attacker chose.
    private enum PType: UInt8 {
        case ping = 1              // initiator -> responder: [seq: UInt32][sentAt: Double]
        case pong = 2              // responder -> initiator: ping payload + [token: 8 bytes]
        case downloadRequest = 3   // initiator -> responder: [count: UInt32][size: UInt16][token: 8 bytes]
        case downloadData = 4      // responder -> initiator
        case uploadStart = 5       // initiator -> responder: [count: UInt32][size: UInt16][token: 8 bytes]
        case uploadData = 6        // initiator -> responder
        case uploadResult = 7      // responder -> initiator: [packets: UInt32][bytes: UInt32][ms: UInt32]
    }

    private static let tokenLength = 8
    /// Bytes the responder will burst to one source per minute: a little over
    /// one full test, so a peer can re-run but cannot use this Mac as a
    /// traffic source.
    private static let burstBudgetPerMinute = 8_000_000
    private static let maxTrackedSources = 256

    struct Result: Sendable {
        let rttMs: Double
        let jitterMs: Double
        let downloadMbps: Double
        let downloadLossPct: Double
        let uploadMbps: Double
        let uploadLossPct: Double
    }

    /// ~1400 B keeps each test packet within a typical 1500 B MTU, matching the
    /// LocalCast fragment size so loss behaves the same.
    private static let packetSize = 1400
    private static let testPackets = 3000   // ~4.2 MB per direction

    private static func udpParameters() -> NWParameters {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        return params
    }

    // MARK: - Byte helpers

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ data: inout Data, _ value: Double) {
        var v = value.bitPattern.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    private static func readDouble(_ data: Data, _ offset: Int) -> Double {
        guard data.count >= offset + 8 else { return 0 }
        let bits = data.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return Double(bitPattern: bits)
    }

    // MARK: - Responder

    private var listener: NWListener?
    private let respLock = NSLock()
    private var uploadExpected: [String: Int] = [:]
    private var uploadReceived: [String: (packets: Int, bytes: Int, firstAt: Date?, lastAt: Date?)] = [:]
    private var uploadResultSent: Set<String> = []
    /// Per-source proof of a completed round trip, and per-source burst budget.
    private var sourceTokens: [String: (token: Data, issuedAt: Date)] = [:]
    private var burstBudget: [String: (bytes: Int, windowStart: Date)] = [:]

    private static func hostString(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return "\(host)"
    }

    /// Token for `key`, minting one on first contact. Caller holds `respLock`.
    private func tokenLocked(for key: String) -> Data {
        if let existing = sourceTokens[key] { return existing.token }
        if sourceTokens.count >= Self.maxTrackedSources,
           let oldest = sourceTokens.min(by: { $0.value.issuedAt < $1.value.issuedAt }) {
            sourceTokens.removeValue(forKey: oldest.key)
        }
        var token = Data(count: Self.tokenLength)
        token.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, Self.tokenLength, buffer.baseAddress!)
        }
        sourceTokens[key] = (token, Date())
        return token
    }

    /// Whether `data` (a downloadRequest or uploadStart) carries the token
    /// issued to `key`, and the source's budget allows `bytes` more.
    private func authorizeBurst(_ data: Data, key: String, bytes: Int) -> Bool {
        let tokenStart = 7
        guard data.count >= tokenStart + Self.tokenLength else { return false }
        let presented = data.subdata(in: tokenStart..<tokenStart + Self.tokenLength)

        respLock.lock()
        defer { respLock.unlock() }
        guard let issued = sourceTokens[key], SessionCrypto.constantTimeEquals(issued.token, presented) else {
            return false
        }
        let now = Date()
        var budget = burstBudget[key] ?? (0, now)
        if now.timeIntervalSince(budget.windowStart) > 60 { budget = (0, now) }
        guard budget.bytes + bytes <= Self.burstBudgetPerMinute else { return false }
        budget.bytes += bytes
        burstBudget[key] = budget
        if burstBudget.count > Self.maxTrackedSources,
           let oldest = burstBudget.min(by: { $0.value.windowStart < $1.value.windowStart }) {
            burstBudget.removeValue(forKey: oldest.key)
        }
        return true
    }

    /// Start the always-on responder so peers can test against this Mac.
    func startResponder() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: Self.udpParameters(), on: NWEndpoint.Port(rawValue: Self.port)!)
            l.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.logger.error("Speed-test responder failed: \(error.localizedDescription)")
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                self.receiveResponder(on: conn)
            }
            l.start(queue: queue)
            listener = l
            logger.info("Speed-test responder listening on UDP \(Self.port)")
        } catch {
            logger.error("Speed-test responder failed to start: \(error.localizedDescription)")
        }
    }

    private func receiveResponder(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleResponder(data, on: conn)
            }
            if error == nil, conn.state == .ready {
                self.receiveResponder(on: conn)
            }
        }
    }

    private func handleResponder(_ data: Data, on conn: NWConnection) {
        guard let type = PType(rawValue: data[0]) else { return }
        // The responder is unauthenticated; only LAN peers get any reply.
        guard let host = Self.hostString(of: conn.endpoint), NetworkUtils.isLocalPeerAddress(host) else { return }
        let key = "\(conn.endpoint)"

        switch type {
        case .ping:
            // Echo the payload (carries the initiator's send timestamp) as a
            // pong, plus the token that authorizes this source's bursts. The
            // pong only reaches the real owner of the source address.
            respLock.lock()
            let token = tokenLocked(for: key)
            respLock.unlock()
            var out = Data(data.prefix(13))
            out[0] = PType.pong.rawValue
            out.append(token)
            conn.send(content: out, completion: .idempotent)

        case .downloadRequest:
            let count = min(max(Int(Self.readU32(data, 1)), 1), 20_000)
            let size = min(max(Int(Self.readU16(data, 5)), 64), 1500)
            guard authorizeBurst(data, key: key, bytes: count * size) else {
                logger.warning("Speed test: refused download burst for \(key, privacy: .private) (no token or over budget)")
                return
            }
            sendDownloadBurst(on: conn, count: count, size: size)

        case .uploadStart:
            // Uploads cost this Mac nothing to send, but the tracking entry and
            // the result datagram are still gated on the round trip.
            guard authorizeBurst(data, key: key, bytes: 0) else { return }
            let count = Int(Self.readU32(data, 1))
            respLock.lock()
            uploadExpected[key] = count
            uploadReceived[key] = (0, 0, nil, nil)
            uploadResultSent.remove(key)
            respLock.unlock()
            // Safety net: report even if the tail of the burst is lost, then
            // drop the source's state so the tables do not grow per peer.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.sendUploadResult(on: conn, key: key)
                self.respLock.lock()
                self.uploadResultSent.remove(key)
                self.respLock.unlock()
            }

        case .uploadData:
            respLock.lock()
            if var r = uploadReceived[key] {
                let now = Date()
                if r.firstAt == nil { r.firstAt = now }
                r.lastAt = now
                r.packets += 1
                r.bytes += data.count
                uploadReceived[key] = r
                let done = (uploadExpected[key] ?? 0) > 0 && r.packets >= (uploadExpected[key] ?? 0)
                respLock.unlock()
                if done { sendUploadResult(on: conn, key: key) }
            } else {
                respLock.unlock()
            }

        default:
            break
        }
    }

    private func sendDownloadBurst(on conn: NWConnection, count: Int, size: Int) {
        let clampedCount = min(max(count, 1), 20_000)
        let clampedSize = min(max(size, 64), 1500)
        let payload = Data(count: clampedSize - 5)
        for seq in 0..<clampedCount {
            var p = Data([PType.downloadData.rawValue])
            Self.appendU32(&p, UInt32(seq))
            p.append(payload)
            conn.send(content: p, completion: .idempotent)
        }
    }

    private func sendUploadResult(on conn: NWConnection, key: String) {
        respLock.lock()
        if uploadResultSent.contains(key) {
            respLock.unlock()
            return
        }
        let r = uploadReceived[key] ?? (0, 0, nil, nil)
        uploadResultSent.insert(key)
        uploadReceived.removeValue(forKey: key)
        uploadExpected.removeValue(forKey: key)
        respLock.unlock()

        // Measure over the actual receive window (first to last packet), not to
        // the safety-net deadline. Tail loss must not inflate the duration and
        // crush the reported throughput.
        let ms: UInt32
        if let first = r.firstAt, let last = r.lastAt {
            ms = UInt32(max(last.timeIntervalSince(first) * 1000, 1))
        } else {
            ms = 1
        }
        var out = Data([PType.uploadResult.rawValue])
        Self.appendU32(&out, UInt32(r.packets))
        Self.appendU32(&out, UInt32(r.bytes))
        Self.appendU32(&out, ms)
        conn.send(content: out, completion: .idempotent)
    }

    // MARK: - Initiator

    /// Collected results from the responder during a test, guarded for the
    /// shared receive loop.
    private final class InitiatorState: @unchecked Sendable {
        let lock = NSLock()
        var rtts: [Double] = []
        /// Burst authorization token from the responder's pongs.
        var token: Data?
        var downloadPackets = 0
        var downloadBytes = 0
        var downloadFirstAt: Date?
        var downloadLastAt: Date?
        var uploadResult: (packets: Int, bytes: Int, ms: Int)?
    }

    func runTest(toHost host: String) async -> Result? {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: Self.port)!
        )
        let conn = NWConnection(to: endpoint, using: Self.udpParameters())
        let state = InitiatorState()

        let ready = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumed = AtomicFlag()
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if resumed.compareAndSwap(expected: false, desired: true) { cont.resume(returning: true) }
                case .failed, .cancelled:
                    if resumed.compareAndSwap(expected: false, desired: true) { cont.resume(returning: false) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if resumed.compareAndSwap(expected: false, desired: true) { cont.resume(returning: false) }
            }
        }
        guard ready else {
            conn.cancel()
            logger.warning("Speed test: could not reach \(host):\(Self.port)")
            return nil
        }

        receiveInitiator(on: conn, state: state)

        // Phase 1: latency — 10 pings, 100 ms apart, timestamp embedded.
        for seq in 0..<10 {
            var p = Data([PType.ping.rawValue])
            Self.appendU32(&p, UInt32(seq))
            Self.appendDouble(&p, CFAbsoluteTimeGetCurrent())
            conn.send(content: p, completion: .idempotent)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000) // drain late pongs

        // No pong means no token, and a responder that never answered pings
        // (old build, firewall) would ignore the burst requests anyway.
        state.lock.lock()
        let token = state.token
        state.lock.unlock()
        guard let token else {
            conn.cancel()
            logger.warning("Speed test: no pong from \(host):\(Self.port); both Macs need the current build")
            return computeResult(state)
        }

        // Phase 2: download — peer blasts to us; measure a receive window.
        var req = Data([PType.downloadRequest.rawValue])
        Self.appendU32(&req, UInt32(Self.testPackets))
        Self.appendU16(&req, UInt16(Self.packetSize))
        req.append(token)
        conn.send(content: req, completion: .idempotent)
        try? await Task.sleep(nanoseconds: 4_000_000_000)

        // Phase 3: upload — tell the peer, blast, await its report.
        var us = Data([PType.uploadStart.rawValue])
        Self.appendU32(&us, UInt32(Self.testPackets))
        Self.appendU16(&us, UInt16(Self.packetSize))
        us.append(token)
        conn.send(content: us, completion: .idempotent)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let padding = Data(count: Self.packetSize - 5)
        for seq in 0..<Self.testPackets {
            var p = Data([PType.uploadData.rawValue])
            Self.appendU32(&p, UInt32(seq))
            p.append(padding)
            conn.send(content: p, completion: .idempotent)
            // Light pacing so the local send buffer doesn't overflow and drop
            // everything before it hits the wire.
            if seq % 50 == 49 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        // Wait for the responder's upload report (it also self-reports after 5s).
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        conn.cancel()
        return computeResult(state)
    }

    private func receiveInitiator(on conn: NWConnection, state: InitiatorState) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let type = PType(rawValue: data[0]) {
                let now = Date()
                state.lock.lock()
                switch type {
                case .pong:
                    let sent = Self.readDouble(data, 5)
                    let rtt = (CFAbsoluteTimeGetCurrent() - sent) * 1000
                    if rtt >= 0, rtt < 10_000 { state.rtts.append(rtt) }
                    if data.count >= 13 + Self.tokenLength {
                        state.token = data.subdata(in: 13..<13 + Self.tokenLength)
                    }
                case .downloadData:
                    if state.downloadFirstAt == nil { state.downloadFirstAt = now }
                    state.downloadLastAt = now
                    state.downloadPackets += 1
                    state.downloadBytes += data.count
                case .uploadResult:
                    state.uploadResult = (
                        Int(Self.readU32(data, 1)),
                        Int(Self.readU32(data, 5)),
                        Int(Self.readU32(data, 9))
                    )
                default:
                    break
                }
                state.lock.unlock()
            }
            if error == nil, conn.state == .ready {
                self.receiveInitiator(on: conn, state: state)
            }
        }
    }

    private func computeResult(_ state: InitiatorState) -> Result {
        state.lock.lock()
        defer { state.lock.unlock() }

        let rtts = state.rtts.sorted()
        let rttAvg = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
        let jitter: Double
        if rtts.count > 1 {
            let mean = rttAvg
            let variance = rtts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rtts.count)
            jitter = variance.squareRoot()
        } else {
            jitter = 0
        }

        let dlSeconds = (state.downloadFirstAt != nil && state.downloadLastAt != nil)
            ? max(state.downloadLastAt!.timeIntervalSince(state.downloadFirstAt!), 0.001)
            : 0
        let dlMbps = dlSeconds > 0 ? Double(state.downloadBytes) * 8 / dlSeconds / 1_000_000 : 0
        let dlLoss = Double(Self.testPackets - state.downloadPackets) / Double(Self.testPackets) * 100

        let ulMbps: Double
        let ulLoss: Double
        if let up = state.uploadResult, up.ms > 0 {
            ulMbps = Double(up.bytes) * 8 / (Double(up.ms) / 1000) / 1_000_000
            ulLoss = Double(Self.testPackets - up.packets) / Double(Self.testPackets) * 100
        } else {
            ulMbps = 0
            ulLoss = 100
        }

        return Result(
            rttMs: rttAvg,
            jitterMs: jitter,
            downloadMbps: dlMbps,
            downloadLossPct: max(0, dlLoss),
            uploadMbps: ulMbps,
            uploadLossPct: max(0, min(100, ulLoss))
        )
    }
}

// MARK: - Settings recommendation

extension SpeedTestService {
    /// Recommended LocalCast settings derived from a speed-test result. Maps to
    /// the `localCast*` UserDefaults keys the host/client read at session start.
    struct Recommendation {
        let maxDimension: Int        // 0 = native
        let regionAware: Bool
        let adaptive: Bool
        let dropToNewest: Bool
        let lossRecovery: Bool
        let codec: String            // "h264" or "hevc"
        let headline: String
        let bullets: [String]
    }

    /// Turn measured link quality into a concrete settings recommendation. Uses
    /// the more constrained of the two directions as the budget, since either
    /// Mac may be the host. Resilience options stay on (no-ops on a clean link);
    /// resolution and codec scale with bandwidth, and region-aware turns on for
    /// lossy or low-bandwidth links.
    static func recommend(from r: Result) -> Recommendation {
        let up = r.uploadMbps > 0 ? r.uploadMbps : r.downloadMbps
        let budget = min(r.downloadMbps, up)
        let loss = max(r.downloadLossPct, r.uploadLossPct)
        let lossy = loss > 5
        let highJitter = r.jitterMs > 20

        let dimension: Int
        let resLabel: String
        switch budget {
        case 300...:    dimension = 0;    resLabel = "Native"
        case 120..<300: dimension = 2560; resLabel = "1440p"
        case 50..<120:  dimension = 1920; resLabel = "1080p"
        default:        dimension = 1280; resLabel = "720p"
        }

        let regionAware = lossy || budget < 50
        let useHEVC = budget < 80
        let codec = useHEVC ? "hevc" : "h264"

        var bullets: [String] = []
        bullets.append("Resolution: \(resLabel) — sized to about \(Int(budget)) Mbps of usable bandwidth.")
        bullets.append("Adaptive bitrate: On — eases quality under load, restores it when the link clears.")
        bullets.append("Drop-to-newest + loss recovery: On — keeps motion smooth and heals quickly.")
        if regionAware {
            bullets.append("Region-aware: On — send only changed regions; lighter on a \(lossy ? "lossy" : "limited") link and crisper for text/UI.")
        } else {
            bullets.append("Region-aware: Off — plenty of clean bandwidth for full-frame video.")
        }
        bullets.append(useHEVC
            ? "Codec: HEVC — better compression for a constrained link (experimental)."
            : "Codec: H.264 — reliable at this bandwidth.")
        if highJitter {
            bullets.append("Note: jitter is high (±\(Int(r.jitterMs)) ms); the adaptive jitter buffer adds a little smoothing latency.")
        }

        let headline: String
        if r.downloadMbps <= 0 {
            headline = "Couldn't measure the link — re-run with both Macs updated."
        } else if lossy {
            headline = "Lossy link: optimized for resilience over maximum sharpness."
        } else if budget < 50 {
            headline = "Limited bandwidth: trade some resolution for smoothness."
        } else {
            headline = "Healthy link: you can run high quality."
        }

        return Recommendation(
            maxDimension: dimension,
            regionAware: regionAware,
            adaptive: true,
            dropToNewest: true,
            lossRecovery: true,
            codec: codec,
            headline: headline,
            bullets: bullets
        )
    }
}
