import Foundation

/// Parser for Leica MakerNote data.
/// Leica ships seven MakerNote variants depending on body. This parser handles the three
/// that account for >90% of files in the wild:
/// - Type 2 (M8/M9/M Monochrom): `LEICA\0\0\0` header (8 bytes) + IFD.
/// - Type 5 (Q/SL/CL): `LEICA\0\x07\0` or similar 8-byte header + IFD.
/// - Type 4 (S2/M-E/X1): bare IFD with no header.
/// Other variants fall through to opaque storage so round-trip preservation still works.
struct LeicaMakerNote: Sendable {

    private static let lensType: UInt16          = 0x0301
    private static let lensSerialNumber: UInt16  = 0x0303
    private static let serialNumber: UInt16      = 0x0307
    private static let firmwareVersion: UInt16   = 0x0501

    /// "LEICA\0"
    static let leicaPrefix = Data([0x4C, 0x45, 0x49, 0x43, 0x41, 0x00])

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]
        guard data.count > 8 else { return tags }

        let ifdOffset: Int
        let endian: ByteOrder

        if data.prefix(6) == leicaPrefix {
            // Header is 8 bytes total: "LEICA\0" + 2 type/version bytes. IFD follows immediately.
            ifdOffset = 8
            endian = byteOrder
        } else {
            // Bare IFD (Type 4 bodies).
            ifdOffset = 0
            endian = byteOrder
        }

        guard ifdOffset < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdOffset, endian: endian
        ) else { return tags }

        if let entry = ifd.entry(for: lensType) {
            if let value = entry.stringValue(endian: endian) {
                tags["LensType"] = .string(value)
            } else if let value = entry.uint16Value(endian: endian) {
                tags["LensType"] = .int(Int(value))
            }
        }

        if let entry = ifd.entry(for: lensSerialNumber),
           let value = entry.stringValue(endian: endian) {
            tags["LensSerialNumber"] = .string(value)
        }

        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: endian) {
            tags["SerialNumber"] = .string(value)
        }

        if let entry = ifd.entry(for: firmwareVersion),
           let value = entry.stringValue(endian: endian) {
            tags["FirmwareVersion"] = .string(value)
        }

        return tags
    }
}
