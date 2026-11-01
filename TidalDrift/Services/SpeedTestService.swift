import Foundation
import Network
import OSLog
import Darwin

/// Sustained TCP throughput and paced UDP delivery, measured by bundled iperf3.
/// The LAN-only control listener leases a temporary, interface-bound server for
/// one test. Disconnect, cancellation, app exit, and the lease deadline stop it.
@MainActor
final class SpeedTestService {
    static let shared = SpeedTestService()
    static let port: UInt16 = 5905
    private let logger = Logger(subsystem: "com.tidaldrift", category: "SpeedTest")
    private var listener: NWListener?
    private var controls: [UUID: SpeedTestControl] = [:]
    private var server: IPerfRunner?
    private var serverOwner: UUID?
    private var client: IPerfRunner?
    private var runningTest = false
    private let helperURL: URL?

    init(helperURL: URL? = nil) { self.helperURL = helperURL }

    struct Result: Sendable {
        let rttMs: Double
        let jitterMs: Double
        let downloadMbps: Double
        let downloadLossPct: Double
        let uploadMbps: Double
        let uploadLossPct: Double
        let downloadUDPRateMbps: Double
        let uploadUDPRateMbps: Double
        let downloadUDPJitterMs: Double
        let uploadUDPJitterMs: Double
        let route: String
    }

    func startResponder() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: SpeedTestControl.parameters(), on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in
                        self?.logger.error("Network-test listener failed: \(error.localizedDescription)")
                        self?.listener?.cancel()
                        self?.listener = nil
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "com.tidaldrift.speedtest.listener"))
            self.listener = listener
        } catch { logger.error("Network-test listener failed: \(error.localizedDescription)") }
    }

    func stopResponder() {
        listener?.cancel()
        listener = nil
        for control in controls.values { control.connection.cancel() }
        controls.removeAll()
        server?.stop()
        server = nil
        serverOwner = nil
        client?.stop()
        client = nil
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              NetworkUtils.isLocalPeerAddress("\(host)"), controls.count < 4 else {
            connection.cancel()
            return
        }
        let id = UUID()
        let control = SpeedTestControl(connection: connection)
        controls[id] = control
        Task { await serve(control, id: id) }
    }

    private func serve(_ control: SpeedTestControl, id: UUID) async {
        // Also bounds malicious/abandoned clients and helpers stuck inside iperf.
        let lease = Task {
            try await Task.sleep(for: .seconds(50))
            control.connection.cancel()
            if serverOwner == id { server?.stop() }
        }
        defer {
            lease.cancel()
            control.connection.cancel()
            controls.removeValue(forKey: id)
            if serverOwner == id {
                server?.stop()
                server = nil
                serverOwner = nil
            }
        }
        do {
            try await control.start()
            while true {
                let request = try await control.receive()
                switch request.action {
                case "ping": try await control.send(.init(action: "pong"))
                case "start":
                    guard serverOwner == nil || serverOwner == id, let address = control.localAddress,
                          NetworkUtils.isLocalPeerAddress(address) else {
                        throw IPerfRunner.Failure.message("The peer is busy with another network test. Try again shortly.")
                    }
                    server?.stop()
                    let executable = try helperURL ?? IPerfRunner.executable()
                    let port = try Self.availablePort(address: address)
                    let helper = try IPerfRunner(executable: executable, arguments: [
                        "-s", "-1", "-4", "-B", address, "-p", String(port), "--forceflush",
                        "--idle-timeout", "12", "--server-max-duration", "10", "--rcv-timeout", "5000"
                    ])
                    serverOwner = id
                    server = helper
                    try await helper.waitForServer()
                    try await control.send(.init(action: "ready", port: port))
                case "stop": return
                default: throw IPerfRunner.Failure.message("Update both Macs to use this network test.")
                }
            }
        } catch {
            try? await control.send(.init(action: "error", error: error.localizedDescription))
        }
    }

    /// Reserve a random port on the selected local address. iperf binds immediately
    /// afterwards; a rare competing bind becomes a reported startup failure.
    private static func availablePort(address: String) throws -> UInt16 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw IPerfRunner.Failure.message("Cannot allocate a network-test port.") }
        defer { close(socketFD) }
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &endpoint.sin_addr) == 1 else {
            throw IPerfRunner.Failure.message("The network test requires an IPv4 address.")
        }
        let result = withUnsafePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &endpoint) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard result == 0, named == 0 else { throw IPerfRunner.Failure.message("Cannot allocate a network-test port.") }
        return UInt16(bigEndian: endpoint.sin_port)
    }

    func runTest(toHost host: String, udpLimitMbps: Int = 100, progress: @escaping (String) -> Void = { _ in }) async throws -> Result {
        guard !runningTest else { throw IPerfRunner.Failure.message("A network test is already running on this Mac.") }
        guard NetworkUtils.isLocalPeerAddress(host), !host.contains(":") else {
            throw IPerfRunner.Failure.message("Choose a local IPv4 address for the network test.")
        }
        let executable = try helperURL ?? IPerfRunner.executable()
        runningTest = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.port)!,
                                      using: SpeedTestControl.parameters())
        let control = SpeedTestControl(connection: connection)
        defer {
            connection.cancel()
            client?.stop()
            client = nil
            runningTest = false
        }
        progress("Connecting to peer…")
        try await control.start()
        guard let localAddress = control.localAddress else { throw IPerfRunner.Failure.message("Cannot identify the test route.") }
        let route = "\(control.interfaceDescription) · \(localAddress) → \(host)"
        var rtts: [Double] = []
        for _ in 0..<6 {
            try Task.checkCancellation()
            let started = ProcessInfo.processInfo.systemUptime
            guard try await control.exchange("ping").action == "pong" else {
                throw IPerfRunner.Failure.message("Unexpected response. Update both Macs.")
            }
            rtts.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            try await Task.sleep(for: .milliseconds(50))
        }
        // Keep the control connection alive between phases, and detect a dead peer.
        progress("1 of 4 · Download speed…")
        let download = try await measure(executable, host, localAddress, control, reverse: true)
        _ = try await control.exchange("ping")
        progress("2 of 4 · Upload speed…")
        let upload = try await measure(executable, host, localAddress, control, reverse: false)
        _ = try await control.exchange("ping")
        let downloadRate = Self.udpRate(forTCPMbps: download.mbps, limitMbps: udpLimitMbps)
        let uploadRate = Self.udpRate(forTCPMbps: upload.mbps, limitMbps: udpLimitMbps)
        progress(String(format: "3 of 4 · Download delivery at %.1f Mbps…", downloadRate))
        let downloadUDP = try await measure(executable, host, localAddress, control, reverse: true, rate: downloadRate)
        _ = try await control.exchange("ping")
        progress(String(format: "4 of 4 · Upload delivery at %.1f Mbps…", uploadRate))
        let uploadUDP = try await measure(executable, host, localAddress, control, reverse: false, rate: uploadRate)
        try? await control.send(.init(action: "stop"))
        let mean = rtts.reduce(0, +) / Double(rtts.count)
        let jitter = (rtts.reduce(0) { $0 + pow($1 - mean, 2) } / Double(rtts.count)).squareRoot()
        return Result(rttMs: mean, jitterMs: jitter, downloadMbps: download.mbps,
                      downloadLossPct: downloadUDP.lossPercent!, uploadMbps: upload.mbps,
                      uploadLossPct: uploadUDP.lossPercent!, downloadUDPRateMbps: downloadRate,
                      uploadUDPRateMbps: uploadRate, downloadUDPJitterMs: downloadUDP.jitterMs!,
                      uploadUDPJitterMs: uploadUDP.jitterMs!, route: route)
    }

    /// Probe streaming delivery below saturation, not loss from an unlimited flood.
    static func udpRate(forTCPMbps mbps: Double, limitMbps: Int = 100) -> Double {
        min(Double(min(1000, max(25, limitMbps))), max(0.1, mbps * 0.5))
    }

    private func measure(_ executable: URL, _ host: String, _ local: String, _ control: SpeedTestControl,
                         reverse: Bool, rate: Double? = nil) async throws -> IPerfRunner.Measurement {
        try Task.checkCancellation()
        let ready = try await control.exchange("start")
        guard ready.action == "ready", let port = ready.port, port > 0 else {
            throw IPerfRunner.Failure.message("The peer could not prepare the network test.")
        }
        let helper = try IPerfRunner(executable: executable, arguments: IPerfRunner.clientArguments(
            host: host, localAddress: local, port: port, reverse: reverse, udpRateMbps: rate))
        client = helper
        defer { client = nil }
        return try IPerfRunner.parse(await helper.result(), udp: rate != nil)
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
        let lossy = loss > 1
        let highJitter = max(r.downloadUDPJitterMs, r.uploadUDPJitterMs) > 20

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
        bullets.append("Resolution: \(resLabel) — based on about \(Int(budget)) Mbps of measured TCP throughput.")
        bullets.append("UDP delivery was checked at the rates shown above; higher streaming rates may behave differently.")
        bullets.append("Adaptive bitrate: On — eases quality under load, restores it when the link clears.")
        bullets.append("Drop-to-newest + loss recovery: On — keeps motion smooth and heals quickly.")
        if regionAware {
            bullets.append("Region-aware: On — send only changed regions; lighter on a \(lossy ? "lossy" : "limited") link and crisper for text/UI.")
        } else {
            bullets.append("Region-aware: Off — a starting point based on TCP throughput.")
        }
        bullets.append(useHEVC
            ? "Codec: HEVC — better compression for a constrained link (experimental)."
            : "Codec: H.264 — reliable at this bandwidth.")
        if highJitter {
            bullets.append("Note: UDP jitter is high; the adaptive jitter buffer adds a little smoothing latency.")
        }

        let headline: String
        if r.downloadMbps <= 0 {
            headline = "Couldn't measure the link — re-run with both Macs updated."
        } else if lossy {
            headline = "UDP loss at the tested rates: optimized for resilience."
        } else if budget < 50 {
            headline = "Limited bandwidth: trade some resolution for smoothness."
        } else {
            headline = "Good TCP throughput and low loss at the tested UDP rates."
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
