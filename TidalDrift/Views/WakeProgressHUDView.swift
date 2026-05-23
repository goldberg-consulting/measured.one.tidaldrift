import SwiftUI

/// HUD shown while `WakeOnLANService.prepareForConnection` is waiting for a
/// sleeping Mac to come online. Hosted inside a small floating NSWindow that
/// `AppDelegate` shows when `WakeProgressTracker.shared.current` is non-nil
/// and hides otherwise.
struct WakeProgressHUDView: View {
    @ObservedObject var tracker: WakeProgressTracker = .shared
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        Group {
            if let wake = tracker.current {
                content(for: wake)
            } else {
                EmptyView()
            }
        }
        .frame(width: 320, height: 110)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.background)
                .shadow(radius: 12, y: 2)
        )
        .onChange(of: tracker.current?.id) { _ in
            restartTimer()
        }
        .onAppear { restartTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func content(for wake: WakeProgressTracker.InflightWake) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(0.85)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Waking \(wake.deviceName)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Connecting via \(serviceLabel(wake.service))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack {
                Text(String(format: "Elapsed %.0fs", elapsed))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Dismiss") {
                    tracker.cancelCurrent()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func restartTimer() {
        timer?.invalidate()
        elapsed = tracker.current.map { Date().timeIntervalSince($0.startedAt) } ?? 0
        guard tracker.current != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if let started = tracker.current?.startedAt {
                    elapsed = Date().timeIntervalSince(started)
                }
            }
        }
    }

    private func serviceLabel(_ service: DiscoveredDevice.ServiceType) -> String {
        switch service {
        case .screenSharing, .tidalDrift: return "Screen Share"
        case .fileSharing: return "File Share"
        case .afp: return "AFP"
        case .ssh: return "SSH"
        case .localCast: return "Metal Stream"
        case .tidalDrop: return "TidalDrop"
        }
    }
}
