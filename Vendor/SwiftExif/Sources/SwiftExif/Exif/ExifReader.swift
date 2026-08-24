import Foundation

/// Parse Exif data from an APP1 segment or raw TIFF data.
public struct ExifReader: Sendable {

    /// Parse Exif data from APP1 segment payload (including "Exif\0\0" identifier).
    public static func read(from data: Data) throws -> ExifData {
        var reader = BinaryReader(data: data)

        // Skip Exif identifier: "Exif\0\0" (6 bytes)
        try reader.expect([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

        return try parseFromTIFFStart(data: data, tiffStart: reader.offset)
    }

    /// Parse Exif data from raw TIFF data (no "Exif\0\0" prefix).
    /// Used for standalone TIFF files, RAW files, PNG eXIf chunks.
    public static func readFromTIFF(data: Data) throws -> ExifData {
        return try parseFromTIFFStart(data: data, tiffStart: 0)
    }

    /// Parse Exif data from an ISOBMFF Exif box payload.
    /// The box contains a 4-byte big-endian offset prefix followed by TIFF data.
    /// Used by AVIF Exif properties and JPEG XL Exif boxes.
    public static func readFromExifBox(data: Data) throws -> ExifData? {
        guard data.count > 4 else { return nil }

        var reader = BinaryReader(data: data)
        let offset = try reader.readUInt32BigEndian()

        if offset > 0 {
            try reader.skip(Int(offset))
        }

        let tiffData = Data(data.suffix(from: data.startIndex + reader.offset))
        guard !tiffData.isEmpty else { return nil }

        return try readFromTIFF(data: tiffData)
    }

    // MARK: - Private

    private static func parseFromTIFFStart(data: Data, tiffStart: Int) throws -> ExifData {
        var reader = BinaryReader(data: data)
        try reader.seek(to: tiffStart)

        // Parse TIFF header
        let header = try TIFFHeader.parse(from: &reader)
        let endian = header.byteOrder

        var exifData = ExifData(byteOrder: endian)

        // Parse IFD0
        try reader.seek(to: tiffStart + Int(header.ifdOffset))
        let (ifd0, nextOffset) = try IFDParser.parseIFD(data: data, tiffStart: tiffStart, offset: reader.offset, endian: endian)
        exifData.ifd0 = ifd0

        // Check for Exif sub-IFD
        if let exifPointer = ifd0.entry(for: ExifTag.exifIFDPointer),
           let exifOffset = exifPointer.uint32Value(endian: endian) {
            let (exifIFD, _) = try IFDParser.parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(exifOffset), endian: endian)
            exifData.exifIFD = exifIFD
        }

        // Check for GPS sub-IFD
        if let gpsPointer = ifd0.entry(for: ExifTag.gpsIFDPointer),
           let gpsOffset = gpsPointer.uint32Value(endian: endian) {
            let (gpsIFD, _) = try IFDParser.parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(gpsOffset), endian: endian)
            exifData.gpsIFD = gpsIFD
        }

        // Check for IFD1 (thumbnail)
        if nextOffset > 0 {
            let (ifd1, _) = try IFDParser.parseIFD(data: data, tiffStart: tiffStart, offset: tiffStart + Int(nextOffset), endian: endian)
            exifData.ifd1 = ifd1
        }

        // Parse MakerNote from Exif sub-IFD
        if let exifIFD = exifData.exifIFD {
            exifData.makerNote = MakerNoteReader.parse(
                from: exifIFD,
                make: exifData.make,
                byteOrder: endian
            )
        }

        return exifData
    }
}
