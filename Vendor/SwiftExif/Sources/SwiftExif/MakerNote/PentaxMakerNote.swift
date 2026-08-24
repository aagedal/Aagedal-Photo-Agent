import Foundation

/// Parser for Pentax/Ricoh Imaging MakerNote data.
/// Modern bodies use an "AOC\0" header followed by a 2-byte BOM and a standard IFD;
/// older Asahi/Pentax bodies emit a bare IFD with no header.
struct PentaxMakerNote: Sendable {

    private static let pentaxVersion: UInt16    = 0x0000
    private static let modelID: UInt16          = 0x0005
    private static let quality: UInt16          = 0x0008
    private static let pictureMode: UInt16      = 0x000B
    private static let flashMode: UInt16        = 0x000C
    private static let lensType: UInt16         = 0x0207
    private static let serialNumber: UInt16     = 0x0229

    /// "AOC\0"
    static let aocPrefix = Data([0x41, 0x4F, 0x43, 0x00])

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]
        guard data.count > 8 else { return tags }

        // Detect "AOC\0" + BOM header and resolve byte order from it.
        let endian: ByteOrder
        let ifdOffset: Int
        if data.prefix(4) == aocPrefix {
            let bom0 = data[data.startIndex + 4]
            let bom1 = data[data.startIndex + 5]
            if bom0 == 0x4D && bom1 == 0x4D {
                endian = .bigEndian
            } else if bom0 == 0x49 && bom1 == 0x49 {
                endian = .littleEndian
            } else {
                endian = byteOrder
            }
            ifdOffset = 6
        } else {
            // Bare IFD (older bodies).
            endian = byteOrder
            ifdOffset = 0
        }

        guard ifdOffset < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdOffset, endian: endian
        ) else { return tags }

        // PentaxVersion (tag 0x0000) — UInt8[4] or undefined; surface as dotted-quad string.
        if let entry = ifd.entry(for: pentaxVersion), entry.valueData.count >= 4 {
            let bytes = entry.valueData.prefix(4)
            let dotted = bytes.map { String($0) }.joined(separator: ".")
            tags["PentaxVersion"] = .string(dotted)
        }

        if let entry = ifd.entry(for: modelID),
           let value = entry.uint32Value(endian: endian) {
            tags["ModelID"] = .uint(UInt(value))
        }

        if let entry = ifd.entry(for: quality),
           let value = entry.uint16Value(endian: endian) {
            tags["Quality"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: pictureMode),
           let value = entry.uint16Value(endian: endian) {
            tags["PictureMode"] = .int(Int(value))
        }

        // FlashMode is int16[2]; surface the first component (the mode).
        if let entry = ifd.entry(for: flashMode), entry.type == .short {
            let values = entry.uint16Values(endian: endian)
            if let first = values.first {
                tags["FlashMode"] = .int(Int(first))
            }
        }

        // LensType is typically int8[4] (lens body bytes); surface as colon-separated digits.
        if let entry = ifd.entry(for: lensType), entry.valueData.count >= 2 {
            let bytes = entry.valueData.prefix(min(4, entry.valueData.count))
            let formatted = bytes.map { String($0) }.joined(separator: " ")
            tags["LensType"] = .string(formatted)
        }

        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: endian) {
            tags["SerialNumber"] = .string(value)
        }

        return tags
    }
}
