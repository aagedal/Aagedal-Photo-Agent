import Foundation

/// A single IPTC tag-value pair as stored in the binary format.
public struct IPTCDataSet: Equatable, Sendable {
    public let tag: IPTCTag
    public let rawValue: Data

    public init(tag: IPTCTag, rawValue: Data) {
        self.tag = tag
        self.rawValue = rawValue
    }

    /// Create a dataset from a string value, encoding as UTF-8.
    /// Throws `MetadataError.encodingError` if the string cannot be represented in the given encoding.
    public init(tag: IPTCTag, stringValue: String, encoding: String.Encoding = .utf8) throws {
        guard let encoded = stringValue.data(using: encoding) else {
            throw MetadataError.encodingError(
                "Cannot encode \"\(stringValue)\" for tag \(tag.name) using \(encoding)")
        }
        self.tag = tag
        self.rawValue = encoded
    }

    /// Create a dataset from a UInt16 value (big-endian, for record version fields).
    public init(tag: IPTCTag, uint16Value: UInt16) {
        self.tag = tag
        var writer = BinaryWriter(capacity: 2)
        writer.writeUInt16BigEndian(uint16Value)
        self.rawValue = writer.data
    }

    /// Decode the raw bytes as a string using the specified encoding.
    public func stringValue(encoding: String.Encoding = .utf8) -> String? {
        String(data: rawValue, encoding: encoding)
    }

    /// Decode as UInt16 big-endian (for record version fields).
    public func uint16Value() -> UInt16? {
        guard rawValue.count >= 2 else { return nil }
        return UInt16(rawValue[rawValue.startIndex]) << 8 | UInt16(rawValue[rawValue.startIndex + 1])
    }

    /// Decode as a single-byte unsigned integer.
    public func uint8Value() -> UInt8? {
        guard rawValue.count >= 1 else { return nil }
        return rawValue[rawValue.startIndex]
    }

    /// Decode as UInt32 big-endian (Record 3 / Record 8 numeric fields).
    public func uint32Value() -> UInt32? {
        guard rawValue.count >= 4 else { return nil }
        let s = rawValue.startIndex
        return UInt32(rawValue[s]) << 24
            | UInt32(rawValue[s + 1]) << 16
            | UInt32(rawValue[s + 2]) << 8
            | UInt32(rawValue[s + 3])
    }
}
