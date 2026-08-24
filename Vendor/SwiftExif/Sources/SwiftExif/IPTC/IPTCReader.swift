import Foundation

/// Parse raw IPTC binary data into an IPTCData collection.
public struct IPTCReader: Sendable {
    /// The UTF-8 CodedCharacterSet escape sequence: ESC % G
    static let utf8EscapeSequence: [UInt8] = [0x1B, 0x25, 0x47]

    /// Parse raw IPTC binary data (the content of 8BIM resource 0x0404) into IPTCData.
    public static func read(from data: Data) throws -> IPTCData {
        var reader = BinaryReader(data: data)
        var datasets: [IPTCDataSet] = []
        var explicitEncoding: String.Encoding? = nil

        while !reader.isAtEnd {
            // Each dataset starts with 0x1C tag marker
            let marker = try reader.readUInt8()
            guard marker == 0x1C else {
                // Tolerate trailing padding (null bytes) often found in real-world files
                if marker == 0x00 { break }
                throw MetadataError.invalidIPTCData("Expected 0x1C tag marker, got 0x\(String(marker, radix: 16))")
            }

            let record = try reader.readUInt8()
            let dataSet = try reader.readUInt8()

            // Read length (2 bytes, big-endian)
            let lengthRaw = try reader.readUInt16BigEndian()

            let length: Int
            if lengthRaw & 0x8000 != 0 {
                // Extended length: lower 15 bits = number of bytes encoding the actual length
                let extLengthBytes = Int(lengthRaw & 0x7FFF)
                if extLengthBytes == 4 {
                    length = Int(try reader.readUInt32BigEndian())
                } else if extLengthBytes == 2 {
                    length = Int(try reader.readUInt16BigEndian())
                } else {
                    throw MetadataError.invalidIPTCData("Unsupported extended length size: \(extLengthBytes)")
                }
            } else {
                length = Int(lengthRaw)
            }

            let valueData = try reader.readBytes(length)
            let tag = IPTCTag(record: record, dataSet: dataSet)

            // Check for CodedCharacterSet (1:90)
            if tag == .codedCharacterSet {
                explicitEncoding = detectEncodingFromCharacterSet(valueData)
            }

            datasets.append(IPTCDataSet(tag: tag, rawValue: valueData))
        }

        // Determine encoding: explicit from CodedCharacterSet, or heuristic from content
        let encoding = explicitEncoding ?? detectEncodingFromContent(datasets)
        return IPTCData(datasets: datasets, encoding: encoding)
    }

    /// Detect encoding from IPTC CodedCharacterSet (Record 1:90) ESC sequences.
    private static func detectEncodingFromCharacterSet(_ data: Data) -> String.Encoding {
        if data.count >= 3,
           data[data.startIndex] == 0x1B,
           data[data.startIndex + 1] == 0x25,
           data[data.startIndex + 2] == 0x47 {
            return .utf8
        }
        // No other ESC sequence recognized — fall back to ISO-8859-1
        return .isoLatin1
    }

    /// When no CodedCharacterSet is present, detect encoding from content heuristics.
    /// Many programs write UTF-8 without setting the CodedCharacterSet tag.
    private static func detectEncodingFromContent(_ datasets: [IPTCDataSet]) -> String.Encoding {
        var hasHighBytes = false
        var looksLikeUTF8 = true

        for ds in datasets {
            guard ds.tag.dataType == .string || ds.tag.dataType == .digits else { continue }

            for byte in ds.rawValue {
                if byte > 127 {
                    hasHighBytes = true
                    break
                }
            }
            if hasHighBytes { break }
        }

        // All ASCII — encoding doesn't matter
        if !hasHighBytes { return .utf8 }

        // Collect all string bytes to test UTF-8 validity
        var allStringBytes = Data()
        for ds in datasets {
            guard ds.tag.dataType == .string || ds.tag.dataType == .digits else { continue }
            allStringBytes.append(ds.rawValue)
        }

        // If it's valid UTF-8, use UTF-8 (common in modern files without CodedCharacterSet)
        if String(data: allStringBytes, encoding: .utf8) != nil {
            looksLikeUTF8 = true
        } else {
            looksLikeUTF8 = false
        }

        if looksLikeUTF8 {
            return .utf8
        }

        // Bytes in 0x80-0x9F exist only in Windows-1252, not ISO-8859-1
        let hasCP1252OnlyBytes = allStringBytes.contains { $0 >= 0x80 && $0 <= 0x9F }
        if hasCP1252OnlyBytes {
            return .windowsCP1252
        }

        return .isoLatin1
    }

    /// Read IPTC data from an APP13 segment payload.
    public static func readFromAPP13(_ app13Data: Data) throws -> IPTCData {
        guard let iptcData = try PhotoshopIRB.extractIPTCData(app13Data) else {
            return IPTCData() // No IPTC resource found
        }
        return try read(from: iptcData)
    }
}
