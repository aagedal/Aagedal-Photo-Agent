import Foundation

/// Reconstructs a HEIF/HEIC file from parsed components.
public struct HEIFWriter: Sendable {

    /// Reconstruct a HEIF file from its boxes, with updated metadata.
    public static func write(_ file: HEIFFile, exif: ExifData?, xmp: XMPData?) throws -> Data {
        var updatedBoxes = file.boxes
        try ISOBMFFMetadata.updateMetadata(in: &updatedBoxes, exif: exif, xmp: xmp)
        return ISOBMFFBoxWriter.serialize(boxes: updatedBoxes)
    }
}
