import SwiftUI

struct LocalCastSettingsView: View {
    @AppStorage("localCastQuality") var quality: LocalCastConfiguration.QualityPreset = .high
    @AppStorage("localCastCodec") var codec: LocalCastConfiguration.Codec = .hevc
    @AppStorage("localCastAdaptive") var adaptiveQuality = true
    @AppStorage("localCastAutoHost") var autoHost = false
    @AppStorage("localCastRequireAuth") var requireAuth = true
    @AppStorage("localCastInputRateLimit") var inputRateLimit = 120
    @AppStorage("localCastMaxDimension") var maxDimension = 0
    @AppStorage("localCastDropToNewest") var dropToNewest = true
    @AppStorage("localCastLossRecovery") var lossRecovery = true
    @AppStorage("localCastRegionAware") var regionAware = false
    @AppStorage("localCastFEC") var forwardErrorCorrection = false
    @AppStorage("localCastLatencyMode") var latencyMode: LocalCastConfiguration.LatencyMode = .low
    @AppStorage("localCastCaptureCursor") var captureCursor = false
    @AppStorage("localCastTransportProfile") var transportProfile: LocalCastConfiguration.TransportProfile = .auto
    @AppStorage("localCastThermalThrottle") var thermalThrottle = true
    
    @State private var hostPassword = ""
    @State private var isRestartingStream = false
    @State private var pendingRestart: Task<Void, Never>?
    
    @StateObject private var permissions = LocalCastPermissions()
    @ObservedObject private var service = LocalCastService.shared
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Metal Streaming")
                    .font(.headline)

                Text("High-resolution, high-framerate screen streaming over UDP. Uses ScreenCaptureKit, VideoToolbox (H.264/HEVC), and a Metal renderer on the client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Host toggle — same action as the menu bar LocalCast toggle,
                // surfaced here for discoverability since the Settings pane
                // is where most users configure the service.
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(service.isHosting ? .yellow : .secondary)
                    Text("Host this Mac")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { service.isHosting },
                        set: { newValue in
                            Task {
                                if newValue {
                                    try? await service.startHosting()
                                } else {
                                    service.stopHosting()
                                }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.vertical, 4)
                
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
                        if isRestartingStream {
                            ProgressView().scaleEffect(0.7)
                            Text("Applying codec/resolution to the live stream...")
                        } else {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                            Text("Settings apply live. Codec and resolution re-apply automatically a moment after you change them.")
                        }
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
                    
                    Toggle("Auto-host on launch", isOn: $autoHost)
                        .help("Automatically start hosting when TidalDrift launches")
                }
                .padding(.leading, 8)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Resolution & Resilience")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Streaming resolution", selection: $maxDimension) {
                        ForEach(LocalCastConfiguration.captureDimensionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .help("Caps the captured frame's longest edge (aspect ratio preserved). Native streams the full panel resolution, including ultrawide (5120x1440). Applies to the next session.")

                    Toggle("Adaptive bitrate", isOn: $adaptiveQuality)
                        .help("Automatically lowers bitrate when the link drops packets so motion (e.g. dragging) stays smooth, then restores quality when it clears. Host-side; applies live.")

                    Toggle("Drop to newest frame", isOn: $dropToNewest)
                        .help("Skip stale/incomplete frames instead of playing through a backlog. Client-side; applies to the next connection.")

                    Toggle("Loss-triggered recovery", isOn: $lossRecovery)
                        .help("Request a fresh keyframe immediately when a frame is lost, so the picture heals in ~1 round trip instead of waiting for the next scheduled keyframe. Client-side; applies to the next connection.")

                    Toggle("Forward error correction (FEC)", isOn: $forwardErrorCorrection)
                        .help("Send two parity packets per 16 video fragments so the viewer can rebuild up to two lost packets without a retransmit (Moonlight/Sunshine-style). Best for lossy Wi-Fi; adds ~12% bandwidth. Host-side; applies live. Watch \"Recovered/s\" in the stats overlay.")

                    Picker("Latency mode", selection: $latencyMode) {
                        ForEach(LocalCastConfiguration.LatencyMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .help("Client-side jitter buffer policy. Low Latency (default) reduces buffering for snappier cursor/control; Smooth adds more cushion for uneven Wi-Fi. Applies to the next viewer connection.")

                    Picker("Transport profile", selection: $transportProfile) {
                        ForEach(LocalCastConfiguration.TransportProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .help("Auto picks Fast LAN on a clean wired link (low RTT, no loss) and Resilient on Wi-Fi. Fast LAN drops pacing, widens the reassembly window, loosens the keyframe cap, and raises bitrate. Forcing Fast LAN also uses jumbo datagrams (needs a 9000 MTU). Applies live.")

                    Toggle("Show remote cursor in stream", isOn: $captureCursor)
                        .help("Composites the host's cursor into the video. Off (default), your local cursor is the pointer, removing the network round trip from pointer motion. Turn on for view-only sessions. Applies live on macOS 14+, otherwise next session.")

                    Toggle("Thermal throttling", isOn: $thermalThrottle)
                        .help("When macOS reports thermal pressure, automatically lowers the stream's frame rate and bitrate (30 fps / half bitrate at serious, 15 fps / quarter bitrate at critical) so the host cools down, then restores quality. Host-side; applies live.")

                    Text("On lossy Wi-Fi these keep motion smooth and recover quickly. On a clean wired link they have little effect. Turn them off to force fixed-bitrate, play-everything behavior.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Region-aware streaming (experimental)", isOn: $regionAware)
                        .help("Send only changed screen regions as crisp lossless tiles, falling back to full-frame video on large motion. Reduces bandwidth and sharpens static content (text, UI), especially on large/ultrawide displays. Host-side; applies live.")

                    if regionAware {
                        Text("Experimental. Best for desktop/text work; large continuous motion still uses full-frame video. Both Macs must run a build with region-aware support.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
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
        .onChange(of: adaptiveQuality) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        .onChange(of: forwardErrorCorrection) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        .onChange(of: regionAware) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        .onChange(of: captureCursor) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        .onChange(of: transportProfile) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        .onChange(of: thermalThrottle) { _ in service.applyLiveResilienceSettingsFromDefaults() }
        // Codec and resolution need a fresh capture/encoder session, but the user
        // shouldn't have to find and click a button. Re-apply them automatically
        // (debounced) so changing them while hosting "just works".
        .onChange(of: codec) { _ in scheduleAutoApply() }
        .onChange(of: maxDimension) { _ in scheduleAutoApply() }
        .onChange(of: quality) { _ in scheduleAutoApply() }
        .onDisappear { pendingRestart?.cancel() }
    }

    /// Debounced auto-restart for settings that need a new session (codec,
    /// resolution). Coalesces rapid changes into a single restart ~0.6s after
    /// the last edit, so flipping through options doesn't thrash the stream.
    private func scheduleAutoApply() {
        guard service.isHosting else { return }
        pendingRestart?.cancel()
        pendingRestart = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await MainActor.run { isRestartingStream = true }
            await service.restartHostingToApplySettings()
            await MainActor.run { isRestartingStream = false }
        }
    }
}

struct LocalCastSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        LocalCastSettingsView()
            .frame(width: 450, height: 700)
    }
}





