import Foundation
import Combine

/// User preference for clipboard sync over LocalCast sessions.
///
/// Stored directly in UserDefaults under the key the legacy standalone service
/// used, so existing users keep their on/off choice. Deliberately not part of
/// the Codable `AppSettings` struct: that struct is decoded with a plain
/// `JSONDecoder` whose failure path resets every setting, so adding a
/// non-optional field there would wipe user configuration on upgrade.
@MainActor
final class ClipboardSyncPreferences: ObservableObject {
    static let shared = ClipboardSyncPreferences()

    private nonisolated static let key = "clipboardSyncEnabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.key) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            UserDefaults.standard.set(true, forKey: Self.key)
        }
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Read the preference without touching the main actor. The sessions check
    /// this from transport queues, where hopping to the main actor for a
    /// UserDefaults read is not worth the coordination.
    nonisolated static func isEnabledSnapshot() -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            || UserDefaults.standard.bool(forKey: key)
    }
}
