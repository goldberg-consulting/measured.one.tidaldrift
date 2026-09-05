import Foundation
import CommonCrypto
import CryptoKit
import OSLog

/// Handles all cryptographic operations for LocalCast sessions:
/// PIN generation, HKDF key derivation, AES-256-GCM encrypt/decrypt.
enum SessionCrypto {
    private static let logger = Logger(subsystem: "com.tidaldrift", category: "SessionCrypto")
    
    /// Domain separator prevents cross-protocol key reuse.
    private static let pairingInfo = "LocalCast-Pairing-v1".data(using: .utf8)!

    /// Domain separator for the v2 (password-stretched) pairing key.
    private static let pairingInfoV2 = Data("LocalCast-Pairing-v2".utf8)

    /// Domain separator for the clipboard bulk channel subkey.
    private static let clipboardInfo = Data("LocalCast-Clipboard-v1".utf8)

    /// Pairing handshake versions. The authRequest payload is the 32-byte
    /// client nonce, optionally followed by a single version byte; a bare
    /// 32-byte nonce is v1. The host derives the pairing key for whichever
    /// version the request carries, so old and new builds interoperate:
    /// a v2 client talking to a v1 host falls back to v1 in its retransmit
    /// chain, and a v1 client talking to a v2 host is served v1.
    enum PairingVersion: UInt8 {
        /// Plain HKDF over the password. Fast, so a sniffed handshake can be
        /// brute-forced offline at hash speed. Kept only for interop.
        case v1 = 1
        /// PBKDF2-HMAC-SHA256 stretch of the password (salted with both
        /// nonces) before HKDF. Makes an offline guess cost ~150k hashes.
        case v2 = 2

        static let current: PairingVersion = .v2
    }

    /// Payload of an authRequest for the given version.
    static func authRequestPayload(nonce: Data, version: PairingVersion) -> Data {
        switch version {
        case .v1: return nonce
        case .v2: return nonce + Data([version.rawValue])
        }
    }

    /// Parse an authRequest payload into (clientNonce, version). Nil for any
    /// shape this build does not understand.
    static func parseAuthRequest(_ payload: Data) -> (nonce: Data, version: PairingVersion)? {
        switch payload.count {
        case 32:
            return (payload, .v1)
        case 33:
            guard let version = PairingVersion(rawValue: payload[payload.startIndex + 32]), version != .v1 else { return nil }
            return (payload.prefix(32), version)
        default:
            return nil
        }
    }

    /// PBKDF2-HMAC-SHA256 work factor for v2 (the OWASP 2023 floor). Measured
    /// at ~70 ms on an M-series Mac; paid once per handshake on each side.
    static let pbkdf2Iterations: UInt32 = 600_000
    
    // MARK: - Key & PIN Generation
    
    /// Generate a random 256-bit symmetric key for the session.
    static func generateSessionKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }
    
    /// Generate 32 random bytes (auth nonces, clipboard offer tokens).
    /// CryptoKit's RNG traps rather than silently failing, unlike
    /// SecRandomCopyBytes whose ignored status could have yielded an all-zero,
    /// predictable token.
    static func generateNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    
    // MARK: - Key Derivation
    
    /// Derive a pairing key from the PIN and both nonces using HKDF-SHA256.
    /// The PIN never travels over the wire; both sides compute this independently.
    /// Derive a pairing key from the shared secret (password) and both nonces.
    /// The password never travels over the wire; both sides compute this independently.
    static func derivePairingKey(password: String, clientNonce: Data, hostNonce: Data, version: PairingVersion = .v1) -> SymmetricKey {
        let salt = clientNonce + hostNonce
        switch version {
        case .v1:
            let inputKey = SymmetricKey(data: Data(password.utf8))
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: pairingInfo,
                outputByteCount: 32
            )
        case .v2:
            let stretched = pbkdf2(password: password, salt: salt, iterations: pbkdf2Iterations)
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: stretched),
                salt: salt,
                info: pairingInfoV2,
                outputByteCount: 32
            )
        }
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto (CryptoKit has no PBKDF).
    private static func pbkdf2(password: String, salt: Data, iterations: UInt32) -> Data {
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuf -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { CChar(bitPattern: $0) }, passwordBytes.count,
                saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &output, output.count
            )
        }
        // CCKeyDerivationPBKDF only fails on parameter errors, which the fixed
        // arguments above rule out. Fail closed anyway: returning the zeroed
        // buffer would let both sides derive the same key from an empty
        // secret and pass the handshake with any password.
        if status != kCCSuccess {
            logger.error("PBKDF2 failed with status \(status); handshake will not match")
            return generateNonce()
        }
        return Data(output)
    }
    
    /// Derive the clipboard bulk-channel key from the session key. A distinct
    /// subkey keeps bulk traffic cryptographically separated from the UDP
    /// session without a second handshake.
    static func deriveClipboardKey(from sessionKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sessionKey,
            info: clipboardInfo,
            outputByteCount: 32
        )
    }

    /// Compare two byte sequences without early exit, for token checks where a
    /// timing side channel would let a connecting peer probe byte by byte.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
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
