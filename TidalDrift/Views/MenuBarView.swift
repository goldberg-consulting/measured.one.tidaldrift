import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var discoveryService = NetworkDiscoveryService.shared
    @ObservedObject private var clipboardService = ClipboardSyncService.shared
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
            
            devicesSection
            
            Divider().padding(.vertical, 6)
            
            quickSettingsSection
            
            Divider().padding(.vertical, 6)
            
            actionsSection
        }
        .padding(12)
        .frame(width: 340)
    }
    
    /// Close the menu bar popover, then run an action on the next run loop
    /// so the target window can become key without competing for focus.
    private func dismissPopoverAndRun(_ action: @escaping () -> Void) {
        if let popover = NSApp.windows.first(where: {
            $0.isVisible
                && ($0.level == .statusBar
                    || $0.styleMask.contains(.nonactivatingPanel)
                    || $0.className.contains("StatusBar"))
        }) {
            popover.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
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
                dismissPopoverAndRun {
                    NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
                }
            }
            
            MenuBarActionButton(icon: "arrow.counterclockwise", label: "Run Setup Wizard") {
                dismissPopoverAndRun {
                    (NSApp.delegate as? AppDelegate)?.showOnboarding()
                }
            }
            
            Divider().padding(.vertical, 2)
            
            MenuBarActionButton(icon: "power", label: "Quit TidalDrift") {
                NSApplication.shared.terminate(nil)
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
    @State private var isHovering = false
    
    private var showSSH: Bool {
        device.services.contains(.ssh) || device.isTidalDriftPeer
    }
    
    private var savedDevicePassword: String? {
        guard let creds = try? KeychainService.shared.getCredential(for: device.stableId) else {
            return nil
        }
        return creds.password.isEmpty ? nil : creds.password
    }
    
    /// Close the status-bar popover before opening external apps/URLs.
    private func dismissPopoverAndRun(_ action: @escaping () -> Void) {
        if let popover = NSApp.keyWindow,
           popover.level == .statusBar || popover.styleMask.contains(.nonactivatingPanel) || popover.className.contains("StatusBar") {
            popover.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            action()
        }
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
                            dismissPopoverAndRun {
                                Task { try? await ScreenShareConnectionService.shared.connect(to: device) }
                            }
                        }
                        
                        QuickActionIcon(icon: "folder", color: .orange, tooltip: "File Share") {
                            dismissPopoverAndRun {
                                Task { try? await ScreenShareConnectionService.shared.connectToFileShare(device: device) }
                            }
                        }
                        
                        if showSSH {
                            QuickActionIcon(icon: "terminal", color: .green, tooltip: "SSH") {
                                dismissPopoverAndRun {
                                    ScreenShareConnectionService.shared.connectToSSH(device: device)
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
