import Foundation

/// Parser for Apple iOS (iPhone/iPad) MakerNote data.
/// Format: "Apple iOS\0" (10-byte header) + standard IFD.
/// Offsets are relative to the MakerNote start. Apple files use the parent's byte order
/// (typically big-endian on iPhone JPEG/HEIC).
struct AppleMakerNote: Sendable {

    private static let makerNoteVersion: UInt16     = 0x0001
    private static let runTime: UInt16              = 0x0003
    private static let accelerationVector: UInt16   = 0x0008
    private static let hdrImageType: UInt16         = 0x000A
    private static let burstUUID: UInt16            = 0x000B
    private static let contentIdentifier: UInt16    = 0x0011
    private static let imageCaptureType: UInt16     = 0x0014
    private static let livePhotoVideoIndex: UInt16  = 0x0017
    private static let imageProcessingFlags: UInt16 = 0x0019
    private static let hdrHeadroom: UInt16          = 0x001E

    /// "Apple iOS\0"
    static let headerPrefix = Data([0x41, 0x70, 0x70, 0x6C, 0x65, 0x20, 0x69, 0x4F, 0x53, 0x00])

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard data.count > 14, data.prefix(10) == headerPrefix else { return tags }

        // Apple MakerNotes can encode their own byte order in the 4 bytes following the header
        // ("MM\0\x01" or "II\0\x01"); fall back to parent byte order when absent.
        let endian: ByteOrder
        let bom0 = data[data.startIndex + 10]
        let bom1 = data[data.startIndex + 11]
        if bom0 == 0x4D && bom1 == 0x4D {
            endian = .bigEndian
        } else if bom0 == 0x49 && bom1 == 0x49 {
            endian = .littleEndian
        } else {
            endian = byteOrder
        }

        // IFD starts at offset 14 (10-byte header + 4-byte BOM/version), but if there's no
        // recognizable BOM the IFD often starts right after the header.
        let ifdOffset = (bom0 == 0x4D || bom0 == 0x49) ? 14 : 10
        guard ifdOffset < data.count else { return tags }

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: ifdOffset, endian: endian
        ) else { return tags }

        if let entry = ifd.entry(for: makerNoteVersion),
           let value = entry.uint32Value(endian: endian) {
            tags["MakerNoteVersion"] = .uint(UInt(value))
        }

        // RunTime is a binary plist containing CMTime fields (epoch, value, timescale, flags).
        if let entry = ifd.entry(for: runTime), entry.type == .undefined {
            decodeRunTime(entry.valueData, into: &tags)
        }

        // AccelerationVector: srational[3] in g.
        if let entry = ifd.entry(for: accelerationVector), entry.type == .srational, entry.count >= 3 {
            var reader = BinaryReader(data: entry.valueData)
            var components: [Double] = []
            for _ in 0..<3 {
                guard let num = try? reader.readInt32(endian: endian),
                      let den = try? reader.readInt32(endian: endian),
                      den != 0 else { break }
                components.append(Double(num) / Double(den))
            }
            if components.count == 3 {
                tags["AccelerationX"] = .double(components[0])
                tags["AccelerationY"] = .double(components[1])
                tags["AccelerationZ"] = .double(components[2])
            }
        }

        if let entry = ifd.entry(for: hdrImageType),
           let value = entry.uint32Value(endian: endian) {
            tags["HDRImageType"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: burstUUID),
           let value = entry.stringValue(endian: endian) {
            tags["BurstUUID"] = .string(value)
        }

        // ContentIdentifier: the UUID that pairs a Live Photo HEIC with its MOV companion.
        if let entry = ifd.entry(for: contentIdentifier),
           let value = entry.stringValue(endian: endian) {
            tags["ContentIdentifier"] = .string(value)
        }

        if let entry = ifd.entry(for: imageCaptureType),
           let value = entry.uint32Value(endian: endian) {
            tags["ImageCaptureType"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: livePhotoVideoIndex),
           let value = entry.uint32Value(endian: endian) {
            tags["LivePhotoVideoIndex"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: imageProcessingFlags),
           let value = entry.uint32Value(endian: endian) {
            tags["ImageProcessingFlags"] = .int(Int(value))
        }

        if let entry = ifd.entry(for: hdrHeadroom), entry.type == .rational, entry.count >= 1 {
            if let (num, den) = entry.rationalValue(endian: endian), den != 0 {
                tags["HDRHeadroom"] = .double(Double(num) / Double(den))
            }
        }

        return tags
    }

    /// Decode the binary plist stored in tag 0x0003 and surface its CMTime fields.
    private static func decodeRunTime(_ data: Data, into tags: inout [String: MakerNoteValue]) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            tags["RunTime"] = .data(data)
            return
        }
        guard let dict = plist as? [String: Any] else {
            tags["RunTime"] = .data(data)
            return
        }
        if let value = dict["value"] as? Int { tags["RunTimeValue"] = .int(value) }
        if let scale = dict["timescale"] as? Int { tags["RunTimeScale"] = .int(scale) }
        if let epoch = dict["epoch"] as? Int { tags["RunTimeEpoch"] = .int(epoch) }
        if let flags = dict["flags"] as? Int { tags["RunTimeFlags"] = .int(flags) }
    }
}
