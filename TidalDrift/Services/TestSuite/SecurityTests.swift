import Foundation
import CryptoKit

extension TidalDriftTestRunner {

    func testSessionKeyGeneration() async -> (Bool, String) {
        let key1 = SessionCrypto.generateSessionKey()
        let key2 = SessionCrypto.generateSessionKey()

        let data1 = key1.withUnsafeBytes { Data($0) }
        let data2 = key2.withUnsafeBytes { Data($0) }

        guard data1.count == 32 else {
            return (false, "Key size is \(data1.count) bytes, expected 32")
        }
        guard data1 != data2 else {
            return (false, "Two generated keys are identical — RNG failure")
        }
        return (true, "Generated 256-bit keys, verified uniqueness")
    }

    func testHKDFKeyDerivation() async -> (Bool, String) {
        let password = "test-password-123"
        let clientNonce = SessionCrypto.generateNonce()
        let hostNonce = SessionCrypto.generateNonce()

        // Same inputs should produce same key
        let key1 = SessionCrypto.derivePairingKey(password: password, clientNonce: clientNonce, hostNonce: hostNonce)
        let key2 = SessionCrypto.derivePairingKey(password: password, clientNonce: clientNonce, hostNonce: hostNonce)

        let d1 = key1.withUnsafeBytes { Data($0) }
        let d2 = key2.withUnsafeBytes { Data($0) }

        guard d1 == d2 else {
            return (false, "Same inputs produced different keys")
        }

        // Different password should produce different key
        let key3 = SessionCrypto.derivePairingKey(password: "wrong-password", clientNonce: clientNonce, hostNonce: hostNonce)
        let d3 = key3.withUnsafeBytes { Data($0) }

        guard d1 != d3 else {
            return (false, "Different passwords produced same key — critical failure")
        }

        return (true, "HKDF-SHA256 deterministic, password-sensitive, 32-byte output")
    }

    func testAESGCMRoundtrip() async -> (Bool, String) {
        let key = SessionCrypto.generateSessionKey()
        let original = "Hello, TidalDrift! This is a secret message for testing AES-256-GCM."
        let plaintext = Data(original.utf8)

        guard let ciphertext = SessionCrypto.encrypt(plaintext, using: key) else {
            return (false, "Encryption returned nil")
        }

        // Ciphertext should be larger than plaintext (nonce + tag + flag byte)
        guard ciphertext.count > plaintext.count else {
            return (false, "Ciphertext (\(ciphertext.count)B) not larger than plaintext (\(plaintext.count)B)")
        }

        // First byte should be the encrypted flag
        guard ciphertext[0] == SessionCrypto.encryptedFlag else {
            return (false, "Missing encrypted flag byte")
        }

        guard let decrypted = SessionCrypto.decrypt(ciphertext, using: key) else {
            return (false, "Decryption returned nil")
        }

        guard decrypted == plaintext else {
            return (false, "Decrypted data does not match original")
        }

        return (true, "AES-256-GCM roundtrip: \(plaintext.count)B -> \(ciphertext.count)B -> \(decrypted.count)B")
    }

    func testTamperedCiphertextRejected() async -> (Bool, String) {
        let key = SessionCrypto.generateSessionKey()
        let plaintext = Data("Tamper test payload".utf8)

        guard var ciphertext = SessionCrypto.encrypt(plaintext, using: key) else {
            return (false, "Encryption failed")
        }

        // Flip a bit in the middle of the ciphertext
        let midpoint = ciphertext.count / 2
        ciphertext[midpoint] ^= 0xFF

        let result = SessionCrypto.decrypt(ciphertext, using: key)

        if result == nil {
            return (true, "Tampered ciphertext correctly rejected (GCM authentication tag failed)")
        }
        return (false, "CRITICAL: Tampered ciphertext was accepted — AES-GCM integrity check broken")
    }

    func testWrongPasswordRejected() async -> (Bool, String) {
        let clientNonce = SessionCrypto.generateNonce()
        let hostNonce = SessionCrypto.generateNonce()

        let correctKey = SessionCrypto.derivePairingKey(
            password: "correct-password", clientNonce: clientNonce, hostNonce: hostNonce
        )
        let wrongKey = SessionCrypto.derivePairingKey(
            password: "wrong-password", clientNonce: clientNonce, hostNonce: hostNonce
        )

        let plaintext = Data("Secret message".utf8)
        guard let encrypted = SessionCrypto.encrypt(plaintext, using: correctKey) else {
            return (false, "Encryption failed")
        }

        let decryptedWithWrongKey = SessionCrypto.decrypt(encrypted, using: wrongKey)
        if decryptedWithWrongKey == nil {
            return (true, "Wrong password correctly rejected during decryption")
        }
        return (false, "CRITICAL: Wrong password decrypted successfully")
    }

    func testKeychainLegacyCredentialMigration() async -> (Bool, String) {
        let peerId = "test-peer-\(UUID().uuidString)"
        let device = DiscoveredDevice(
            name: "Keychain Test",
            hostname: "keychain-test.local",
            ipAddress: "192.0.2.44",
            peerId: peerId
        )

        try? KeychainService.shared.deleteCredential(for: device.identityKey)
        try? KeychainService.shared.deleteCredential(for: device.stableId)

        do {
            try KeychainService.shared.saveCredential(
                for: device.stableId,
                username: "test-user",
                password: "test-password"
            )
            let migrated = try KeychainService.shared.getCredential(for: device)
            guard migrated?.username == "test-user", migrated?.password == "test-password" else {
                return (false, "Migrated credential did not match legacy value")
            }
            guard KeychainService.shared.hasCredential(for: device.identityKey) else {
                return (false, "Credential was not written under identity key")
            }
            try? KeychainService.shared.deleteCredential(for: device)
            return (true, "Legacy credential migrated to identity key")
        } catch {
            try? KeychainService.shared.deleteCredential(for: device)
            return (false, "Keychain migration failed: \(error.localizedDescription)")
        }
    }

    func testKeychainCredentialUpsert() async -> (Bool, String) {
        let account = "test-upsert-\(UUID().uuidString)"

        do {
            try? KeychainService.shared.deleteCredential(for: account)
            try KeychainService.shared.saveCredential(for: account, username: "first", password: "old")
            try KeychainService.shared.saveCredential(for: account, username: "second", password: "new")

            let credential = try KeychainService.shared.getCredential(for: account)
            guard credential?.username == "second", credential?.password == "new" else {
                return (false, "Upsert did not replace existing credential")
            }
            try? KeychainService.shared.deleteCredential(for: account)
            return (true, "Credential save updates existing Keychain item")
        } catch {
            try? KeychainService.shared.deleteCredential(for: account)
            return (false, "Keychain upsert failed: \(error.localizedDescription)")
        }
    }
}
