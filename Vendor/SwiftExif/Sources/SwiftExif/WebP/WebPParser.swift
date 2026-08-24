import Foundation

/// Parse WebP files stored in the RIFF container format.
///
/// WebP RIFF structure:
/// ```
/// "RIFF" <file-size-minus-8> "WEBP"
///   chunk1: <FourCC> <size:LE-u32> <payload> [padding]
///   chunk2: ...
/// ```
///
/// Metadata chunks:
/// - "EXIF" — Exif data (raw TIFF bytes)
/// - "XMP " — XMP data (UTF-8 XML)
/// - "ICCP" — ICC color profile
/// - "VP8X" — Extended format header with feature flags
public struct WebPParser: Sendable {

    /// Parse a WebP file from raw data.
    public static func parse(_ data: Data) throws -> WebPFile {
        guard data.count >= 12 else {
            throw MetadataError.invalidWebP("File too small")
        }

        // Verify RIFF header
        let riff = String(data: data[data.startIndex ..< data.startIndex + 4], encoding: .ascii)
        guard riff == "RIFF" else {
            throw MetadataError.invalidWebP("Missing RIFF header")
        }

        // Verify WEBP signature at offset 8
        let webp = String(data: data[data.startIndex + 8 ..< data.startIndex + 12], encoding: .ascii)
        guard webp == "WEBP" else {
            throw MetadataError.invalidWebP("Missing WEBP signature")
        }

        // Parse chunks starting at offset 12 (after "RIFF" + size + "WEBP")
        var chunks: [WebPChunk] = []
        var offset = data.startIndex + 12

        while offset + 8 <= data.endIndex {
            // FourCC (4 bytes)
            let fourCC = String(data: data[offset ..< offset + 4], encoding: .ascii) ?? "????"

            // Chunk size (4 bytes, little-endian)
            let size = Int(data[offset + 4])
                | (Int(data[offset + 5]) << 8)
                | (Int(data[offset + 6]) << 16)
                | (Int(data[offset + 7]) << 24)

            let payloadStart = offset + 8
            let payloadEnd = min(payloadStart + size, data.endIndex)

            guard payloadStart <= data.endIndex else { break }

            let payload = data[payloadStart ..< payloadEnd]
            chunks.append(WebPChunk(fourCC: fourCC, data: Data(payload)))

            // Advance past payload + optional padding byte (chunks are 2-byte aligned)
            let paddedSize = size + (size & 1)
            offset = payloadStart + paddedSize
        }

        return WebPFile(chunks: chunks)
    }

    /// Extract Exif data from a WebP file's EXIF chunk.
    public static func extractExif(from file: WebPFile) throws -> ExifData? {
        guard let chunk = file.findChunk("EXIF") else { return nil }
        guard !chunk.data.isEmpty else { return nil }
        return try ExifReader.readFromTIFF(data: chunk.data)
    }

    /// Extract XMP data from a WebP file's XMP chunk.
    public static func extractXMP(from file: WebPFile) throws -> XMPData? {
        guard let chunk = file.findChunk("XMP ") else { return nil }
        guard !chunk.data.isEmpty else { return nil }
        return try XMPReader.readFromXML(chunk.data)
    }

    /// Extract ICC profile from a WebP file's ICCP chunk.
    public static func extractICCProfile(from file: WebPFile) -> ICCProfile? {
        guard let chunk = file.findChunk("ICCP") else { return nil }
        guard chunk.data.count >= 128 else { return nil }
        return ICCProfile(data: chunk.data)
    }
}
