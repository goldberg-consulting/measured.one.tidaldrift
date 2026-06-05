import Foundation
import OSLog

/// Keeps the home LAN subnet routed directly over the physical interface so
/// TidalDrift (and other local) traffic bypasses a full-tunnel VPN (e.g. Palo
/// Alto GlobalProtect) while at home. It installs a small root LaunchDaemon
/// that adds a subnet route pinned to the physical interface; longest-prefix
/// match makes it win over the VPN's broader routes, and the daemon re-asserts
/// it every 15s and on network changes (the VPN watchdog can reclaim routes).
///
/// The daemon only fires when the recorded home subnet AND gateway MAC are
/// present, so it is inert on other networks. Install/remove each take one
/// admin authorization; afterward the daemon runs as root on its own.
///
/// Mirrors the standalone `unas-direct-route` utility, whole-subnet scope.
final class LocalDirectRouteService {
    static let shared = LocalDirectRouteService()
    private let logger = Logger(subsystem: "com.tidaldrift", category: "DirectRoute")

    static let label = "com.tidaldrift.direct-route"
    private let binPath = "/usr/local/bin/tidaldrift-direct-route.sh"
    private var plistPath: String { "/Library/LaunchDaemons/\(Self.label).plist" }

    private let subnetKey = "directRouteSubnet"
    private let gatewayKey = "directRouteGateway"

    struct HomeNetwork {
        let interface: String     // e.g. en0
        let ipv4: String          // e.g. 192.168.1.50
        let subnetCIDR: String    // e.g. 192.168.1.0/24
        let subnetPrefix: String  // e.g. 192.168.1.
        let gatewayIP: String     // e.g. 192.168.1.1
        let gatewayMAC: String    // e.g. aa:bb:cc:dd:ee:ff (as `arp` prints it)
    }

    struct Status {
        let installed: Bool
        let subnet: String?
        /// Interface the home gateway currently routes through (en* = direct,
        /// utun* = still in the VPN tunnel), or nil if unknown / away.
        let routingInterface: String?
        var isActive: Bool {
            guard let iface = routingInterface else { return false }
            return !iface.hasPrefix("utun")
        }
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    func currentStatus() -> Status {
        let subnet = UserDefaults.standard.string(forKey: subnetKey)
        var iface: String?
        if let gateway = UserDefaults.standard.string(forKey: gatewayKey),
           let out = run("/sbin/route", ["-n", "get", gateway])?.out {
            iface = value(of: "interface", in: out)
        }
        return Status(installed: isInstalled, subnet: subnet, routingInterface: iface)
    }

    // MARK: - Detection (user level)

    /// Find the physical LAN interface, its IPv4, the /24 subnet, and the gateway
    /// + its MAC. Deliberately does NOT use the default route: behind a
    /// full-tunnel VPN the default route is the tunnel (utun), while the physical
    /// interface still holds its home IP. We scan physical interfaces directly so
    /// detection works even while the VPN is up (the whole point of this tool).
    func detectHomeNetwork() -> HomeNetwork? {
        guard let (iface, ip) = physicalPrivateInterface() else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        let prefix = "\(octets[0]).\(octets[1]).\(octets[2])."
        let cidr = "\(prefix)0/24"

        // Home gateway from this interface's DHCP lease (still correct with the
        // VPN up), falling back to the conventional .1 of the subnet.
        var gateway = "\(prefix)1"
        if let router = run("/usr/sbin/ipconfig", ["getoption", iface, "router"])?.out
            .trimmingCharacters(in: .whitespacesAndNewlines),
           NetworkUtils.isValidIPAddress(router) {
            gateway = router
        }

        // Gateway MAC (best effort), captured in the same format `arp` prints so
        // the daemon's comparison against live `arp` output matches.
        var mac = ""
        if let arp = run("/usr/sbin/arp", ["-n", gateway])?.out,
           let at = arp.range(of: " at ") {
            mac = arp[at.upperBound...]
                .split(separator: " ").first.map(String.init) ?? ""
        }

        return HomeNetwork(interface: iface, ipv4: ip, subnetCIDR: cidr,
                           subnetPrefix: prefix, gatewayIP: gateway, gatewayMAC: mac)
    }

    /// A physical (en*) interface currently holding a private, non-link-local
    /// IPv4. Prefers en0. Ignores VPN (utun/ipsec) and virtual interfaces.
    private func physicalPrivateInterface() -> (iface: String, ip: String)? {
        var result: (String, String)?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            ptr = ifa.ifa_next
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }  // Wi-Fi / Ethernet only

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard NetworkUtils.isLocalNetworkAddress(ip), !ip.hasPrefix("169.254.") else { continue }

            if name == "en0" { return (name, ip) }
            if result == nil { result = (name, ip) }
        }
        return result
    }

    // MARK: - Enable / disable (privileged)

    @discardableResult
    func enable(_ home: HomeNetwork) async -> Bool {
        let scriptB64 = Data(makeDaemonScript(home).utf8).base64EncodedString()
        let plistB64 = Data(makePlist().utf8).base64EncodedString()

        // Root creates the files itself from inline base64 (no user-owned
        // executable is run as root), then loads the daemon. base64 contains
        // only [A-Za-z0-9+/=], so there are no quotes to escape.
        let command = [
            "mkdir -p /usr/local/bin",
            "printf %s '\(scriptB64)' | base64 -D > \(binPath)",
            "chmod 755 \(binPath)",
            "chown root:wheel \(binPath)",
            "printf %s '\(plistB64)' | base64 -D > \(plistPath)",
            "chown root:wheel \(plistPath)",
            "chmod 644 \(plistPath)",
            "launchctl bootout system/\(Self.label) 2>/dev/null; launchctl bootstrap system \(plistPath)",
            "launchctl enable system/\(Self.label)"
        ].joined(separator: " && ")

        let ok = await runAdmin(command)
        if ok {
            UserDefaults.standard.set(home.subnetCIDR, forKey: subnetKey)
            UserDefaults.standard.set(home.gatewayIP, forKey: gatewayKey)
            logger.info("Direct routing enabled for \(home.subnetCIDR, privacy: .public) via \(home.interface, privacy: .public)")
        }
        return ok
    }

    @discardableResult
    func disable() async -> Bool {
        var parts = ["launchctl bootout system/\(Self.label) 2>/dev/null; rm -f \(plistPath) \(binPath)"]
        if let subnet = UserDefaults.standard.string(forKey: subnetKey) {
            parts.append("route -n delete -net \(subnet) 2>/dev/null")
        }
        parts.append("true")
        let ok = await runAdmin(parts.joined(separator: "; "))
        if ok { logger.info("Direct routing disabled") }
        return ok
    }

    // MARK: - Daemon templates

    private func makeDaemonScript(_ home: HomeNetwork) -> String {
        """
        #!/bin/bash
        # Managed by TidalDrift. Pins the home subnet to the physical interface
        # so local traffic bypasses a full-tunnel VPN, only while on this network.
        set -u

        DESTS=( "\(home.subnetCIDR)" )
        HOME_SUBNET_PREFIX="\(home.subnetPrefix)"
        HOME_GATEWAY_IP="\(home.gatewayIP)"
        HOME_GATEWAY_MAC="\(home.gatewayMAC)"
        LOG="/var/log/tidaldrift-direct-route.log"

        log() { echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >>"$LOG" 2>/dev/null; }

        find_home_iface() {
          local iface=""
          while IFS= read -r line; do
            case "$line" in
              [a-z]*:*) iface="${line%%:*}" ;;
              *"inet ${HOME_SUBNET_PREFIX}"*)
                case "$iface" in
                  utun*|lo*|gif*|stf*|bridge*|"") : ;;
                  *) echo "$iface"; return 0 ;;
                esac
                ;;
            esac
          done < <(ifconfig)
          return 1
        }

        gateway_mac_ok() {
          [ -z "$HOME_GATEWAY_MAC" ] && return 0
          local mac
          mac="$(arp -n "$HOME_GATEWAY_IP" 2>/dev/null | awk '{print $4}' | head -1)"
          [ "$mac" = "$HOME_GATEWAY_MAC" ]
        }

        IFACE="$(find_home_iface)" || { log "not on home network; no changes"; exit 0; }

        if ! gateway_mac_ok; then
          log "home subnet present on $IFACE but gateway MAC mismatch; skipping"
          exit 0
        fi

        for d in "${DESTS[@]}"; do
          route -n delete -net "$d" >/dev/null 2>&1
          route -n add -net "$d" -interface "$IFACE" >/dev/null 2>&1
        done

        log "pinned direct via $IFACE: ${DESTS[*]}"
        """
    }

    private func makePlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>15</integer>
            <key>WatchPaths</key>
            <array>
                <string>/etc/resolv.conf</string>
                <string>/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist</string>
            </array>
            <key>StandardErrorPath</key>
            <string>/var/log/tidaldrift-direct-route.err</string>
            <key>StandardOutPath</key>
            <string>/var/log/tidaldrift-direct-route.out</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Process helpers

    private func runAdmin(_ command: String) async -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.run("/usr/bin/osascript", ["-e", source])
                cont.resume(returning: result?.code == 0)
            }
        }
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> (code: Int32, out: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            logger.error("run \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Extract `key: value` from `route get` / `ifconfig`-style output.
    private func value(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
