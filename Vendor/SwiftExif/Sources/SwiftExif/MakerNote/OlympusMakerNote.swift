import Foundation

/// Parser for Olympus/OM System MakerNote data.
/// Two header variants:
/// - Old: "OLYMP\0" (6 bytes) + version (2 bytes), IFD at offset 8
/// - New: "OLYMPUS\0II" or "OLYMPUS\0MM" (10 bytes) with embedded byte order
struct OlympusMakerNote: Sendable {

    private static let cameraID: UInt16     = 0x0207
    private static let serialNumber2: UInt16 = 0x0404
    private static let quality: UInt16      = 0x0201
    private static let cameraType: UInt16   = 0x0207

    private static let oldPrefix = Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x00]) // "OLYMP\0"
    private static let newPrefix = Data([0x4F, 0x4C, 0x59, 0x4D, 0x50, 0x55, 0x53, 0x00]) // "OLYMPUS\0"

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard data.count > 12 else { return tags }

        let ifdOffset: Int
        let endian: ByteOrder

        if data.prefix(8) == newPrefix {
            // New format: "OLYMPUS\0" + byte order marker (2 bytes)
            guard data.count > 12 else { return tags }
            let bom0 = data[data.startIndex + 8]
            let bom1 = data[data.startIndex + 9]
            if bom0 == 0x49 && bom1 == 0x49 {
                endian = .littleEndian
            } else if bom0 == 0x4D && bom1 == 0x4D {
                endian = .bigEndian
            } else {
                endian = byteOrder
            }
            // IFD typically at offset 12 (after "OLYMPUS\0" + BOM + version)
            ifdOffset = 12
        } else if data.prefix(6) == oldPrefix {
            // Old format: "OLYMP\0" + version (2 bytes), IFD at offset 8
            endian = byteOrder
            ifdOffset = 8
        } else {
            return tags
        }

        guard ifdOffset < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdOffset, endian: endian
        ) else { return tags }

        // CameraID / Equipment (tag 0x0207) — ASCII or undefined
        if let entry = ifd.entry(for: cameraID) {
            if let value = entry.stringValue(endian: endian) {
                tags["CameraID"] = .string(value)
            } else if entry.type == .undefined, entry.valueData.count >= 4 {
                let hex = entry.valueData.prefix(16).map { String(format: "%02X", $0) }.joined()
                tags["CameraID"] = .string(hex)
            }
        }

        // Quality (tag 0x0201) — UInt16
        if let entry = ifd.entry(for: quality),
           let value = entry.uint16Value(endian: endian) {
            tags["Quality"] = .int(Int(value))
        }

        return tags
    }
}
