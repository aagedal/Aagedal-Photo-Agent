import Foundation

/// XYZ tristimulus value, decoded from ICC s15Fixed16 entries.
public struct ICCXYZ: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Tone reproduction curve from a `curv` or `para` tag.
public enum ICCToneCurve: Equatable, Sendable {
    /// `curv` with count == 0 (identity transform).
    case identity
    /// `curv` with count == 1 — single u8.8 fixed-point gamma value.
    case gamma(Double)
    /// `curv` with count > 1 — sampled curve, each entry uint16 in 0..65535.
    case table(samples: Int)
    /// `para` parametric curve, function type 0..4.
    case parametric(functionType: Int)
}

/// Lookup-table summary for `mft1`, `mft2`, `mAB ` and `mBA ` tags.
public struct ICCLUTSummary: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 8-bit lookup table (`mft1`).
        case lut8 = "mft1"
        /// 16-bit lookup table (`mft2`).
        case lut16 = "mft2"
        /// Multi-process A→B (`mAB `).
        case mAB
        /// Multi-process B→A (`mBA `).
        case mBA
    }

    public let kind: Kind
    public let inputChannels: Int
    public let outputChannels: Int
}

/// A tag entry in an ICC profile's tag table.
public struct ICCTagEntry: Equatable, Sendable {
    /// 4-character tag signature (e.g. "desc", "rXYZ", "A2B0").
    public let signature: String
    /// Byte offset of the tag's data within the profile.
    public let offset: UInt32
    /// Length of the tag's data in bytes.
    public let size: UInt32
    /// 4-character type signature taken from the first 4 bytes of the tag data.
    public let typeSignature: String
}

/// A wrapper around an ICC color profile.
/// Stores the raw profile bytes and parses the header plus the most common tags
/// (description, copyright, white/black point, colorants, TRCs, LUTs, viewing
/// conditions, measurement, chromatic adaptation, named colors).
public struct ICCProfile: Equatable, Sendable {
    /// Raw profile data (full bytes including header).
    public let data: Data

    // MARK: - Header (always present in a valid ICC profile)

    /// Profile size in bytes from header bytes 0-3.
    public let profileSize: UInt32

    /// Profile version, formatted as `major.minor.bugfix` (header bytes 8-11).
    public let profileVersion: String?

    /// Profile/device class (header bytes 12-15): "mntr" (display), "scnr",
    /// "prtr", "spac", "link", "abst", "nmcl".
    public let deviceClass: String?

    /// Data color space (header bytes 16-19, e.g. "RGB ", "CMYK", "GRAY").
    public let colorSpace: String

    /// Profile connection space (header bytes 20-23, e.g. "XYZ ", "Lab ").
    public let profileConnectionSpace: String

    /// Profile creation timestamp from the header (formatted "yyyy:MM:dd HH:mm:ss").
    public let creationDate: String?

    /// Primary platform signature (header bytes 40-43, e.g. "APPL", "MSFT").
    public let primaryPlatform: String?

    /// Device manufacturer (header bytes 48-51).
    public let manufacturer: String?

    /// Device model (header bytes 52-55).
    public let model: String?

    /// Rendering intent (header bytes 64-67):
    /// 0=perceptual, 1=relative colorimetric, 2=saturation, 3=absolute colorimetric.
    public let renderingIntent: UInt32?

    /// PCS illuminant XYZ from header bytes 68-79 (3 × s15Fixed16).
    public let pcsIlluminant: ICCXYZ?

    /// Profile creator (header bytes 80-83).
    public let creator: String?

    /// MD5 profile ID from header bytes 84-99, hex-encoded. `nil` if all zeros.
    public let profileID: String?

    // MARK: - Tag table

    /// All parsed tag table entries indexed by 4-character signature.
    public let tags: [String: ICCTagEntry]

    // MARK: - Tag-derived convenience fields

    /// Description from the `desc` (ICC v2) or `mluc` (ICC v4) tag.
    public let profileDescription: String?

    /// Copyright string from the `cprt` tag.
    public let copyright: String?

    /// Media white point from the `wtpt` tag.
    public let mediaWhitePoint: ICCXYZ?

    /// Media black point from the `bkpt` tag.
    public let mediaBlackPoint: ICCXYZ?

    /// 3×3 chromatic adaptation matrix (9 floats, row-major) from `chad`.
    public let chromaticAdaptation: [Double]?

    /// Red colorant XYZ (`rXYZ` — matrix-shaper RGB profiles).
    public let redColorant: ICCXYZ?

    /// Green colorant XYZ (`gXYZ`).
    public let greenColorant: ICCXYZ?

    /// Blue colorant XYZ (`bXYZ`).
    public let blueColorant: ICCXYZ?

    /// Red tone reproduction curve (`rTRC`).
    public let redTRC: ICCToneCurve?

    /// Green tone reproduction curve (`gTRC`).
    public let greenTRC: ICCToneCurve?

    /// Blue tone reproduction curve (`bTRC`).
    public let blueTRC: ICCToneCurve?

    /// Gray tone reproduction curve (`kTRC` — used by GRAY profiles).
    public let grayTRC: ICCToneCurve?

    /// A→B perceptual LUT (`A2B0`) summary, if present.
    public let aToB0: ICCLUTSummary?

    /// A→B relative-colorimetric LUT (`A2B1`).
    public let aToB1: ICCLUTSummary?

    /// A→B saturation LUT (`A2B2`).
    public let aToB2: ICCLUTSummary?

    /// B→A perceptual LUT (`B2A0`).
    public let bToA0: ICCLUTSummary?

    /// B→A relative-colorimetric LUT (`B2A1`).
    public let bToA1: ICCLUTSummary?

    /// B→A saturation LUT (`B2A2`).
    public let bToA2: ICCLUTSummary?

    /// Number of named colors in the `ncl2` tag, if present.
    public let namedColorCount: Int?

    /// True if the `view` (viewing conditions) tag is present.
    public let hasViewingConditions: Bool

    /// True if the `meas` (measurement) tag is present.
    public let hasMeasurement: Bool

    // MARK: - Init

    /// Parse an ICC profile from raw data.
    /// Returns `nil` if the data is too small to contain a valid 128-byte ICC header.
    public init?(data: Data) {
        guard data.count >= 128 else { return nil }
        self.data = data

        // --- Header ---
        self.profileSize = Self.readUInt32BE(data, at: 0) ?? 0
        self.profileVersion = Self.readVersion(data, at: 8)
        self.deviceClass = Self.readASCII(data, at: 12, length: 4)
        // Preserve trailing space (e.g. "RGB ", "XYZ ") for the 4-char color-space
        // fields — ICC pads these and downstream code matches on the raw form.
        self.colorSpace = Self.readASCIIRaw(data, at: 16, length: 4) ?? "????"
        self.profileConnectionSpace = Self.readASCIIRaw(data, at: 20, length: 4) ?? "????"
        self.creationDate = Self.readDateTime(data, at: 24)
        self.primaryPlatform = Self.readASCII(data, at: 40, length: 4)
        self.manufacturer = Self.readASCII(data, at: 48, length: 4)
        self.model = Self.readASCII(data, at: 52, length: 4)
        self.renderingIntent = Self.readUInt32BE(data, at: 64)
        self.pcsIlluminant = Self.readXYZHeader(data, at: 68)
        self.creator = Self.readASCII(data, at: 80, length: 4)
        self.profileID = Self.readProfileID(data, at: 84)

        // --- Tag table ---
        let tagEntries = Self.parseTagTable(data: data)
        self.tags = tagEntries

        // --- Derived tag fields ---
        self.profileDescription = Self.parseTextLike(data: data, entry: tagEntries["desc"])
        self.copyright = Self.parseTextLike(data: data, entry: tagEntries["cprt"])
        self.mediaWhitePoint = Self.parseXYZ(data: data, entry: tagEntries["wtpt"])
        self.mediaBlackPoint = Self.parseXYZ(data: data, entry: tagEntries["bkpt"])
        self.chromaticAdaptation = Self.parseSF32(data: data, entry: tagEntries["chad"], expectedCount: 9)
        self.redColorant = Self.parseXYZ(data: data, entry: tagEntries["rXYZ"])
        self.greenColorant = Self.parseXYZ(data: data, entry: tagEntries["gXYZ"])
        self.blueColorant = Self.parseXYZ(data: data, entry: tagEntries["bXYZ"])
        self.redTRC = Self.parseToneCurve(data: data, entry: tagEntries["rTRC"])
        self.greenTRC = Self.parseToneCurve(data: data, entry: tagEntries["gTRC"])
        self.blueTRC = Self.parseToneCurve(data: data, entry: tagEntries["bTRC"])
        self.grayTRC = Self.parseToneCurve(data: data, entry: tagEntries["kTRC"])
        self.aToB0 = Self.parseLUTSummary(data: data, entry: tagEntries["A2B0"])
        self.aToB1 = Self.parseLUTSummary(data: data, entry: tagEntries["A2B1"])
        self.aToB2 = Self.parseLUTSummary(data: data, entry: tagEntries["A2B2"])
        self.bToA0 = Self.parseLUTSummary(data: data, entry: tagEntries["B2A0"])
        self.bToA1 = Self.parseLUTSummary(data: data, entry: tagEntries["B2A1"])
        self.bToA2 = Self.parseLUTSummary(data: data, entry: tagEntries["B2A2"])
        self.namedColorCount = Self.parseNamedColorCount(data: data, entry: tagEntries["ncl2"])
        self.hasViewingConditions = tagEntries["view"] != nil
        self.hasMeasurement = tagEntries["meas"] != nil
    }

    // MARK: - Header helpers

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let s = data.startIndex + offset
        return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16 | UInt32(data[s + 2]) << 8 | UInt32(data[s + 3])
    }

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let s = data.startIndex + offset
        return UInt16(data[s]) << 8 | UInt16(data[s + 1])
    }

    private static func readInt32BE(_ data: Data, at offset: Int) -> Int32? {
        guard let u = readUInt32BE(data, at: offset) else { return nil }
        return Int32(bitPattern: u)
    }

    /// Decode an s15Fixed16 value (signed 32-bit, 16 fractional bits).
    private static func readS15Fixed16(_ data: Data, at offset: Int) -> Double? {
        guard let i = readInt32BE(data, at: offset) else { return nil }
        return Double(i) / 65536.0
    }

    private static func readASCII(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let s = data.startIndex + offset
        let bytes = data[s ..< s + length]
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        let str = String(data: Data(bytes), encoding: .ascii) ?? ""
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Like `readASCII` but preserves trailing padding spaces. Used for ICC's
    /// fixed-width 4-char `colorSpace` and `profileConnectionSpace` codes
    /// (e.g. "RGB ", "XYZ ", "GRAY") where the space is part of the canonical form.
    private static func readASCIIRaw(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let s = data.startIndex + offset
        let bytes = data[s ..< s + length]
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        return String(data: Data(bytes), encoding: .ascii)
    }

    /// Profile version is encoded as: major(1) | (minor<<4 | bugfix)(1) | reserved(2).
    private static func readVersion(_ data: Data, at offset: Int) -> String? {
        guard offset + 4 <= data.count else { return nil }
        let s = data.startIndex + offset
        let major = Int(data[s])
        let minor = Int(data[s + 1] >> 4)
        let bugfix = Int(data[s + 1] & 0x0F)
        if major == 0 && minor == 0 && bugfix == 0 { return nil }
        return "\(major).\(minor).\(bugfix)"
    }

    /// dateTimeNumber: 6 × uint16be (year, month, day, hour, minute, second).
    private static func readDateTime(_ data: Data, at offset: Int) -> String? {
        guard offset + 12 <= data.count else { return nil }
        let s = data.startIndex + offset
        let year = UInt16(data[s]) << 8 | UInt16(data[s + 1])
        let month = UInt16(data[s + 2]) << 8 | UInt16(data[s + 3])
        let day = UInt16(data[s + 4]) << 8 | UInt16(data[s + 5])
        let hour = UInt16(data[s + 6]) << 8 | UInt16(data[s + 7])
        let minute = UInt16(data[s + 8]) << 8 | UInt16(data[s + 9])
        let second = UInt16(data[s + 10]) << 8 | UInt16(data[s + 11])
        if year == 0 { return nil }
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    private static func readXYZHeader(_ data: Data, at offset: Int) -> ICCXYZ? {
        guard let x = readS15Fixed16(data, at: offset),
              let y = readS15Fixed16(data, at: offset + 4),
              let z = readS15Fixed16(data, at: offset + 8) else { return nil }
        if x == 0 && y == 0 && z == 0 { return nil }
        return ICCXYZ(x: x, y: y, z: z)
    }

    private static func readProfileID(_ data: Data, at offset: Int) -> String? {
        guard offset + 16 <= data.count else { return nil }
        let s = data.startIndex + offset
        let bytes = data[s ..< s + 16]
        if bytes.allSatisfy({ $0 == 0 }) { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tag table parsing

    /// Parse the tag table starting at byte 128.
    /// Format: 4-byte tag count, then N × 12 bytes (signature + offset + size).
    private static func parseTagTable(data: Data) -> [String: ICCTagEntry] {
        guard data.count >= 132 else { return [:] }
        guard let rawCount = readUInt32BE(data, at: 128) else { return [:] }
        // Cap at a sensible upper bound to defend against malformed profiles.
        let count = min(Int(rawCount), 512)
        guard 132 + count * 12 <= data.count else { return [:] }

        var entries: [String: ICCTagEntry] = [:]
        entries.reserveCapacity(count)

        for i in 0..<count {
            let entryOffset = 132 + i * 12
            let s = data.startIndex + entryOffset
            let sigBytes = data[s ..< s + 4]
            guard let sig = String(data: Data(sigBytes), encoding: .ascii) else { continue }
            guard let offset = readUInt32BE(data, at: entryOffset + 4),
                  let size = readUInt32BE(data, at: entryOffset + 8) else { continue }

            // Bounds-check the tag data area.
            let tagOffset = Int(offset)
            let tagSize = Int(size)
            guard tagSize >= 8, tagOffset >= 0, tagOffset + tagSize <= data.count else {
                // Record entry but mark type as empty so callers can still see the signature.
                entries[sig] = ICCTagEntry(signature: sig, offset: offset, size: size, typeSignature: "")
                continue
            }

            let ts = data.startIndex + tagOffset
            let typeBytes = data[ts ..< ts + 4]
            let typeSig = String(data: Data(typeBytes), encoding: .ascii) ?? ""
            entries[sig] = ICCTagEntry(signature: sig, offset: offset, size: size, typeSignature: typeSig)
        }

        return entries
    }

    // MARK: - Tag value parsers

    /// Parse `desc` (textDescriptionType, ICC v2), `mluc` (multiLocalizedUnicodeType,
    /// ICC v4), or `text` (textType, plain ASCII).
    private static func parseTextLike(data: Data, entry: ICCTagEntry?) -> String? {
        guard let entry = entry else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        guard size > 8, offset + size <= data.count else { return nil }

        switch entry.typeSignature {
        case "desc":
            return parseDescType(data: data, offset: offset, size: size)
        case "mluc":
            return parseMlucType(data: data, offset: offset, size: size)
        case "text":
            // text: 8-byte header (sig + reserved) + ASCII string with optional null
            let strStart = offset + 8
            let strLen = size - 8
            guard strLen > 0 else { return nil }
            let s = data.startIndex + strStart
            var bytes = Data(data[s ..< s + strLen])
            // Drop trailing null bytes.
            while bytes.last == 0 { bytes = bytes.dropLast() }
            guard !bytes.isEmpty else { return nil }
            return String(data: bytes, encoding: .ascii) ?? String(data: bytes, encoding: .utf8)
        default:
            return nil
        }
    }

    /// `desc` textDescriptionType: 4 sig + 4 reserved + 4 ASCII length + ASCII string.
    private static func parseDescType(data: Data, offset: Int, size: Int) -> String? {
        guard offset + 12 <= data.count else { return nil }
        guard let strLen = readUInt32BE(data, at: offset + 8), strLen > 0 else { return nil }
        let readLen = min(Int(strLen), size - 12)
        guard readLen > 0, offset + 12 + readLen <= data.count else { return nil }
        let s = data.startIndex + offset + 12
        var bytes = Data(data[s ..< s + readLen])
        if bytes.last == 0 { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return nil }
        return String(data: bytes, encoding: .ascii) ?? String(data: bytes, encoding: .utf8)
    }

    /// `mluc` multiLocalizedUnicodeType (ICC v4): use the first record (UTF-16BE).
    private static func parseMlucType(data: Data, offset: Int, size: Int) -> String? {
        guard offset + 16 <= data.count else { return nil }
        guard let recordCount = readUInt32BE(data, at: offset + 8),
              let recordSize = readUInt32BE(data, at: offset + 12),
              recordCount > 0, recordSize >= 12 else { return nil }
        // First record begins at offset+16: language(2) + country(2) + length(4) + offset(4).
        guard offset + 16 + 12 <= data.count else { return nil }
        guard let strLen = readUInt32BE(data, at: offset + 16 + 4),
              let strRel = readUInt32BE(data, at: offset + 16 + 8) else { return nil }
        let absOffset = offset + Int(strRel)
        let readLen = min(Int(strLen), data.count - absOffset)
        guard readLen > 0, absOffset >= 0, absOffset + readLen <= data.count else { return nil }
        let s = data.startIndex + absOffset
        let strData = Data(data[s ..< s + readLen])
        return String(data: strData, encoding: .utf16BigEndian)
    }

    /// `XYZ ` tag: 4 sig + 4 reserved + N × (3 × s15Fixed16). Returns first triplet.
    private static func parseXYZ(data: Data, entry: ICCTagEntry?) -> ICCXYZ? {
        guard let entry = entry, entry.typeSignature == "XYZ " else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        guard size >= 20, offset + 20 <= data.count else { return nil }
        return readXYZHeader(data, at: offset + 8)
    }

    /// `sf32` s15Fixed16ArrayType: 4 sig + 4 reserved + N × s15Fixed16.
    /// Returns nil unless the tag has exactly `expectedCount` values.
    private static func parseSF32(data: Data, entry: ICCTagEntry?, expectedCount: Int) -> [Double]? {
        guard let entry = entry, entry.typeSignature == "sf32" else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        let need = 8 + expectedCount * 4
        guard size >= need, offset + need <= data.count else { return nil }
        var result: [Double] = []
        result.reserveCapacity(expectedCount)
        for i in 0..<expectedCount {
            guard let v = readS15Fixed16(data, at: offset + 8 + i * 4) else { return nil }
            result.append(v)
        }
        return result
    }

    /// `curv` (curveType) or `para` (parametricCurveType).
    private static func parseToneCurve(data: Data, entry: ICCTagEntry?) -> ICCToneCurve? {
        guard let entry = entry else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        guard size >= 12, offset + 12 <= data.count else { return nil }

        switch entry.typeSignature {
        case "curv":
            // 4 sig + 4 reserved + 4 count + count × uint16
            guard let count = readUInt32BE(data, at: offset + 8) else { return nil }
            if count == 0 {
                return .identity
            }
            if count == 1 {
                // Single u8.8 fixed-point gamma value (uint16be).
                guard offset + 14 <= data.count else { return nil }
                guard let raw = readUInt16BE(data, at: offset + 12) else { return nil }
                return .gamma(Double(raw) / 256.0)
            }
            return .table(samples: Int(count))
        case "para":
            // 4 sig + 4 reserved + 2 function type + 2 reserved + N × s15Fixed16
            guard offset + 12 <= data.count else { return nil }
            guard let fn = readUInt16BE(data, at: offset + 8) else { return nil }
            return .parametric(functionType: Int(fn))
        default:
            return nil
        }
    }

    /// LUT summary for `mft1`, `mft2`, `mAB ` and `mBA ` tags.
    /// Reads channel counts from the type-specific header.
    private static func parseLUTSummary(data: Data, entry: ICCTagEntry?) -> ICCLUTSummary? {
        guard let entry = entry else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        guard size >= 12, offset + 12 <= data.count else { return nil }

        switch entry.typeSignature {
        case "mft1", "mft2":
            // Both share: 4 sig + 4 reserved + 1 input ch + 1 output ch + ...
            let s = data.startIndex + offset + 8
            let input = Int(data[s])
            let output = Int(data[s + 1])
            let kind: ICCLUTSummary.Kind = entry.typeSignature == "mft1" ? .lut8 : .lut16
            return ICCLUTSummary(kind: kind, inputChannels: input, outputChannels: output)
        case "mAB ", "mBA ":
            // 4 sig + 4 reserved + 1 input + 1 output + 2 reserved + ...
            let s = data.startIndex + offset + 8
            let input = Int(data[s])
            let output = Int(data[s + 1])
            let kind: ICCLUTSummary.Kind = entry.typeSignature == "mAB " ? .mAB : .mBA
            return ICCLUTSummary(kind: kind, inputChannels: input, outputChannels: output)
        default:
            return nil
        }
    }

    /// Named-color list (`ncl2`): 4 sig + 4 reserved + 4 vendor flag + 4 count + ...
    private static func parseNamedColorCount(data: Data, entry: ICCTagEntry?) -> Int? {
        guard let entry = entry, entry.typeSignature == "ncl2" else { return nil }
        let offset = Int(entry.offset)
        let size = Int(entry.size)
        guard size >= 16, offset + 16 <= data.count else { return nil }
        guard let count = readUInt32BE(data, at: offset + 12) else { return nil }
        return Int(count)
    }
}
