import SwiftUI
import Combine

class DashboardViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedDevice: DiscoveredDevice?
    @Published var showAddDeviceSheet: Bool = false
    @Published var showDeviceDetail: Bool = false
    @Published var isConnecting: Bool = false
    @Published var connectionError: String?
    @Published var viewMode: ViewMode = .grid
    @Published var sortOrder: SortOrder = .name
    
    private var cancellables = Set<AnyCancellable>()
    
    enum ViewMode: String, CaseIterable {
        case grid
        case list
        
        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }
    
    enum SortOrder: String, CaseIterable {
        case name
        case lastSeen
        case status
        
        var displayName: String {
            switch self {
            case .name: return "Name"
            case .lastSeen: return "Last Seen"
            case .status: return "Status"
            }
        }
    }
    
    func filteredDevices(_ devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        var filtered = devices
        
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.ipAddress.contains(searchText)
            }
        }
        
        // Sort priority:
        // 1. THIS MAC (current device) always first
        // 2. TidalDrift peers second
        // 3. Other devices last
        // Within each category, apply user's sort preference
        filtered.sort { device1, device2 in
            // THIS MAC (current device) always comes first
            if device1.isCurrentDevice != device2.isCurrentDevice {
                return device1.isCurrentDevice
            }
            
            // TidalDrift peers come before non-peers
            if device1.isTidalDriftPeer != device2.isTidalDriftPeer {
                return device1.isTidalDriftPeer
            }
            
            // Within same category, apply user's sort preference
            switch sortOrder {
            case .name:
                return device1.name < device2.name
            case .lastSeen:
                return device1.lastSeen > device2.lastSeen
            case .status:
                if device1.isOnline != device2.isOnline {
                    return device1.isOnline
                }
                return device1.name < device2.name
            }
        }
        
        return filtered
    }
    
    func selectDevice(_ device: DiscoveredDevice) {
        selectedDevice = device
        showDeviceDetail = true
    }
    
    func connectToDevice(_ device: DiscoveredDevice, service: DiscoveredDevice.ServiceType) async {
        await MainActor.run {
            isConnecting = true
            connectionError = nil
        }
        
        do {
            switch service {
            case .screenSharing, .tidalDrift:
                try await ScreenShareConnectionService.shared.connect(to: device)
            case .fileSharing:
                try await ScreenShareConnectionService.shared.connectToFileShare(device: device)
            case .afp:
                try await ScreenShareConnectionService.shared.connectToAFP(device: device)
            case .ssh:
                ScreenShareConnectionService.shared.connectToSSH(device: device)
            case .tidalDrop:
                // For now, handle as file sharing
                if device.services.contains(.fileSharing) {
                    try await ScreenShareConnectionService.shared.connectToFileShare(device: device)
                } else if device.services.contains(.afp) {
                    try await ScreenShareConnectionService.shared.connectToAFP(device: device)
                }
            case .localCast:
                let viewer = try await LocalCastService.shared.connect(to: device)
                await MainActor.run { viewer.showWindow(nil) }
            }
            
            let record = ConnectionRecord(
                deviceId: device.id,
                deviceName: device.name,
                deviceIP: device.ipAddress,
                connectionType: service == .screenSharing ? .screenShare : .fileShare,
                wasSuccessful: true
            )
            
            await MainActor.run {
                AppState.shared.addConnectionRecord(record)
                isConnecting = false
            }
        } catch {
            await MainActor.run {
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }
    
    func refreshScan() {
        NetworkDiscoveryService.shared.refreshScan()
    }
    
    /// Single-button discovery: Bonjour refresh + subnet scan combined
    func discoverDevices() async {
        NetworkDiscoveryService.shared.clearStaleDevices()
        NetworkDiscoveryService.shared.refreshScan()
        
        let baseIP = NetworkUtils.getLocalIPAddress() ?? "192.168.1.1"
        await NetworkDiscoveryService.shared.scanSubnet(baseIP: baseIP)
    }
    
    func addManualDevice(name: String, ipAddress: String) {
        NetworkDiscoveryService.shared.addManualDevice(name: name, ipAddress: ipAddress)
        showAddDeviceSheet = false
    }
    
    func scanSpecificIP(_ ipAddress: String) async {
        await NetworkDiscoveryService.shared.scanIPForAllServices(ipAddress)
    }
    
    func scanSubnet(baseIP: String) async {
        await NetworkDiscoveryService.shared.scanSubnet(baseIP: baseIP)
    }
}
