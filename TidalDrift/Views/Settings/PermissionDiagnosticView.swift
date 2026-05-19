import SwiftUI

struct PermissionDiagnosticView: View {
    @StateObject private var healthService = PermissionHealthService.shared
    @State private var showConfirmation = false
    @State private var resultMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                fixButtonSection

                if let result = healthService.lastResetResult {
                    resultSection(result)
                }

                explanationSection

                systemSettingsSection
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 450)
        .alert("Fix All Permissions?", isPresented: $showConfirmation) {
            Button("Fix Now", role: .destructive) {
                Task {
                    let result = await healthService.fixAllPermissions()
                    resultMessage = result.message
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will:\n• Restart Screen Sharing service\n• Reset Screen Recording permission\n• Reset Local Network permission\n\nYou may need to re-grant permissions when prompted.")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fix Permission Issues")
                .font(.title2)
                .fontWeight(.bold)

            Text("Having trouble connecting? Permissions sometimes get \"stuck\" on macOS. Use the button below to reset them.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var fixButtonSection: some View {
        VStack(alignment: .center, spacing: 16) {
            Button {
                showConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    if healthService.isResetting {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.title2)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fix All Permission Issues")
                            .font(.headline)
                        Text("Resets Screen Sharing, Screen Recording, and Local Network")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(healthService.isResetting)

            if let message = resultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.green)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .onAppear {
                        // Clear message after 10 seconds
                        Task {
                            try? await Task.sleep(nanoseconds: 10_000_000_000)
                            resultMessage = nil
                        }
                    }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
        )
    }

    @ViewBuilder
    private func resultSection(_ result: PermissionHealthService.ResetResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Fix Attempt")
                .font(.headline)

            Text("At \(result.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ResultRow(
                    label: "Screen Sharing Restarted",
                    success: result.screenSharingRestarted
                )
                ResultRow(
                    label: "Screen Recording Reset",
                    success: result.screenRecordingReset
                )
                ResultRow(
                    label: "Local Network Reset",
                    success: result.localNetworkReset
                )
                ResultRow(
                    label: "Accessibility Reset",
                    success: result.accessibilityReset
                )
                ResultRow(
                    label: "Input Monitoring Reset",
                    success: result.inputMonitoringReset
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var explanationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why This Happens")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ExplanationRow(
                    icon: "signature",
                    title: "Code Signature Changes",
                    description: "Rebuilding the app can cause macOS to treat it as a new app."
                )

                ExplanationRow(
                    icon: "memorychip",
                    title: "Cached Permissions",
                    description: "macOS caches permissions. Sometimes they need a hard reset."
                )

                ExplanationRow(
                    icon: "network",
                    title: "Service States",
                    description: "Screen Sharing can get into a stuck state where it's 'enabled' but not listening."
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var systemSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Settings")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    openSystemPreferences("x-apple.systempreferences:com.apple.preference.sharing")
                } label: {
                    Label("Sharing", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)

                Button {
                    openSystemPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                } label: {
                    Label("Screen Recording", systemImage: "video.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    openSystemPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                } label: {
                    Label("Local Network", systemImage: "network")
                }
                .buttonStyle(.bordered)

                Button {
                    openSystemPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                } label: {
                    Label("Accessibility", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    openSystemPreferences("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                } label: {
                    Label("Input Monitoring", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
            }

            Text("If fixing doesn't work, try manually toggling these settings off and on.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func openSystemPreferences(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ResultRow: View {
    let label: String
    let success: Bool

    var body: some View {
        HStack {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(success ? .green : .red)
            Text(label)
                .font(.subheadline)
            Spacer()
        }
    }
}

struct ExplanationRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PermissionDiagnosticView_Previews: PreviewProvider {
    static var previews: some View {
        PermissionDiagnosticView()
    }
}
