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
        let context = LAContext()
        context.localizedReason = "Access saved credentials for \(deviceId)"

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: deviceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Always provide an authentication context so older ACL-protected items
        // remain readable even if the current biometric setting is off.
        query[kSecUseAuthenticationContext as String] = context

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            if status == errSecItemNotFound {
                return nil
            }
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw KeychainError.authenticationFailed
            }
            throw KeychainError.retrieveFailed(status)
        }

        // Try new JSON format first
        if let credential = try? JSONDecoder().decode(StoredCredential.self, from: data) {
            return (username: credential.username, password: credential.password)
        }

        // Fall back to legacy colon-separated format for existing credentials
        if let credentials = String(data: data, encoding: .utf8) {
            let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return (username: parts[0], password: parts[1])
            }
        }

        throw KeychainError.invalidData
    }

    func getCredential(for device: DiscoveredDevice) throws -> (username: String, password: String)? {
        if let credentials = try getCredential(for: device.identityKey) {
            return credentials
        }

        guard device.identityKey != device.stableId,
              let legacy = try getCredential(for: device.stableId) else {
            return nil
        }

        try saveCredential(for: device.identityKey, username: legacy.username, password: legacy.password)
        try? deleteCredential(for: device.stableId)
        return legacy
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
