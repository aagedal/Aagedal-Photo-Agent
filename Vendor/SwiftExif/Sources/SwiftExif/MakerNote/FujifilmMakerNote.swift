import Foundation

/// Parser for Fujifilm MakerNote data.
/// Format: "FUJIFILM" (8 bytes) + 4-byte little-endian offset to IFD.
/// Always little-endian regardless of parent TIFF byte order.
struct FujifilmMakerNote: Sendable {

    private static let serialNumber: UInt16      = 0x0010
    private static let quality: UInt16           = 0x1000
    private static let sharpness: UInt16         = 0x1001
    private static let whiteBalance: UInt16      = 0x1002
    private static let filmMode: UInt16          = 0x1401

    private static let headerPrefix = Data([0x46, 0x55, 0x4A, 0x49, 0x46, 0x49, 0x4C, 0x4D]) // "FUJIFILM"

    static func parse(data: Data, parentByteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Verify Fujifilm header
        guard data.count > 12, data.prefix(8) == headerPrefix else { return tags }

        // Read IFD offset (always little-endian, at bytes 8-11)
        var reader = BinaryReader(data: data)
        guard (try? reader.seek(to: 8)) != nil,
              let ifdOffset = try? reader.readUInt32(endian: .littleEndian) else { return tags }

        let absoluteOffset = Int(ifdOffset)
        guard absoluteOffset < data.count else { return tags }

        // Fujifilm always uses little-endian
        let endian = ByteOrder.littleEndian

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: absoluteOffset, endian: endian
        ) else { return tags }

        // Serial number (tag 0x0010) — ASCII string
        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: endian) {
            tags["SerialNumber"] = .string(value)
        }

        // Quality (tag 0x1000) — ASCII string
        if let entry = ifd.entry(for: quality),
           let value = entry.stringValue(endian: endian) {
            tags["Quality"] = .string(value)
        }

        // Sharpness (tag 0x1001) — UInt16
        if let entry = ifd.entry(for: sharpness),
           let value = entry.uint16Value(endian: endian) {
            tags["Sharpness"] = .int(Int(value))
        }

        // Film mode (tag 0x1401) — UInt16
        if let entry = ifd.entry(for: filmMode),
           let value = entry.uint16Value(endian: endian) {
            tags["FilmMode"] = .int(Int(value))
        }

        return tags
    }
}
