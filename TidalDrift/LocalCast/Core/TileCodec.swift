import Foundation
import Compression

/// Encoding scheme used for a single region-aware tile payload.
enum TileEncoding: UInt8 {
    case lzfse = 0   // LZFSE-compressed BGRA (lossless)
    case raw = 1     // uncompressed BGRA (fallback when compression doesn't help)
}

/// Serializes/deserializes a changed screen region ("tile") for region-aware
/// streaming. A tile is a tightly packed BGRA sub-rectangle of the captured
/// frame, compressed losslessly so text and UI stay crisp. The decoded size is
/// fully determined by width*height*4, so it is not stored.
///
/// Wire layout: [x:UInt16][y:UInt16][w:UInt16][h:UInt16][encoding:UInt8][data...]
enum TileCodec {
    static let headerSize = 9

    struct Tile {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        /// Tightly packed BGRA, `width * height * 4` bytes.
        let bgra: Data
    }

    /// Compress a tile into a `tileUpdate` payload. `bgra` must be tightly
    /// packed (no row padding) and exactly `width * height * 4` bytes.
    static func encode(x: Int, y: Int, width: Int, height: Int, bgra: Data) -> Data? {
        let expected = width * height * 4
        guard width > 0, height > 0, bgra.count == expected else { return nil }

        var encoding = TileEncoding.lzfse
        var body = compress(bgra)
        if body == nil || (body?.count ?? Int.max) >= expected {
            // Incompressible (or compression failed): store raw.
            encoding = .raw
            body = bgra
        }
        guard let payloadBody = body else { return nil }

        var out = Data(capacity: headerSize + payloadBody.count)
        appendU16(&out, UInt16(x))
        appendU16(&out, UInt16(y))
        appendU16(&out, UInt16(width))
        appendU16(&out, UInt16(height))
        out.append(encoding.rawValue)
        out.append(payloadBody)
        return out
    }

    /// Decode a `tileUpdate` payload back into a tile with tightly packed BGRA.
    static func decode(_ data: Data) -> Tile? {
        guard data.count > headerSize else { return nil }
        let x = Int(readU16(data, 0))
        let y = Int(readU16(data, 2))
        let width = Int(readU16(data, 4))
        let height = Int(readU16(data, 6))
        guard let encoding = TileEncoding(rawValue: data[data.startIndex + 8]) else { return nil }
        let expected = width * height * 4
        guard width > 0, height > 0 else { return nil }

        let body = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        let bgra: Data?
        switch encoding {
        case .raw:
            bgra = body.count == expected ? body : nil
        case .lzfse:
            bgra = decompress(body, expectedSize: expected)
        }
        guard let pixels = bgra, pixels.count == expected else { return nil }
        return Tile(x: x, y: y, width: width, height: height, bgra: pixels)
    }

    // MARK: - LZFSE

    private static func compress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let dstCap = input.count + 1024
        var dst = Data(count: dstCap)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            input.withUnsafeBytes { srcPtr in
                compression_encode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCap,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    private static func decompress(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty, expectedSize > 0 else { return nil }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            input.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard written == expectedSize else { return nil }
        return dst
    }

    // MARK: - Byte helpers

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }
}
