import SwiftUI

struct AppStreamingTabView: View {
    @ObservedObject private var streamingService = AppStreamingService.shared
    @ObservedObject private var networkService = StreamingNetworkService.shared
    @ObservedObject private var permissionService = PermissionDiagnosticService.shared
    @State private var showingPermissionAlert = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                
                statusSection
                
                if streamingService.isExperimentalEnabled {
                    if permissionService.screenRecordingGranted {
                        enabledContent
                    } else if permissionService.isRunningDiagnostic {
                        loadingPermissionsContent
                    } else {
                        permissionRequiredContent
                    }
                } else {
                    disabledContent
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task {
                await checkPermissions()
                if streamingService.isExperimentalEnabled && permissionService.screenRecordingGranted {
                    await streamingService.refreshAvailableApps()
                }
            }
        }
    }
    
    private func checkPermissions() async {
        _ = await permissionService.runFullDiagnostic()
    }
    
    private var loadingPermissionsContent: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Checking system permissions...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
    
    private var permissionRequiredContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
            Text("Screen Recording Permission Required")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("To list and stream individual windows, TidalDrift needs Screen Recording permission. This is a system security requirement.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            
            Button {
                permissionService.openScreenRecordingSettings()
            } label: {
                Label("Open System Settings", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Instructions:")
                    .font(.headline)
                
                BulletPoint(text: "1. Click 'Open System Settings' above", done: false)
                BulletPoint(text: "2. Find 'TidalDrift' in the list", done: false)
                BulletPoint(text: "3. Toggle the switch to ON", done: false)
                BulletPoint(text: "4. When prompted, click 'Quit & Reopen'", done: false)
                
                Divider()
                    .padding(.vertical, 4)
                
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("**Note for Developers:** If you rebuild the app, the signature changes and macOS may require you to toggle this OFF and ON again in System Settings to refresh the permission.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.05)))
            
            Button("I've granted permission, refresh status") {
                Task {
                    await checkPermissions()
                }
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "app.connected.to.app.below.fill")
                        .font(.largeTitle)
                        .foregroundColor(.purple)
                    
                    Text("App Streaming")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("β")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .foregroundColor(.white)
                }
                
                Text("Stream individual app windows instead of the full desktop")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    private var statusSection: some View {
        HStack(spacing: 16) {
            Toggle(isOn: Binding(
                get: { streamingService.isExperimentalEnabled },
                set: { 
                    print("🔘 Toggle clicked: new value \($0)")
                    streamingService.setExperimentalEnabled($0) 
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Experimental Feature")
                        .font(.headline)
                    Text("Enable to explore window-specific streaming capabilities")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            
            if streamingService.isExperimentalEnabled {
                Button {
                    Task {
                        await streamingService.refreshAvailableApps()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh Apps")
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    private var disabledContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("This is an experimental feature")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("App Streaming aims to let you stream just one application window instead of the whole desktop. This could be useful for remote pair programming or sharing a specific tool.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Status:")
                    .font(.headline)
                
                BulletPoint(text: "Can list running applications and windows", done: true)
                BulletPoint(text: "Can capture window screenshots", done: true)
                BulletPoint(text: "Network discovery via Bonjour", done: false)
                BulletPoint(text: "Live streaming protocol", done: false)
                BulletPoint(text: "Remote app activation", done: false)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.1)))
            
            Text("Enable the toggle above to explore what's working so far.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
    
    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // My Apps section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("My Running Apps")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Text("\(streamingService.availableApps.count) apps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if streamingService.availableApps.isEmpty {
                    Text("No apps detected. Make sure Screen Recording permission is granted.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)
                    ], spacing: 12) {
                        ForEach(streamingService.availableApps) { app in
                            AppCard(app: app, isSelected: streamingService.selectedApp?.id == app.id) {
                                streamingService.selectApp(app)
                            }
                        }
                    }
                }
            }
            
            // Selected app detail
            if let selectedApp = streamingService.selectedApp {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Selected: \(selectedApp.name)")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    HStack {
                        Text("Windows: \(selectedApp.windows.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button("Bring to Front") {
                            streamingService.bringAppToFront()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if selectedApp.windows.isEmpty {
                        Text("No visible windows")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(selectedApp.windows) { window in
                                    WindowCard(window: window)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.1)))
            }
            
            // Limitations note
            VStack(alignment: .leading, spacing: 8) {
                Label("Limitations", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text("This feature can detect running apps and windows, but actual streaming to another computer isn't implemented yet. It would require building a custom protocol similar to VNC but for individual windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
        }
    }
}

struct BulletPoint: View {
    let text: String
    let done: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundColor(done ? .green : .secondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(done ? .primary : .secondary)
        }
    }
}

struct AppCard: View {
    let app: StreamableApp
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    Text("\(app.windows.count) window\(app.windows.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct WindowCard: View {
    let window: StreamableWindow
    
    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 160, height: 100)
                .cornerRadius(6)
                .overlay(
                    VStack(spacing: 4) {
                        Image(systemName: window.isOnScreen ? "macwindow" : "macwindow.badge.plus")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text(window.isOnScreen ? "On Screen" : "Hidden")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                )
            
            Text(window.title.isEmpty ? "Untitled" : window.title)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 160)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct AppStreamingTabView_Previews: PreviewProvider {
    static var previews: some View {
        AppStreamingTabView()
    }
}

