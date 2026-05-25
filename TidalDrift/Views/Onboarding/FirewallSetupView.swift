import SwiftUI

struct FirewallSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var isChecking = false
    @State private var isAddingException = false
    @State private var firewallEnabled = false
    @State private var blockingAll = false
    @State private var tidalDriftAllowed = false
    @State private var firewallMessage: String?
    
    var body: some View {
        VStack(spacing: 24) {
            headerSection
            
            statusSection
            
            if firewallEnabled {
                configurationInfo
            }
            
            actionSection
        }
        .onAppear {
            checkStatus()
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 50))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            Text("Firewall")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            
            Text("Ensure your firewall allows incoming connections")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private var statusSection: some View {
        VStack(spacing: 12) {
            // Firewall status card
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Firewall Status")
                        .font(.headline)
                    
                    if isChecking {
                        Text("Checking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(firewallEnabled ? "Firewall is ON" : "Firewall is OFF")
                            .font(.caption)
                            .foregroundColor(firewallEnabled ? .orange : .green)
                    }
                }
                
                Spacer()
                
                if isChecking {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: firewallEnabled ? "shield.fill" : "shield.slash")
                        .font(.title2)
                        .foregroundColor(firewallEnabled ? .orange : .green)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            
            // Status message
            if !isChecking {
                if !firewallEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No firewall blocking - you're all set!")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                } else if blockingAll {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Firewall is blocking ALL incoming connections")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                } else if tidalDriftAllowed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Firewall allows TidalDrift")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Add TidalDrift as an allowed app")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }
    
    private var configurationInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("If connections aren't working:")
                .font(.subheadline)
                .fontWeight(.medium)
            
            VStack(alignment: .leading, spacing: 6) {
                Label("Open Firewall settings", systemImage: "1.circle.fill")
                    .font(.caption)
                Label("Ensure \"Block all incoming\" is OFF", systemImage: "2.circle.fill")
                    .font(.caption)
                Label("Add TidalDrift to allowed apps", systemImage: "3.circle.fill")
                    .font(.caption)
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
    
    private var actionSection: some View {
        VStack(spacing: 12) {
            if firewallEnabled {
                Button {
                    addFirewallException()
                } label: {
                    if isAddingException {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Label("Allow TidalDrift Through Firewall", systemImage: "shield.checkered")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAddingException)
            }

            Button("Open Firewall Settings") {
                SharingConfigurationService.shared.openFirewallSettings()
            }
            .buttonStyle(.bordered)
            
            Button("Check Again") {
                checkStatus()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)

            if let firewallMessage {
                Text(firewallMessage)
                    .font(.caption)
                    .foregroundColor(firewallMessage.contains("Could not") ? .orange : .secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    private func checkStatus() {
        isChecking = true
        Task {
            let enabled = await SharingConfigurationService.shared.isFirewallEnabled()
            let blocking = await SharingConfigurationService.shared.isFirewallBlockingAll()
            let allowed = await SharingConfigurationService.shared.isTidalDriftAllowedThroughFirewall()
            
            await MainActor.run {
                firewallEnabled = enabled
                blockingAll = blocking
                tidalDriftAllowed = allowed
                isChecking = false
            }
        }
    }

    private func addFirewallException() {
        isAddingException = true
        firewallMessage = nil

        Task {
            let ok = await SharingConfigurationService.shared.allowTidalDriftThroughFirewall()
            let allowed = await SharingConfigurationService.shared.isTidalDriftAllowedThroughFirewall()
            await MainActor.run {
                isAddingException = false
                tidalDriftAllowed = allowed
                firewallMessage = ok && allowed
                    ? "TidalDrift is allowed through the firewall."
                    : "Could not confirm the firewall exception. Open Firewall Settings and verify TidalDrift is allowed."
            }
        }
    }
}

struct FirewallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        FirewallSetupView(viewModel: OnboardingViewModel())
            .frame(width: 600, height: 500)
    }
}
