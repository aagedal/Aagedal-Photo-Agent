import Foundation

/// Parser for Nikon Type 3 MakerNote data.
/// Format: "Nikon\0" (6 bytes) + version (2 bytes) + embedded TIFF header + IFD.
/// Offsets are relative to the embedded TIFF header (offset 10 from MakerNote start).
struct NikonMakerNote: Sendable {

    // Nikon MakerNote tag IDs
    private static let quality: UInt16           = 0x0004
    private static let whiteBalance: UInt16      = 0x0005
    private static let isoInfo: UInt16           = 0x0025
    private static let serialNumber: UInt16      = 0x001D
    private static let lensType: UInt16          = 0x0083
    private static let lensData: UInt16          = 0x0084
    private static let shutterCount: UInt16      = 0x00A7
    private static let internalSerial: UInt16    = 0x00D0

    private static let headerPrefix = Data([0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00]) // "Nikon\0"

    static func parse(data: Data, parentByteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Verify Nikon header
        guard data.count > 18, data.prefix(6) == headerPrefix else { return tags }

        // Embedded TIFF header starts at offset 10
        let tiffStart = 10
        guard tiffStart + 8 <= data.count else { return tags }

        // Parse embedded byte order
        let bom0 = data[data.startIndex + tiffStart]
        let bom1 = data[data.startIndex + tiffStart + 1]
        let endian: ByteOrder
        if bom0 == 0x4D && bom1 == 0x4D {
            endian = .bigEndian
        } else if bom0 == 0x49 && bom1 == 0x49 {
            endian = .littleEndian
        } else {
            return tags
        }

        // Read IFD offset from embedded TIFF header
        var reader = BinaryReader(data: data)
        guard (try? reader.seek(to: tiffStart + 4)) != nil,
              let ifdOffset = try? reader.readUInt32(endian: endian) else { return tags }

        let absoluteIFDOffset = tiffStart + Int(ifdOffset)
        guard absoluteIFDOffset < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: tiffStart, offset: absoluteIFDOffset, endian: endian
        ) else { return tags }

        // Serial number (tag 0x001D) — ASCII string
        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: endian) {
            tags["SerialNumber"] = .string(value)
        }

        // Shutter count (tag 0x00A7) — UInt32
        if let entry = ifd.entry(for: shutterCount),
           let value = entry.uint32Value(endian: endian) {
            tags["ShutterCount"] = .int(Int(value))
        }

        // Lens type (tag 0x0083) — byte value
        if let entry = ifd.entry(for: lensType), entry.valueData.count >= 1 {
            tags["LensType"] = .int(Int(entry.valueData[entry.valueData.startIndex]))
        }

        // Lens data (tag 0x0084) — 4 rational values: min FL, max FL, min FN at min FL, min FN at max FL
        if let entry = ifd.entry(for: lensData), entry.type == .rational, entry.count >= 4 {
            var lensReader = BinaryReader(data: entry.valueData)
            if let minFLNum = try? lensReader.readUInt32(endian: endian),
               let minFLDen = try? lensReader.readUInt32(endian: endian),
               let maxFLNum = try? lensReader.readUInt32(endian: endian),
               let maxFLDen = try? lensReader.readUInt32(endian: endian),
               minFLDen > 0, maxFLDen > 0 {
                let minFL = Double(minFLNum) / Double(minFLDen)
                let maxFL = Double(maxFLNum) / Double(maxFLDen)
                tags["LensSpec"] = .string(String(format: "%.0f-%.0fmm", minFL, maxFL))
            }
        }

        // Internal serial number (tag 0x00D0) — ASCII string
        if let entry = ifd.entry(for: internalSerial),
           let value = entry.stringValue(endian: endian) {
            tags["InternalSerialNumber"] = .string(value)
        }

        return tags
    }
}
