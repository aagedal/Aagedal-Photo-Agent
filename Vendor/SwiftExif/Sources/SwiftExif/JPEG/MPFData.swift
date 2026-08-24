import Foundation

/// Parsed JPEG Multi-Picture Format (MPF) data from an APP2 segment.
/// MPF is defined by CIPA DC-007 and used to embed multiple images inside a
/// single JPEG: Apple Live Photo aux frames and depth maps, Sony A-series
/// continuous-shoot bursts, and stereo / 3D pairs.
public struct MPFData: Sendable, Equatable {
    /// MPF version as a 4-character ASCII string ("0100" for the standard).
    public var version: String?
    /// Total image count declared in the MP Index IFD (NumberOfImages tag).
    public var numberOfImages: Int
    /// Individual image entries from the MPEntry tag, in declaration order.
    public var entries: [MPFEntry]

    public init(version: String? = nil, numberOfImages: Int = 0, entries: [MPFEntry] = []) {
        self.version = version
        self.numberOfImages = numberOfImages
        self.entries = entries
    }
}

/// A single image record inside a JPEG MPF block (16 bytes in the file).
public struct MPFEntry: Sendable, Equatable {
    /// Raw 32-bit attribute word (see CIPA DC-007 §5.2.3.3).
    public var attribute: UInt32
    /// Image data size in bytes.
    public var imageSize: UInt32
    /// Image data offset, in bytes from the MPF base (the byte after the
    /// 4-byte MPF identifier inside the APP2 payload).
    public var imageOffset: UInt32
    /// Dependent-image entry numbers (1-based, 0 = none).
    public var dependentEntry1: UInt16
    public var dependentEntry2: UInt16

    public init(
        attribute: UInt32,
        imageSize: UInt32,
        imageOffset: UInt32,
        dependentEntry1: UInt16,
        dependentEntry2: UInt16
    ) {
        self.attribute = attribute
        self.imageSize = imageSize
        self.imageOffset = imageOffset
        self.dependentEntry1 = dependentEntry1
        self.dependentEntry2 = dependentEntry2
    }

    /// Lower 24 bits of `attribute` — the MPType tag. The top 8 bits hold
    /// the dependent / representative flags (`isPrimary`, `isDependentParent`).
    public var mpType: UInt32 { attribute & 0x00FFFFFF }

    /// True when bit 29 of `attribute` is set ("representative image" flag —
    /// the image a viewer should show by default).
    public var isRepresentative: Bool { (attribute & 0x20000000) != 0 }

    /// True when bit 31 is set — this image depends on others (parent role).
    public var isDependentParent: Bool { (attribute & 0x80000000) != 0 }

    /// True when bit 30 is set — this image is a child of another.
    public var isDependentChild: Bool { (attribute & 0x40000000) != 0 }

    /// Human-readable MPType label (CIPA DC-007 Table 3). Returns
    /// "Unknown (0xNNNNNN)" for unrecognised values.
    public var imageType: String {
        switch mpType {
        case 0x030000: return "Baseline MP Primary Image"
        case 0x010001: return "Large Thumbnail (VGA equivalent)"
        case 0x010002: return "Large Thumbnail (Full HD equivalent)"
        case 0x020001: return "Multi-Frame Panorama"
        case 0x020002: return "Multi-Frame Disparity"
        case 0x020003: return "Multi-Frame Multi-Angle"
        default: return String(format: "Unknown (0x%06X)", mpType)
        }
    }
}

/// Parses MPF data out of a JPEG APP2 segment payload.
public struct MPFParser: Sendable {

    /// MPF identifier prefix that precedes the TIFF-shaped MPF index inside an APP2 segment.
    public static let mpfIdentifier = Data([0x4D, 0x50, 0x46, 0x00])  // "MPF\0"

    // MPF MP Index IFD tags (CIPA DC-007 §5.2).
    private static let tagMPFVersion: UInt16     = 0xB000
    private static let tagNumberOfImages: UInt16 = 0xB001
    private static let tagMPEntry: UInt16        = 0xB002

    /// Parse the APP2 payload of an MPF segment. The caller has already
    /// confirmed the segment starts with `mpfIdentifier`.
    public static func parse(_ segmentData: Data) -> MPFData? {
        guard segmentData.starts(with: mpfIdentifier),
              segmentData.count >= mpfIdentifier.count + 8 else { return nil }

        // The MPF base address is the byte after the "MPF\0" identifier.
        // Copy into a fresh Data so downstream parsers don't trip on the
        // slice's non-zero startIndex.
        let mpfBase = segmentData.startIndex + mpfIdentifier.count
        let body = Data(segmentData[mpfBase...])

        // body now points at a TIFF-shaped IFD with a header. Let ExifReader
        // handle the byte-order detection + IFD walk so we don't reimplement
        // that logic here.
        guard let exif = try? ExifReader.readFromTIFF(data: body) else { return nil }
        guard let ifd = exif.ifd0 else { return nil }
        let endian = exif.byteOrder

        var data = MPFData()

        if let v = ifd.entry(for: tagMPFVersion)?.valueData,
           v.count >= 4,
           let s = String(data: Data(v.prefix(4)), encoding: .ascii) {
            data.version = s
        }

        if let n = ifd.entry(for: tagNumberOfImages)?.uint32Value(endian: endian) {
            data.numberOfImages = Int(n)
        }

        if let entry = ifd.entry(for: tagMPEntry) {
            data.entries = parseMPEntries(entry.valueData, endian: endian)
        }

        return data
    }

    /// Decode the MPEntry tag value (16 bytes per image record).
    private static func parseMPEntries(_ data: Data, endian: ByteOrder) -> [MPFEntry] {
        let recordSize = 16
        let count = data.count / recordSize
        guard count > 0 else { return [] }

        var out: [MPFEntry] = []
        out.reserveCapacity(count)
        var reader = BinaryReader(data: data)
        for _ in 0..<count {
            guard let attribute = try? reader.readUInt32(endian: endian),
                  let size = try? reader.readUInt32(endian: endian),
                  let offset = try? reader.readUInt32(endian: endian),
                  let dep1 = try? reader.readUInt16(endian: endian),
                  let dep2 = try? reader.readUInt16(endian: endian) else { break }
            out.append(MPFEntry(
                attribute: attribute,
                imageSize: size,
                imageOffset: offset,
                dependentEntry1: dep1,
                dependentEntry2: dep2
            ))
        }
        return out
    }
}
