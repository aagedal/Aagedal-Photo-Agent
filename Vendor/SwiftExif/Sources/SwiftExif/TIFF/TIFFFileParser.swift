import Foundation

/// Parse standalone TIFF files (and TIFF-based RAW formats) for metadata.
public struct TIFFFileParser: Sendable {

    /// Parse a TIFF file from raw data.
    public static func parse(_ data: Data) throws -> TIFFFile {
        var reader = BinaryReader(data: data)
        let header = try TIFFHeader.parse(from: &reader)
        let endian = header.byteOrder

        var ifds: [IFD] = []
        var nextOffset = header.ifdOffset

        // Walk the IFD chain (limit to 64 IFDs to prevent pathological files)
        let maxIFDs = 64
        while nextOffset > 0 && ifds.count < maxIFDs {
            let absoluteOffset = Int(nextOffset)
            guard absoluteOffset + 2 <= data.count else { break }

            let (ifd, next) = try IFDParser.parseIFD(data: data, tiffStart: 0, offset: absoluteOffset, endian: endian)
            ifds.append(ifd)
            nextOffset = next

            // Safety: prevent infinite loops
            if Int(nextOffset) <= absoluteOffset { break }
        }

        return TIFFFile(rawData: data, header: header, ifds: ifds)
    }

    /// Build ExifData from parsed TIFF IFDs.
    public static func extractExif(from tiffFile: TIFFFile, data: Data) throws -> ExifData? {
        guard let ifd0 = tiffFile.ifd0 else { return nil }
        let endian = tiffFile.header.byteOrder

        var exifData = ExifData(byteOrder: endian)
        exifData.ifd0 = ifd0

        // IFD1 (thumbnail)
        if tiffFile.ifds.count > 1 {
            exifData.ifd1 = tiffFile.ifds[1]
        }

        // Exif sub-IFD
        if let exifPointer = ifd0.entry(for: ExifTag.exifIFDPointer),
           let exifOffset = exifPointer.uint32Value(endian: endian) {
            let (exifIFD, _) = try IFDParser.parseIFD(data: data, tiffStart: 0, offset: Int(exifOffset), endian: endian)
            exifData.exifIFD = exifIFD
        }

        // GPS sub-IFD
        if let gpsPointer = ifd0.entry(for: ExifTag.gpsIFDPointer),
           let gpsOffset = gpsPointer.uint32Value(endian: endian) {
            let (gpsIFD, _) = try IFDParser.parseIFD(data: data, tiffStart: 0, offset: Int(gpsOffset), endian: endian)
            exifData.gpsIFD = gpsIFD
        }

        // MakerNote from the Exif sub-IFD. Mirrors ExifReader's JPEG path; without
        // this, TIFF-based RAW formats (ARW, NEF, ORF, CR2, …) silently drop their
        // manufacturer MakerNote. Value offsets here are TIFF-relative (tiffStart 0).
        if let exifIFD = exifData.exifIFD {
            exifData.makerNote = MakerNoteReader.parse(
                from: exifIFD,
                make: exifData.make,
                byteOrder: endian
            )
        }

        return exifData
    }

    /// Extract IPTC metadata from TIFF IFD tags.
    public static func extractIPTC(from tiffFile: TIFFFile) throws -> IPTCData {
        guard let ifd0 = tiffFile.ifd0 else { return IPTCData() }

        // Try Photoshop IRB (tag 0x8649) first — most common in TIFF
        if let irbEntry = ifd0.entry(for: ExifTag.photoshopIRB) {
            if let iptcData = try PhotoshopIRB.extractIPTCData(irbEntry.valueData) {
                return try IPTCReader.read(from: iptcData)
            }
        }

        // Fallback: raw IPTC-NAA (tag 0x83BB)
        if let iptcEntry = ifd0.entry(for: ExifTag.iptcNAA) {
            return try IPTCReader.read(from: iptcEntry.valueData)
        }

        return IPTCData()
    }

    /// Extract XMP metadata from TIFF IFD tag 0x02BC.
    public static func extractXMP(from tiffFile: TIFFFile) throws -> XMPData? {
        guard let ifd0 = tiffFile.ifd0,
              let xmpEntry = ifd0.entry(for: ExifTag.xmpTag) else { return nil }
        return try XMPReader.readFromXML(xmpEntry.valueData)
    }

    /// Extract ICC profile from TIFF IFD tag 0x8773.
    public static func extractICCProfile(from tiffFile: TIFFFile) -> ICCProfile? {
        guard let ifd0 = tiffFile.ifd0,
              let iccEntry = ifd0.entry(for: ExifTag.iccProfile) else { return nil }
        return ICCProfile(data: iccEntry.valueData)
    }
}
