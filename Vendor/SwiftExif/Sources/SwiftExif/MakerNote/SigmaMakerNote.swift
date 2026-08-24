import Foundation

/// Parser for Sigma/Foveon MakerNote data.
/// Format: `SIGMA\0\0\0` or `FOVEON\0\0` (8-byte header) + bare IFD with offsets
/// relative to the MakerNote start.
struct SigmaMakerNote: Sendable {

    private static let serialNumber: UInt16     = 0x0002
    private static let resolution: UInt16       = 0x0011
    private static let lensType: UInt16         = 0x0012
    private static let whiteBalance: UInt16     = 0x0017
    private static let lensRange: UInt16        = 0x002A

    /// "SIGMA\0\0\0"
    static let sigmaPrefix = Data([0x53, 0x49, 0x47, 0x4D, 0x41, 0x00, 0x00, 0x00])
    /// "FOVEON\0\0"
    static let foveonPrefix = Data([0x46, 0x4F, 0x56, 0x45, 0x4F, 0x4E, 0x00, 0x00])

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]
        guard data.count > 10 else { return tags }

        let ifdOffset: Int
        if data.prefix(8) == sigmaPrefix || data.prefix(8) == foveonPrefix {
            ifdOffset = 8
        } else {
            return tags
        }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdOffset, endian: byteOrder
        ) else { return tags }

        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }

        if let entry = ifd.entry(for: resolution),
           let value = entry.stringValue(endian: byteOrder) {
            tags["Resolution"] = .string(value)
        }

        if let entry = ifd.entry(for: lensType),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensType"] = .string(value)
        }

        if let entry = ifd.entry(for: whiteBalance),
           let value = entry.stringValue(endian: byteOrder) {
            tags["WhiteBalance"] = .string(value)
        }

        if let entry = ifd.entry(for: lensRange),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensRange"] = .string(value)
        }

        return tags
    }
}
