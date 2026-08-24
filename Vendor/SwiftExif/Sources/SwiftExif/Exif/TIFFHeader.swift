import Foundation

/// TIFF header structure (8 bytes at the start of Exif data).
public struct TIFFHeader: Equatable, Sendable {
    public let byteOrder: ByteOrder
    public let magic: UInt16  // Always 42
    public let ifdOffset: UInt32

    public init(byteOrder: ByteOrder, ifdOffset: UInt32 = 8) {
        self.byteOrder = byteOrder
        self.magic = 42
        self.ifdOffset = ifdOffset
    }

    public static func parse(from reader: inout BinaryReader) throws -> TIFFHeader {
        let byte1 = try reader.readUInt8()
        let byte2 = try reader.readUInt8()

        let byteOrder: ByteOrder
        if byte1 == 0x49 && byte2 == 0x49 {
            byteOrder = .littleEndian
        } else if byte1 == 0x4D && byte2 == 0x4D {
            byteOrder = .bigEndian
        } else {
            throw MetadataError.invalidTIFFHeader
        }

        let magic = try reader.readUInt16(endian: byteOrder)
        guard magic == 42 else {
            throw MetadataError.invalidTIFFHeader
        }

        let ifdOffset = try reader.readUInt32(endian: byteOrder)

        return TIFFHeader(byteOrder: byteOrder, ifdOffset: ifdOffset)
    }

    public func write(to writer: inout BinaryWriter) {
        switch byteOrder {
        case .littleEndian:
            writer.writeBytes([0x49, 0x49])
        case .bigEndian:
            writer.writeBytes([0x4D, 0x4D])
        }
        writer.writeUInt16(magic, endian: byteOrder)
        writer.writeUInt32(ifdOffset, endian: byteOrder)
    }
}
