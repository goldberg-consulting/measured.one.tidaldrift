import Foundation
import CryptoKit
import OSLog

/// Handles all cryptographic operations for LocalCast sessions:
/// PIN generation, HKDF key derivation, AES-256-GCM encrypt/decrypt.
enum SessionCrypto {
    private static let logger = Logger(subsystem: "com.tidaldrift", category: "SessionCrypto")
    
    /// Domain separator prevents cross-protocol key reuse.
    private static let pairingInfo = "LocalCast-Pairing-v1".data(using: .utf8)!
    
    // MARK: - Key & PIN Generation
    
    /// Generate a random 256-bit symmetric key for the session.
    static func generateSessionKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }
    
    /// Generate a random 32-byte nonce for the auth handshake.
    static func generateNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
    
    // MARK: - Key Derivation
    
    /// Derive a pairing key from the PIN and both nonces using HKDF-SHA256.
    /// The PIN never travels over the wire; both sides compute this independently.
    /// Derive a pairing key from the shared secret (password) and both nonces.
    /// The password never travels over the wire; both sides compute this independently.
    static func derivePairingKey(password: String, clientNonce: Data, hostNonce: Data) -> SymmetricKey {
        let passData = Data(password.utf8)
        // Use the password as the input key material, nonces as salt
        let salt = clientNonce + hostNonce
        let inputKey = SymmetricKey(data: passData)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: pairingInfo,
            outputByteCount: 32
        )
        return derived
    }
    
    // MARK: - Encrypt / Decrypt
    
    /// Plaintext prefix byte (used during auth handshake only).
    static let plaintextFlag: UInt8 = 0x00
    /// Encrypted prefix byte (used for all post-auth traffic).
    static let encryptedFlag: UInt8 = 0x01
    
    /// Encrypt data with AES-256-GCM. Returns `[0x01] + nonce + ciphertext + tag`.
    static func encrypt(_ plaintext: Data, using key: SymmetricKey) -> Data? {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { return nil }
            return Data([encryptedFlag]) + combined
        } catch {
            logger.error("Encryption failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Decrypt data produced by `encrypt(_:using:)`.
    /// Expects the `0x01` prefix followed by the AES-GCM combined representation.
    static func decrypt(_ data: Data, using key: SymmetricKey) -> Data? {
        guard data.count > 1, data[0] == encryptedFlag else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst())
            return try AES.GCM.open(box, using: key)
        } catch {
            logger.error("Decryption failed: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Wrap raw data with the plaintext flag (no encryption).
    static func wrapPlaintext(_ data: Data) -> Data {
        Data([plaintextFlag]) + data
    }
    
    /// Unwrap plaintext-flagged data (strip the leading 0x00 byte).
    static func unwrapPlaintext(_ data: Data) -> Data? {
        guard data.count > 1, data[0] == plaintextFlag else { return nil }
        return Data(data.dropFirst())
    }
    
    /// Export a SymmetricKey to raw bytes.
    static func exportKey(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
    
    /// Import raw bytes as a SymmetricKey.
    static func importKey(_ data: Data) -> SymmetricKey {
        SymmetricKey(data: data)
    }
}

// MARK: - Input Rate Limiter

/// Sliding-window rate limiter for input events.
/// Thread-safe via NSLock.
final class InputRateLimiter {
    private let maxPerSecond: Int
    private var timestamps: [TimeInterval] = []
    private let lock = NSLock()
    
    /// Create a rate limiter. Pass 0 for unlimited.
    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
    }
    
    /// Returns `true` if the event should be allowed, `false` if rate-limited.
    func shouldAllow() -> Bool {
        guard maxPerSecond > 0 else { return true } // 0 = unlimited
        
        lock.lock()
        defer { lock.unlock() }
        
        let now = ProcessInfo.processInfo.systemUptime
        let windowStart = now - 1.0
        
        // Evict timestamps older than 1 second
        timestamps.removeAll { $0 < windowStart }
        
        if timestamps.count < maxPerSecond {
            timestamps.append(now)
            return true
        }
        return false
    }
}
