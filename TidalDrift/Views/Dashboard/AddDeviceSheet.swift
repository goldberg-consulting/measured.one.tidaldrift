import SwiftUI

struct AddDeviceSheet: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var discoveryService = NetworkDiscoveryService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var deviceName: String = ""
    @State private var ipAddress: String = ""
    @State private var port: String = "5900"
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var validationSuccess: String?
    @State private var isScanningIP = false
    
    var body: some View {
        VStack(spacing: 20) {
            header
            
            form
            
            scanSection
            
            #if DEBUG
            loopbackSection
            #endif
            
            if let error = validationError {
                errorView(error)
            }
            
            if let success = validationSuccess {
                successView(success)
            }
            
            buttons
        }
        .padding(24)
        .frame(width: 420)
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            
            Text("Add Device")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Enter an IP address or scan your network")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var form: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Device Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("e.g., Office iMac", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("IP Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("e.g., 192.168.1.100", text: $ipAddress)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Port (optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("5900", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
        }
    }
    
    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button {
                    scanSpecificIP()
                } label: {
                    HStack {
                        if isScanningIP {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("Scan IP")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(ipAddress.isEmpty || isScanningIP || discoveryService.isScanningSubnet)
                
                Button {
                    scanSubnet()
                } label: {
                    HStack {
                        if discoveryService.isScanningSubnet {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "network")
                        }
                        Text("Scan Subnet")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(discoveryService.isScanningSubnet || isScanningIP)
            }
            
            if discoveryService.isScanningSubnet {
                VStack(spacing: 4) {
                    ProgressView(value: discoveryService.scanProgress)
                        .progressViewStyle(.linear)
                    Text("Scanning network... \(Int(discoveryService.scanProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
    
    private func errorView(_ error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(error)
                .font(.caption)
                .foregroundColor(.orange)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
    }
    
    private func successView(_ message: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            
            Text(message)
                .font(.caption)
                .foregroundColor(.green)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.1))
        )
    }
    
    private var loopbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Development")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                NetworkDiscoveryService.shared.addManualDevice(
                    name: "Loopback (This Mac)",
                    ipAddress: "127.0.0.1",
                    port: Int(LocalCastConfiguration.hostPort),
                    services: [.screenSharing, .localCast]
                )
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Add Loopback Device")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.purple.opacity(0.1))
        )
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Button("Add Device") {
                addDevice()
            }
            .buttonStyle(.borderedProminent)
            .disabled(deviceName.isEmpty || ipAddress.isEmpty || isValidating)
        }
    }
    
    private func scanSpecificIP() {
        guard NetworkUtils.isValidIPAddress(ipAddress) else {
            validationError = "Invalid IP address format"
            validationSuccess = nil
            return
        }
        
        isScanningIP = true
        validationError = nil
        validationSuccess = nil
        
        Task {
            await viewModel.scanSpecificIP(ipAddress)
            
            await MainActor.run {
                isScanningIP = false
                // Check if device was found
                if discoveryService.discoveredDevices.contains(where: { $0.ipAddress == ipAddress }) {
                    validationSuccess = "Found services at \(ipAddress)! Device added to list."
                    // Auto-fill name if empty
                    if deviceName.isEmpty {
                        deviceName = "Mac at \(ipAddress)"
                    }
                } else {
                    validationError = "No screen sharing or file sharing found at \(ipAddress)"
                }
            }
        }
    }
    
    private func scanSubnet() {
        // Get local IP to determine subnet
        let localIP = NetworkUtils.getLocalIPAddress() ?? "192.168.1.1"
        
        Task {
            await viewModel.scanSubnet(baseIP: localIP)
        }
    }
    
    private func addDevice() {
        guard NetworkUtils.isValidIPAddress(ipAddress) else {
            validationError = "Invalid IP address format"
            return
        }
        
        viewModel.addManualDevice(name: deviceName, ipAddress: ipAddress)
    }
}

struct AddDeviceSheet_Previews: PreviewProvider {
    static var previews: some View {
        AddDeviceSheet(viewModel: DashboardViewModel())
    }
}
