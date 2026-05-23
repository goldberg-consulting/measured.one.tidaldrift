import Foundation
import Security
import LocalAuthentication

class KeychainService {
    static let shared = KeychainService()

    private let serviceName = "com.tidaldrift.credentials"

    /// Whether to require biometric authentication for credential access
    var requireBiometricAuth: Bool {
        AppState.shared.settings.useBiometrics
    }

    private init() {}

    /// Credential structure for JSON encoding (safer than delimiter-based storage)
    private struct StoredCredential: Codable {
        let username: String
        let password: String
    }

    /// Create access control with optional biometric requirement
    private func createAccessControl() -> SecAccessControl? {
        if requireBiometricAuth {
            // Require biometric auth (Touch ID/Face ID) or device passcode
            return SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence],
                nil
            )
        }
        return nil
    }

    func saveCredential(for deviceId: String, username: String, password: String) throws {
        let credential = StoredCredential(username: username, password: password)
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        var addAttributes = updateAttributes
        if let accessControl = createAccessControl() {
            addAttributes[kSecAttrAccessControl as String] = accessControl
        } else {
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addAttributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retryStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
                guard retryStatus == errSecSuccess else {
                    throw KeychainError.updateFailed(retryStatus)
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        default:
            throw KeychainError.updateFailed(updateStatus)
        }
    }

    func saveCredential(for device: DiscoveredDevice, username: String, password: String) throws {
        try saveCredential(for: device.identityKey, username: username, password: password)
    }

    func getCredential(for deviceId: String) throws -> (username: String, password: String)? {
        try copyCredential(for: deviceId, allowUI: true)
    }

    func getCredential(for device: DiscoveredDevice) throws -> (username: String, password: String)? {
        if let credentials = try copyCredential(for: device.identityKey, allowUI: true) {
            return credentials
        }

        guard device.identityKey != device.stableId,
              let legacy = try copyCredential(for: device.stableId, allowUI: true) else {
            return nil
        }

        try saveCredential(for: device.identityKey, username: legacy.username, password: legacy.password)
        try? deleteCredential(for: device.stableId)
        return legacy
    }

    /// Reads a credential without ever triggering a biometric prompt or sheet.
    /// Returns nil if the item exists but requires authentication. Use this
    /// from SwiftUI view bodies and other paths where blocking the main
    /// thread on Touch ID would freeze the UI. When you need the value for
    /// an actual connection, call `getCredential(for:)` from a background
    /// task after the app has been activated.
    func peekCredential(for deviceId: String) -> (username: String, password: String)? {
        guard let credentials = try? copyCredential(for: deviceId, allowUI: false) else {
            return nil
        }
        return credentials
    }

    func peekCredential(for device: DiscoveredDevice) -> (username: String, password: String)? {
        if let credentials = peekCredential(for: device.identityKey) {
            return credentials
        }
        if device.identityKey != device.stableId {
            return peekCredential(for: device.stableId)
        }
        return nil
    }

    private func copyCredential(for deviceId: String, allowUI: Bool) throws -> (username: String, password: String)? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if allowUI {
            let context = LAContext()
            context.localizedReason = "Access saved credentials for \(deviceId)"
            query[kSecUseAuthenticationContext as String] = context
        } else {
            // Probe-only read: returns errSecInteractionNotAllowed instead
            // of putting up Touch ID. The caller treats that as "no credential
            // available right now" and falls back to the auth-required path
            // only when the user explicitly initiates a connection.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            switch status {
            case errSecItemNotFound, errSecInteractionNotAllowed:
                return nil
            case errSecUserCanceled, errSecAuthFailed:
                throw KeychainError.authenticationFailed
            default:
                throw KeychainError.retrieveFailed(status)
            }
        }

        if let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) {
            return (username: credential.username, password: credential.password)
        }

        if let credentials = String(data: data, encoding: .utf8) {
            let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return (username: parts[0], password: parts[1])
            }
        }

        throw KeychainError.invalidData
    }

    func deleteCredential(for deviceId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteCredential(for device: DiscoveredDevice) throws {
        try deleteCredential(for: device.identityKey)
        if device.identityKey != device.stableId {
            try? deleteCredential(for: device.stableId)
        }
    }

    func hasCredential(for deviceId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func hasCredential(for device: DiscoveredDevice) -> Bool {
        hasCredential(for: device.identityKey) || hasCredential(for: device.stableId)
    }

    func getAllSavedDeviceIds() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                return []
            }
            throw KeychainError.retrieveFailed(status)
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func authenticateWithBiometrics(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
                continuation.resume(returning: success)
            }
        }
    }

    /// Result of a biometric-ACL migration pass.
    struct MigrationSummary {
        let processed: Int
        let migrated: Int
        let skipped: Int
        let failed: Int
    }

    /// Re-save every credential in the keychain under the access policy that
    /// matches the current `useBiometrics` setting. Use this when the user
    /// disables Touch ID so previously-saved items stop prompting for
    /// fingerprint on every read. One pre-auth biometric prompt covers the
    /// entire run via a shared `LAContext`.
    ///
    /// The migration is intentionally best-effort: items the user cannot
    /// authenticate for are left in place and reported in `failed`. The
    /// caller can surface a summary message.
    func migrateCredentialsToCurrentBiometricSetting() async throws -> MigrationSummary {
        let allAccounts = try getAllSavedDeviceIds()
        guard !allAccounts.isEmpty else {
            return MigrationSummary(processed: 0, migrated: 0, skipped: 0, failed: 0)
        }

        let context = LAContext()
        context.localizedReason = "Update saved credentials for the new authentication setting"

        // Pre-authenticate once so individual reads do not each prompt.
        var canAuth = false
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            canAuth = await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication,
                                       localizedReason: "Update saved credentials") { success, _ in
                    continuation.resume(returning: success)
                }
            }
        }

        var migrated = 0
        var skipped = 0
        var failed = 0

        for account in allAccounts {
            // Read with the shared context. Items not protected by an ACL
            // succeed without prompting; ACL-protected items reuse the
            // context's prior evaluation.
            let credentials: (username: String, password: String)?
            do {
                credentials = try readWithContext(account: account, context: canAuth ? context : nil)
            } catch {
                failed += 1
                continue
            }

            guard let credentials else {
                skipped += 1
                continue
            }

            // Delete and re-add so the new ACL or its absence takes effect.
            do {
                try deleteCredential(for: account)
                try saveCredential(for: account, username: credentials.username, password: credentials.password)
                migrated += 1
            } catch {
                failed += 1
            }
        }

        return MigrationSummary(processed: allAccounts.count, migrated: migrated, skipped: skipped, failed: failed)
    }

    private func readWithContext(account: String, context: LAContext?) throws -> (username: String, password: String)? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        } else {
            // No usable context: read non-prompting so we never block here.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            switch status {
            case errSecItemNotFound, errSecInteractionNotAllowed:
                return nil
            case errSecUserCanceled, errSecAuthFailed:
                throw KeychainError.authenticationFailed
            default:
                throw KeychainError.retrieveFailed(status)
            }
        }

        if let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) {
            return (username: credential.username, password: credential.password)
        }
        if let credentials = String(data: data, encoding: .utf8) {
            let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return (username: parts[0], password: parts[1])
            }
        }
        throw KeychainError.invalidData
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case updateFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidData
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode credentials"
        case .saveFailed(let status):
            return "Failed to save credentials (error: \(status))"
        case .updateFailed(let status):
            return "Failed to update credentials (error: \(status))"
        case .retrieveFailed(let status):
            return "Failed to retrieve credentials (error: \(status))"
        case .deleteFailed(let status):
            return "Failed to delete credentials (error: \(status))"
        case .invalidData:
            return "Invalid credential data"
        case .authenticationFailed:
            return "Biometric authentication failed or was cancelled"
        }
    }
}
