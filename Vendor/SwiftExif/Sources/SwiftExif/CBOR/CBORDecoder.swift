import Foundation

/// Decodes CBOR (RFC 8949) binary data into CBORValue.
public struct CBORDecoder: Sendable {

    /// Maximum nesting depth for arrays, maps, and tags. C2PA manifests in
    /// the wild stay well under 10 — the cap exists to stop a crafted
    /// payload from exhausting the stack.
    static let maxDepth = 100

    /// Decode a single CBOR value from the given data.
    public static func decode(from data: Data) throws -> CBORValue {
        var reader = BinaryReader(data: data)
        return try decodeValue(from: &reader, depth: 0)
    }

    // MARK: - Internal

    static func decodeValue(from reader: inout BinaryReader, depth: Int) throws -> CBORValue {
        guard depth <= Self.maxDepth else {
            throw MetadataError.invalidCBOR("Nesting depth exceeds limit (\(Self.maxDepth))")
        }
        let initial = try reader.readUInt8()
        let majorType = initial >> 5
        let additionalInfo = initial & 0x1F

        switch majorType {
        case 0: // Unsigned integer
            let value = try decodeLength(additionalInfo, from: &reader)
            return .unsignedInt(value)

        case 1: // Negative integer: -1 - n
            let n = try decodeLength(additionalInfo, from: &reader)
            if n <= UInt64(Int64.max) {
                return .negativeInt(-1 - Int64(n))
            }
            // Overflow: store as the largest representable negative
            return .negativeInt(Int64.min)

        case 2: // Byte string
            if additionalInfo == 31 {
                // Indefinite-length byte string
                return .byteString(try decodeIndefiniteBytes(from: &reader, depth: depth + 1))
            }
            let length = try decodeLength(additionalInfo, from: &reader)
            // Bound the UInt64 length by remaining data before converting to Int —
            // Int(UInt64) traps when length > Int.max, and a crafted manifest can
            // specify lengths up to 2^64-1.
            guard length <= UInt64(reader.remainingCount) else {
                throw MetadataError.invalidCBOR("Byte string length \(length) exceeds remaining data")
            }
            return .byteString(try reader.readBytes(Int(length)))

        case 3: // Text string
            if additionalInfo == 31 {
                // Indefinite-length text string
                let data = try decodeIndefiniteBytes(from: &reader, depth: depth + 1)
                guard let string = String(data: data, encoding: .utf8) else {
                    throw MetadataError.invalidCBOR("Invalid UTF-8 in text string")
                }
                return .textString(string)
            }
            let length = try decodeLength(additionalInfo, from: &reader)
            guard length <= UInt64(reader.remainingCount) else {
                throw MetadataError.invalidCBOR("Text string length \(length) exceeds remaining data")
            }
            let data = try reader.readBytes(Int(length))
            guard let string = String(data: data, encoding: .utf8) else {
                throw MetadataError.invalidCBOR("Invalid UTF-8 in text string")
            }
            return .textString(string)

        case 4: // Array
            if additionalInfo == 31 {
                // Indefinite-length array
                var items: [CBORValue] = []
                while true {
                    if try reader.peek() == 0xFF {
                        _ = try reader.readUInt8() // consume break
                        break
                    }
                    items.append(try decodeValue(from: &reader, depth: depth + 1))
                }
                return .array(items)
            }
            let count = try decodeLength(additionalInfo, from: &reader)
            guard count <= UInt64(reader.remainingCount) else {
                throw MetadataError.invalidCBOR("Array count \(count) exceeds remaining data")
            }
            var items: [CBORValue] = []
            items.reserveCapacity(min(Int(count), 1024))
            for _ in 0..<count {
                items.append(try decodeValue(from: &reader, depth: depth + 1))
            }
            return .array(items)

        case 5: // Map
            if additionalInfo == 31 {
                // Indefinite-length map
                var entries: [CBORMapEntry] = []
                while true {
                    if try reader.peek() == 0xFF {
                        _ = try reader.readUInt8() // consume break
                        break
                    }
                    let key = try decodeValue(from: &reader, depth: depth + 1)
                    let value = try decodeValue(from: &reader, depth: depth + 1)
                    entries.append(CBORMapEntry(key: key, value: value))
                }
                return .map(entries)
            }
            let count = try decodeLength(additionalInfo, from: &reader)
            guard count <= UInt64(reader.remainingCount) else {
                throw MetadataError.invalidCBOR("Map count \(count) exceeds remaining data")
            }
            var entries: [CBORMapEntry] = []
            entries.reserveCapacity(min(Int(count), 1024))
            for _ in 0..<count {
                let key = try decodeValue(from: &reader, depth: depth + 1)
                let value = try decodeValue(from: &reader, depth: depth + 1)
                entries.append(CBORMapEntry(key: key, value: value))
            }
            return .map(entries)

        case 6: // Semantic tag
            let tag = try decodeLength(additionalInfo, from: &reader)
            let content = try decodeValue(from: &reader, depth: depth + 1)
            return .tagged(tag, content)

        case 7: // Simple values and floats
            return try decodeSimple(additionalInfo, from: &reader)

        default:
            throw MetadataError.invalidCBOR("Unknown CBOR major type: \(majorType)")
        }
    }

    // MARK: - Private

    /// Decode the argument value from additional info.
    private static func decodeLength(_ info: UInt8, from reader: inout BinaryReader) throws -> UInt64 {
        switch info {
        case 0...23:
            return UInt64(info)
        case 24:
            return UInt64(try reader.readUInt8())
        case 25:
            return UInt64(try reader.readUInt16BigEndian())
        case 26:
            return UInt64(try reader.readUInt32BigEndian())
        case 27:
            return try reader.readUInt64BigEndian()
        default:
            throw MetadataError.invalidCBOR("Invalid CBOR additional info: \(info)")
        }
    }

    /// Decode simple values and floating-point numbers (major type 7).
    private static func decodeSimple(_ info: UInt8, from reader: inout BinaryReader) throws -> CBORValue {
        switch info {
        case 20: return .boolean(false)
        case 21: return .boolean(true)
        case 22: return .null
        case 23: return .undefined
        case 25:
            // IEEE 754 half-precision float (float16)
            let bits = try reader.readUInt16BigEndian()
            return .float(Double(decodeFloat16(bits)))
        case 26:
            // IEEE 754 single-precision float (float32)
            let bits = try reader.readUInt32BigEndian()
            return .float(Double(Float(bitPattern: bits)))
        case 27:
            // IEEE 754 double-precision float (float64)
            let bits = try reader.readUInt64BigEndian()
            return .float(Double(bitPattern: bits))
        case 0...19:
            // Simple value encoded directly (RFC 8949 §3.3)
            return .simple(info)
        case 24:
            // Simple value in following byte (RFC 8949 §3.3)
            let value = try reader.readUInt8()
            return .simple(value)
        default:
            throw MetadataError.invalidCBOR("Reserved CBOR simple value: \(info)")
        }
    }

    /// Decode an indefinite-length byte/text string (concatenate chunks until break).
    private static func decodeIndefiniteBytes(from reader: inout BinaryReader, depth: Int) throws -> Data {
        var result = Data()
        while true {
            if try reader.peek() == 0xFF {
                _ = try reader.readUInt8() // consume break
                break
            }
            let chunk = try decodeValue(from: &reader, depth: depth)
            guard let bytes = chunk.byteStringValue else {
                throw MetadataError.invalidCBOR("Non-byte-string chunk in indefinite-length byte string")
            }
            result.append(bytes)
        }
        return result
    }

    /// Decode IEEE 754 half-precision (binary16) to Float.
    private static func decodeFloat16(_ bits: UInt16) -> Float {
        let sign = (bits >> 15) & 1
        let exponent = (bits >> 10) & 0x1F
        let mantissa = bits & 0x3FF

        let signF: Float = sign == 1 ? -1.0 : 1.0

        if exponent == 0 {
            if mantissa == 0 {
                return signF * 0.0
            }
            // Subnormal: (-1)^sign * 2^(-14) * (mantissa / 1024)
            return signF * Float(mantissa) / 1024.0 * exp2(-14)
        }

        if exponent == 31 {
            if mantissa == 0 {
                return signF * .infinity
            }
            return .nan
        }

        // Normal: (-1)^sign * 2^(exponent-15) * (1 + mantissa/1024)
        return signF * exp2(Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
    }
}
