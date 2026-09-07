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

    /// Whether the data protection keychain is usable from this process.
    /// `kSecAttrAccessible` and `kSecAttrAccessControl` are only honored
    /// there, but it requires an application identifier from code signing;
    /// an unsigned dev build gets errSecMissingEntitlement, so probe once and
    /// fall back to the file-based keychain rather than fail every call.
    /// Every query goes through `baseQuery` so saves and lookups always
    /// target the same keychain.
    private var dataProtectionProbe: Bool?
    private let probeLock = NSLock()
    private var useDataProtectionKeychain: Bool {
        probeLock.lock()
        defer { probeLock.unlock() }
        if let known = dataProtectionProbe { return known }
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: "com.tidaldrift.keychain-probe",
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        let usable = status != errSecMissingEntitlement
        dataProtectionProbe = usable
        if usable { migrateLegacyItemsIfNeeded() }
        return usable
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecUseDataProtectionKeychain as String: useDataProtectionKeychain
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private static let legacyMigrationKey = "keychainLegacyMigrationDone"

    /// One-time copy of items saved before queries pinned the data protection
    /// keychain. Legacy items carry no ACL, so reading them never prompts.
    /// Runs from the `useDataProtectionKeychain` initializer, so it must not
    /// touch that property; it addresses both keychains explicitly.
    private func migrateLegacyItemsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey) }

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            var add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
                kSecValueData as String: data
            ]
            applyProtection(to: &add)
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
            let legacyDelete: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: false
            ]
            SecItemDelete(legacyDelete as CFDictionary)
        }
    }

    /// Attach the protection class that matches the current biometric setting.
    private func applyProtection(to attributes: inout [String: Any]) {
        if let accessControl = createAccessControl() {
            attributes[kSecAttrAccessControl as String] = accessControl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }
    }

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

        // Delete and re-add rather than update: SecItemUpdate cannot change
        // the protection class, so an item saved before Touch ID was enabled
        // would otherwise keep its old ACL forever.
        let query = baseQuery(account: deviceId)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.deleteFailed(deleteStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        applyProtection(to: &addQuery)

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Lost a race with a concurrent save; the value wins, the ACL is
            // whatever the winner set.
            let update: [String: Any] = [kSecValueData as String: data]
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainError.updateFailed(retryStatus)
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    func saveCredential(for device: DiscoveredDevice, username: String, password: String) throws {
        try saveCredential(for: device.identityKey, username: username, password: password)
    }

    func getCredential(for deviceId: String) throws -> (username: String, password: String)? {
        try copyCredential(for: deviceId, allowUI: true)
    }

    /// Look up the device's credential under every identity it has ever been
    /// keyed by (peer ID, manual ref, hostname, cache UUID, legacy name_ip).
    /// A hit under a non-canonical alias is re-saved under the canonical key
    /// so the next lookup is direct. This is what keeps a saved login seated
    /// when the computer comes back with a new IP, a different NIC, or a
    /// late-resolving hostname.
    func getCredential(for device: DiscoveredDevice) throws -> (username: String, password: String)? {
        let aliases = device.credentialAliases
        guard let canonical = aliases.first else { return nil }

        for alias in aliases {
            guard let credentials = try copyCredential(for: alias, allowUI: true) else { continue }
            if alias != canonical {
                try saveCredential(for: canonical, username: credentials.username, password: credentials.password)
                try? deleteCredential(for: alias)
            }
            return credentials
        }
        return nil
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

    /// Alias-walking variant of `peekCredential`. Read-only: no migration,
    /// so it stays safe to call from SwiftUI view bodies.
    func peekCredential(for device: DiscoveredDevice) -> (username: String, password: String)? {
        for alias in device.credentialAliases {
            if let credentials = peekCredential(for: alias) {
                return credentials
            }
        }
        return nil
    }

    private func copyCredential(for deviceId: String, allowUI: Bool) throws -> (username: String, password: String)? {
        var query = baseQuery(account: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

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
        let status = SecItemDelete(baseQuery(account: deviceId) as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    func deleteCredential(for device: DiscoveredDevice) throws {
        let aliases = device.credentialAliases
        guard let canonical = aliases.first else { return }
        try deleteCredential(for: canonical)
        for alias in aliases.dropFirst() {
            try? deleteCredential(for: alias)
        }
    }

    func hasCredential(for deviceId: String) -> Bool {
        var query = baseQuery(account: deviceId)
        query[kSecReturnData as String] = false
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func hasCredential(for device: DiscoveredDevice) -> Bool {
        device.credentialAliases.contains { hasCredential(for: $0) }
    }

    func getAllSavedDeviceIds() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

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
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
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
