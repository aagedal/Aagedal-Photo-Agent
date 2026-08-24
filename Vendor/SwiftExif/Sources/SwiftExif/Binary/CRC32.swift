import Foundation

/// CRC32 implementation for PNG chunk validation.
struct CRC32 {
    /// Precomputed lookup table.
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table[n] = c
        }
        return table
    }()

    /// Compute CRC32 over the given data.
    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Compute CRC32 over a type string + data (as PNG does for each chunk).
    static func compute(type: String, data: Data) -> UInt32 {
        var combined = Data(type.utf8)
        combined.append(data)
        return compute(combined)
    }
}
