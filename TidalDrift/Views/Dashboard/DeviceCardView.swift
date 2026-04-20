import SwiftUI

struct DeviceCardView: View {
    @EnvironmentObject var viewModel: DashboardViewModel
    let device: DiscoveredDevice
    let onTap: () -> Void
    
    @State private var isPressed = false
    @State private var isTargetedForDrop = false
    @State private var showPINEntry = false
    
    @ObservedObject private var dropService = TidalDropService.shared
    
    /// Active transfer to/from this device
    private var activeTransfer: TidalDropService.DropTransfer? {
        dropService.activeTransfers.values.first { $0.remoteEndpoint == device.ipAddress }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            deviceIconSection
            deviceInfoSection
            serviceBadgeSection
            peerInfoSection
            
            // Show transfer progress if active
            if let transfer = activeTransfer {
                transferProgressSection(transfer)
            }
            
            onlineStatusSection
            actionButtonsSection
        }
        .padding(12)
        .frame(width: 160)
        .background(cardBackground)
        .overlay(cardOverlay)
        .shadow(color: shadowColor, radius: 4, x: 0, y: 2)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onTapGesture { handleTap() }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
        .sheet(isPresented: $showPINEntry) {
            LocalCastPINEntryView(
                deviceName: device.name,
                savedPassword: savedDevicePassword,
                onConnect: { password in
                    showPINEntry = false
                    connectLocalCast(password: password)
                },
                onCancel: {
                    showPINEntry = false
                }
            )
        }
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
    }
    
    private var cardOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(borderColor, lineWidth: isTargetedForDrop || device.isCurrentDevice ? 2 : 1)
    }
    
    private var borderColor: Color {
        if isTargetedForDrop {
            return Color.accentColor
        } else if device.isCurrentDevice {
            return Color.blue.opacity(0.6)
        } else if device.isTidalDriftPeer {
            return Color.tidalDriftPeer.opacity(0.4)
        }
        return Color.primary.opacity(0.05)
    }
    
    private var shadowColor: Color {
        if device.isCurrentDevice {
            return Color.blue.opacity(0.15)
        } else if device.isTidalDriftPeer {
            return Color.tidalDriftPeer.opacity(0.1)
        }
        return Color.black.opacity(0.05)
    }
    
    private func handleTap() {
        withAnimation { isPressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation { isPressed = false }
            onTap()
        }
    }
    
    /// Look up saved password for this device from Keychain.
    private var savedDevicePassword: String? {
        guard let creds = try? KeychainService.shared.getCredential(for: device.stableId) else {
            return nil
        }
        return creds.password.isEmpty ? nil : creds.password
    }
    
    private func startLocalCast() {
        // If saved credentials exist, auto-connect without showing the sheet
        if let password = savedDevicePassword {
            connectLocalCast(password: password)
        } else {
            showPINEntry = true
        }
    }
    
    private func connectLocalCast(password: String?) {
        Task {
            do {
                let viewer = try await LocalCastService.shared.connect(to: device, password: password)
                await MainActor.run {
                    viewer.showWindow(nil)
                }
            } catch {
                print("❌ LocalCast: Connection failed, falling back to VNC: \(error.localizedDescription)")
                onTap() // Fallback to standard VNC
            }
        }
    }
    
    /// System Screen Share + App Control: opens macOS Screen Sharing.app
    /// for the video and a floating TidalDrift panel for app-level control.
    private func startSystemScreenShare() {
        Task {
            do {
                let panel = try await LocalCastService.shared.connectSystemScreenShare(to: device)
                await MainActor.run {
                    panel.showWindow(nil)
                }
            } catch {
                print("❌ System Screen Share: \(error.localizedDescription)")
                // Fallback to plain VNC
                onTap()
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let targetDevice = device
        
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (item, error) in
                if let error = error {
                    print("TidalDrop: Drop load error: \(error.localizedDescription)")
                    return
                }
                
                let url: URL? = item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let fileURL = url else { return }
                
                let didStartAccess = fileURL.startAccessingSecurityScopedResource()
                defer { if didStartAccess { fileURL.stopAccessingSecurityScopedResource() } }
                
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { return }
                
                if isDirectory.boolValue {
                    self.sendFolderContents(at: fileURL, to: targetDevice)
                } else {
                    self.readAndSendFile(at: fileURL, to: targetDevice)
                }
            }
        }
        return true
    }
    
    /// Read file data while security-scoped access is still active, then send.
    private func readAndSendFile(at fileURL: URL, to device: DiscoveredDevice) {
        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("TidalDrop: Cannot read file \(fileURL.lastPathComponent)")
            return
        }
        let fileName = fileURL.lastPathComponent
        DispatchQueue.main.async {
            TidalDropService.shared.smartSendFileData(
                fileName: fileName, fileData: fileData, to: device
            )
        }
    }
    
    /// Read all files in a folder while security-scoped access is active, then send each.
    private func sendFolderContents(at folderURL: URL, to device: DiscoveredDevice) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        let files = contents.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return !isDir.boolValue
        }
        
        for file in files {
            readAndSendFile(at: file, to: device)
        }
    }
    
    
    private var deviceIconSection: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: iconGradientColors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                
                Image(systemName: device.deviceIcon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(iconColor)
            }
            
            // Badge in bottom-right corner
            if device.isCurrentDevice {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Image(systemName: "star.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .background(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                    .offset(x: 2, y: 2)
            } else if device.isTidalDriftPeer {
                Circle()
                    .fill(Color.tidalDriftPeer)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    )
                    .background(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
        }
        .padding(.top, 4)
    }
    
    private var iconGradientColors: [Color] {
        if device.isCurrentDevice {
            return [Color.blue.opacity(0.2), Color.blue.opacity(0.08)]
        } else if device.isTidalDriftPeer {
            return [Color.tidalDriftPeer.opacity(0.15), Color.tidalDriftPeer.opacity(0.05)]
        }
        return [Color.secondary.opacity(0.1), Color.secondary.opacity(0.05)]
    }
    
    private var iconColor: Color {
        if device.isCurrentDevice {
            return .blue
        } else if device.isTidalDriftPeer {
            return .tidalDriftPeer
        }
        return .primary.opacity(0.8)
    }
    
    private var deviceInfoSection: some View {
        VStack(spacing: 2) {
            Text(device.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            
            Text(device.ipAddress)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(device.isCurrentDevice ? .blue : .secondary)
                .lineLimit(1)
            
            if device.isCurrentDevice {
                Text("THIS MAC")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue))
            } else if device.isTidalDriftPeer, let model = device.peerModelName, !model.isEmpty {
                Text(cleanModelName(model))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.tidalDriftPeer.opacity(0.8))
                    .lineLimit(1)
            }
        }
    }
    
    /// Clean up model name and convert raw identifiers to friendly names
    private func cleanModelName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove trailing backslash or other escape characters
        while cleaned.hasSuffix("\\") || cleaned.hasSuffix("/") {
            cleaned = String(cleaned.dropLast())
        }
        
        // Convert raw model identifiers to friendly names
        // Format: "Mac17,2" or "MacBookPro18,1" etc.
        if cleaned.hasPrefix("Mac") && cleaned.contains(",") {
            // It's a raw identifier like "Mac17,2" - convert to friendly name
            return friendlyModelName(from: cleaned)
        }
        
        return cleaned
    }
    
    /// Convert raw model identifier to friendly name
    private func friendlyModelName(from identifier: String) -> String {
        let lower = identifier.lowercased()
        
        // Check for specific model families
        if lower.contains("macbookpro") { return "MacBook Pro" }
        if lower.contains("macbookair") { return "MacBook Air" }
        if lower.contains("macbook") { return "MacBook" }
        if lower.contains("imac") { return "iMac" }
        if lower.contains("macmini") { return "Mac mini" }
        if lower.contains("macpro") { return "Mac Pro" }
        if lower.contains("macstudio") { return "Mac Studio" }
        
        // Generic Mac identifier (e.g., "Mac17,2" for Apple Silicon)
        // These are typically MacBook Pro/Air on M-series chips
        if identifier.hasPrefix("Mac") && identifier.contains(",") {
            // Could be any Apple Silicon Mac - return generic
            return "Mac"
        }
        
        return identifier
    }
    
    private var serviceBadgeSection: some View {
        HStack(spacing: 4) {
            ForEach(Array(device.services).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { service in
                Image(systemName: service.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            if device.isTidalDriftPeer {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.tidalDriftPeer.opacity(0.6))
            }
        }
        .padding(.vertical, 2)
    }
    
    private var peerInfoSection: some View {
        Group {
            if device.isTidalDriftPeer && !device.isCurrentDevice {
                VStack(spacing: 2) {
                    if let processor = device.peerProcessorInfo, !processor.isEmpty {
                        Text(cleanModelName(processor))
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                    
                    // Always show peer info (no expand on hover)
                    if let memory = device.peerMemoryGB, memory > 0,
                       let macOS = device.peerMacOSVersion, !macOS.isEmpty {
                        Text("\(memory)GB • macOS \(cleanModelName(macOS))")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(height: 20)
            } else {
                Spacer().frame(height: 10)
            }
        }
    }
    
    @ViewBuilder
    private func transferProgressSection(_ transfer: TidalDropService.DropTransfer) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: transfer.isIncoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                
                Text(transfer.fileName)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundColor(.primary)
            }
            
            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
                .frame(height: 4)
            
            Text(transfer.status.isTransferring ? "\(Int(transfer.progress * 100))%" : statusText(transfer.status))
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.1))
        )
    }
    
    private func statusText(_ status: TidalDropStatus) -> String {
        switch status {
        case .pending: return "Connecting..."
        case .transferring: return "Transferring..."
        case .completed: return "Complete!"
        case .failed(let error): return "Failed: \(error)"
        }
    }
    
    
    private var onlineStatusSection: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(device.isOnline ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            
            Text(device.isOnline ? "ONLINE" : device.lastSeenText.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(device.isOnline ? .green : .secondary)
        }
        .padding(.bottom, 4)
    }
    
    private var actionButtonsSection: some View {
        VStack(spacing: 6) {
            if device.supportsLocalCast {
                // Two-button row for LocalCast-capable devices
                HStack(spacing: 4) {
                    Button(action: { startLocalCast() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                            Text("LOCALCAST")
                        }
                        .font(.system(size: 9, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.yellow))
                        .foregroundColor(.black)
                    }
                    .buttonStyle(.plain)
                    .help("Low-latency LocalCast streaming")
                    
                    Button(action: { startSystemScreenShare() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "play.display")
                            Text("SYS")
                        }
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 52)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.tidalDriftPeer))
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .help("System Screen Share + App Control: Apple's VNC with TidalDrift app picker")
                }
            } else {
                Button(action: { onTap() }) {
                    HStack(spacing: 4) {
                        Image(systemName: device.isTidalDriftPeer ? "macwindow.on.rectangle" : "link")
                        Text(device.isTidalDriftPeer ? "SCREEN SHARE" : "CONNECT")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(device.isTidalDriftPeer ? Color.tidalDriftPeer : Color.accentColor))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .help("Standard screen sharing")
            }
            
            HStack(spacing: 6) {
                if device.isTidalDriftPeer || device.services.contains(.ssh) {
                    Button(action: {
                        Task { await viewModel.connectToDevice(device, service: .ssh) }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal.fill")
                            Text("SSH")
                        }
                        .font(.system(size: 8, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .help("Quick SSH")
                }
                
                if device.isTidalDriftPeer || device.services.contains(.fileSharing) || device.services.contains(.afp) {
                    Button(action: {
                        Task {
                            let service: DiscoveredDevice.ServiceType = device.isTidalDriftPeer ? .tidalDrop : (device.services.contains(.fileSharing) ? .fileSharing : .afp)
                            await viewModel.connectToDevice(device, service: service)
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                            Text("FILES")
                        }
                        .font(.system(size: 8, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .help("Open Files")
                }
            }
        }
        .padding(.bottom, 4)
    }
}
