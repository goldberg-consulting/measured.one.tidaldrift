import Foundation
import Network
import SystemConfiguration

/// Thread-safe flag for use in concurrent contexts (Swift 6 compatible).
/// Guards withCheckedContinuation callbacks against double-resume crashes.
final class AtomicFlag: @unchecked Sendable {
    private var _value: Bool
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    
    init(_ initialValue: Bool = false) {
        _value = initialValue
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    var value: Bool {
        get {
            os_unfair_lock_lock(lock)
            let v = _value
            os_unfair_lock_unlock(lock)
            return v
        }
        set {
            os_unfair_lock_lock(lock)
            _value = newValue
            os_unfair_lock_unlock(lock)
        }
    }
    
    /// Atomically checks if value is `expected`, sets it to `desired` if so.
    /// Returns true if the swap happened. Use this to safely guard
    /// one-shot operations (e.g. continuation.resume).
    @discardableResult
    func compareAndSwap(expected: Bool, desired: Bool) -> Bool {
        os_unfair_lock_lock(lock)
        if _value == expected {
            _value = desired
            os_unfair_lock_unlock(lock)
            return true
        }
        os_unfair_lock_unlock(lock)
        return false
    }
}

struct NetworkUtils {
    
    // MARK: - Cached Computer Name (avoids slow DNS lookup on every call)
    
    /// Cached computer name - computed once to avoid repeated slow DNS lookups
    /// Host.current().localizedName can take 2-5+ seconds on slow networks
    private static let _cachedComputerName: String = {
        // Use SCDynamicStoreCopyComputerName which is faster than Host.current().localizedName
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        // Fallback to ProcessInfo which is also fast
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty && hostName != "localhost" {
            return hostName.replacingOccurrences(of: ".local", with: "")
        }
        return "Mac"
    }()
    
    /// Get the computer name (cached for performance)
    static var computerName: String {
        return _cachedComputerName
    }
    
    /// Sanitized computer name for network service names (no spaces/special chars)
    static var sanitizedComputerName: String {
        return _cachedComputerName
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
    
    static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Skip loopback
                if name != "lo0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    
                    // Prefer en0 (Wi-Fi) but accept any valid local IP
                    if name == "en0" {
                        return ip
                    }
                    if address == nil {
                        address = ip
                    }
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return address
    }
    
    static func getAllIPAddresses() -> [String: String] {
        var addresses: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return addresses
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, socklen_t(0), NI_NUMERICHOST)
                addresses[name] = String(cString: hostname)
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return addresses
    }
    
    static func isValidIPAddress(_ string: String) -> Bool {
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        
        if inet_pton(AF_INET, string, &sin.sin_addr) == 1 {
            return true
        }
        if inet_pton(AF_INET6, string, &sin6.sin6_addr) == 1 {
            return true
        }
        return false
    }
    
    /// Whether a peer address is on the local network in the sense that
    /// unauthenticated LAN services (TidalDrop, the speed-test responder) may
    /// talk to it: private or link-local IPv4, loopback, or IPv6 link-local /
    /// unique-local. A zone suffix ("%en0") is ignored.
    static func isLocalPeerAddress(_ address: String) -> Bool {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        if bare == "127.0.0.1" || bare == "::1" { return true }
        if isLocalNetworkAddress(bare) { return true }
        let lower = bare.lowercased()
        guard isValidIPAddress(bare) else { return false }
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fd") || lower.hasPrefix("fc")
    }

    static func isLocalNetworkAddress(_ address: String) -> Bool {
        guard isValidIPAddress(address) else { return false }
        
        let privateRanges = [
            "10.",
            "172.16.", "172.17.", "172.18.", "172.19.",
            "172.20.", "172.21.", "172.22.", "172.23.",
            "172.24.", "172.25.", "172.26.", "172.27.",
            "172.28.", "172.29.", "172.30.", "172.31.",
            "192.168.",
            "169.254."
        ]
        
        return privateRanges.contains { address.hasPrefix($0) }
    }
    
    static func getSubnetMask(for interfaceName: String = "en0") -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            
            if name == interfaceName && interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                if let netmask = interface.ifa_netmask {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    return String(cString: hostname)
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return nil
    }
    
    static func getCurrentWiFiSSID() -> String? {
        // Use CoreWLAN for macOS WiFi SSID detection
        guard let interface = CWWiFiClient.shared().interface() else {
            return nil
        }
        return interface.ssid()
    }
    
    static func isNetworkAvailable() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)
        
        guard let reachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else {
            return false
        }
        
        var flags: SCNetworkReachabilityFlags = []
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {
            return false
        }
        
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        
        return isReachable && !needsConnection
    }
    
    static func getBroadcastAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "255.255.255.255"
        }
        
        defer { freeifaddrs(ifaddr) }
        
        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Filter for Wi-Fi (en0/en1) or Ethernet (en0/en1/en2...)
                if name.hasPrefix("en") || name.hasPrefix("eth") {
                    if let dstaddr = interface.ifa_dstaddr {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(dstaddr, socklen_t(dstaddr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, socklen_t(0), NI_NUMERICHOST)
                        let address = String(cString: hostname)
                        if address != "0.0.0.0" && address != "127.0.0.1" {
                            return address
                        }
                    }
                }
            }
            
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        
        return "255.255.255.255"
    }
    
    static func getMACAddress(for interfaceName: String = "en0") -> String? {
        return nil
    }
}

import CoreWLAN

// MARK: - Bundle Extension for Version Info

extension Bundle {
    /// Returns the app version string (CFBundleShortVersionString)
    var appVersion: String {
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    /// Returns the build number (CFBundleVersion)
    var buildNumber: String {
        return infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    /// Returns a combined version string (e.g., "1.3.5 (9)")
    var fullVersion: String {
        return "\(appVersion) (\(buildNumber))"
    }
}
