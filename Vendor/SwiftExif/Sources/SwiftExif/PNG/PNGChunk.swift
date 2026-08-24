import Foundation

/// A single PNG chunk.
public struct PNGChunk: Sendable, Equatable {
    /// 4-character ASCII chunk type (e.g. "eXIf", "iTXt", "IHDR").
    public let type: String
    /// Chunk data payload (excluding length, type, and CRC fields).
    public let data: Data
    /// Stored CRC32 value.
    public let crc: UInt32

    public init(type: String, data: Data, crc: UInt32) {
        self.type = type
        self.data = data
        self.crc = crc
    }
}
