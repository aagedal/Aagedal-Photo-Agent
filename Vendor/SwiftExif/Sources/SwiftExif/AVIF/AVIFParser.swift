import Foundation

/// Parse AVIF files for metadata.
public struct AVIFParser: Sendable {

    /// Parse an AVIF file from raw data.
    public static func parse(_ data: Data) throws -> AVIFFile {
        guard data.count >= 12 else {
            throw MetadataError.invalidAVIF("File too small")
        }

        // Parse the ftyp box to verify this is AVIF
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: data)
        guard let ftypBox = boxes.first(where: { $0.type == "ftyp" }) else {
            throw MetadataError.invalidAVIF("Missing ftyp box")
        }

        // Extract major brand (first 4 bytes of ftyp payload)
        guard ftypBox.data.count >= 4 else {
            throw MetadataError.invalidAVIF("Invalid ftyp box")
        }
        let brand = String(data: ftypBox.data.prefix(4), encoding: .ascii) ?? "????"

        return AVIFFile(boxes: boxes, brand: brand)
    }

    /// Extract Exif data, preferring a conformant `iloc`-located `Exif` item
    /// (requires `fileData`) and falling back to a top-level/`ipco` `Exif` box.
    public static func extractExif(from avifFile: AVIFFile, fileData: Data? = nil) throws -> ExifData? {
        try ISOBMFFMetadata.extractExif(from: avifFile.boxes, fileData: fileData)
    }

    /// Extract XMP data, preferring a conformant `iloc`-located `mime` item
    /// (requires `fileData`) and falling back to an `ipco` `mime` property.
    public static func extractXMP(from avifFile: AVIFFile, fileData: Data? = nil) throws -> XMPData? {
        try ISOBMFFMetadata.extractXMP(from: avifFile.boxes, fileData: fileData)
    }
}
