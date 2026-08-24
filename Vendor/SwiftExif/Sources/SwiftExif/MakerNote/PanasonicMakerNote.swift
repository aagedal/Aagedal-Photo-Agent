import Foundation

/// Parser for Panasonic/Lumix MakerNote data.
/// Format: "Panasonic\0\0\0" (12 bytes) + IFD.
/// Offsets relative to start of MakerNote data.
struct PanasonicMakerNote: Sendable {

    private static let internalSerialNumber: UInt16 = 0x0025
    private static let lensSerialNumber: UInt16     = 0x002E
    private static let lensType: UInt16             = 0x0051
    private static let quality: UInt16              = 0x0001

    private static let headerPrefix = Data("Panasonic\0\0\0".utf8)

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Verify Panasonic header (12 bytes)
        guard data.count > 14,
              data.prefix(9) == Data("Panasonic".utf8) else { return tags }

        let ifdStart = 12
        guard ifdStart < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdStart, endian: byteOrder
        ) else { return tags }

        // Internal serial number (tag 0x0025) — ASCII string
        if let entry = ifd.entry(for: internalSerialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["InternalSerialNumber"] = .string(value)
        }

        // Lens serial number (tag 0x002E) — ASCII string
        if let entry = ifd.entry(for: lensSerialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensSerialNumber"] = .string(value)
        }

        // Lens type (tag 0x0051) — ASCII string or UInt16
        if let entry = ifd.entry(for: lensType) {
            if let value = entry.stringValue(endian: byteOrder) {
                tags["LensType"] = .string(value)
            } else if let value = entry.uint16Value(endian: byteOrder) {
                tags["LensType"] = .int(Int(value))
            }
        }

        return tags
    }
}
