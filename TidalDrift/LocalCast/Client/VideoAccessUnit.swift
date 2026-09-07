import Foundation

/// Parses one transport packet containing one complete compressed video picture.
/// Slice NALs stay together in one VideoToolbox sample, including multi-slice IDRs.
struct VideoAccessUnit {
    let nalUnits: [Data]

    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        let units = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Data]? in
            func startCodeLength(at offset: Int) -> Int {
                guard offset + 3 <= bytes.count,
                      bytes[offset] == 0, bytes[offset + 1] == 0 else { return 0 }
                if bytes[offset + 2] == 1 { return 3 }
                if offset + 4 <= bytes.count, bytes[offset + 2] == 0, bytes[offset + 3] == 1 { return 4 }
                return 0
            }
            var result: [Data] = []
            if startCodeLength(at: 0) > 0 {
                var start = startCodeLength(at: 0)
                var cursor = start
                while cursor < bytes.count {
                    let codeLength = startCodeLength(at: cursor)
                    if codeLength > 0 {
                        guard cursor > start else { return nil }
                        result.append(Data(bytes[start..<cursor]))
                        start = cursor + codeLength
                        cursor = start
                    } else {
                        cursor += 1
                    }
                }
                guard start < bytes.count else { return nil }
                result.append(Data(bytes[start..<bytes.count]))
            } else {
                var cursor = 0
                while cursor < bytes.count {
                    guard bytes.count - cursor >= 4 else { return nil }
                    let length = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16
                        | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
                    cursor += 4
                    guard length > 0, length <= bytes.count - cursor else { return nil }
                    result.append(Data(bytes[cursor..<(cursor + length)]))
                    cursor += length
                }
            }
            return result.isEmpty ? nil : result
        }
        guard let units else { return nil }
        nalUnits = units
    }

    /// Parameter sets identify codec changes before slices are classified.
    var codecHint: LocalCastConfiguration.Codec? {
        if nalUnits.contains(where: { $0.count >= 2 && $0[0] == 0x40 && $0[1] & 0x07 != 0 }) {
            return .hevc
        }
        if nalUnits.contains(where: { $0.count >= 4 && $0[0] & 0x9F == 7 }) {
            return .h264
        }
        return nil
    }

    /// Returns all slices of the picture, with their original order preserved.
    func pictureNALUnits(codec: LocalCastConfiguration.Codec) -> [Data] {
        nalUnits.filter { nal in
            if codec == .hevc { return nal.count >= 2 && ((nal[0] >> 1) & 0x3F) <= 31 }
            return (1...5).contains(nal[0] & 0x1F)
        }
    }

    func isRandomAccess(codec: LocalCastConfiguration.Codec) -> Bool {
        pictureNALUnits(codec: codec).contains { nal in
            if codec == .hevc { return (16...21).contains((nal[0] >> 1) & 0x3F) }
            return nal[0] & 0x1F == 5
        }
    }

    static func lengthPrefixed(_ nalUnits: [Data]) -> Data {
        var data = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(nal)
        }
        return data
    }
}
