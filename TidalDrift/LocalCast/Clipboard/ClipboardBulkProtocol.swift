import Foundation
import CryptoKit

/// Wire protocol for the clipboard bulk channel (TCP, `LocalCastConfiguration.clipboardPort`).
///
/// Every frame travels as `[UInt32 big-endian length][sealed bytes]`. On a
/// keyed session the sealed bytes are `SessionCrypto.encrypt` output under the
/// HKDF clipboard subkey; on a keyless session they carry the plaintext flag.
/// The first plaintext byte is the frame type tag. Chunk frames prepend a
/// 4-byte per-transfer sequence number so frames from one transfer cannot be
/// spliced into another under the same session key.

enum ClipboardBulkFrameType: UInt8 {
    case hello = 1     // JSON ClipboardBulkHello
    case helloAck = 2  // JSON ClipboardBulkManifest (fetch direction)
    case chunk = 3     // 4-byte BE sequence + content bytes
    case trailer = 4   // JSON ClipboardBulkTrailer
    case done = 5      // Receiver confirms a verified push so the pusher can close
}

/// First frame on every connection. `push` supplies its own manifest;
/// `fetch` presents a token and receives the manifest in the hello-ack.
struct ClipboardBulkHello: Codable {
    enum Op: String, Codable {
        case push
        case fetch
    }

    let op: Op
    let token: Data
    let manifest: ClipboardBulkManifest?
}

struct ClipboardBulkManifest: Codable {
    let updateId: UUID
    let kind: ClipboardContentKind
    let totalBytes: Int64
    let files: [ClipboardFileStub]?
}

struct ClipboardBulkTrailer: Codable {
    let sha256: Data
}

/// Large text rides the bulk channel as JSON so the RTF rendition survives.
struct ClipboardTextContent: Codable {
    let text: String
    let rtf: Data?
}

/// What a completed inbound transfer delivers.
enum ClipboardBulkReceived {
    case data(kind: ClipboardContentKind, data: Data)
    /// Files staged in a cache directory, in manifest order.
    case files([URL])
}

/// Outbound content a transfer streams.
enum ClipboardBulkContent {
    case data(kind: ClipboardContentKind, data: Data)
    case files([URL])

    var totalBytes: Int64 {
        switch self {
        case .data(_, let data):
            return Int64(data.count)
        case .files(let urls):
            return urls.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
    }
}

enum ClipboardBulkError: Error, LocalizedError {
    case connectionFailed
    case badFrame
    case frameTooLarge
    case sealRejected
    case tokenRejected
    case manifestMismatch
    case digestMismatch
    case limitExceeded
    case timedOut
    case cancelled
    case fileUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Could not reach the other Mac"
        case .badFrame: return "Malformed clipboard transfer frame"
        case .frameTooLarge: return "Clipboard transfer frame exceeds the size cap"
        case .sealRejected: return "Clipboard transfer frame failed decryption"
        case .tokenRejected: return "Clipboard transfer token was not accepted"
        case .manifestMismatch: return "Clipboard transfer content did not match its offer"
        case .digestMismatch: return "Clipboard transfer failed integrity verification"
        case .limitExceeded: return "Clipboard content exceeds the transfer limit"
        case .timedOut: return "Clipboard transfer timed out"
        case .cancelled: return "Clipboard transfer was cancelled"
        case .fileUnreadable(let name): return "Could not read \(name)"
        }
    }
}

enum ClipboardBulkFraming {
    /// Plaintext bytes per chunk frame (before the sequence prefix).
    static let chunkSize = 256 * 1024

    /// Hard cap on an incoming frame length: chunk + sequence prefix + type
    /// tag + seal overhead (flag, 12-byte nonce, 16-byte tag), with margin for
    /// JSON frames carrying a 64-file manifest. Anything larger aborts the
    /// connection before allocation, so a hostile length field cannot balloon
    /// memory.
    static let maxFrameLength = chunkSize + 64 * 1024

    /// Seal a frame body. Keyed sessions must encrypt; keyless sessions wrap
    /// plaintext.
    static func seal(_ plaintext: Data, key: SymmetricKey?) -> Data? {
        if let key {
            return SessionCrypto.encrypt(plaintext, using: key)
        }
        return SessionCrypto.wrapPlaintext(plaintext)
    }

    /// Open a sealed frame body. On a keyed session a plaintext-flagged frame
    /// is rejected outright (downgrade defense, mirroring UDPTransport); on a
    /// keyless session an encrypted frame is unreadable and equally rejected.
    static func unseal(_ sealed: Data, key: SymmetricKey?) -> Data? {
        if let key {
            guard sealed.first == SessionCrypto.encryptedFlag else { return nil }
            return SessionCrypto.decrypt(sealed, using: key)
        }
        guard sealed.first == SessionCrypto.plaintextFlag else { return nil }
        return SessionCrypto.unwrapPlaintext(sealed)
    }

    /// Build one length-prefixed wire frame: type tag + body, sealed.
    static func encodeFrame(type: ClipboardBulkFrameType, body: Data, key: SymmetricKey?) -> Data? {
        var plaintext = Data([type.rawValue])
        plaintext.append(body)
        guard let sealed = seal(plaintext, key: key) else { return nil }
        var frame = Data(capacity: 4 + sealed.count)
        var length = UInt32(sealed.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(sealed)
        return frame
    }

    /// Parse an unsealed frame into its type tag and body.
    static func decodeFrame(_ plaintext: Data) -> (type: ClipboardBulkFrameType, body: Data)? {
        guard let first = plaintext.first, let type = ClipboardBulkFrameType(rawValue: first) else { return nil }
        return (type, plaintext.dropFirst())
    }

    /// Chunk body: 4-byte big-endian sequence number + content slice.
    static func encodeChunkBody(sequence: UInt32, content: Data) -> Data {
        var body = Data(capacity: 4 + content.count)
        var seq = sequence.bigEndian
        withUnsafeBytes(of: &seq) { body.append(contentsOf: $0) }
        body.append(content)
        return body
    }

    static func decodeChunkBody(_ body: Data) -> (sequence: UInt32, content: Data)? {
        guard body.count >= 4 else { return nil }
        let seq = body.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        return (seq, body.dropFirst(4))
    }

    /// Sanitize a file name received from the network: last path component
    /// only, no traversal, no hidden files. Deliberately avoids
    /// `URL(fileURLWithPath:)`, which resolves ".." and "" against the current
    /// working directory and would return its name instead of rejecting.
    static func sanitizeFileName(_ raw: String) -> String? {
        guard let last = raw.split(separator: "/").last else { return nil }
        let name = String(last)
        if name.isEmpty || name == "." || name == ".." { return nil }
        if name.hasPrefix(".") { return nil }
        return name
    }

    /// A destination URL that does not collide with an existing file:
    /// "name.ext", then "name 2.ext", "name 3.ext", and so on.
    static func collisionFreeURL(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
