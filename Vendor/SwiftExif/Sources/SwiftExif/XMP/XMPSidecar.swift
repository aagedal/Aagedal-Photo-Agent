import Foundation

/// Read and write XMP sidecar files (.xmp).
///
/// XMP sidecar files are standalone XML files that store metadata alongside
/// image files. They are commonly used with RAW formats where writing metadata
/// directly into the image file is undesirable.
public struct XMPSidecar: Sendable {

    /// Read XMP data from a sidecar file.
    public static func read(from url: URL) throws -> XMPData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        return try XMPReader.readFromXML(data)
    }

    /// Write XMP data to a sidecar file.
    public static func write(_ xmpData: XMPData, to url: URL) throws {
        let xml = XMPWriter.generateXML(xmpData)
        guard let data = xml.data(using: .utf8) else {
            throw MetadataError.encodingError("Failed to encode XMP XML as UTF-8")
        }
        try data.write(to: url)
    }

    /// Derive the sidecar file URL for a given image URL.
    /// Replaces the file extension with `.xmp`.
    public static func sidecarURL(for imageURL: URL) -> URL {
        imageURL.deletingPathExtension().appendingPathExtension("xmp")
    }
}
