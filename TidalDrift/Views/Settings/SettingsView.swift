import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            LocalCastSettingsView()
                .tabItem {
                    Label("Metal Streaming", systemImage: "bolt.fill")
                }
            
            NetworkSettingsView()
                .tabItem {
                    Label("Network", systemImage: "network")
                }
            
            PermissionDiagnosticView()
                .tabItem {
                    Label("Permissions", systemImage: "hand.raised")
                }
            
            SecuritySettingsView()
                .tabItem {
                    Label("Security", systemImage: "lock.shield")
                }
            
            MaintenanceSettingsView()
                .tabItem {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                }
            
            TestSuiteView()
                .tabItem {
                    Label("Tests", systemImage: "testtube.2")
                }
            
            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 600, height: 520)
    }
}

struct MaintenanceSettingsView: View {
    @State private var showCleanup = false
    @State private var duplicateCount = 0
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.orange)
                        Text("Installation Cleanup")
                            .font(.headline)
                    }
                    
                    Text("Find and remove duplicate TidalDrift installations to free up space and avoid confusion.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        if duplicateCount > 0 {
                            Text("\(duplicateCount) duplicate(s) found")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        
                        Spacer()
                        
                        Button("Scan & Cleanup...") {
                            showCleanup = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 8)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.blue)
                        Text("Reset App")
                            .font(.headline)
                    }
                    
                    Text("Reset TidalDrift to its initial state. This will clear all settings and restart the onboarding process.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Spacer()
                        
                        Button("Reset All Settings") {
                            resetApp()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCleanup) {
            CleanupDuplicatesView()
        }
        .onAppear {
            checkForDuplicates()
        }
    }
    
    private func checkForDuplicates() {
        DispatchQueue.global(qos: .utility).async {
            let count = InstallationCleanupService.shared.findAllInstallations().count
            DispatchQueue.main.async {
                duplicateCount = count
            }
        }
    }
    
    private func resetApp() {
        AppState.shared.resetAllSettingsAndShowOnboarding()
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var clipboardService = ClipboardSyncService.shared
    @State private var launchAtLoginError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.launchAtLogin },
            set: { enabled in
                appState.settings.launchAtLogin = enabled
                if !SettingsService.shared.setLaunchAtLogin(enabled) {
                    appState.settings.launchAtLogin = SettingsService.shared.isLaunchAtLoginEnabled()
                    launchAtLoginError = "Launch at login could not be changed. Make sure TidalDrift is installed in /Applications."
                } else {
                    launchAtLoginError = nil
                }
            }
        )
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Toggle("Show menu bar icon", isOn: $appState.settings.showMenuBarIcon)
                
                Toggle("Show notifications", isOn: $appState.settings.showNotifications)
            }
            
            Section("Clipboard") {
                Toggle("Sync clipboard between Macs", isOn: $clipboardService.isEnabled)
                
                Text("When enabled, anything you copy will be available on other Macs running TidalDrift on your network.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("TidalDrop") {
                TidalDropFolderPicker()
            }
            
            Section("Experimental Features") {
                Toggle(isOn: $appState.settings.showExperimentalFeatures) {
                    HStack {
                        Image(systemName: "flask")
                            .foregroundColor(.purple)
                        VStack(alignment: .leading) {
                            Text("Show Experimental Features")
                            Text("Enable Clipboard Sync in sidebar")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                #if DEBUG
                if appState.settings.showExperimentalFeatures {
                    Toggle(isOn: Binding(
                        get: { AppStreamingService.shared.isExperimentalEnabled },
                        set: { AppStreamingService.shared.setExperimentalEnabled($0) }
                    )) {
                        HStack {
                            Image(systemName: "app.connected.to.app.below.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("App Streaming (debug)")
                                Text("Per-window streaming — dormant pipeline, debug builds only")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 24)
                }
                #endif

                Text("⚠️ These features are experimental and may not work reliably. Enable at your own risk.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            
            Section {
                Picker("Appearance", selection: $appState.settings.theme) {
                    ForEach(AppSettings.AppTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .onChange(of: appState.settings.theme) { theme in
                    SettingsService.shared.applyTheme(theme)
                }
            }
            
            Section {
                Button {
                    appState.hasCompletedOnboarding = false
                    (NSApp.delegate as? AppDelegate)?.showOnboarding()
                } label: {
                    Label("Run Setup Wizard Again", systemImage: "arrow.counterclockwise")
                }
                
                Button(role: .destructive) {
                    appState.resetAllSettingsAndShowOnboarding()
                } label: {
                    Label("Reset All Settings", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            appState.settings.launchAtLogin = SettingsService.shared.isLaunchAtLoginEnabled()
            SettingsService.shared.applyTheme(appState.settings.theme)
        }
    }
}

struct NetworkSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Form {
            Section("Discovery") {
                Toggle("Enable Peer Discovery", isOn: $appState.settings.peerDiscoveryEnabled)
                    .help("Allows other TidalDrift instances to find this Mac and vice versa.")
                
                Toggle("Enable SSH Discovery", isOn: $appState.settings.sshDiscoveryEnabled)
                    .help("Actively scan the network for devices with SSH enabled.")
                
                Picker("Scan interval", selection: $appState.settings.scanIntervalSeconds) {
                    ForEach(AppSettings.scanIntervalOptions, id: \.self) { interval in
                        Text(AppSettings.scanIntervalDisplayName(for: interval)).tag(interval)
                    }
                }
                
                Toggle("Auto-connect to trusted devices", isOn: $appState.settings.autoConnectTrustedDevices)
            }
            
            Section {
                Toggle("Enable Wake-on-LAN", isOn: $appState.settings.wakeOnLANEnabled)
                
                if appState.settings.wakeOnLANEnabled {
                    Toggle("Auto-wake before connecting", isOn: $appState.settings.autoWakeBeforeConnect)
                        .help("Automatically send a wake signal before connecting to an offline device")
                    
                    Picker("WOL Port", selection: $appState.settings.wakeOnLANPort) {
                        ForEach(AppSettings.wolPortOptions, id: \.self) { port in
                            Text(AppSettings.wolPortDisplayName(for: port)).tag(port)
                        }
                    }
                    
                    Picker("Retry attempts", selection: $appState.settings.wakeOnLANRetries) {
                        ForEach(AppSettings.wolRetryOptions, id: \.self) { count in
                            Text("\(count) \(count == 1 ? "attempt" : "attempts")").tag(count)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Wake-on-LAN")
                    Image(systemName: "poweron")
                        .foregroundColor(.green)
                }
            } footer: {
                Text("Wake sleeping Macs on your network. Requires the target Mac to have Wake for network access enabled in Energy Saver settings.")
                    .font(.caption)
            }
            
            Section {
                DirectRoutingToggle()
            } header: {
                HStack {
                    Text("Local Direct Routing")
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.green)
                }
            } footer: {
                Text("Keeps your home LAN (TidalDrift peers, NAS, etc.) routed directly over Wi-Fi/Ethernet instead of through a full-tunnel VPN, only while you're on your home network. Confirm this is allowed by your employer's VPN policy before enabling.")
                    .font(.caption)
            }

            Section("Network Status") {
                HStack {
                    Text("Local IP")
                    Spacer()
                    Text(appState.localIPAddress)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Computer Name")
                    Spacer()
                    Text(appState.computerName)
                        .foregroundColor(.secondary)
                }
                
                Button("Refresh") {
                    appState.refreshLocalInfo()
                }
            }
            
            Section("Sharing Status") {
                HStack {
                    Text("Screen Sharing")
                    Spacer()
                    StatusBadge(isEnabled: appState.screenSharingEnabled)
                }
                
                HStack {
                    Text("File Sharing")
                    Spacer()
                    StatusBadge(isEnabled: appState.fileSharingEnabled)
                }
                
                RemoteLoginToggle()
                
                Button("Open Sharing Settings") {
                    SharingConfigurationService.shared.openSharingPreferences()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct SecuritySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var trustedDeviceCount: Int = 0
    @State private var savedCredentialsCount: Int = 0
    @State private var isMigrating: Bool = false
    @State private var migrationResult: String?

    /// Bridge `useBiometrics` through this binding so we can run the
    /// keychain re-save migration when the user flips the switch. Without
    /// the migration, items saved while biometrics were enabled keep
    /// prompting for Touch ID forever — the saved ACL outlives the setting.
    private var biometricsBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.useBiometrics },
            set: { newValue in
                appState.settings.useBiometrics = newValue
                runBiometricMigration(newValue: newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section("Authentication") {
                Toggle("Use Touch ID when available", isOn: biometricsBinding)
                    .disabled(isMigrating)

                if isMigrating {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6)
                        Text("Updating saved credentials...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let migrationResult {
                    Text(migrationResult)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Log connection attempts", isOn: $appState.settings.enableConnectionLogging)
            }
            
            Section("Trusted Devices") {
                HStack {
                    Text("Trusted devices")
                    Spacer()
                    Text("\(appState.trustedDevices.count)")
                        .foregroundColor(.secondary)
                }
                
                Button("Clear All Trusted Devices") {
                    appState.trustedDevices.removeAll()
                }
                .foregroundColor(.red)
                .disabled(appState.trustedDevices.isEmpty)
            }
            
            Section("Saved Credentials") {
                HStack {
                    Text("Saved credentials")
                    Spacer()
                    Text("\(savedCredentialsCount)")
                        .foregroundColor(.secondary)
                }
                
                Button("View in Keychain Access") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
                }
            }
            
            Section("Connection History") {
                HStack {
                    Text("Logged connections")
                    Spacer()
                    Text("\(appState.connectionHistory.count)")
                        .foregroundColor(.secondary)
                }
                
                Button("Clear History") {
                    appState.connectionHistory.removeAll()
                }
                .foregroundColor(.red)
                .disabled(appState.connectionHistory.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadCounts()
        }
    }
    
    private func loadCounts() {
        trustedDeviceCount = appState.trustedDevices.count
        if let ids = try? KeychainService.shared.getAllSavedDeviceIds() {
            savedCredentialsCount = ids.count
        }
    }

    /// Re-save every keychain item under the new biometric policy. Runs once
    /// per toggle change. Without this, an item saved while biometrics were
    /// on keeps prompting for Touch ID even after the user turns biometrics
    /// off, because the ACL stamped on the item is independent of the
    /// app's current setting.
    private func runBiometricMigration(newValue: Bool) {
        guard savedCredentialsCount > 0 else { return }
        isMigrating = true
        migrationResult = nil

        Task {
            do {
                let summary = try await KeychainService.shared.migrateCredentialsToCurrentBiometricSetting()
                let message: String
                if summary.processed == 0 {
                    message = "No saved credentials to update."
                } else if summary.failed == 0 && summary.migrated == summary.processed {
                    message = "Updated \(summary.migrated) saved credential\(summary.migrated == 1 ? "" : "s")."
                } else {
                    var parts: [String] = []
                    if summary.migrated > 0 { parts.append("\(summary.migrated) updated") }
                    if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
                    if summary.failed > 0 { parts.append("\(summary.failed) failed") }
                    message = parts.joined(separator: ", ") + "."
                }
                await MainActor.run {
                    migrationResult = message
                    isMigrating = false
                    loadCounts()
                }
            } catch {
                await MainActor.run {
                    migrationResult = "Could not update credentials: \(error.localizedDescription)"
                    isMigrating = false
                }
            }
        }
    }
}

struct StatusBadge: View {
    let isEnabled: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(isEnabled ? "Enabled" : "Disabled")
                .font(.caption)
                .foregroundColor(isEnabled ? .green : .orange)
        }
    }
}

struct RemoteLoginToggle: View {
    @State private var isEnabled: Bool = false
    @State private var isToggling: Bool = false
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Login (SSH)")
                Text("Requires admin password to change")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isToggling {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        toggleRemoteLogin(enable: newValue)
                    }
                ))
                .labelsHidden()
            }
        }
        .onAppear {
            checkStatus()
        }
        .alert("Remote Login Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    private func checkStatus() {
        Task {
            let enabled = await SharingConfigurationService.shared.isRemoteLoginEnabled()
            await MainActor.run {
                isEnabled = enabled
            }
        }
    }
    
    private func toggleRemoteLogin(enable: Bool) {
        isToggling = true
        
        Task {
            let success = await SharingConfigurationService.shared.toggleRemoteLogin(enable: enable)
            
            // Wait for system to process
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Verify the new state
            let newState = await SharingConfigurationService.shared.isRemoteLoginEnabled()
            
            await MainActor.run {
                isToggling = false
                isEnabled = newState
                
                if !success {
                    errorMessage = "Failed to change Remote Login. You may have cancelled the authentication, or there was a system error."
                    showError = true
                } else if enable && !newState {
                    errorMessage = "Remote Login was enabled but the SSH service doesn't appear to be running yet. Try checking again in a moment."
                    showError = true
                }
            }
        }
    }
}

struct DirectRoutingToggle: View {
    @State private var status = LocalDirectRouteService.shared.currentStatus()
    @State private var isToggling = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route home LAN direct (bypass VPN)")
                    Text("Requires admin password to change")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isToggling {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Toggle("", isOn: Binding(
                        get: { status.installed },
                        set: { setEnabled($0) }
                    ))
                    .labelsHidden()
                }
            }

            if status.installed {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.isActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    if let subnet = status.subnet {
                        Text(status.isActive
                             ? "Active: \(subnet) direct via \(status.routingInterface ?? "LAN")"
                             : "Installed: \(subnet) (not on home network)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(isError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = LocalDirectRouteService.shared.currentStatus() }
    }

    private func setEnabled(_ enable: Bool) {
        message = nil
        isError = false

        if enable {
            guard let home = LocalDirectRouteService.shared.detectHomeNetwork() else {
                message = "Couldn't detect a home network. Connect to your home Wi-Fi/Ethernet (a private LAN) first, then try again."
                isError = true
                return
            }
            isToggling = true
            Task {
                let ok = await LocalDirectRouteService.shared.enable(home)
                await MainActor.run {
                    isToggling = false
                    status = LocalDirectRouteService.shared.currentStatus()
                    if ok {
                        message = "Pinned \(home.subnetCIDR) direct via \(home.interface)."
                    } else {
                        message = "Could not enable (authentication cancelled or failed)."
                        isError = true
                    }
                }
            }
        } else {
            isToggling = true
            Task {
                let ok = await LocalDirectRouteService.shared.disable()
                await MainActor.run {
                    isToggling = false
                    status = LocalDirectRouteService.shared.currentStatus()
                    if !ok {
                        message = "Could not disable (authentication cancelled or failed)."
                        isError = true
                    }
                }
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 24) {
            TidalDriftLogo(size: .medium)
            
            Text("Version \(Bundle.main.appVersion)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("VPN & VNET Screen Sharing Made Simple")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("Built for internal corporate networks where screen sharing typically stinks. Discover, connect, and share with other Macs instantly.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // Goldberg Consulting branding
            VStack(spacing: 8) {
                Divider()
                    .padding(.horizontal, 40)
                
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                            .font(.caption)
                        Text("Developed by")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    
                    Text("Goldberg Consulting, LLC")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
    }
}

struct TidalDropFolderPicker: View {
    @EnvironmentObject var appState: AppState
    @State private var showFolderPicker = false
    
    private var currentFolder: URL {
        appState.settings.tidalDropFolder
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Received Files Destination")
                        .font(.headline)
                    
                    Text(currentFolder.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                Button("Choose...") {
                    showFolderPicker = true
                }
                .buttonStyle(.bordered)
            }
            
            Text("Files received via TidalDrop will be saved to this folder.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button("Open Folder") {
                    NSWorkspace.shared.open(currentFolder)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .font(.caption)
                
                if !appState.settings.tidalDropDestination.isEmpty {
                    Button("Reset to Default") {
                        appState.settings.tidalDropDestination = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.settings.tidalDropDestination = url.path
                appState.settings.tidalDropDestinationBookmark = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                _ = url.startAccessingSecurityScopedResource()
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState.shared)
    }
}
