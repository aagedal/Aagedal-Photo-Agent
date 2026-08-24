import Foundation

/// Parse PNG files for metadata.
public struct PNGParser: Sendable {

    /// PNG file signature (8 bytes).
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Parse a PNG file from raw data.
    public static func parse(_ data: Data) throws -> PNGFile {
        var reader = BinaryReader(data: data)

        // Validate signature
        guard data.count >= 8 else {
            throw MetadataError.invalidPNG("File too small")
        }
        let sig = try reader.readBytes(8)
        guard [UInt8](sig) == signature else {
            throw MetadataError.invalidPNG("Invalid PNG signature")
        }

        var chunks: [PNGChunk] = []

        while !reader.isAtEnd {
            // Each chunk: 4-byte length + 4-byte type + data + 4-byte CRC
            guard reader.remainingCount >= 12 else { break }

            let length = try reader.readUInt32BigEndian()
            let typeData = try reader.readBytes(4)
            guard let type = String(data: typeData, encoding: .ascii) else {
                throw MetadataError.invalidPNG("Invalid chunk type")
            }

            let chunkData: Data
            if length > 0 {
                guard reader.remainingCount >= 4, Int(length) <= reader.remainingCount - 4 else {
                    throw MetadataError.invalidPNG("Chunk length exceeds available data")
                }
                chunkData = try reader.readBytes(Int(length))
            } else {
                chunkData = Data()
            }

            let storedCRC = try reader.readUInt32BigEndian()

            // Validate CRC32 (over type + data)
            let computedCRC = CRC32.compute(type: type, data: chunkData)
            guard computedCRC == storedCRC else {
                throw MetadataError.crcMismatch(expected: storedCRC, actual: computedCRC)
            }

            chunks.append(PNGChunk(type: type, data: chunkData, crc: storedCRC))

            // Stop after IEND
            if type == "IEND" { break }
        }

        return PNGFile(chunks: chunks)
    }

    /// Extract XMP from the first iTXt chunk with keyword "XML:com.adobe.xmp".
    public static func extractXMP(from pngFile: PNGFile) throws -> XMPData? {
        for chunk in pngFile.findChunks("iTXt") {
            if let xmpData = try parseITXtForXMP(chunk.data) {
                return xmpData
            }
        }
        return nil
    }

    // MARK: - Private

    /// Parse an iTXt chunk looking for XMP content.
    /// iTXt structure: keyword\0 + compression_flag(1) + compression_method(1) + language_tag\0 + translated_keyword\0 + text
    private static func parseITXtForXMP(_ data: Data) throws -> XMPData? {
        let bytes = [UInt8](data)

        // Find keyword null terminator
        guard let keywordEnd = bytes.firstIndex(of: 0) else { return nil }
        let keyword = String(bytes: bytes[0..<keywordEnd], encoding: .utf8)
        guard keyword == "XML:com.adobe.xmp" else { return nil }

        var offset = keywordEnd + 1 // past null

        // Compression flag and method
        guard offset + 2 <= bytes.count else { return nil }
        let compressionFlag = bytes[offset]
        // let compressionMethod = bytes[offset + 1]
        offset += 2

        // Language tag (null terminated)
        guard let langEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = langEnd + 1

        // Translated keyword (null terminated)
        guard let transEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = transEnd + 1

        // Text data
        let textData = Data(bytes[offset...])

        if compressionFlag == 0 {
            // Uncompressed
            return try XMPReader.readFromXML(textData)
        } else {
            // Compressed (deflate) — use zlib
            guard let decompressed = decompress(textData) else {
                throw MetadataError.invalidPNG("Failed to decompress iTXt XMP data")
            }
            return try XMPReader.readFromXML(decompressed)
        }
    }

    private static func decompress(_ data: Data) -> Data? {
        ZlibInflate.inflate(data)
    }
}
