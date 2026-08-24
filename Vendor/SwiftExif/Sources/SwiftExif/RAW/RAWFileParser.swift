import Foundation

/// Parse TIFF-based RAW camera files for metadata.
/// Most RAW formats use TIFF IFD structure; this parser validates format-specific
/// magic bytes and delegates to TIFFFileParser. RAF uses a custom header with
/// an embedded TIFF/Exif block.
public struct RAWFileParser: Sendable {

    /// Validate that data looks like a specific RAW format.
    /// Returns the detected RAW format, or nil if not recognized.
    public static func detectRAWFormat(_ data: Data) -> ImageFormat.RawFormat? {
        guard data.count >= 12 else { return nil }

        let bytes = [UInt8](data.prefix(12))

        // RAF: "FUJIFILMCCD-RAW" at offset 0
        if data.count >= 16,
           let prefix = String(data: data.prefix(15), encoding: .ascii),
           prefix == "FUJIFILMCCD-RAW" {
            return .raf
        }

        // RW2: TIFF-like with version 0x0055 instead of 0x002A
        let isRW2LE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x55 && bytes[3] == 0x00
        if isRW2LE {
            return .rw2
        }

        // Must have TIFF magic for remaining formats
        let isLE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00
        let isBE = bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A
        guard isLE || isBE else { return nil }

        // CR2: "CR" at offset 8-9
        if bytes[8] == 0x43 && bytes[9] == 0x52 {
            return .cr2
        }

        // DNG: scan IFD0 for DNGVersion tag (0xC612)
        if hasDNGVersionTag(data) {
            return .dng
        }

        // ORF/PEF/NEF/ARW detection requires MakerNote analysis — use extension-based detection
        return nil
    }

    /// Parse a RAW file. Delegates to TIFFFileParser since most supported RAW
    /// formats use TIFF IFD structure.
    public static func parse(_ data: Data, format: ImageFormat.RawFormat) throws -> TIFFFile {
        switch format {
        case .raf:
            return try parseRAF(data)
        case .rw2:
            return try parseRW2(data)
        case .cr3:
            // CR3 is ISOBMFF-based, not TIFF — should not reach here
            throw MetadataError.invalidRAW("CR3 files should not be parsed as TIFF")
        case .cr2:
            let tiff = try TIFFFileParser.parse(data)
            // CR2 should have "CR" signature at offset 8
            if data.count >= 10 {
                let bytes = [UInt8](data.prefix(10))
                guard bytes[8] == 0x43 && bytes[9] == 0x52 else {
                    throw MetadataError.invalidRAW("Missing CR2 signature")
                }
            }
            return tiff
        case .iiq:
            return try parseIIQ(data)
        case .threefr, .fff:
            // Hasselblad 3FR / FFF — TIFF-based, custom MakerNote tags. Parse
            // as plain TIFF; vendor-specific MakerNote IFD is parsed lazily.
            return try TIFFFileParser.parse(data)
        case .x3f:
            return try parseX3F(data)
        case .mrw:
            return try parseMRW(data)
        case .dng, .gpr, .nef, .nrw, .arw, .orf, .pef, .srw, .raw:
            // These all parse identically to TIFF.
            // GPR (GoPro) is DNG-structured. NRW (Nikon Coolpix) and SRW (Samsung)
            // are TIFF/IFD-based variants. The generic `.raw` case is a best-effort
            // TIFF parse for vendor-neutral extensions.
            return try TIFFFileParser.parse(data)
        }
    }

    // MARK: - IIQ (Phase One)

    /// Parse Phase One IIQ. Two on-disk variants exist:
    ///   1. Older IIQ files carry a TIFF magic header — they parse fine via TIFFFileParser.
    ///   2. Newer (≥ 2014) IIQ files prefix the data with a custom 8-byte
    ///      "IIIIIIII" magic + 8-byte structure pointer. The TIFF data starts
    ///      at the offset pointed to by bytes 8..11 (little-endian uint32).
    /// We auto-detect the variant and slice into the embedded TIFF block.
    private static func parseIIQ(_ data: Data) throws -> TIFFFile {
        guard data.count >= 16 else {
            throw MetadataError.invalidRAW("IIQ file too small")
        }
        // Variant 1 — already-TIFF? Walk straight in.
        let bytes = [UInt8](data.prefix(4))
        let isLE = bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00
        let isBE = bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A
        if isLE || isBE {
            return try TIFFFileParser.parse(data)
        }
        // Variant 2 — IIIIIIII magic. The IFD pointer at bytes 8..11 is little-endian.
        let allI = data.prefix(8).allSatisfy { $0 == 0x49 }
        guard allI else {
            throw MetadataError.invalidRAW("Missing IIQ magic")
        }
        let s = data.startIndex
        let tiffOffset = Int(data[s + 8])
            | (Int(data[s + 9]) << 8)
            | (Int(data[s + 10]) << 16)
            | (Int(data[s + 11]) << 24)
        guard tiffOffset > 0, tiffOffset + 8 <= data.count else {
            throw MetadataError.invalidRAW("IIQ TIFF offset out of bounds (\(tiffOffset))")
        }
        let tiffData = Data(data[s + tiffOffset ..< data.endIndex])
        return try TIFFFileParser.parse(tiffData)
    }

    // MARK: - X3F (Sigma)

    /// Parse Sigma X3F. The format is fully proprietary — no TIFF anywhere.
    /// We synthesize a minimal TIFFFile shell so the rest of the pipeline
    /// (which expects `TIFFFile`) doesn't need an X3F-specific branch. Rich
    /// X3F metadata extraction is deferred; downstream consumers can read the
    /// raw data via `tiffFile.rawData` and decode the embedded property list
    /// ('PROP' section) themselves if needed.
    /// X3F header (40 bytes):
    ///   0..3   "FOVb" magic
    ///   4..7   format version (uint32 LE)
    ///   8..23  unique ID (16 bytes)
    ///   24..27 mark/flag bits
    ///   28..31 image rotation (uint32 LE)
    ///   32..63 white balance label (ASCII)
    private static func parseX3F(_ data: Data) throws -> TIFFFile {
        guard data.count >= 64 else {
            throw MetadataError.invalidRAW("X3F file too small")
        }
        let s = data.startIndex
        guard data[s] == 0x46, data[s + 1] == 0x4F, data[s + 2] == 0x56, data[s + 3] == 0x62 else {
            throw MetadataError.invalidRAW("Missing X3F FOVb magic")
        }
        // Synthesize a placeholder TIFF header. The downstream `extractExif`
        // call sees an empty IFD0 and no Exif sub-IFD, which is exactly what
        // we want for X3F today — extension by future work can populate
        // ImageMetadata fields from the X3F directory directly.
        let header = TIFFHeader(byteOrder: .littleEndian, ifdOffset: 0)
        return TIFFFile(rawData: data, header: header, ifds: [])
    }

    // MARK: - MRW (Minolta)

    /// Parse Minolta MRW. Layout:
    ///   0      0x00
    ///   1..3   "MRM" (Maxxum/Dynax) or "MRI" (older DiMAGE)
    ///   4..7   total length of MRW header blocks (big-endian uint32)
    ///   8..    MRW blocks (PRD, TTW, WBG, RIF), then raw image data
    /// The TTW block contains the embedded TIFF/Exif IFD; its body starts
    /// with the standard "II*\0" or "MM\0*" TIFF magic.
    private static func parseMRW(_ data: Data) throws -> TIFFFile {
        guard data.count >= 8 else {
            throw MetadataError.invalidRAW("MRW file too small")
        }
        let s = data.startIndex
        guard data[s] == 0x00, data[s + 1] == 0x4D, data[s + 2] == 0x52,
              data[s + 3] == 0x4D || data[s + 3] == 0x49 else {
            throw MetadataError.invalidRAW("Missing MRW magic")
        }
        // headerLen is the number of bytes after offset 8 belonging to the
        // MRW headers (PRD/TTW/WBG/RIF). Walk MRW blocks looking for "TTW\0"
        // which carries the embedded TIFF.
        let headerLen = Int(data[s + 4]) << 24
            | Int(data[s + 5]) << 16
            | Int(data[s + 6]) << 8
            | Int(data[s + 7])
        let headerEnd = min(8 + headerLen, data.count)
        var off = 8
        while off + 8 <= headerEnd {
            // Each MRW block: 4-byte tag + 4-byte length (big-endian).
            let tag = data[s + off ..< s + off + 4]
            let blockLen = Int(data[s + off + 4]) << 24
                | Int(data[s + off + 5]) << 16
                | Int(data[s + off + 6]) << 8
                | Int(data[s + off + 7])
            let bodyStart = off + 8
            let bodyEnd = min(bodyStart + blockLen, headerEnd)
            // TTW block (ASCII "TTW\0" or " TTW") carries the embedded TIFF.
            // Some MRW writers leave a leading 0x00; accept either ordering.
            let isTTW = (tag.count == 4 && tag.contains(0x54) && tag.contains(0x57))
            if isTTW, bodyEnd > bodyStart {
                let inner = Data(data[s + bodyStart ..< s + bodyEnd])
                if inner.count >= 4 {
                    let ib = [UInt8](inner.prefix(4))
                    let isLE = ib[0] == 0x49 && ib[1] == 0x49 && ib[2] == 0x2A && ib[3] == 0x00
                    let isBE = ib[0] == 0x4D && ib[1] == 0x4D && ib[2] == 0x00 && ib[3] == 0x2A
                    if isLE || isBE {
                        return try TIFFFileParser.parse(inner)
                    }
                }
            }
            off = bodyEnd
        }
        throw MetadataError.invalidRAW("MRW TTW block (TIFF/Exif IFD) not found")
    }

    // MARK: - RAF (Fujifilm)

    /// Parse Fujifilm RAF file. The RAF container has a proprietary header followed by
    /// an embedded JPEG preview and a TIFF/Exif metadata block.
    /// Header layout:
    ///   0-15: "FUJIFILMCCD-RAW " magic
    ///  16-19: format version
    ///  20-27: camera model ID
    ///  28-31: camera model string (padded)
    ///  84-87: JPEG offset (big-endian UInt32)
    ///  88-91: JPEG length (big-endian UInt32)
    /// 92-95: CFA header offset (or metadata offset)
    /// 96-99: CFA header length
    /// 100-103: CFA offset
    /// 104-107: CFA length
    private static func parseRAF(_ data: Data) throws -> TIFFFile {
        guard data.count >= 108 else {
            throw MetadataError.invalidRAW("RAF file too small")
        }

        // Verify magic
        guard let magic = String(data: data.prefix(15), encoding: .ascii),
              magic == "FUJIFILMCCD-RAW" else {
            throw MetadataError.invalidRAW("Missing FUJIFILMCCD-RAW magic")
        }

        // Read JPEG offset and length from header (big-endian at offsets 84-91)
        var reader = BinaryReader(data: data)
        try reader.seek(to: 84)
        let jpegOffset = Int(try reader.readUInt32BigEndian())
        let jpegLength = Int(try reader.readUInt32BigEndian())

        guard jpegOffset > 0 && jpegLength > 0 && jpegOffset + jpegLength <= data.count else {
            throw MetadataError.invalidRAW("Invalid RAF JPEG offset/length")
        }

        // The embedded JPEG contains the TIFF/Exif metadata in its APP1 segment.
        // Parse it as TIFF by extracting Exif data from the JPEG.
        let jpegData = data[data.startIndex + jpegOffset ..< data.startIndex + jpegOffset + jpegLength]

        // Find the Exif APP1 segment within the embedded JPEG
        if let exifOffset = findExifInJPEG(Data(jpegData)) {
            let start = jpegData.startIndex + exifOffset
            let tiffData = Data(jpegData[start ..< jpegData.endIndex])
            return try TIFFFileParser.parse(tiffData)
        }

        // Fallback: try to parse the whole embedded JPEG as if it has a TIFF structure
        throw MetadataError.invalidRAW("No Exif data found in RAF embedded JPEG")
    }

    /// Find the offset of TIFF data within JPEG Exif APP1 segment.
    private static func findExifInJPEG(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        var offset = 2 // Skip SOI (FF D8)

        while offset + 4 < data.count {
            guard data[data.startIndex + offset] == 0xFF else { return nil }
            let marker = data[data.startIndex + offset + 1]

            // APP1 = 0xE1
            if marker == 0xE1 {
                let segLen = Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
                // Check for "Exif\0\0" header
                let headerStart = offset + 4
                if headerStart + 6 <= data.count {
                    let exifHeader = data[data.startIndex + headerStart ..< data.startIndex + headerStart + 6]
                    if exifHeader == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
                        return headerStart + 6 // TIFF data starts after "Exif\0\0"
                    }
                }
                offset += 2 + segLen
            } else if marker == 0xDA || marker == 0xD9 {
                break // SOS or EOI — stop scanning
            } else {
                let segLen = Int(data[data.startIndex + offset + 2]) << 8 | Int(data[data.startIndex + offset + 3])
                offset += 2 + segLen
            }
        }
        return nil
    }

    // MARK: - RW2 (Panasonic)

    /// Parse Panasonic RW2 file. RW2 uses a TIFF-like structure but with version
    /// byte 0x55 instead of 0x2A. We patch the version to standard TIFF for parsing.
    private static func parseRW2(_ data: Data) throws -> TIFFFile {
        guard data.count >= 8 else {
            throw MetadataError.invalidRAW("RW2 file too small")
        }

        // Verify RW2 magic: "II" + 0x55 0x00
        guard data[data.startIndex] == 0x49 && data[data.startIndex + 1] == 0x49 &&
              data[data.startIndex + 2] == 0x55 && data[data.startIndex + 3] == 0x00 else {
            throw MetadataError.invalidRAW("Missing RW2 magic bytes")
        }

        // Patch version byte from 0x55 to standard TIFF 0x2A so TIFFFileParser can handle it
        var patched = data
        patched[patched.startIndex + 2] = 0x2A
        return try TIFFFileParser.parse(patched)
    }

    // MARK: - Private

    private static func hasDNGVersionTag(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }

        var reader = BinaryReader(data: data)
        guard let header = try? TIFFHeader.parse(from: &reader) else { return false }

        let endian = header.byteOrder
        let ifdOffset = Int(header.ifdOffset)
        guard ifdOffset + 2 <= data.count else { return false }

        do {
            try reader.seek(to: ifdOffset)
            let entryCount = try reader.readUInt16(endian: endian)
            let maxEntries = min(Int(entryCount), (data.count - ifdOffset - 2) / 12)

            for i in 0..<maxEntries {
                let entryOffset = ifdOffset + 2 + (i * 12)
                guard entryOffset + 2 <= data.count else { break }
                try reader.seek(to: entryOffset)
                let tag = try reader.readUInt16(endian: endian)
                if tag == 0xC612 { return true }
            }
        } catch {
            return false
        }

        return false
    }
}
