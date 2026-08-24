import Foundation

/// TIFF data type identifiers and their byte sizes.
public enum TIFFDataType: UInt16, Sendable {
    case byte      = 1   // UInt8
    case ascii     = 2   // 7-bit ASCII + null
    case short     = 3   // UInt16
    case long      = 4   // UInt32
    case rational  = 5   // Two UInt32s (numerator/denominator)
    case sbyte     = 6   // Int8
    case undefined = 7   // Raw bytes
    case sshort    = 8   // Int16
    case slong     = 9   // Int32
    case srational = 10  // Two Int32s
    case float     = 11  // Float32
    case double    = 12  // Float64

    /// Size in bytes of a single value of this type.
    public var unitSize: Int {
        switch self {
        case .byte, .sbyte, .ascii, .undefined: return 1
        case .short, .sshort: return 2
        case .long, .slong, .float: return 4
        case .rational, .srational, .double: return 8
        }
    }
}

/// A single IFD entry (12 bytes in file).
public struct IFDEntry: Equatable, Sendable {
    public let tag: UInt16
    public let type: TIFFDataType
    public let count: UInt32
    /// The resolved value data (either inline 4 bytes or fetched from offset).
    public let valueData: Data
    /// TIFF-relative offset where out-of-line value bytes were read from the
    /// source (the raw value of the entry's 4-byte offset field); `nil` for
    /// inline values and synthesized entries. Provenance only — used by the
    /// writers to relocate a MakerNote's internal offsets; excluded from
    /// equality (see `==` below).
    public let sourceOffset: Int?

    public init(tag: UInt16, type: TIFFDataType, count: UInt32, valueData: Data, sourceOffset: Int? = nil) {
        self.tag = tag
        self.type = type
        self.count = count
        self.valueData = valueData
        self.sourceOffset = sourceOffset
    }

    public static func == (lhs: IFDEntry, rhs: IFDEntry) -> Bool {
        lhs.tag == rhs.tag &&
        lhs.type == rhs.type &&
        lhs.count == rhs.count &&
        lhs.valueData == rhs.valueData
        // sourceOffset intentionally excluded (provenance, not semantic value)
    }

    /// Total byte size of this entry's value data.
    public var totalValueSize: Int { Int(count) * type.unitSize }

    /// Whether the value fits inline (<=4 bytes) or is at an offset.
    public var isInline: Bool { totalValueSize <= 4 }

    // MARK: - Value Extraction

    public func stringValue(endian: ByteOrder = .bigEndian) -> String? {
        guard type == .ascii else { return nil }
        // Remove null terminator if present
        var data = valueData
        if let lastByte = data.last, lastByte == 0 {
            data = data.dropLast()
        }
        return String(data: data, encoding: .ascii)
    }

    public func uint16Value(endian: ByteOrder) -> UInt16? {
        guard type == .short, valueData.count >= 2 else { return nil }
        var reader = BinaryReader(data: valueData)
        return try? reader.readUInt16(endian: endian)
    }

    public func uint32Value(endian: ByteOrder) -> UInt32? {
        guard type == .long, valueData.count >= 4 else { return nil }
        var reader = BinaryReader(data: valueData)
        return try? reader.readUInt32(endian: endian)
    }

    public func rationalValue(endian: ByteOrder) -> (numerator: UInt32, denominator: UInt32)? {
        guard type == .rational, valueData.count >= 8 else { return nil }
        var reader = BinaryReader(data: valueData)
        guard let num = try? reader.readUInt32(endian: endian),
              let den = try? reader.readUInt32(endian: endian) else { return nil }
        return (num, den)
    }

    public func srationalValue(endian: ByteOrder) -> (numerator: Int32, denominator: Int32)? {
        guard type == .srational, valueData.count >= 8 else { return nil }
        var reader = BinaryReader(data: valueData)
        guard let num = try? reader.readInt32(endian: endian),
              let den = try? reader.readInt32(endian: endian) else { return nil }
        return (num, den)
    }

    public func floatValue(endian: ByteOrder) -> Float? {
        guard type == .float, valueData.count >= 4 else { return nil }
        var reader = BinaryReader(data: valueData)
        return try? reader.readFloat32(endian: endian)
    }

    public func uint16Values(endian: ByteOrder) -> [UInt16] {
        guard type == .short else { return [] }
        var reader = BinaryReader(data: valueData)
        var values: [UInt16] = []
        for _ in 0..<count {
            if let v = try? reader.readUInt16(endian: endian) {
                values.append(v)
            }
        }
        return values
    }
}

/// A complete IFD (Image File Directory).
public struct IFD: Equatable, Sendable {
    public let entries: [IFDEntry]
    public let nextIFDOffset: UInt32

    public init(entries: [IFDEntry], nextIFDOffset: UInt32 = 0) {
        self.entries = entries
        self.nextIFDOffset = nextIFDOffset
    }

    /// Find an entry by tag.
    public func entry(for tag: UInt16) -> IFDEntry? {
        entries.first { $0.tag == tag }
    }

    public subscript(tag: UInt16) -> IFDEntry? {
        entry(for: tag)
    }

    /// Return a new IFD with the given tag removed.
    public func removingEntry(for tag: UInt16) -> IFD {
        IFD(entries: entries.filter { $0.tag != tag }, nextIFDOffset: nextIFDOffset)
    }

    /// Whether this IFD contains an entry for the given tag.
    public func hasEntry(for tag: UInt16) -> Bool {
        entries.contains { $0.tag == tag }
    }
}
