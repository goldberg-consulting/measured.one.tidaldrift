import Foundation
import Combine

/// Lightweight tracker for in-flight Wake-on-LAN connection prep. Exists so
/// the UI can show a HUD while `WakeOnLANService.prepareForConnection` waits
/// up to 30s for the target Mac to come online. Without this, the menu
/// dismisses and the app appears frozen for the duration of the wait.
@MainActor
final class WakeProgressTracker: ObservableObject {
    static let shared = WakeProgressTracker()

    struct InflightWake: Identifiable, Equatable {
        let id = UUID()
        let deviceId: UUID
        let deviceName: String
        let service: DiscoveredDevice.ServiceType
        let startedAt: Date

        static func == (lhs: InflightWake, rhs: InflightWake) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published private(set) var current: InflightWake?

    private init() {}

    /// Begin tracking a wake attempt. Returns a token; pass it back to `end`
    /// so concurrent calls do not stomp each other.
    func begin(device: DiscoveredDevice, service: DiscoveredDevice.ServiceType) -> UUID {
        let wake = InflightWake(
            deviceId: device.id,
            deviceName: device.displayName,
            service: service,
            startedAt: Date()
        )
        current = wake
        return wake.id
    }

    func end(_ token: UUID) {
        if current?.id == token {
            current = nil
        }
    }

    /// Cancel any in-flight wake. The underlying network probes complete
    /// on their own; this only clears the HUD so the user can dismiss it.
    func cancelCurrent() {
        current = nil
    }
}
