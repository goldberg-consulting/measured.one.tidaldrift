import SwiftUI

struct LocalCastSettingsView: View {
    @AppStorage("localCastQuality") var quality: LocalCastConfiguration.QualityPreset = .high
    @AppStorage("localCastCodec") var codec: LocalCastConfiguration.Codec = .h264
    @AppStorage("localCastAdaptive") var adaptiveQuality = true
    @AppStorage("showLatencyOverlay") var showOverlay = false
    @AppStorage("localCastAutoHost") var autoHost = false
    @AppStorage("localCastRequireAuth") var requireAuth = true
    @AppStorage("localCastInputRateLimit") var inputRateLimit = 120
    
    @State private var hostPassword = ""
    
    @StateObject private var permissions = LocalCastPermissions()
    @ObservedObject private var service = LocalCastService.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("LocalCast Screen Sharing")
                    .font(.headline)
                
                // Live quality controls (always visible, marked "LIVE" when hosting)
                StreamingQualityControlView(
                    tuning: service.streamingTuning,
                    isLive: service.isHosting
                )
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(service.isHosting ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                
                if service.isHosting {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Quality changes apply instantly to the active stream.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Codec & Options")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Picker("Initial Quality Preset", selection: $quality) {
                        ForEach(LocalCastConfiguration.QualityPreset.allCases, id: \.self) { preset in
                            Text(preset.rawValue.capitalized).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Sets the starting quality when a new session begins. Use the slider above for live tuning.")
                    
                    Picker("Video Codec", selection: $codec) {
                        Text("H.264 (Faster)").tag(LocalCastConfiguration.Codec.h264)
                        Text("HEVC (Smaller)").tag(LocalCastConfiguration.Codec.hevc)
                    }
                    
                    Toggle("Show latency overlay", isOn: $showOverlay)
                    
                    Toggle("Auto-host on launch", isOn: $autoHost)
                        .help("Automatically start hosting when TidalDrift launches")
                }
                .padding(.leading, 8)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Security")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Toggle("Require authentication", isOn: $requireAuth)
                        .help("When enabled, clients must authenticate with the host password to connect.")
                    
                    if requireAuth {
                        HStack {
                            Text("Host password")
                            Spacer()
                            SecureField("Set a password", text: $hostPassword)
                                .frame(width: 160)
                                .textFieldStyle(.roundedBorder)
                        }
                        .help("Clients use this password (or their saved device credentials) to connect. Set the same password on both machines.")
                        
                        if hostPassword.isEmpty {
                            Text("Set a password above to enable encrypted connections.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Picker("Input rate limit", selection: $inputRateLimit) {
                        Text("60 / sec").tag(60)
                        Text("120 / sec (default)").tag(120)
                        Text("240 / sec").tag(240)
                        Text("500 / sec").tag(500)
                        Text("Unlimited").tag(0)
                    }
                    .help("Maximum number of input events per second from the client. Prevents input flooding.")
                    
                    Text("Authentication encrypts all traffic with AES-256-GCM. Clients can connect using their saved device credentials or by entering the host password. Rate limiting protects against input flooding.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 8)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Image(systemName: "video.fill")
                            .foregroundColor(.blue)
                            .frame(width: 20)
                        Text("Screen Recording")
                        Spacer()
                        if permissions.screenCaptureGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant") {
                                permissions.openScreenCapturePreferences()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "keyboard")
                            .foregroundColor(.purple)
                            .frame(width: 20)
                        Text("Accessibility (for input)")
                        Spacer()
                        if permissions.accessibilityGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant") {
                                permissions.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.leading, 8)
            }
            .padding()
        }
        .task {
            await permissions.checkPermissions()
            hostPassword = LocalCastPasswordStore.load() ?? ""
        }
        .onChange(of: hostPassword) { newValue in
            LocalCastPasswordStore.save(newValue)
        }
    }
}

struct LocalCastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        LocalCastSettingsView()
            .frame(width: 450, height: 700)
    }
}





