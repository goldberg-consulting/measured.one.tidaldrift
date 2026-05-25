import SwiftUI

struct OnboardingContainerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = OnboardingViewModel()
    
    var body: some View {
        ZStack {
            backgroundGradient
            
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    progressIndicator
                        .frame(maxWidth: .infinity)

                    Text("v\(Bundle.main.fullVersion)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .help("Installed TidalDrift version and build")
                }
                .padding(.top, 18)
                
                currentStepView
                    .frame(maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(viewModel.currentStep)
                
                navigationButtons
                    .padding(.vertical, 24)
            }
            .padding(.horizontal, 50)
        }
        .frame(minWidth: 700, minHeight: 620)
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor).opacity(0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
    
    private var progressIndicator: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == viewModel.currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)
                    .scaleEffect(step == viewModel.currentStep ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3), value: viewModel.currentStep)
            }
        }
    }
    
    @ViewBuilder
    private var currentStepView: some View {
        switch viewModel.currentStep {
        case .welcome:
            WelcomeStepView()
        case .screenSharing:
            ScreenSharingSetupView(viewModel: viewModel)
        case .sharingUser:
            SharingUserSetupView(viewModel: viewModel)
        case .fileSharing:
            FileSharingSetupView(viewModel: viewModel)
        case .sshSetup:
            RemoteLoginSetupView(viewModel: viewModel)
        case .firewall:
            FirewallSetupView(viewModel: viewModel)
        case .completion:
            CompletionStepView(viewModel: viewModel)
        }
    }
    
    private var navigationButtons: some View {
        HStack {
            if viewModel.currentStep != .welcome && viewModel.currentStep != .completion {
                Button("Back") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.previousStep()
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if viewModel.currentStep == .completion {
                Button("Get Started") {
                    (NSApp.delegate as? AppDelegate)?.finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if viewModel.canProceed {
                Button(viewModel.currentStep == .welcome ? "Let's Go" : "Continue") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.nextStep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(viewModel.currentStep == .sshSetup ? "Skip SSH" : "Skip for Now") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.nextStep()
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case screenSharing
    case sharingUser  // New: Create dedicated sharing account
    case fileSharing
    case sshSetup     // New: Remote Login / SSH
    case firewall
    case completion
}

struct OnboardingContainerView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingContainerView()
            .environmentObject(AppState.shared)
    }
}
