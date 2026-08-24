import Foundation

/// Parser for Samsung MakerNote data.
/// Samsung MakerNotes use standard IFD format starting immediately (no header prefix),
/// identical to the Canon pattern.
struct SamsungMakerNote: Sendable {

    // Samsung MakerNote tag IDs
    private static let makerNoteVersion: UInt16          = 0x0001
    private static let deviceType: UInt16                = 0x0002
    private static let modelID: UInt16                   = 0x0003
    private static let smartAlbumColor: UInt16           = 0x000c
    private static let encryptionKey: UInt16             = 0x0010
    private static let colorTemperature: UInt16          = 0x0035
    private static let imageEditor: UInt16               = 0x0040
    private static let firmwareName: UInt16              = 0x0043
    private static let faceDetect: UInt16                = 0x0050
    private static let faceRecognition: UInt16           = 0x0100
    private static let focalLengthIn35mmFormat: UInt16   = 0xa001

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: 0, endian: byteOrder
        ) else { return tags }

        // MakerNoteVersion (tag 0x0001) — ASCII or undefined
        if let entry = ifd.entry(for: makerNoteVersion),
           let value = entry.stringValue(endian: byteOrder) {
            tags["MakerNoteVersion"] = .string(value)
        }

        // DeviceType (tag 0x0002) — UInt32
        if let entry = ifd.entry(for: deviceType),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["DeviceType"] = .uint(UInt(value))
        }

        // ModelID (tag 0x0003) — UInt32
        if let entry = ifd.entry(for: modelID),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["ModelID"] = .uint(UInt(value))
        }

        // SmartAlbumColor (tag 0x000c) — UInt32
        if let entry = ifd.entry(for: smartAlbumColor),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["SmartAlbumColor"] = .uint(UInt(value))
        }

        // EncryptionKey (tag 0x0010) — UInt32
        if let entry = ifd.entry(for: encryptionKey),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["EncryptionKey"] = .uint(UInt(value))
        }

        // ColorTemperature (tag 0x0035) — UInt32
        if let entry = ifd.entry(for: colorTemperature),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["ColorTemperature"] = .uint(UInt(value))
        }

        // ImageEditor (tag 0x0040) — ASCII
        if let entry = ifd.entry(for: imageEditor),
           let value = entry.stringValue(endian: byteOrder) {
            tags["ImageEditor"] = .string(value)
        }

        // FirmwareName (tag 0x0043) — ASCII
        if let entry = ifd.entry(for: firmwareName),
           let value = entry.stringValue(endian: byteOrder) {
            tags["FirmwareName"] = .string(value)
        }

        // FaceDetect (tag 0x0050) — UInt16
        if let entry = ifd.entry(for: faceDetect),
           let value = entry.uint16Value(endian: byteOrder) {
            tags["FaceDetect"] = .int(Int(value))
        }

        // FaceRecognition (tag 0x0100) — UInt32
        if let entry = ifd.entry(for: faceRecognition),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["FaceRecognition"] = .uint(UInt(value))
        }

        // FocalLengthIn35mmFormat (tag 0xa001) — UInt32
        if let entry = ifd.entry(for: focalLengthIn35mmFormat),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["FocalLengthIn35mmFormat"] = .uint(UInt(value))
        }

        return tags
    }
}
