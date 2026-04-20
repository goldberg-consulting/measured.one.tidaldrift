import SwiftUI
import Combine

class DeviceDetailViewModel: ObservableObject {
    @Published var device: DiscoveredDevice
    @Published var isConnecting: Bool = false
    @Published var connectionError: String?
    @Published var showCredentialsSheet: Bool = false
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var saveCredentials: Bool = true
    @Published var connectionMode: ScreenShareMode = .control
    @Published var isTestingConnection: Bool = false
    @Published var connectionTestResult: Bool?
    
    init(device: DiscoveredDevice) {
        self.device = device
        loadSavedCredentials()
    }
    
    var isTrusted: Bool {
        AppState.shared.isDeviceTrusted(device.id)
    }
    
    var hasCredentials: Bool {
        KeychainService.shared.hasCredential(for: device.stableId)
    }
    
    var connectionHistory: [ConnectionRecord] {
        AppState.shared.connectionHistory.filter { $0.deviceId == device.id }
    }
    
    func toggleTrust() {
        AppState.shared.toggleDeviceTrust(device.id)
        objectWillChange.send()
    }
    
    func loadSavedCredentials() {
        if let credentials = try? KeychainService.shared.getCredential(for: device.stableId) {
            username = credentials.username
            password = credentials.password
        }
    }
    
    func saveCredentialsIfNeeded() {
        if saveCredentials && !username.isEmpty {
            try? KeychainService.shared.saveCredential(
                for: device.stableId,
                username: username,
                password: password
            )
        }
    }
    
    func deleteCredentials() {
        try? KeychainService.shared.deleteCredential(for: device.stableId)
        username = ""
        password = ""
    }
    
    func connect(to service: DiscoveredDevice.ServiceType) async {
        await MainActor.run {
            isConnecting = true
            connectionError = nil
        }
        
        do {
            switch service {
            case .screenSharing, .tidalDrift:
                let usernameToUse = username.isEmpty ? nil : username
                let passwordToUse = password.isEmpty ? nil : password
                try await ScreenShareConnectionService.shared.connect(
                    to: device,
                    mode: connectionMode,
                    username: usernameToUse,
                    password: passwordToUse
                )
            case .fileSharing:
                let usernameToUse = username.isEmpty ? nil : username
                try await ScreenShareConnectionService.shared.connectToFileShare(
                    device: device,
                    username: usernameToUse
                )
            case .afp:
                let usernameToUse = username.isEmpty ? nil : username
                try await ScreenShareConnectionService.shared.connectToAFP(
                    device: device,
                    username: usernameToUse
                )
            case .ssh:
                ScreenShareConnectionService.shared.connectToSSH(
                    device: device,
                    username: username.isEmpty ? nil : username
                )
            case .tidalDrop:
                if device.services.contains(.fileSharing) {
                    try await ScreenShareConnectionService.shared.connectToFileShare(device: device, username: username.isEmpty ? nil : username)
                } else if device.services.contains(.afp) {
                    try await ScreenShareConnectionService.shared.connectToAFP(device: device, username: username.isEmpty ? nil : username)
                }
            case .localCast:
                let viewer = try await LocalCastService.shared.connect(to: device)
                await MainActor.run { viewer.showWindow(nil) }
            }
            
            saveCredentialsIfNeeded()
            
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
            let record = ConnectionRecord(
                deviceId: device.id,
                deviceName: device.name,
                deviceIP: device.ipAddress,
                connectionType: service == .screenSharing ? .screenShare : .fileShare,
                wasSuccessful: false
            )
            
            await MainActor.run {
                AppState.shared.addConnectionRecord(record)
                connectionError = error.localizedDescription
                isConnecting = false
            }
        }
    }
    
    func testConnection() async {
        await MainActor.run {
            isTestingConnection = true
            connectionTestResult = nil
        }
        
        // Use smart resolution-based connection test (handles stale IPs)
        let result = await ScreenShareConnectionService.shared.testConnectionToDevice(device)
        
        await MainActor.run {
            connectionTestResult = result
            isTestingConnection = false
        }
    }
    
    func quickConnect() async {
        if device.services.contains(.screenSharing) {
            await connect(to: .screenSharing)
        } else if device.services.contains(.fileSharing) {
            await connect(to: .fileSharing)
        }
    }
}
