import Foundation

public struct BinaryWriter: Sendable {
    public private(set) var data: Data

    public init(capacity: Int = 256) {
        self.data = Data()
        self.data.reserveCapacity(capacity)
    }

    public var count: Int { data.count }

    // MARK: - Writing Primitives

    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeUInt16BigEndian(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    public mutating func writeUInt16LittleEndian(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    public mutating func writeUInt16(_ value: UInt16, endian: ByteOrder) {
        switch endian {
        case .bigEndian: writeUInt16BigEndian(value)
        case .littleEndian: writeUInt16LittleEndian(value)
        }
    }

    public mutating func writeInt16(_ value: Int16, endian: ByteOrder) {
        writeUInt16(UInt16(bitPattern: value), endian: endian)
    }

    public mutating func writeUInt32BigEndian(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    public mutating func writeUInt32LittleEndian(_ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    public mutating func writeUInt32(_ value: UInt32, endian: ByteOrder) {
        switch endian {
        case .bigEndian: writeUInt32BigEndian(value)
        case .littleEndian: writeUInt32LittleEndian(value)
        }
    }

    public mutating func writeInt32(_ value: Int32, endian: ByteOrder) {
        writeUInt32(UInt32(bitPattern: value), endian: endian)
    }

    public mutating func writeFloat32(_ value: Float, endian: ByteOrder) {
        writeUInt32(value.bitPattern, endian: endian)
    }

    public mutating func writeUInt64BigEndian(_ value: UInt64) {
        data.append(UInt8((value >> 56) & 0xFF))
        data.append(UInt8((value >> 48) & 0xFF))
        data.append(UInt8((value >> 40) & 0xFF))
        data.append(UInt8((value >> 32) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    public mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    public mutating func writeString(_ string: String, encoding: String.Encoding = .utf8) {
        if let encoded = string.data(using: encoding) {
            data.append(encoded)
        }
    }

    /// Write a null-terminated string.
    public mutating func writeNullTerminatedString(_ string: String, encoding: String.Encoding = .utf8) {
        writeString(string, encoding: encoding)
        writeUInt8(0)
    }

    // MARK: - Padding

    /// Pad to even byte boundary by writing 0x00 if current length is odd.
    public mutating func padToEven() {
        if data.count % 2 != 0 {
            data.append(0)
        }
    }

    /// Write zero bytes to reach a specific alignment.
    public mutating func align(to alignment: Int) {
        let remainder = data.count % alignment
        if remainder != 0 {
            let padding = alignment - remainder
            for _ in 0..<padding {
                data.append(0)
            }
        }
    }

    // MARK: - Patching

    /// Overwrite bytes at a specific offset without changing the writer position.
    public mutating func patchUInt16BigEndian(_ value: UInt16, at offset: Int) throws {
        guard offset >= 0 && offset + 2 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    public mutating func patchUInt32BigEndian(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0 && offset + 4 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    public mutating func patchUInt32LittleEndian(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0 && offset + 4 <= data.count else {
            throw MetadataError.unexpectedEndOfData
        }
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    public mutating func patchUInt32(_ value: UInt32, at offset: Int, endian: ByteOrder) throws {
        switch endian {
        case .bigEndian: try patchUInt32BigEndian(value, at: offset)
        case .littleEndian: try patchUInt32LittleEndian(value, at: offset)
        }
    }
}
