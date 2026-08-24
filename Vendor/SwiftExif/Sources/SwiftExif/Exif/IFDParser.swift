import Foundation

/// Shared IFD parsing logic used by ExifReader and TIFFFileParser.
struct IFDParser {

    /// Parse a single IFD at the given offset in the data.
    /// - Parameters:
    ///   - data: The full data buffer containing the IFD.
    ///   - tiffStart: The offset where the TIFF header begins (0 for standalone TIFF, 6 for JPEG Exif).
    ///   - offset: The absolute offset of the IFD in `data`.
    ///   - endian: The byte order from the TIFF header.
    /// - Returns: The parsed IFD and the next IFD offset (0 if none).
    static func parseIFD(data: Data, tiffStart: Int, offset: Int, endian: ByteOrder) throws -> (IFD, UInt32) {
        var reader = BinaryReader(data: data)
        try reader.seek(to: offset)

        let count = try reader.readUInt16(endian: endian)
        var entries: [IFDEntry] = []

        for _ in 0..<count {
            let tag = try reader.readUInt16(endian: endian)
            let typeRaw = try reader.readUInt16(endian: endian)
            let valueCount = try reader.readUInt32(endian: endian)
            let valueOrOffset = try reader.readBytes(4)

            guard let type = TIFFDataType(rawValue: typeRaw) else {
                // Skip unknown types
                continue
            }

            let (totalSize, overflow) = Int(valueCount).multipliedReportingOverflow(by: type.unitSize)
            guard !overflow, totalSize >= 0 else {
                throw MetadataError.invalidIFDEntry
            }
            let valueData: Data
            // TIFF-relative offset of out-of-line value bytes (nil when inline).
            var sourceOffset: Int? = nil

            if totalSize <= 4 {
                // Value is inline (in the 4-byte field)
                valueData = Data(valueOrOffset.prefix(totalSize))
            } else {
                // Value is at an offset
                var offsetReader = BinaryReader(data: valueOrOffset)
                let dataOffset = try offsetReader.readUInt32(endian: endian)
                valueData = try reader.slice(from: tiffStart + Int(dataOffset), count: totalSize)
                sourceOffset = Int(dataOffset)
            }

            entries.append(IFDEntry(tag: tag, type: type, count: valueCount, valueData: valueData, sourceOffset: sourceOffset))
        }

        let nextIFDOffset = try reader.readUInt32(endian: endian)

        return (IFD(entries: entries, nextIFDOffset: nextIFDOffset), nextIFDOffset)
    }
}
