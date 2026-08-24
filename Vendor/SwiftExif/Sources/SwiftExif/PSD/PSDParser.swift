import Foundation

/// Parse PSD/PSB files to extract metadata from image resources.
public struct PSDParser: Sendable {

    /// PSD magic bytes: "8BPS"
    static let magic: [UInt8] = [0x38, 0x42, 0x50, 0x53]

    /// Parse a PSD file and extract metadata-relevant structures.
    public static func parse(_ data: Data) throws -> PSDFile {
        var reader = BinaryReader(data: data)

        // Verify "8BPS" magic
        guard data.count >= 26 else {
            throw MetadataError.invalidPSD("File too small")
        }
        let sig = try reader.readBytes(4)
        guard sig == Data(magic) else {
            throw MetadataError.invalidPSD("Missing 8BPS signature")
        }

        let version = try reader.readUInt16BigEndian()
        guard version == 1 || version == 2 else {
            throw MetadataError.invalidPSD("Unsupported version \(version)")
        }

        try reader.skip(6) // Reserved bytes

        let channels = try reader.readUInt16BigEndian()
        let height = try reader.readUInt32BigEndian()
        let width = try reader.readUInt32BigEndian()
        let depth = try reader.readUInt16BigEndian()
        let colorMode = try reader.readUInt16BigEndian()
        // Header is 26 bytes total

        // Color mode data section
        let colorModeStart = reader.offset
        let colorModeLength = Int(try reader.readUInt32BigEndian())
        try reader.skip(colorModeLength)
        let colorModeEnd = reader.offset

        // Image resources section
        let imageResourcesStart = reader.offset
        let imageResourcesLength = Int(try reader.readUInt32BigEndian())
        let imageResourcesDataStart = reader.offset
        let imageResourcesData: Data
        if imageResourcesLength > 0 && imageResourcesDataStart + imageResourcesLength <= data.count {
            imageResourcesData = Data(data[data.startIndex + imageResourcesDataStart ..< data.startIndex + imageResourcesDataStart + imageResourcesLength])
            try reader.skip(imageResourcesLength)
        } else {
            imageResourcesData = Data()
            try reader.skip(imageResourcesLength)
        }
        let imageResourcesEnd = reader.offset

        // Layer and mask data section
        let layerMaskStart = reader.offset
        let layerMaskLength: Int
        if version == 2 {
            // PSB uses 8-byte length for layer/mask section. Clamp to Int.max —
            // Int(UInt64) traps on overflow, and a malformed PSB could specify
            // a length > 2^63-1.
            let hi = try reader.readUInt32BigEndian()
            let lo = try reader.readUInt32BigEndian()
            let fullLength = UInt64(hi) << 32 | UInt64(lo)
            layerMaskLength = fullLength > UInt64(Int.max) ? Int.max : Int(fullLength)
        } else {
            layerMaskLength = Int(try reader.readUInt32BigEndian())
        }
        try reader.skip(min(layerMaskLength, reader.remainingCount))
        let layerMaskEnd = reader.offset

        // Image data starts here
        let imageDataOffset = reader.offset

        // Parse IRB blocks from image resources
        let irbBlocks: [IRBBlock]
        if !imageResourcesData.isEmpty {
            irbBlocks = (try? PhotoshopIRB.parseRaw(imageResourcesData)) ?? []
        } else {
            irbBlocks = []
        }

        return PSDFile(
            version: version,
            channels: channels,
            height: height,
            width: width,
            depth: depth,
            colorMode: colorMode,
            rawData: data,
            colorModeDataRange: colorModeStart..<colorModeEnd,
            imageResourcesRange: imageResourcesStart..<imageResourcesEnd,
            layerMaskDataRange: layerMaskStart..<layerMaskEnd,
            imageDataOffset: imageDataOffset,
            irbBlocks: irbBlocks
        )
    }

    /// Extract EXIF data from PSD IRB blocks.
    public static func extractExif(from file: PSDFile) -> ExifData? {
        guard let block = file.irbBlocks.first(where: { $0.resourceID == PSDFile.exifResourceID }),
              !block.data.isEmpty else { return nil }
        return try? ExifReader.readFromTIFF(data: block.data)
    }

    /// Extract XMP data from PSD IRB blocks.
    public static func extractXMP(from file: PSDFile) throws -> XMPData? {
        guard let block = file.irbBlocks.first(where: { $0.resourceID == PSDFile.xmpResourceID }),
              !block.data.isEmpty else { return nil }
        return try XMPReader.readFromXML(block.data)
    }

    /// Extract ICC profile from PSD IRB blocks.
    public static func extractICCProfile(from file: PSDFile) -> ICCProfile? {
        guard let block = file.irbBlocks.first(where: { $0.resourceID == PSDFile.iccProfileResourceID }),
              !block.data.isEmpty else { return nil }
        return ICCProfile(data: block.data)
    }
}
