import Foundation

/// DNG-specific (Adobe Digital Negative) tags read from the IFD0 of a TIFF file.
///
/// These are the private tags Adobe added to TIFF for camera-RAW interop:
/// color-correction matrices, noise profile, default crop, opcode lists,
/// and look tables. Standalone TIFF files won't have these; they appear
/// only in DNG-marked files (those carrying tag 0xC612 DNGVersion).
public struct DNGMetadata: Sendable, Equatable {
    /// Tag 0xC612 — DNG specification version this file conforms to (4 × UInt8, e.g. "1.4.0.0").
    public let dngVersion: String?
    /// Tag 0xC613 — earliest DNG version a reader needs to interpret the file.
    public let dngBackwardVersion: String?
    /// Tag 0xC614 — unique camera model name (ASCII).
    public let uniqueCameraModel: String?
    /// Tag 0xC615 — LocalizedCameraModel: human-readable camera model (ASCII).
    public let localizedCameraModel: String?
    /// Tag 0xC62F — camera serial number (ASCII).
    public let cameraSerialNumber: String?
    /// Tag 0xC65A — calibration illuminant 1 (Exif LightSource codepoint).
    public let calibrationIlluminant1: UInt16?
    /// Tag 0xC65B — calibration illuminant 2.
    public let calibrationIlluminant2: UInt16?
    /// Tag 0xC621 — ColorMatrix1 (XYZ-to-camera-RGB), 3×3 row-major s-rationals.
    public let colorMatrix1: [Double]?
    /// Tag 0xC622 — ColorMatrix2 (second illuminant), 3×3 row-major s-rationals.
    public let colorMatrix2: [Double]?
    /// Tag 0xC623 — CameraCalibration1 (3×3 row-major).
    public let cameraCalibration1: [Double]?
    /// Tag 0xC624 — CameraCalibration2 (3×3 row-major).
    public let cameraCalibration2: [Double]?
    /// Tag 0xC627 — AnalogBalance gain applied before AsShotNeutral (one per color plane).
    public let analogBalance: [Double]?
    /// Tag 0xC628 — AsShotNeutral white-balance multipliers (one per color plane).
    public let asShotNeutral: [Double]?
    /// Tag 0xC629 — AsShotWhiteXY chromaticity (x, y).
    public let asShotWhiteXY: [Double]?
    /// Tag 0xC62A — BaselineExposure adjustment in EV stops (s-rational).
    public let baselineExposure: Double?
    /// Tag 0xC62B — BaselineNoise factor (rational).
    public let baselineNoise: Double?
    /// Tag 0xC62C — BaselineSharpness factor (rational).
    public let baselineSharpness: Double?
    /// Tag 0xC62D — BayerGreenSplit: non-uniformity of the two green CFA values (0–5000).
    public let bayerGreenSplit: UInt32?
    /// Tag 0xC62E — LinearResponseLimit fraction beyond which response is non-linear (rational).
    public let linearResponseLimit: Double?
    /// Tag 0xC632 — AntiAliasStrength of the optical low-pass filter (0–1, rational).
    public let antiAliasStrength: Double?
    /// Tag 0xC633 — ShadowScale relative weighting of shadow vs highlight (rational).
    public let shadowScale: Double?
    /// Tag 0xC65C — BestQualityScale upsampling factor for the highest quality (rational).
    public let bestQualityScale: Double?
    /// Tag 0xC616 — CFAPlaneColor: color plane → CFA color mapping, e.g. "Red,Green,Blue".
    public let cfaPlaneColor: String?
    /// Tag 0xC617 — CFALayout: physical CFA arrangement (1 = rectangular, 2–9 staggered).
    public let cfaLayout: UInt16?
    /// Tag 0xC619 — BlackLevelRepeatDim (rows, cols) of the BlackLevel pattern.
    public let blackLevelRepeatDim: [Double]?
    /// Tag 0xC61A — BlackLevel zero-light encoding level(s); one per repeat-pattern cell.
    public let blackLevel: [Double]?
    /// Tag 0xC61D — WhiteLevel fully-saturated encoding level(s).
    public let whiteLevel: [Double]?
    /// Tag 0xC61E — DefaultScale (h, v) non-square-pixel correction (rational).
    public let defaultScale: [Double]?
    /// Tag 0xC68D — ActiveArea (top, left, bottom, right) of the valid sensor rectangle.
    public let activeArea: [Double]?
    /// Tag 0xC7B5 — DefaultUserCrop (top, left, bottom, right) as fractions of the active area.
    public let defaultUserCrop: [Double]?
    /// Tag 0xC61F — DefaultCropOrigin (x, y) in pixels from the raw image origin.
    public let defaultCropOrigin: [Double]?
    /// Tag 0xC620 — DefaultCropSize (w, h) in pixels.
    public let defaultCropSize: [Double]?
    /// Tag 0x828D — CFARepeatPatternDim (rows, cols) of the CFA mosaic pattern.
    public let cfaRepeatPatternDim: [Double]?
    /// Tag 0xC6F8 — ProfileName (ASCII).
    public let profileName: String?
    /// Tag 0xC6FE — ProfileCopyright (ASCII).
    public let profileCopyright: String?
    /// Tag 0xC716/0xC717 — Preview application name and version.
    public let previewApplicationName: String?
    public let previewApplicationVersion: String?
    /// Tag 0xC718 — PreviewSettingsName (ASCII).
    public let previewSettingsName: String?
    /// Tag 0xC68B — OriginalRawFileName (ASCII).
    public let originalRawFileName: String?
    /// Tag 0xC65D — RawDataUniqueID (16-byte hex).
    public let rawDataUniqueID: String?
    /// Tag 0xC6BF — ColorimetricReference: 0=Scene-referred, 1=Output-referred ICC v4, 2=Output-referred ICC v2.
    public let colorimetricReference: UInt16?
    /// Tag 0xC6FD — ProfileEmbedPolicy: 0=allow copying, 1=embed if used, 2=embed never, 3=no restrictions.
    public let profileEmbedPolicy: UInt32?
    /// Tag 0xC6F9 — ProfileHueSatMapDims (hueDivisions, satDivisions, valDivisions).
    public let profileHueSatMapDims: [UInt32]?
    /// Tag 0xC725 — ProfileLookTableDims (hueDivisions, satDivisions, valDivisions).
    public let profileLookTableDims: [UInt32]?
    /// Tag 0xC761 — NoiseProfile (one or two pairs of (a, b) shot/read noise coefficients).
    public let noiseProfile: [Double]?
    /// Tag 0xC7A5 — BaselineExposureOffset (s-rational EV).
    public let baselineExposureOffset: Double?

    /// Tag 0xC740 — OpcodeList1 raw bytes (mapping from raw IFD to original mosaiced image).
    public let opcodeList1Size: Int?
    /// Tag 0xC741 — OpcodeList2 raw bytes (after demosaic, before linearization).
    public let opcodeList2Size: Int?
    /// Tag 0xC74E — OpcodeList3 raw bytes (after linearization, before color processing).
    public let opcodeList3Size: Int?
    /// Tag 0xC726 — ProfileLookTableData raw float count (hue×sat×val × 3 floats).
    public let profileLookTableSampleCount: Int?

    /// True if any DNG-specific field was decoded.
    public var hasAnyField: Bool {
        dngVersion != nil || colorMatrix1 != nil || colorMatrix2 != nil ||
        defaultCropOrigin != nil || defaultCropSize != nil ||
        blackLevel != nil || whiteLevel != nil || activeArea != nil ||
        opcodeList1Size != nil || opcodeList2Size != nil || opcodeList3Size != nil ||
        noiseProfile != nil || profileLookTableSampleCount != nil
    }
}

/// DNG tag identifiers (Adobe DNG specification 1.7).
///
/// Tag IDs verified against ExifTool's `Image/ExifTool/Exif.pm` table. Several
/// constants above 0xC630 were historically wrong (sourced from a bad table),
/// which silently dropped the corresponding fields — they are now correct.
public enum DNGTag: Sendable {
    public static let cfaRepeatPatternDim: UInt16       = 0x828D
    public static let dngVersion: UInt16                = 0xC612
    public static let dngBackwardVersion: UInt16        = 0xC613
    public static let uniqueCameraModel: UInt16         = 0xC614
    public static let localizedCameraModel: UInt16      = 0xC615
    public static let cfaPlaneColor: UInt16             = 0xC616
    public static let cfaLayout: UInt16                 = 0xC617
    public static let blackLevelRepeatDim: UInt16       = 0xC619
    public static let blackLevel: UInt16                = 0xC61A
    public static let whiteLevel: UInt16                = 0xC61D
    public static let defaultScale: UInt16              = 0xC61E
    public static let defaultCropOrigin: UInt16         = 0xC61F
    public static let defaultCropSize: UInt16           = 0xC620
    public static let colorMatrix1: UInt16              = 0xC621
    public static let colorMatrix2: UInt16              = 0xC622
    public static let cameraCalibration1: UInt16       = 0xC623
    public static let cameraCalibration2: UInt16       = 0xC624
    public static let analogBalance: UInt16             = 0xC627
    public static let asShotNeutral: UInt16             = 0xC628
    public static let asShotWhiteXY: UInt16             = 0xC629
    public static let baselineExposure: UInt16          = 0xC62A
    public static let baselineNoise: UInt16             = 0xC62B
    public static let baselineSharpness: UInt16         = 0xC62C
    public static let bayerGreenSplit: UInt16           = 0xC62D
    public static let linearResponseLimit: UInt16       = 0xC62E
    public static let cameraSerialNumber: UInt16        = 0xC62F
    public static let antiAliasStrength: UInt16         = 0xC632
    public static let shadowScale: UInt16               = 0xC633
    public static let calibrationIlluminant1: UInt16    = 0xC65A
    public static let calibrationIlluminant2: UInt16    = 0xC65B
    public static let bestQualityScale: UInt16          = 0xC65C
    public static let rawDataUniqueID: UInt16           = 0xC65D
    public static let originalRawFileName: UInt16       = 0xC68B
    public static let activeArea: UInt16                = 0xC68D
    public static let colorimetricReference: UInt16     = 0xC6BF
    public static let profileName: UInt16               = 0xC6F8
    public static let profileHueSatMapDims: UInt16      = 0xC6F9
    public static let profileEmbedPolicy: UInt16        = 0xC6FD
    public static let profileCopyright: UInt16          = 0xC6FE
    public static let previewApplicationName: UInt16    = 0xC716
    public static let previewApplicationVersion: UInt16 = 0xC717
    public static let previewSettingsName: UInt16       = 0xC718
    public static let profileLookTableDims: UInt16      = 0xC725
    public static let profileLookTableData: UInt16      = 0xC726
    public static let opcodeList1: UInt16               = 0xC740
    public static let opcodeList2: UInt16               = 0xC741
    public static let opcodeList3: UInt16               = 0xC74E
    public static let noiseProfile: UInt16              = 0xC761
    public static let baselineExposureOffset: UInt16    = 0xC7A5
    public static let defaultUserCrop: UInt16           = 0xC7B5
}

/// Extract DNG private tags from a TIFF file's IFD0.
public struct DNGMetadataReader: Sendable {
    public static func read(from tiffFile: TIFFFile) -> DNGMetadata? {
        guard let ifd0 = tiffFile.ifd0,
              ifd0.hasEntry(for: DNGTag.dngVersion) else { return nil }
        let endian = tiffFile.header.byteOrder

        return DNGMetadata(
            dngVersion: versionString(ifd0[DNGTag.dngVersion]),
            dngBackwardVersion: versionString(ifd0[DNGTag.dngBackwardVersion]),
            uniqueCameraModel: ifd0[DNGTag.uniqueCameraModel]?.stringValue(),
            localizedCameraModel: ifd0[DNGTag.localizedCameraModel]?.stringValue(),
            cameraSerialNumber: ifd0[DNGTag.cameraSerialNumber]?.stringValue(),
            calibrationIlluminant1: ifd0[DNGTag.calibrationIlluminant1]?.uint16Value(endian: endian),
            calibrationIlluminant2: ifd0[DNGTag.calibrationIlluminant2]?.uint16Value(endian: endian),
            colorMatrix1: srationals(ifd0[DNGTag.colorMatrix1], endian: endian, count: 9),
            colorMatrix2: srationals(ifd0[DNGTag.colorMatrix2], endian: endian, count: 9),
            cameraCalibration1: srationals(ifd0[DNGTag.cameraCalibration1], endian: endian, count: 9),
            cameraCalibration2: srationals(ifd0[DNGTag.cameraCalibration2], endian: endian, count: 9),
            analogBalance: rationals(ifd0[DNGTag.analogBalance], endian: endian),
            asShotNeutral: rationals(ifd0[DNGTag.asShotNeutral], endian: endian),
            asShotWhiteXY: rationals(ifd0[DNGTag.asShotWhiteXY], endian: endian, count: 2),
            baselineExposure: srationalScalar(ifd0[DNGTag.baselineExposure], endian: endian),
            baselineNoise: rationalScalar(ifd0[DNGTag.baselineNoise], endian: endian),
            baselineSharpness: rationalScalar(ifd0[DNGTag.baselineSharpness], endian: endian),
            bayerGreenSplit: ifd0[DNGTag.bayerGreenSplit]?.uint32Value(endian: endian),
            linearResponseLimit: rationalScalar(ifd0[DNGTag.linearResponseLimit], endian: endian),
            antiAliasStrength: rationalScalar(ifd0[DNGTag.antiAliasStrength], endian: endian),
            shadowScale: rationalScalar(ifd0[DNGTag.shadowScale], endian: endian),
            bestQualityScale: rationalScalar(ifd0[DNGTag.bestQualityScale], endian: endian),
            cfaPlaneColor: cfaPlaneColorString(ifd0[DNGTag.cfaPlaneColor]),
            cfaLayout: ifd0[DNGTag.cfaLayout]?.uint16Value(endian: endian),
            blackLevelRepeatDim: numericArray(ifd0[DNGTag.blackLevelRepeatDim], endian: endian, count: 2),
            blackLevel: numericArray(ifd0[DNGTag.blackLevel], endian: endian),
            whiteLevel: numericArray(ifd0[DNGTag.whiteLevel], endian: endian),
            defaultScale: numericArray(ifd0[DNGTag.defaultScale], endian: endian, count: 2),
            activeArea: numericArray(ifd0[DNGTag.activeArea], endian: endian, count: 4),
            defaultUserCrop: numericArray(ifd0[DNGTag.defaultUserCrop], endian: endian, count: 4),
            defaultCropOrigin: numericArray(ifd0[DNGTag.defaultCropOrigin], endian: endian, count: 2),
            defaultCropSize: numericArray(ifd0[DNGTag.defaultCropSize], endian: endian, count: 2),
            cfaRepeatPatternDim: numericArray(ifd0[DNGTag.cfaRepeatPatternDim], endian: endian, count: 2),
            profileName: ifd0[DNGTag.profileName]?.stringValue(),
            profileCopyright: ifd0[DNGTag.profileCopyright]?.stringValue(),
            previewApplicationName: ifd0[DNGTag.previewApplicationName]?.stringValue(),
            previewApplicationVersion: ifd0[DNGTag.previewApplicationVersion]?.stringValue(),
            previewSettingsName: ifd0[DNGTag.previewSettingsName]?.stringValue(),
            originalRawFileName: ifd0[DNGTag.originalRawFileName]?.stringValue(),
            rawDataUniqueID: hexString(ifd0[DNGTag.rawDataUniqueID]?.valueData, length: 16),
            colorimetricReference: ifd0[DNGTag.colorimetricReference]?.uint16Value(endian: endian),
            profileEmbedPolicy: ifd0[DNGTag.profileEmbedPolicy]?.uint32Value(endian: endian),
            profileHueSatMapDims: longArray(ifd0[DNGTag.profileHueSatMapDims], endian: endian, count: 3),
            profileLookTableDims: longArray(ifd0[DNGTag.profileLookTableDims], endian: endian, count: 3),
            noiseProfile: doubleArray(ifd0[DNGTag.noiseProfile], endian: endian),
            baselineExposureOffset: srationalScalar(ifd0[DNGTag.baselineExposureOffset], endian: endian),
            opcodeList1Size: byteCount(ifd0[DNGTag.opcodeList1]),
            opcodeList2Size: byteCount(ifd0[DNGTag.opcodeList2]),
            opcodeList3Size: byteCount(ifd0[DNGTag.opcodeList3]),
            profileLookTableSampleCount: floatCount(ifd0[DNGTag.profileLookTableData])
        )
    }

    // MARK: - Helpers

    /// Decode a 4-byte version tag like [1, 4, 0, 0] → "1.4.0.0".
    private static func versionString(_ entry: IFDEntry?) -> String? {
        guard let entry = entry, entry.type == .byte, entry.count == 4,
              entry.valueData.count >= 4 else { return nil }
        let s = entry.valueData.startIndex
        let b = entry.valueData
        return "\(b[s]).\(b[s + 1]).\(b[s + 2]).\(b[s + 3])"
    }

    /// Decode an array of s-rational pairs, optionally requiring an exact count.
    private static func srationals(_ entry: IFDEntry?, endian: ByteOrder, count: Int? = nil) -> [Double]? {
        guard let entry = entry, entry.type == .srational else { return nil }
        if let c = count, Int(entry.count) != c { return nil }
        let total = Int(entry.count)
        guard entry.valueData.count >= total * 8 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(total)
        var reader = BinaryReader(data: entry.valueData)
        for _ in 0..<total {
            guard let num = try? reader.readInt32(endian: endian),
                  let den = try? reader.readInt32(endian: endian),
                  den != 0 else { return nil }
            result.append(Double(num) / Double(den))
        }
        return result
    }

    /// Decode an array of unsigned rational pairs.
    private static func rationals(_ entry: IFDEntry?, endian: ByteOrder, count: Int? = nil) -> [Double]? {
        guard let entry = entry, entry.type == .rational else { return nil }
        if let c = count, Int(entry.count) != c { return nil }
        let total = Int(entry.count)
        guard total > 0, entry.valueData.count >= total * 8 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(total)
        var reader = BinaryReader(data: entry.valueData)
        for _ in 0..<total {
            guard let num = try? reader.readUInt32(endian: endian),
                  let den = try? reader.readUInt32(endian: endian),
                  den != 0 else { return nil }
            result.append(Double(num) / Double(den))
        }
        return result
    }

    private static func srationalScalar(_ entry: IFDEntry?, endian: ByteOrder) -> Double? {
        guard let pair = entry?.srationalValue(endian: endian), pair.denominator != 0 else { return nil }
        return Double(pair.numerator) / Double(pair.denominator)
    }

    private static func rationalScalar(_ entry: IFDEntry?, endian: ByteOrder) -> Double? {
        guard let pair = entry?.rationalValue(endian: endian), pair.denominator != 0 else { return nil }
        return Double(pair.numerator) / Double(pair.denominator)
    }

    /// Decode a numeric array tag (SHORT/LONG/RATIONAL/SRATIONAL), coercing every
    /// element to Double. Used by the sensor-geometry tags (ActiveArea, BlackLevel,
    /// DefaultCropOrigin/Size, DefaultScale/UserCrop, …) whose element type and count
    /// vary by camera. Pass `count` to require an exact element count, or leave it nil
    /// to read all `entry.count` elements.
    private static func numericArray(_ entry: IFDEntry?, endian: ByteOrder, count: Int? = nil) -> [Double]? {
        guard let entry = entry else { return nil }
        let total = Int(entry.count)
        guard total > 0 else { return nil }
        if let c = count, total != c { return nil }
        // Validate the value bytes back the declared element count before
        // reserving — `entry.count` is an attacker-controlled UInt32, and
        // `reserveCapacity` allocates eagerly, so an oversized count would
        // otherwise force a huge allocation before the per-element reads bail.
        // Mirrors the guard in `srationals`/`rationals`/`longArray`/`doubleArray`.
        guard entry.valueData.count >= total * entry.type.unitSize else { return nil }
        var reader = BinaryReader(data: entry.valueData)
        var result: [Double] = []
        result.reserveCapacity(total)
        switch entry.type {
        case .short:
            for _ in 0..<total {
                guard let v = try? reader.readUInt16(endian: endian) else { return nil }
                result.append(Double(v))
            }
        case .long:
            for _ in 0..<total {
                guard let v = try? reader.readUInt32(endian: endian) else { return nil }
                result.append(Double(v))
            }
        case .rational:
            for _ in 0..<total {
                guard let num = try? reader.readUInt32(endian: endian),
                      let den = try? reader.readUInt32(endian: endian), den != 0 else { return nil }
                result.append(Double(num) / Double(den))
            }
        case .srational:
            for _ in 0..<total {
                guard let num = try? reader.readInt32(endian: endian),
                      let den = try? reader.readInt32(endian: endian), den != 0 else { return nil }
                result.append(Double(num) / Double(den))
            }
        default:
            return nil
        }
        return result
    }

    /// DNG CFAPlaneColor (BYTE array of color codes) → comma-joined names, e.g.
    /// `[0, 1, 2]` → "Red,Green,Blue".
    private static func cfaPlaneColorString(_ entry: IFDEntry?) -> String? {
        guard let entry = entry, entry.type == .byte, entry.count > 0,
              entry.valueData.count >= Int(entry.count) else { return nil }
        let names = ["Red", "Green", "Blue", "Cyan", "Magenta", "Yellow", "White"]
        let s = entry.valueData.startIndex
        let codes = entry.valueData[s ..< s + Int(entry.count)]
        return codes.map { code in
            Int(code) < names.count ? names[Int(code)] : "Color\(code)"
        }.joined(separator: ",")
    }

    private static func longArray(_ entry: IFDEntry?, endian: ByteOrder, count: Int) -> [UInt32]? {
        guard let entry = entry, entry.type == .long, Int(entry.count) == count else { return nil }
        guard entry.valueData.count >= count * 4 else { return nil }
        var reader = BinaryReader(data: entry.valueData)
        var result: [UInt32] = []
        for _ in 0..<count {
            guard let v = try? reader.readUInt32(endian: endian) else { return nil }
            result.append(v)
        }
        return result
    }

    /// NoiseProfile: 1-3 pairs of (a, b) IEEE 754 double-precision coefficients per channel.
    private static func doubleArray(_ entry: IFDEntry?, endian: ByteOrder) -> [Double]? {
        guard let entry = entry, entry.type == .double else { return nil }
        let count = Int(entry.count)
        guard count > 0, entry.valueData.count >= count * 8 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(count)
        var reader = BinaryReader(data: entry.valueData)
        for _ in 0..<count {
            guard let raw = try? reader.readUInt64(endian: endian) else { return nil }
            result.append(Double(bitPattern: raw))
        }
        return result
    }

    /// 16-byte raw digest → 32-char hex string.
    private static func hexString(_ data: Data?, length: Int) -> String? {
        guard let data = data, data.count >= length else { return nil }
        let s = data.startIndex
        return data[s ..< s + length].map { String(format: "%02x", $0) }.joined()
    }

    /// Number of bytes carried by an UNDEFINED-typed tag (opcode lists).
    private static func byteCount(_ entry: IFDEntry?) -> Int? {
        guard let entry = entry, entry.type == .undefined, entry.count > 0 else { return nil }
        return Int(entry.count)
    }

    /// Number of float samples in a FLOAT-typed look-table tag.
    private static func floatCount(_ entry: IFDEntry?) -> Int? {
        guard let entry = entry, entry.type == .float, entry.count > 0 else { return nil }
        return Int(entry.count)
    }
}
