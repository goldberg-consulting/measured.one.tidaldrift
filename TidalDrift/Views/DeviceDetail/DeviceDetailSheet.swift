import SwiftUI

struct DeviceDetailSheet: View {
    let device: DiscoveredDevice
    @StateObject private var viewModel: DeviceDetailViewModel
    @Environment(\.dismiss) var dismiss

    // Wake-on-LAN state
    @State private var macAddress: String = ""
    @State private var isWaking = false
    @State private var wakeResult: WakeResult?
    @State private var isDiscoveringMAC = false

    // Speed test state
    @AppStorage("localCastTestRate") private var udpTestLimit = 100
    @State private var isRunningSpeedTest = false
    @State private var speedTestResult: SpeedTestService.Result?
    @State private var speedTestError: String?
    @State private var speedTestProgress = ""
    @State private var speedTestTask: Task<Void, Never>?
    @State private var optimizedApplied = false
    @State private var isOpeningAppControl = false

    enum WakeResult {
        case success
        case failed
        case waiting
    }

    init(device: DiscoveredDevice) {
        self.device = device
        _viewModel = StateObject(wrappedValue: DeviceDetailViewModel(device: device))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    connectionSection

                    wakeOnLANSection

                    speedTestSection

                    servicesSection

                    peerInfoSection

                    credentialsSection

                    if !viewModel.connectionHistory.isEmpty {
                        historySection
                    }
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .frame(width: 450, height: 580)
        .onDisappear { speedTestTask?.cancel() }
        .alert("Connection Error", isPresented: .constant(viewModel.connectionError != nil)) {
            Button("OK") {
                viewModel.connectionError = nil
            }

        } message: {
            if let error = viewModel.connectionError {
                if error.contains("not permitted") {
                    Text("""
                    \(error)

                    This is a known macOS bug. The remote machine needs to restart its Screen Sharing service.

                    On the remote Mac: System Settings → Sharing → Toggle Screen Sharing OFF then ON.
                    """)
                } else {
                    Text(error)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)

                Image(systemName: device.deviceIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(device.ipAddress)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    StatusIndicator(isOnline: device.isOnline, size: 8)
                    Text(device.statusText)
                        .font(.caption)
                        .foregroundColor(device.isOnline ? .green : .secondary)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }


    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Connect")
                .font(.headline)

            HStack(spacing: 12) {
                if device.services.contains(.screenSharing) {
                    ConnectButton(
                        title: "Screen Share",
                        icon: "rectangle.on.rectangle",
                        isLoading: viewModel.isConnecting
                    ) {
                        Task {
                            await viewModel.connect(to: .screenSharing)
                        }
                    }
                }

                if device.services.contains(.fileSharing) {
                    ConnectButton(
                        title: "File Share",
                        icon: "folder",
                        isLoading: viewModel.isConnecting
                    ) {
                        Task {
                            await viewModel.connect(to: .fileSharing)
                        }
                    }
                }
            }

            HStack {
                Toggle("Trust this device", isOn: Binding(
                    get: { viewModel.isTrusted },
                    set: { _ in viewModel.toggleTrust() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                Button {
                    Task {
                        await viewModel.testConnection()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else if let result = viewModel.connectionTestResult {
                            Image(systemName: result ? "checkmark.circle" : "xmark.circle")
                                .foregroundColor(result ? .green : .red)
                        }
                        Text("Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Show fix instructions if not a TidalDrift peer
            if !device.isTidalDriftPeer {
                Text("💡 If you see 'not permitted' error, toggle Screen Sharing off/on on the remote Mac")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var wakeOnLANSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wake")
                    .foregroundColor(.orange)
                Text("Wake-on-LAN")
                    .font(.headline)

                Spacer()

                if !device.isOnline {
                    Text("Device Offline")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 8) {
                TextField("MAC Address (AA:BB:CC:DD:EE:FF)", text: $macAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onAppear {
                        // Load stored MAC address
                        if let stored = device.storedMACAddress {
                            macAddress = stored
                        }
                    }

                Button {
                    discoverMAC()
                } label: {
                    if isDiscoveringMAC {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .help("Auto-discover MAC address")
                .disabled(isDiscoveringMAC || !device.isOnline)
            }

            HStack {
                Button {
                    wakeDevice()
                } label: {
                    HStack(spacing: 6) {
                        if isWaking {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "power")
                        }
                        Text(isWaking ? "Waking..." : "Wake Device")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(!WakeOnLANService.shared.isValidMACAddress(macAddress) || isWaking)

                if let result = wakeResult {
                    HStack(spacing: 4) {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Awake!")
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("Failed")
                        case .waiting:
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Waiting...")
                        }
                    }
                    .font(.caption)
                }
            }

            Text("Wake-on-LAN sends a magic packet to power on sleeping Macs. The device must have WOL enabled in Energy Saver settings.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func discoverMAC() {
        isDiscoveringMAC = true

        Task {
            // Try to get MAC from ARP table
            if let mac = WakeOnLANService.shared.getMACAddress(for: device.ipAddress) {
                await MainActor.run {
                    macAddress = mac
                    // Store it for future use
                    var mutableDevice = device
                    mutableDevice.storedMACAddress = mac
                }
            }

            await MainActor.run {
                isDiscoveringMAC = false
            }
        }
    }

    private func wakeDevice() {
        guard WakeOnLANService.shared.isValidMACAddress(macAddress) else { return }

        // Store MAC for future use
        var mutableDevice = device
        mutableDevice.storedMACAddress = macAddress

        isWaking = true
        wakeResult = .waiting

        Task {
            let success = await WakeOnLANService.shared.wakeAndWait(device: device, timeout: 30)

            await MainActor.run {
                isWaking = false
                wakeResult = success ? .success : .failed

                // Clear result after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    wakeResult = nil
                }
            }
        }
    }

    private var speedTestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "speedometer")
                    .foregroundColor(.purple)
                Text("Network Speed Test")
                    .font(.headline)
                Spacer()
                Button {
                    if isRunningSpeedTest { speedTestTask?.cancel() } else { runSpeedTest() }
                } label: {
                    HStack(spacing: 6) {
                        if isRunningSpeedTest {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(isRunningSpeedTest ? "Cancel" : "Run Test")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Picker("Delivery test limit", selection: $udpTestLimit) {
                ForEach([100, 250, 500, 1000], id: \.self) { rate in
                    Text("\(rate) Mbps").tag(rate)
                }
            }
            .disabled(isRunningSpeedTest)
            .help("Choose a higher rate to check delivery closer to your streaming settings. The test stays below half the measured TCP speed.")

            if let r = speedTestResult {
                VStack(alignment: .leading, spacing: 6) {
                    speedRow("Latency", String(format: "%.1f ms (±%.1f jitter)", r.rttMs, r.jitterMs))
                    speedRow("TCP down", String(format: "%.1f Mbps", r.downloadMbps))
                    speedRow("TCP up", String(format: "%.1f Mbps", r.uploadMbps))
                    speedRow("UDP down", deliverySummary(r.downloadUDP))
                    speedRow("UDP up", deliverySummary(r.uploadUDP))
                    Text(String(format: "UDP targets: ↓ %.1f Mbps · ↑ %.1f Mbps", r.downloadUDP.targetMbps, r.uploadUDP.targetMbps))
                        .font(.caption)
                    Text(String(format: "UDP jitter: ↓ %.2f ms · ↑ %.2f ms", r.downloadUDP.jitterMs, r.uploadUDP.jitterMs))
                        .font(.caption)
                    Text(r.route).font(.caption2).textSelection(.enabled)
                    Text(r.deliveryVerdict)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if r.downloadMbps > 0 {
                    recommendationView(SpeedTestService.recommend(from: r))
                }
            } else if isRunningSpeedTest {
                Text(speedTestProgress).font(.caption)
            } else if let speedTestError {
                Text(speedTestError).font(.caption).foregroundColor(.orange)
            } else {
                Text("Tests TCP speed and paced UDP delivery with iperf3 in about 30 seconds. Both Macs need the current app. Choose the delivery test rate above; slower connections are tested at a lower rate.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func recommendationView(_ rec: SpeedTestService.Recommendation) -> some View {
        Divider().padding(.vertical, 2)
        VStack(alignment: .leading, spacing: 6) {
            Label("Recommended LocalCast settings", systemImage: "wand.and.stars")
                .font(.subheadline.bold())
            Text(rec.headline)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rec.bullets, id: \.self) { bullet in
                Text("• \(bullet)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    applyRecommendation(rec)
                } label: {
                    Label(optimizedApplied ? "Applied" : "Apply optimized settings",
                          systemImage: optimizedApplied ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(optimizedApplied)

                if optimizedApplied {
                    Text("Applies on the next session")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 2)
        }
    }

    private func applyRecommendation(_ rec: SpeedTestService.Recommendation) {
        let defaults = UserDefaults.standard
        defaults.set(rec.maxDimension, forKey: "localCastMaxDimension")
        defaults.set(rec.regionAware, forKey: "localCastRegionAware")
        defaults.set(rec.adaptive, forKey: "localCastAdaptive")
        defaults.set(rec.dropToNewest, forKey: "localCastDropToNewest")
        defaults.set(rec.lossRecovery, forKey: "localCastLossRecovery")
        defaults.set(rec.codec, forKey: "localCastCodec")
        optimizedApplied = true
    }

    private func speedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
            Spacer()
        }
    }

    private func deliverySummary(_ delivery: SpeedTestService.UDPDelivery) -> String {
        String(format: "%.2f%% loss at %.1f Mbps sent", delivery.lossPercent, delivery.senderMbps)
    }

    private func runSpeedTest() {
        isRunningSpeedTest = true
        speedTestResult = nil
        speedTestError = nil
        optimizedApplied = false
        speedTestTask = Task { @MainActor in
            defer {
                isRunningSpeedTest = false
                speedTestTask = nil
            }
            do {
                speedTestResult = try await SpeedTestService.shared.runTest(toHost: device.ipAddress, udpLimitMbps: udpTestLimit) {
                    speedTestProgress = $0
                }
            } catch {
                speedTestError = Task.isCancelled ? "Test cancelled." : error.localizedDescription
            }
        }
    }

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Services")
                .font(.headline)

            if device.services.isEmpty {
                Text("No services discovered")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(device.services), id: \.self) { service in
                    HStack {
                        Image(systemName: service.icon)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)

                        Text(service.displayName)
                            .font(.subheadline)

                        Spacer()

                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            Button {
                isOpeningAppControl = true
                Task {
                    _ = try? await LocalCastService.shared.openAppControl(for: device)
                    await MainActor.run { isOpeningAppControl = false }
                }
            } label: {
                HStack(spacing: 6) {
                    if isOpeningAppControl {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "macwindow.on.rectangle")
                    }
                    Text("Screen Share + App Control")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isOpeningAppControl)
            .help("Opens macOS Screen Sharing for the picture plus a panel to focus or isolate a single app on the remote Mac.")

            Text("Picture comes from macOS Screen Sharing; \"Isolate\" hides the remote's other apps so you see just one. Requires LocalCast hosting on the remote Mac (for the control channel).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var peerInfoSection: some View {
        if device.isTidalDriftPeer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "wave.3.right.circle.fill")
                        .foregroundColor(.blue)
                    Text("TidalDrift Peer")
                        .font(.headline)
                    Spacer()
                    Text("Enhanced Info")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.blue.opacity(0.1)))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let model = device.peerModelName, !model.isEmpty {
                        PeerInfoRow(label: "Model", value: model, icon: "desktopcomputer")
                    }

                    if let processor = device.peerProcessorInfo, !processor.isEmpty {
                        PeerInfoRow(label: "Processor", value: processor, icon: "cpu")
                    }

                    if let memory = device.peerMemoryGB, memory > 0 {
                        PeerInfoRow(label: "Memory", value: "\(memory) GB RAM", icon: "memorychip")
                    }

                    if let macOS = device.peerMacOSVersion, !macOS.isEmpty {
                        PeerInfoRow(label: "macOS", value: macOS, icon: "applelogo")
                    }

                    if let user = device.peerUserName, !user.isEmpty {
                        PeerInfoRow(label: "User", value: user, icon: "person")
                    }

                    if let uptime = device.peerUptimeHours, uptime > 0 {
                        let days = uptime / 24
                        let hours = uptime % 24
                        let uptimeStr = days > 0 ? "\(days)d \(hours)h" : "\(hours)h"
                        PeerInfoRow(label: "Uptime", value: uptimeStr, icon: "clock")
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saved Credentials")
                    .font(.headline)

                Spacer()

                if viewModel.hasCredentials {
                    Button("Delete") {
                        viewModel.deleteCredentials()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }

            TextField("Username", text: $viewModel.username)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $viewModel.password)
                .textFieldStyle(.roundedBorder)

            Toggle("Save credentials in Keychain", isOn: $viewModel.saveCredentials)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            if let credentialError = viewModel.credentialError {
                Text(credentialError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection History")
                .font(.headline)

            ForEach(viewModel.connectionHistory.prefix(5)) { record in
                HStack {
                    Image(systemName: record.connectionType.icon)
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Text(record.relativeTimestamp)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Image(systemName: record.wasSuccessful ? "checkmark.circle" : "xmark.circle")
                        .foregroundColor(record.wasSuccessful ? .green : .red)
                        .font(.caption)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var footer: some View {
        HStack {
            Text("Last seen: \(device.lastSeen.formatted())")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

struct ConnectButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isLoading)
    }
}

struct PeerInfoRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 20)

            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()
        }
    }
}

struct DeviceDetailSheet_Previews: PreviewProvider {
    static var previews: some View {
        DeviceDetailSheet(device: .preview)
    }
}
