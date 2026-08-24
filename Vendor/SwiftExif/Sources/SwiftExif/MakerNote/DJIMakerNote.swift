import Foundation

/// Parser for DJI drone MakerNote data.
/// DJI MakerNotes use standard IFD format starting immediately (no header prefix),
/// identical to the Canon pattern.
struct DJIMakerNote: Sendable {

    // DJI MakerNote tag IDs
    private static let make: UInt16          = 0x0001
    private static let speedX: UInt16        = 0x0003
    private static let speedY: UInt16        = 0x0004
    private static let speedZ: UInt16        = 0x0005
    private static let pitch: UInt16         = 0x0006
    private static let yaw: UInt16           = 0x0007
    private static let roll: UInt16          = 0x0008
    private static let cameraPitch: UInt16   = 0x0009
    private static let cameraYaw: UInt16     = 0x000a
    private static let cameraRoll: UInt16    = 0x000b
    private static let aircraftModel: UInt16 = 0x000d

    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: 0, endian: byteOrder
        ) else { return tags }

        // Make (tag 0x0001) — ASCII
        if let entry = ifd.entry(for: make),
           let value = entry.stringValue(endian: byteOrder) {
            tags["Make"] = .string(value)
        }

        // Aircraft model (tag 0x000d) — ASCII
        if let entry = ifd.entry(for: aircraftModel),
           let value = entry.stringValue(endian: byteOrder) {
            tags["AircraftModel"] = .string(value)
        }

        // Speed X/Y/Z (tags 0x0003-0x0005) — Float32
        if let entry = ifd.entry(for: speedX),
           let value = entry.floatValue(endian: byteOrder) {
            tags["SpeedX"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: speedY),
           let value = entry.floatValue(endian: byteOrder) {
            tags["SpeedY"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: speedZ),
           let value = entry.floatValue(endian: byteOrder) {
            tags["SpeedZ"] = .double(Double(value))
        }

        // Pitch/Yaw/Roll (tags 0x0006-0x0008) — Float32
        if let entry = ifd.entry(for: pitch),
           let value = entry.floatValue(endian: byteOrder) {
            tags["Pitch"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: yaw),
           let value = entry.floatValue(endian: byteOrder) {
            tags["Yaw"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: roll),
           let value = entry.floatValue(endian: byteOrder) {
            tags["Roll"] = .double(Double(value))
        }

        // Camera Pitch/Yaw/Roll (tags 0x0009-0x000b) — Float32
        if let entry = ifd.entry(for: cameraPitch),
           let value = entry.floatValue(endian: byteOrder) {
            tags["CameraPitch"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: cameraYaw),
           let value = entry.floatValue(endian: byteOrder) {
            tags["CameraYaw"] = .double(Double(value))
        }
        if let entry = ifd.entry(for: cameraRoll),
           let value = entry.floatValue(endian: byteOrder) {
            tags["CameraRoll"] = .double(Double(value))
        }

        return tags
    }
}
