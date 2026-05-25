import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localCast = LocalCastService.shared
    @ObservedObject private var discoveryService = NetworkDiscoveryService.shared
    @ObservedObject private var clipboardService = ClipboardSyncService.shared
    @State private var isTogglingLocalCast = false
    @State private var isEditingName = false
    @State private var editingNameText = ""
    
    private var otherDevices: [DiscoveredDevice] {
        appState.discoveredDevices.filter { !$0.isCurrentDevice }
    }
    
    private var localDisplayName: String {
        let custom = appState.settings.tidalDriftDisplayName
        return custom.isEmpty ? appState.computerName : custom
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection

            Divider().padding(.vertical, 6)

            localCastSection

            Divider().padding(.vertical, 6)

            devicesSection

            Divider().padding(.vertical, 6)

            quickSettingsSection

            Divider().padding(.vertical, 6)

            actionsSection
        }
        .padding(12)
        // Fill the panel width, but keep the natural vertical size. AppDelegate
        // asks the hosting view for `fittingSize` and sizes the NSPanel to
        // match; forcing maxHeight here reintroduces a blank tail.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                if isEditingName {
                    HStack(spacing: 4) {
                        TextField("Display name", text: $editingNameText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(maxWidth: 160)
                            .onSubmit { commitNameEdit() }
                        Button(action: { commitNameEdit() }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        Button(action: { isEditingName = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(localDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Button(action: {
                            editingNameText = appState.settings.tidalDriftDisplayName.isEmpty
                                ? appState.computerName
                                : appState.settings.tidalDriftDisplayName
                            isEditingName = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename this Mac on the TidalDrift network")
                    }
                }
                Text(appState.localIPAddress)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                StatusDot(on: appState.screenSharingEnabled, label: "Screen")
                StatusDot(on: appState.fileSharingEnabled, label: "File")
                StatusDot(on: appState.tidalDropListening, label: "Drop")
            }
        }
    }
    
    private func commitNameEdit() {
        let trimmed = editingNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDefault = trimmed.isEmpty || trimmed == appState.computerName
        appState.settings.tidalDriftDisplayName = isDefault ? "" : trimmed
        isEditingName = false
        TidalDriftPeerService.shared.restartAdvertising()
    }
    
    // MARK: - LocalCast
    
    private var localCastSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(localCast.isHosting ? .yellow : .secondary)
                    .font(.system(size: 12))
                Text("Metal Streaming Host")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                
                if isTogglingLocalCast {
                    ProgressView().scaleEffect(0.6).frame(width: 36)
                } else {
                    Toggle("", isOn: Binding(
                        get: { localCast.isHosting },
                        set: { newValue in
                            isTogglingLocalCast = true
                            Task {
                                if newValue {
                                    do {
                                        try await localCast.startHosting()
                                    } catch let error as LocalCastError {
                                        await MainActor.run {
                                            let message = error.errorDescription ?? "Failed to start LocalCast"
                                            (NSApp.delegate as? AppDelegate)?
                                                .showMetalStreamingPermissionAlert(message: message)
                                        }
                                    } catch {
                                        await MainActor.run {
                                            (NSApp.delegate as? AppDelegate)?
                                                .showMetalStreamingPermissionAlert(message: error.localizedDescription)
                                        }
                                    }
                                } else {
                                    localCast.stopHosting()
                                }
                                await MainActor.run { isTogglingLocalCast = false }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .scaleEffect(0.65)
                    .labelsHidden()
                }
            }
            if localCast.isHosting {
                if !localCast.activeConnections.isEmpty {
                    ForEach(localCast.activeConnections) { conn in
                        HStack(spacing: 4) {
                            Image(systemName: "display").font(.system(size: 10))
                            Text(conn.clientName).font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                    }
                } else {
                    Text("Waiting for connections...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.leading, 20)
                }
            }
        }
    }
    
    // MARK: - Devices
    
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Nearby Devices")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                
                Spacer()
                
                Text("\(otherDevices.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .padding(.bottom, 2)
            
            if otherDevices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "network.slash")
                            .font(.title3)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No devices found")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                let rowHeight: CGFloat = 38
                let listHeight = min(CGFloat(otherDevices.count) * rowHeight, 240)
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(otherDevices) { device in
                            MenuBarDeviceRow(device: device)
                        }
                    }
                }
                .frame(height: listHeight)
                .clipped()
            }
        }
    }
    
    // MARK: - Quick Settings
    
    private var quickSettingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Settings")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .frame(width: 16)
                    .font(.system(size: 10))
                Text("Peer Discovery")
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $appState.settings.peerDiscoveryEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.6)
                    .labelsHidden()
            }
            
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .frame(width: 16)
                    .font(.system(size: 10))
                Text("Clipboard Sync")
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $clipboardService.isEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.6)
                    .labelsHidden()
            }
        }
    }
    
    // MARK: - Actions
    
    private var actionsSection: some View {
        VStack(spacing: 2) {
            MenuBarActionButton(icon: "arrow.clockwise", label: discoveryService.isScanningSubnet ? "Scanning..." : "Discover Devices") {
                Task {
                    NetworkDiscoveryService.shared.refreshScan()
                    let baseIP = NetworkUtils.getLocalIPAddress() ?? "192.168.1.1"
                    await NetworkDiscoveryService.shared.scanSubnet(baseIP: baseIP)
                }
            }
            .disabled(discoveryService.isScanningSubnet)
            
            MenuBarActionButton(icon: "gearshape", label: "Settings...") {
                (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                    // Route directly to the AppDelegate instead of walking the
                    // responder chain via NSApp.sendAction. On macOS Sonoma+,
                    // SwiftUI synthesises a hidden handler for
                    // `showSettingsWindow:` and pops up a phantom Settings
                    // scene (this app deliberately doesn't declare a SwiftUI
                    // `Settings` scene — we manage the window manually).
                    // That phantom window becomes key and silently absorbs
                    // every subsequent menu-bar click, making the app look
                    // frozen. Direct delegate dispatch bypasses SwiftUI's
                    // interception and always reaches our showSettings().
                    (NSApp.delegate as? AppDelegate)?.showSettingsWindow(nil)
                }
            }
            
            MenuBarActionButton(icon: "arrow.counterclockwise", label: "Run Setup Wizard") {
                (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                    (NSApp.delegate as? AppDelegate)?.showOnboarding()
                }
            }
            
            Divider().padding(.vertical, 2)
            
            MenuBarActionButton(icon: "power", label: "Quit TidalDrift") {
                (NSApp.delegate as? AppDelegate)?.requestQuit(nil)
            }
        }
    }
}

// MARK: - Compact Status Dot

struct StatusDot: View {
    let on: Bool
    let label: String
    
    var body: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(on ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Action Button

struct MenuBarActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Device Row

struct MenuBarDeviceRow: View {
    let device: DiscoveredDevice
    @ObservedObject private var localCast = LocalCastService.shared
    @State private var isHovering = false
    
    private var showLocalCast: Bool {
        device.services.contains(.localCast)
    }
    private var showSSH: Bool {
        device.services.contains(.ssh) || device.isTidalDriftPeer
    }
    
    /// Non-prompting peek used to decide whether we have something to send.
    /// Computed properties are evaluated on every SwiftUI re-render; calling
    /// the auth-gated `getCredential` here would put up Touch ID on the main
    /// thread and freeze the menu panel.
    private var savedDevicePassword: String? {
        guard let creds = KeychainService.shared.peekCredential(for: device) else {
            return nil
        }
        return creds.password.isEmpty ? nil : creds.password
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: device.deviceIcon)
                    .font(.system(size: 11))
                    .foregroundColor(device.isTidalDriftPeer ? .red : .accentColor)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(device.isTidalDriftPeer ? .red : .primary)
                        .lineLimit(1)
                    Text(device.ipAddress)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Inline quick-action buttons (visible on hover)
                if isHovering {
                    HStack(spacing: 4) {
                        QuickActionIcon(icon: "display", color: .blue, tooltip: "Screen Share (VNC)") {
                            (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                                Task {
                                    await WakeOnLANService.shared.prepareForConnection(to: device, service: .screenSharing)
                                    try? await ScreenShareConnectionService.shared.connect(to: device)
                                }
                            }
                        }
                        
                        if showLocalCast {
                            QuickActionIcon(icon: "bolt.fill", color: .purple, tooltip: "Metal Stream (high-fps)") {
                                (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                                    startMetalStreaming()
                                }
                            }
                        }
                        
                        QuickActionIcon(icon: "folder", color: .orange, tooltip: "File Share") {
                            (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                                Task {
                                    await WakeOnLANService.shared.prepareForConnection(to: device, service: .fileSharing)
                                    try? await ScreenShareConnectionService.shared.connectToFileShare(device: device)
                                }
                            }
                        }
                        
                        if showSSH {
                            QuickActionIcon(icon: "terminal", color: .green, tooltip: "SSH") {
                                (NSApp.delegate as? AppDelegate)?.runAfterMenuDismissed {
                                    Task {
                                        await WakeOnLANService.shared.prepareForConnection(to: device, service: .ssh)
                                        ScreenShareConnectionService.shared.connectToSSH(device: device)
                                    }
                                }
                            }
                        }
                        
                        QuickActionIcon(icon: "info.circle", color: .secondary, tooltip: "Details") {
                            DeviceDetailWindowManager.shared.showDetail(for: device)
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    // Status indicators when not hovering
                    HStack(spacing: 3) {
                        if device.isTidalDriftPeer {
                            Image(systemName: "wave.3.right")
                                .font(.system(size: 8))
                                .foregroundColor(.blue)
                        }
                        Circle()
                            .fill(device.isOnline ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
            }
        }
    }

    /// Opens the TidalDrift Metal-accelerated streaming viewer for the given
    /// device. Uses the keychain password if one is saved; otherwise the
    /// session connects without a password and the host auth flow decides
    /// whether to reject it.
    private func startMetalStreaming() {
        let password = device.localCastAuthRequired == true ? savedDevicePassword : nil
        Task {
            do {
                await WakeOnLANService.shared.prepareForConnection(to: device, service: .localCast)
                let controller = try await LocalCastService.shared.connect(to: device, password: password)
                await MainActor.run {
                    controller.showWindow(nil)
                    controller.window?.orderFrontRegardless()
                }
            } catch {
                print("MenuBar Metal streaming failed: \(error)")
                await MainActor.run {
                    (NSApp.delegate as? AppDelegate)?.showMetalStreamUnavailableAlert()
                }
            }
        }
    }
}

// MARK: - Quick Action Icon Button

struct QuickActionIcon: View {
    let icon: String
    let color: Color
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isHovering ? .white : color)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovering ? color : color.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovering = $0 }
    }
}

struct MenuBarView_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarView()
            .environmentObject(AppState.shared)
    }
}
