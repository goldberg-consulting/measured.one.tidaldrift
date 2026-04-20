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
}
