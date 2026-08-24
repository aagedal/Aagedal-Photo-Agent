import Foundation

/// Parse HEIF/HEIC files for metadata.
public struct HEIFParser: Sendable {

    /// Parse a HEIF/HEIC file from raw data.
    public static func parse(_ data: Data) throws -> HEIFFile {
        guard data.count >= 12 else {
            throw MetadataError.invalidHEIF("File too small")
        }

        let boxes = try ISOBMFFBoxReader.parseBoxes(from: data)
        guard let ftypBox = boxes.first(where: { $0.type == "ftyp" }) else {
            throw MetadataError.invalidHEIF("Missing ftyp box")
        }

        guard ftypBox.data.count >= 4 else {
            throw MetadataError.invalidHEIF("Invalid ftyp box")
        }
        let brand = String(data: ftypBox.data.prefix(4), encoding: .ascii) ?? "????"

        return HEIFFile(boxes: boxes, brand: brand)
    }

    /// Extract Exif data from HEIF boxes.
    /// Pass the original file data for iloc item-based extraction (used by real HEIC files).
    public static func extractExif(from heifFile: HEIFFile, fileData: Data? = nil) throws -> ExifData? {
        try ISOBMFFMetadata.extractExif(from: heifFile.boxes, fileData: fileData)
    }

    /// Extract XMP data from HEIF boxes.
    public static func extractXMP(from heifFile: HEIFFile, fileData: Data? = nil) throws -> XMPData? {
        try ISOBMFFMetadata.extractXMP(from: heifFile.boxes, fileData: fileData)
    }
}
