import SwiftUI

/// Experimental view for app-specific streaming
struct AppStreamingView: View {
    @ObservedObject private var service = AppStreamingService.shared
    @ObservedObject private var networkService = StreamingNetworkService.shared
    @State private var showingInfo = false
    @State private var showingPermissionAlert = false
    @State private var showingResetAlert = false
    @State private var resetMessage: String?
    @State private var selectedTab = 0  // 0 = Local, 1 = Remote
    
    var body: some View {
        // Fixed size container
        VStack(spacing: 0) {
            header
            
            Divider()
            
            if !service.isExperimentalEnabled {
                experimentalDisabledView
            } else {
                enabledContent
            }
        }
        .frame(width: 720, height: 580)
        .alert("Screen Recording Permission Required", isPresented: $showingPermissionAlert) {
            Button("Open System Settings") {
                openScreenRecordingSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TidalDrift needs screen recording permission to list available apps for streaming.")
        }
        .alert("Reset Screen Recording Permission?", isPresented: $showingResetAlert) {
            Button("Reset & Open Settings") {
                resetScreenRecordingPermission()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset TidalDrift's screen recording permission. After resetting, you'll need to re-add TidalDrift in System Settings.\n\nThis fixes issues where the wrong app version has permission.")
        }
        .alert("Permission Reset", isPresented: .constant(resetMessage != nil)) {
            Button("Open Settings") {
                openScreenRecordingSettings()
                resetMessage = nil
            }
            Button("OK") {
                resetMessage = nil
            }
        } message: {
            Text(resetMessage ?? "")
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.orange)
                    Text("App-Specific Streaming")
                        .font(.headline)
                    
                    Text("EXPERIMENTAL")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
                
                Text("Stream individual apps across your network")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                showingInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingInfo) {
                infoPopover
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
    
    private var experimentalDisabledView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "flask")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("Experimental Feature")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("App-specific streaming allows you to share just one application window instead of your entire desktop, and discover apps shared by other machines on your network.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 60)
            
            VStack(spacing: 12) {
                Toggle("Enable Experimental Features", isOn: Binding(
                    get: { service.isExperimentalEnabled },
                    set: { service.setExperimentalEnabled($0) }
                ))
                .toggleStyle(.switch)
                
                Text("This feature is still in development")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 60)
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    private var enabledContent: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                    Text("My Apps")
                }
                .tag(0)
                
                HStack(spacing: 4) {
                    Image(systemName: "network")
                    Text("Remote Apps")
                    if !networkService.allRemoteApps.isEmpty {
                        Text("(\(networkService.allRemoteApps.count))")
                            .foregroundColor(.secondary)
                    }
                }
                .tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            // Fixed frame container to prevent size changes
            ZStack {
                localAppsContent
                    .opacity(selectedTab == 0 ? 1 : 0)
                
                remoteAppsContent
                    .opacity(selectedTab == 1 ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Local Apps Tab
    
    private var localAppsContent: some View {
        VStack(spacing: 0) {
            // Hosting status bar - fixed at top
            hostingStatusBar
                .frame(height: 44)
            
            Divider()
            
            // Split view with constrained sizes
            HStack(spacing: 0) {
                localAppList
                    .frame(width: 280)
                
                Divider()
                
                localDetailView
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    private var hostingStatusBar: some View {
        HStack(spacing: 12) {
            // Hosting status
            HStack(spacing: 8) {
                Circle()
                    .fill(networkService.isHosting ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
                
                Text(networkService.isHosting ? "Sharing \(networkService.hostedApps.count) apps" : "Not sharing")
                    .font(.caption)
                    .foregroundColor(networkService.isHosting ? .primary : .secondary)
            }
            
            // Use button instead of toggle for more reliable behavior
            if networkService.isHosting {
                Button {
                    networkService.stopHosting()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("Stop Sharing")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    // Log to file for debugging
                    let logPath = "/tmp/tidaldrift_share.log"
                    let msg = "[\(Date())] 🔘 BUTTON PRESSED - Apps: \(service.availableApps.count)\n"
                    if let data = msg.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: logPath) {
                            if let handle = FileHandle(forWritingAtPath: logPath) {
                                handle.seekToEndOfFile()
                                handle.write(data)
                                handle.closeFile()
                            }
                        } else {
                            FileManager.default.createFile(atPath: logPath, contents: data)
                        }
                    }
                    
                    if service.availableApps.isEmpty {
                        print("🔘 No apps available to share!")
                    } else {
                        networkService.startHosting(apps: service.availableApps)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(service.availableApps.isEmpty ? "No Apps to Share" : "Share My Apps")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(service.availableApps.isEmpty)
            }
            
            Spacer()
            
            Button {
                Task {
                    await service.refreshAvailableApps()
                    if networkService.isHosting {
                        networkService.updateHostedApps(service.availableApps)
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(service.isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(networkService.isHosting ? Color.green.opacity(0.1) : Color.clear)
    }
    
    private var localAppList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Running Apps")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("\(service.availableApps.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            
            Divider()
            
            if service.isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading apps...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else if service.availableApps.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: service.errorMessage != nil ? "exclamationmark.triangle" : "app.dashed")
                        .font(.system(size: 30))
                        .foregroundColor(service.errorMessage != nil ? .orange : .secondary)
                    
                    if let error = service.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    } else {
                        Text("No apps found")
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Button("Refresh") {
                                Task {
                                    await service.refreshAvailableApps()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Button("Open Settings") {
                                openScreenRecordingSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        
                        // Show reset option if there's a TCC error
                        if service.errorMessage?.contains("TCC") == true || 
                           service.errorMessage?.contains("declined") == true {
                            Button("Reset TidalDrift Permission") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundColor(.orange)
                        }
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(service.availableApps) { app in
                            AppRow(app: app, isSelected: service.selectedApp?.id == app.id)
                                .onTapGesture {
                                    service.selectApp(app)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            if service.availableApps.isEmpty {
                Task {
                    await service.refreshAvailableApps()
                }
            }
        }
    }
    
    private var localDetailView: some View {
        VStack {
            if let app = service.selectedApp {
                selectedAppDetail(app)
            } else {
                emptySelection
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var emptySelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Select an App")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Choose an app to share with others")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func selectedAppDetail(_ app: StreamableApp) -> some View {
        VStack(spacing: 20) {
            // App header
            VStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                }
                
                Text(app.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if let bundleId = app.bundleIdentifier {
                    Text(bundleId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Sharing status
                if networkService.isHosting && networkService.hostedApps.contains(app.bundleIdentifier ?? "") {
                    HStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.green)
                        Text("Being shared")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.top, 20)
            
            Divider()
                .padding(.horizontal)
            
            // Windows section
            VStack(alignment: .leading, spacing: 8) {
                Text("Windows (\(app.windows.count))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                ForEach(app.windows) { window in
                    WindowRow(
                        window: window,
                        isSelected: service.selectedWindow?.id == window.id
                    )
                    .onTapGesture {
                        service.selectWindow(window)
                    }
                }
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Actions
            VStack(spacing: 12) {
                // Stream button - main action
                if service.isStreaming {
                    Button {
                        Task {
                            await service.stopCapture()
                        }
                    } label: {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("Stop Streaming")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task {
                            do {
                                try await service.startCapture()
                            } catch {
                                print("❌ Failed to start streaming: \(error)")
                            }
                        }
                    } label: {
                        Label("Start Streaming Window", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button {
                    service.bringAppToFront()
                } label: {
                    Label("Bring to Front", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                
                if service.isStreaming {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Streaming - connect from another Mac via LocalCast")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                } else {
                    Text("Select a window above, then click 'Start Streaming'")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }
    
    // MARK: - Remote Apps Tab
    
    private var remoteAppsContent: some View {
        VStack(spacing: 0) {
            // Discovery controls
            discoveryStatusBar
            
            Divider()
            
            if networkService.discoveredHosts.isEmpty {
                remoteEmptyState
            } else {
                remoteAppsList
            }
        }
    }
    
    private var discoveryStatusBar: some View {
        HStack(spacing: 12) {
            // Discovery status
            HStack(spacing: 8) {
                if networkService.isDiscovering {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
                
                Text(networkService.isDiscovering ? "Searching..." : "Not searching")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button {
                if networkService.isDiscovering {
                    networkService.stopDiscovery()
                } else {
                    networkService.startDiscovery()
                }
            } label: {
                Label(
                    networkService.isDiscovering ? "Stop" : "Search Network",
                    systemImage: networkService.isDiscovering ? "stop.fill" : "magnifyingglass"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            
            Spacer()
            
            if !networkService.discoveredHosts.isEmpty {
                Text("\(networkService.discoveredHosts.count) host\(networkService.discoveredHosts.count == 1 ? "" : "s") found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button {
                networkService.refreshDiscovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(!networkService.isDiscovering)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(networkService.isDiscovering ? Color.blue.opacity(0.1) : Color.clear)
        .onAppear {
            // Auto-start discovery when viewing remote tab
            if !networkService.isDiscovering {
                networkService.startDiscovery()
            }
        }
    }
    
    private var remoteEmptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            
            if networkService.isDiscovering {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Searching for streaming apps...")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Make sure TidalDrift is running on other machines\nwith app sharing enabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                Image(systemName: "network.slash")
                    .font(.system(size: 50))
                    .foregroundColor(.secondary)
                
                Text("No Remote Apps Found")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Text("Click 'Search Network' to discover apps\nbeing shared by other TidalDrift users")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                Button {
                    networkService.startDiscovery()
                } label: {
                    Label("Search Network", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    private var remoteAppsList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(networkService.discoveredHosts) { host in
                    RemoteHostSection(host: host)
                }
            }
            .padding()
        }
    }
    
    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About App-Specific Streaming")
                .font(.headline)
            
            Text("""
            This experimental feature lets you stream individual apps across your network.
            
            How it works:
            1. Enable "Share My Apps" to advertise your apps
            2. Go to "Remote Apps" to discover apps from other machines
            3. Click "Connect" to view a remote app
            
            Requirements:
            • TidalDrift running on both machines
            • Screen Recording permission granted
            • Both machines on the same network
            
            Note: Connection opens Screen Sharing to the remote Mac with the selected app brought to front.
            """)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }
    
    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func resetScreenRecordingPermission() {
        // Reset screen recording permission for just TidalDrift
        let bundleId = Bundle.main.bundleIdentifier ?? "com.goldbergconsulting.tidaldrift"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleId]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                resetMessage = "Permission reset successfully!\n\nPlease quit TidalDrift, then:\n1. Reopen TidalDrift\n2. Click 'Open Settings'\n3. Add TidalDrift to the list"
            } else {
                // Try without bundle ID (resets all - may need admin)
                resetMessage = "Couldn't reset just TidalDrift. You may need to manually remove and re-add TidalDrift in System Settings → Screen Recording."
            }
        } catch {
            resetMessage = "Reset failed: \(error.localizedDescription)\n\nTry running in Terminal:\ntccutil reset ScreenCapture \(bundleId)"
        }
    }
}

// MARK: - Remote Host Section

struct RemoteHostSection: View {
    let host: StreamingHost
    @ObservedObject private var networkService = StreamingNetworkService.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Host header
            HStack {
                Image(systemName: "desktopcomputer")
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(host.ipAddress)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("\(host.apps.count) app\(host.apps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }
            
            Divider()
            
            // Apps from this host
            ForEach(host.apps) { app in
                RemoteAppRow(app: app)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct RemoteAppRow: View {
    let app: RemoteStreamableApp
    @ObservedObject private var networkService = StreamingNetworkService.shared
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                
                Text("\(app.windowCount) window\(app.windowCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                networkService.connectToRemoteApp(app)
            } label: {
                Label("Connect", systemImage: "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Existing Row Components

struct AppRow: View {
    let app: StreamableApp
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 24, height: 24)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                
                Text("\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
}

struct WindowRow: View {
    let window: StreamableWindow
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundColor(isSelected ? .accentColor : .secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title.isEmpty ? "Untitled" : window.title)
                    .font(.caption)
                    .lineLimit(1)
                
                Text("\(Int(window.bounds.width))×\(Int(window.bounds.height))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if window.isOnScreen {
                Text("visible")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }
}

struct AppStreamingView_Previews: PreviewProvider {
    static var previews: some View {
        AppStreamingView()
    }
}
