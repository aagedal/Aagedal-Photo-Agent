import Foundation

/// Parse BMP file headers for metadata extraction.
/// BMP is a simple format: 14-byte file header + DIB header (variable size).
public struct BMPParser: Sendable {

    /// BMP file header signature: "BM" (0x42, 0x4D).
    static let signature: [UInt8] = [0x42, 0x4D]

    /// Parse a BMP file from raw data. Extracts header info only (read-only).
    public static func parse(_ data: Data) throws -> BMPFile {
        guard data.count >= 26 else {
            throw MetadataError.invalidBMP("File too small for BMP header")
        }

        // Validate BMP signature
        guard data[0] == 0x42 && data[1] == 0x4D else {
            throw MetadataError.invalidBMP("Invalid BMP signature")
        }

        // BMP File Header (14 bytes)
        let fileSize = readUInt32LE(data, offset: 2)
        // bytes 6-9: reserved
        // bytes 10-13: pixel data offset

        // DIB Header
        let dibHeaderSize = readUInt32LE(data, offset: 14)

        // Handle different DIB header versions
        if dibHeaderSize == 12 {
            // OS/2 BITMAPCOREHEADER (12 bytes)
            guard data.count >= 26 else {
                throw MetadataError.invalidBMP("DIB header truncated")
            }
            let width = Int32(readUInt16LE(data, offset: 18))
            let height = Int32(readUInt16LE(data, offset: 20))
            let planes = readUInt16LE(data, offset: 22)
            let bpp = readUInt16LE(data, offset: 24)

            return BMPFile(
                rawData: data, width: width, height: height,
                bitsPerPixel: bpp, compression: 0,
                fileSize: fileSize, dibHeaderSize: dibHeaderSize, colorPlanes: planes
            )
        }

        // BITMAPINFOHEADER (40 bytes) and larger variants
        guard data.count >= 54 else {
            throw MetadataError.invalidBMP("DIB header truncated")
        }

        let width = readInt32LE(data, offset: 18)
        let height = readInt32LE(data, offset: 22)
        let planes = readUInt16LE(data, offset: 26)
        let bpp = readUInt16LE(data, offset: 28)
        let compression = readUInt32LE(data, offset: 30)
        let imageSize = readUInt32LE(data, offset: 34)
        let xPPM = readInt32LE(data, offset: 38)
        let yPPM = readInt32LE(data, offset: 42)
        let colorsUsed = readUInt32LE(data, offset: 46)
        let colorsImportant = readUInt32LE(data, offset: 50)

        return BMPFile(
            rawData: data, width: width, height: height,
            bitsPerPixel: bpp, compression: compression,
            imageSize: imageSize, xPixelsPerMeter: xPPM, yPixelsPerMeter: yPPM,
            colorsUsed: colorsUsed, colorsImportant: colorsImportant,
            fileSize: fileSize, dibHeaderSize: dibHeaderSize, colorPlanes: planes
        )
    }

    // MARK: - Little-Endian Readers

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readInt32LE(_ data: Data, offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(data, offset: offset))
    }
}
