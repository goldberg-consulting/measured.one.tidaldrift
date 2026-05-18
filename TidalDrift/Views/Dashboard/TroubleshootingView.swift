import SwiftUI

struct TroubleshootingView: View {
    @StateObject private var healthService = PermissionHealthService.shared
    @State private var showConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                driftVsNormalSection

                manualSettingsSection

                quickFixSection

                howItWorksSection

                whyThingsBreakSection

                experimentalFeaturesSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Fix All Permissions?", isPresented: $showConfirmation) {
            Button("Fix Now", role: .destructive) {
                Task {
                    let _ = await healthService.fixAllPermissions()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restart Screen Sharing and reset TCC permissions. You may need to re-grant some permissions.")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading) {
                    Text("Troubleshooting")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Understanding TidalDrift & macOS Permissions")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var driftVsNormalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drift Mode vs Standard Mode")
                .font(.title2)
                .fontWeight(.semibold)

            Text("TidalDrift works in two modes. You get 98% of features without \"drifting,\" but peer discovery simplifies setup between Macs.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 16) {
                // Standard Mode
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundColor(.blue)
                        Text("Standard Mode")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Screen Sharing (VNC)", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "File Sharing (SMB/AFP)", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "SSH/Remote Login", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Wake-on-LAN", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Network Scanning", available: true)
                        FeatureCheckRow(icon: "xmark.circle", text: "Auto peer detection", available: false)
                        FeatureCheckRow(icon: "xmark.circle", text: "TidalDrop file transfers", available: false)
                        FeatureCheckRow(icon: "xmark.circle", text: "Clipboard sync", available: false)
                    }
                    .font(.caption)

                    Text("Works with any Mac on your network, even without TidalDrift installed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.1)))

                // Drift Mode
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "wave.3.right")
                            .font(.title2)
                            .foregroundColor(.tidalDriftPeer)
                        Text("Drift Mode")
                            .font(.headline)

                        Text("Recommended")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.tidalDriftPeer))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "All Standard features", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Auto peer detection", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "TidalDrop (drag & drop files)", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Clipboard sync (β)", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "Hardware info display", available: true)
                        FeatureCheckRow(icon: "checkmark.circle.fill", text: "One-click setup", available: true)
                    }
                    .font(.caption)

                    Text("Requires TidalDrift running on both Macs with Peer Discovery enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.tidalDriftPeer.opacity(0.1)))
            }
        }
    }

    private var quickFixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Fix")
                .font(.title2)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                Button {
                    showConfirmation = true
                } label: {
                    HStack {
                        if healthService.isResetting {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("Reset All Permissions")
                    }
                    .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(healthService.isResetting)

                Button {
                    Task {
                        _ = await healthService.resetScreenRecording()
                    }
                } label: {
                    Label("Reset Screen Recording", systemImage: "video.badge.plus")
                }
                .buttonStyle(.bordered)

                if let result = healthService.lastResetResult {
                    VStack(alignment: .leading) {
                        Text("Last reset: \(result.timestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            statusDot(result.screenSharingRestarted, "Sharing")
                            statusDot(result.screenRecordingReset, "Recording")
                            statusDot(result.localNetworkReset, "Network")
                            statusDot(result.accessibilityReset, "Access")
                            statusDot(result.inputMonitoringReset, "Input")
                        }
                    }
                }
            }

            Text("Use this if connections aren't working. It restarts the Screen Sharing service and resets permission caches.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
    }

    private func statusDot(_ success: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(success ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
        }
    }

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How TidalDrift Works")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                InfoCard(
                    icon: "network",
                    title: "Device Discovery",
                    description: "TidalDrift uses Bonjour (mDNS) to find Macs advertising Screen Sharing or File Sharing. It also scans your subnet for devices that might not advertise.",
                    status: .info
                )

                InfoCard(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Sharing",
                    description: "TidalDrift uses macOS's built-in Screen Sharing app (VNC) to connect. This is the same as connecting through Finder → Go → Connect to Server.",
                    status: .info
                )

                InfoCard(
                    icon: "folder",
                    title: "File Sharing",
                    description: "File connections use AFP/SMB, the same protocols macOS uses natively. TidalDrift just makes finding and connecting easier.",
                    status: .info
                )
            }
        }
    }

    private var whyThingsBreakSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Why Connections Sometimes Fail")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Most issues come down to macOS permissions or service states:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                InfoCard(
                    icon: "exclamationmark.triangle",
                    title: "\"Screen Sharing is not permitted\"",
                    description: """
                    This usually means the remote Mac's Screen Sharing service isn't responding, even if it shows as "on" in System Settings.

                    Fix: On the remote Mac, toggle Screen Sharing OFF, wait 5 seconds, then ON again. Or use our Fix button which does: launchctl kickstart -k system/com.apple.screensharing
                    """,
                    status: .warning
                )

                InfoCard(
                    icon: "signature",
                    title: "Permissions Seem \"Sticky\"",
                    description: """
                    When you rebuild TidalDrift (during development), the code signature changes. macOS treats it as a new app and previous permissions may not apply.

                    This is expected behavior during development. Production builds won't have this issue.
                    """,
                    status: .info
                )

                InfoCard(
                    icon: "network.slash",
                    title: "Devices Not Showing Up",
                    description: """
                    Bonjour discovery requires:
                    • Both Macs on the same network/subnet
                    • Screen Sharing or File Sharing enabled on target Mac
                    • No firewall blocking mDNS (port 5353)
                    • Local Network permission granted to TidalDrift

                    Try "Scan Subnet" if Bonjour isn't finding devices.
                    """,
                    status: .info
                )
            }
        }
    }

    private var experimentalFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About Experimental Features")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                InfoCard(
                    icon: "app.connected.to.app.below.fill",
                    title: "App Streaming (β)",
                    description: """
                    The goal: Stream just one app window instead of the whole desktop.

                    Current status: Very experimental. Uses ScreenCaptureKit to list windows, but the actual streaming/sharing part isn't implemented yet. This would require building a custom VNC-like protocol.

                    For now, use regular Screen Sharing.
                    """,
                    status: .experimental
                )

                InfoCard(
                    icon: "doc.on.clipboard",
                    title: "Clipboard Sync (β)",
                    description: """
                    Shares your clipboard between Macs running TidalDrift.

                    Current status: Basic implementation. Uses Bonjour to find peers and syncs text content. May not work reliably with images or large content.
                    """,
                    status: .experimental
                )
            }
        }
    }

    private var manualSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manual Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Text("If the quick fix doesn't work, try these:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                SettingsButton(
                    title: "Sharing",
                    icon: "rectangle.on.rectangle",
                    url: "x-apple.systempreferences:com.apple.preference.sharing"
                )

                SettingsButton(
                    title: "Screen Recording",
                    icon: "video.fill",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )

                SettingsButton(
                    title: "Local Network",
                    icon: "network",
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
                )

                SettingsButton(
                    title: "Firewall",
                    icon: "flame",
                    url: "x-apple.systempreferences:com.apple.preference.security?Firewall"
                )
            }

            Divider()

            Text("**Pro tip:** When in doubt, toggle the setting OFF, wait 5 seconds, then toggle it back ON.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct InfoCard: View {
    let icon: String
    let title: String
    let description: String
    let status: CardStatus

    enum CardStatus {
        case info, warning, experimental

        var backgroundColor: Color {
            switch self {
            case .info: return Color.blue.opacity(0.1)
            case .warning: return Color.orange.opacity(0.1)
            case .experimental: return Color.purple.opacity(0.1)
            }
        }

        var iconColor: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .experimental: return .purple
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(status.iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(status.backgroundColor))
    }
}

struct SettingsButton: View {
    let title: String
    let icon: String
    let url: String

    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption)
            }
            .frame(width: 80, height: 60)
        }
        .buttonStyle(.bordered)
    }
}

struct FeatureCheckRow: View {
    let icon: String
    let text: String
    let available: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(available ? .green : .secondary.opacity(0.5))
            Text(text)
                .foregroundColor(available ? .primary : .secondary.opacity(0.7))
        }
    }
}

struct TroubleshootingView_Previews: PreviewProvider {
    static var previews: some View {
        TroubleshootingView()
    }
}

