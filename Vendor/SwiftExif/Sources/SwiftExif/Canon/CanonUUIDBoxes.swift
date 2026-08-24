import Foundation

/// Canon-specific UUID identifiers used in CR3 (still images) and CRM/CRL
/// (Cinema RAW Light video) ISOBMFF files. Both formats share the same UUIDs
/// for metadata, preview, and XMP containers — they only differ in `ftyp`
/// brand (`crx` for both, but distinguished further by the CNCV string
/// `"CanonCR3_001/..."` vs `"CanonCRM0001/..."`) and by whether a `CTMD`
/// timed-metadata track is present.
public enum CanonUUID {
    /// Canon metadata container — wraps CMT1-4 TIFF IFDs, THMB thumbnail, CNCV.
    /// 85c0b687-820f-11e0-8111-f4ce462b6a48
    public static let canonMetadata = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48
    ])

    /// Preview container — wraps the larger PRVW JPEG (1620×1080 in current cameras).
    /// eaf42b5e-1c98-4b88-b9fb-b7dc406e4d16
    public static let canonPreview = Data([
        0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88,
        0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16
    ])

    /// XMP metadata container.
    /// be7acfcb-97a9-42e8-9c71-999491e3afac
    public static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC
    ])
}

/// Decodes the contents of Canon's metadata UUID container. Used by both the
/// CR3 image pipeline and the CRM/CRL video reader, which see the same box
/// hierarchy inside the `85c0…` UUID.
public struct CanonUUIDExtractor: Sendable {

    /// Result of decoding a Canon metadata UUID payload.
    public struct Result: Sendable {
        public var exif: ExifData?
        public var thumbnail: Data?
        /// CNCV (Canon Codec Version) string — e.g.
        /// `"CanonCR3_001/00.09.00/00.00.00"` for CR3 still images,
        /// `"CanonCRM0001/02.10.00/00.00.00"` for CRM Cinema RAW Light.
        /// Useful for callers to distinguish CR3 from CRM without re-walking.
        public var cncv: String?
    }

    /// Walk the inside of a Canon metadata UUID payload (caller must strip
    /// the leading 16-byte UUID first). Decodes:
    /// - `CMT1` → IFD0 (Make, Model, Orientation, …)
    /// - `CMT2` → ExifIFD (ISO, FNumber, ExposureTime, …)
    /// - `CMT3` → Canon MakerNotes IFD
    /// - `CMT4` → GPS IFD
    /// - `CNCV` → codec version string
    /// - `THMB` → thumbnail JPEG
    public static func parseCanonMetadata(_ payload: Data) throws -> Result {
        let children = try ISOBMFFBoxReader.parseBoxes(from: payload)

        var ifd0: IFD?
        var exifIFD: IFD?
        var makerNoteIFD: IFD?
        var gpsIFD: IFD?
        var byteOrder: ByteOrder = .littleEndian
        var thumbnail: Data?
        var cncv: String?

        for child in children {
            switch child.type {
            case "CMT1":
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    ifd0 = parsed.ifd0
                    byteOrder = parsed.byteOrder
                }
            case "CMT2":
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    exifIFD = parsed.ifd0 // CMT2's IFD0 IS the Exif sub-IFD
                }
            case "CMT3":
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    makerNoteIFD = parsed.ifd0
                }
            case "CMT4":
                if let parsed = try? ExifReader.readFromTIFF(data: child.data) {
                    gpsIFD = parsed.ifd0
                }
            case "CNCV":
                cncv = String(data: child.data, encoding: .ascii)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case "THMB":
                thumbnail = extractEmbeddedJPEG(from: child.data)
            default:
                break // CCTP, CCDT, CTBO, etc. — not needed for metadata
            }
        }

        var exif: ExifData?
        if ifd0 != nil || exifIFD != nil {
            var data = ExifData(byteOrder: byteOrder)
            data.ifd0 = ifd0
            data.exifIFD = exifIFD
            data.gpsIFD = gpsIFD
            if let makerNoteIFD {
                data.makerNoteIFD = makerNoteIFD
                // CMT3 is the Canon MakerNotes IFD with its values already
                // resolved. Interpret it into named tags here — the normal
                // MakerNoteReader path only fires on a JPEG/TIFF 0x927C blob,
                // which CR3/CRM don't have.
                let tags = CanonMakerNote.interpret(ifd: makerNoteIFD, byteOrder: byteOrder)
                if !tags.isEmpty {
                    data.makerNote = MakerNoteData(
                        manufacturer: .canon, tags: tags, rawData: Data()
                    )
                }
            }
            exif = data
        }

        return Result(exif: exif, thumbnail: thumbnail, cncv: cncv)
    }

    /// Walk the inside of the Canon preview UUID payload (caller must strip
    /// the leading 16-byte UUID first). Returns the JPEG data of the `PRVW` box.
    ///
    /// The preview container prefixes the `PRVW` box with an 8-byte
    /// version/count header (`00000000 00000001` on current bodies), so the box
    /// is not the first child — locate it by its 4CC rather than assuming
    /// position.
    public static func parsePreview(_ payload: Data) throws -> Data? {
        guard let typeRange = payload.range(of: Data("PRVW".utf8)),
              payload.distance(from: payload.startIndex, to: typeRange.lowerBound) >= 4 else {
            return nil
        }
        // The PRVW body begins right after the 4CC type. extractEmbeddedJPEG
        // tolerates the (longer) PRVW header by scanning for the SOI marker.
        let body = payload.subdata(in: typeRange.upperBound ..< payload.endIndex)
        return extractEmbeddedJPEG(from: body)
    }

    /// Extract the embedded JPEG from a `THMB` or `PRVW` box body. Both prefix
    /// the JPEG with a small header — version(4) + width(2) + height(2) +
    /// jpegSize(4) — but the padding between `jpegSize` and the JPEG varies by
    /// firmware (2 bytes on older bodies, 4+ on newer ones such as the EOS R1).
    /// Rather than assume a fixed header length, read the declared `jpegSize`
    /// and then locate the actual `0xFFD8` SOI marker.
    public static func extractEmbeddedJPEG(from data: Data) -> Data? {
        guard data.count > 12 else { return nil }
        var reader = BinaryReader(data: data)
        let jpegSize: Int
        do {
            _ = try reader.readUInt32BigEndian() // version
            _ = try reader.readUInt16BigEndian() // width
            _ = try reader.readUInt16BigEndian() // height
            jpegSize = Int(try reader.readUInt32BigEndian())
        } catch {
            return nil
        }

        // Find the SOI marker at/after the fixed 12-byte prefix.
        let soi = Data([0xFF, 0xD8])
        guard let range = data.range(of: soi, in: (data.startIndex + 12) ..< data.endIndex) else {
            return nil
        }
        let start = range.lowerBound
        // Trust the declared size when it's plausible; otherwise take the rest
        // of the box up to (and including) the EOI marker.
        if jpegSize > 0, start + jpegSize <= data.endIndex {
            return data.subdata(in: start ..< (start + jpegSize))
        }
        if let eoi = data.range(of: Data([0xFF, 0xD9]), options: .backwards,
                                in: start ..< data.endIndex) {
            return data.subdata(in: start ..< eoi.upperBound)
        }
        return data.subdata(in: start ..< data.endIndex)
    }
}
