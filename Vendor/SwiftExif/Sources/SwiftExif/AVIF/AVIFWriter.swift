import Foundation

/// Reconstructs an AVIF file from parsed components.
public struct AVIFWriter: Sendable {

    /// Reconstruct an AVIF file from its boxes, with updated metadata.
    public static func write(_ file: AVIFFile, exif: ExifData?, xmp: XMPData?) throws -> Data {
        var updatedBoxes = file.boxes
        try ISOBMFFMetadata.updateMetadata(in: &updatedBoxes, exif: exif, xmp: xmp)
        return ISOBMFFBoxWriter.serialize(boxes: updatedBoxes)
    }
}
