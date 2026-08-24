import Foundation

/// Parser for Sony MakerNote data.
/// Sony MakerNotes may have a "SONY DSC \0\0\0" or "SONY CAM \0\0\0" prefix (12 bytes)
/// followed by a standard IFD, or start directly with an IFD.
///
/// Tag IDs match ExifTool's `Sony.pm`. The 0xB0xx range is the modern Alpha / RX / FX
/// block; the 0x10xx range is the older Cyber-shot / multi-burst block; 0x2xxx is shared
/// shooting-settings block used across most modern bodies.
struct SonyMakerNote: Sendable {

    // 0x01xx — older Cyber-shot / Minolta-derived
    private static let quality:                UInt16 = 0x0102
    private static let flashExposureComp:      UInt16 = 0x0104
    private static let teleconverter:          UInt16 = 0x0105
    private static let whiteBalanceFineTune:   UInt16 = 0x0112
    private static let multiBurstMode:         UInt16 = 0x1000
    private static let multiBurstImageWidth:   UInt16 = 0x1001
    private static let multiBurstImageHeight:  UInt16 = 0x1002
    private static let panorama:               UInt16 = 0x1003

    // 0x2xxx — modern shooting-settings block. Tag IDs and names verified against
    // ExifTool's Sony.pm Main table (directly-readable scalar entries only;
    // SubDirectory blocks like 0x2010 / 0x9xxx are not decoded here).
    private static let rating:                        UInt16 = 0x2002
    private static let contrast:                      UInt16 = 0x2004
    private static let saturation:                    UInt16 = 0x2005
    private static let sharpness:                     UInt16 = 0x2006
    private static let brightness:                    UInt16 = 0x2007
    private static let longExposureNR2:               UInt16 = 0x2008
    private static let highISONoiseReduction:         UInt16 = 0x2009
    private static let hdr:                           UInt16 = 0x200A
    private static let multiFrameNoiseReduction:      UInt16 = 0x200B
    private static let pictureEffect:                 UInt16 = 0x200E
    private static let softSkinEffect:                UInt16 = 0x200F
    private static let vignettingCorrection:          UInt16 = 0x2011
    private static let lateralChromaticAberration:    UInt16 = 0x2012
    private static let distortionCorrectionSetting:   UInt16 = 0x2013
    private static let wbShiftABGM:                   UInt16 = 0x2014
    private static let autoPortraitFramed:            UInt16 = 0x2016
    private static let flashAction:                   UInt16 = 0x2017
    private static let electronicFrontCurtainShutter: UInt16 = 0x201A
    private static let multiFrameNREffect:            UInt16 = 0x2023
    private static let focusLocation:                 UInt16 = 0x2027
    private static let rawFileType:                   UInt16 = 0x2029
    private static let prioritySetInAWB:              UInt16 = 0x202B
    private static let meteringMode2:                 UInt16 = 0x202C
    private static let shadows:                       UInt16 = 0x2032
    private static let highlights:                    UInt16 = 0x2033
    private static let fade:                          UInt16 = 0x2034
    private static let sharpnessRange:                UInt16 = 0x2035
    private static let clarity:                       UInt16 = 0x2036
    private static let jpegHEIFSwitch:                UInt16 = 0x2039
    private static let focusLocation2:                UInt16 = 0x204A

    // 0xB0xx — Alpha / RX / FX top-level block.
    // 0xB020 is an ASCII string holding the creative-style / color-reproduction
    // preset ("Standard", "Vivid", "AdobeRGB", …) per ExifTool's Sony.pm. It is
    // NOT a serial number — the body serial lives in ExifIFD tag 0xA431.
    private static let creativeStyle:          UInt16 = 0xB020
    private static let colorTemperature:       UInt16 = 0xB021
    private static let colorCompensationFilter: UInt16 = 0xB022
    private static let sceneMode:              UInt16 = 0xB023
    private static let zoneMatching:           UInt16 = 0xB024
    private static let dynamicRangeOptimizer:  UInt16 = 0xB025
    private static let imageStabilization:     UInt16 = 0xB026
    private static let lensType:               UInt16 = 0xB027
    private static let colorMode:              UInt16 = 0xB029
    private static let fullImageSize:          UInt16 = 0xB02B
    private static let previewImageSize:       UInt16 = 0xB02C
    private static let macro:                  UInt16 = 0xB040
    private static let exposureMode:           UInt16 = 0xB041
    private static let focusMode:              UInt16 = 0xB042
    private static let afAreaMode:             UInt16 = 0xB043
    private static let afIlluminator:          UInt16 = 0xB044
    private static let quality16:              UInt16 = 0xB047
    private static let flashLevel:             UInt16 = 0xB048
    private static let releaseMode:            UInt16 = 0xB049
    private static let antiBlur:               UInt16 = 0xB04B
    private static let longExposureNR:         UInt16 = 0xB04E
    private static let dynamicRangeOptimizer2: UInt16 = 0xB04F
    private static let intelligentAuto:        UInt16 = 0xB052
    private static let whiteBalance:           UInt16 = 0xB054

    private static let sonyDSCPrefix = Data("SONY DSC \0\0\0".utf8)
    private static let sonyCAMPrefix = Data("SONY CAM \0\0\0".utf8)

    /// Parse a Sony MakerNote.
    /// - Parameters:
    ///   - data: the verbatim MakerNote value bytes (the 0x927C entry value).
    ///   - byteOrder: the parent TIFF byte order.
    ///   - makerNoteTIFFOffset: the TIFF-relative offset at which `data` begins in
    ///     the originating file (i.e. the MakerNote entry's value offset). Modern
    ///     Sony ("Sony5") MakerNotes store out-of-line value pointers as offsets
    ///     from the TIFF header, not from the start of the MakerNote block. Passing
    ///     the block's own TIFF-relative offset lets us rebase those pointers back
    ///     into `data`. Defaults to 0 for callers that hand us a self-contained,
    ///     block-relative MakerNote.
    static func parse(data: Data, byteOrder: ByteOrder, makerNoteTIFFOffset: Int = 0) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // Detect prefix and determine IFD start
        let ifdStart: Int
        if data.count > 12 && (data.prefix(9) == Data("SONY DSC ".utf8) || data.prefix(9) == Data("SONY CAM ".utf8)) {
            ifdStart = 12
        } else {
            ifdStart = 0
        }

        guard ifdStart < data.count else { return tags }

        // Resolve the offset base. Out-of-line value pointers are either
        // block-relative (some older notes, and our synthetic test fixtures) or
        // TIFF-absolute (modern Sony5 bodies). For the absolute case, the correct
        // index into `data` is `pointer - makerNoteTIFFOffset`, which we model by
        // parsing with a negative `tiffStart`. We pick whichever base keeps every
        // out-of-line value in bounds, preferring block-relative.
        let tiffStart = resolveOffsetBase(
            data: data, ifdStart: ifdStart, endian: byteOrder,
            makerNoteTIFFOffset: makerNoteTIFFOffset
        )

        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: tiffStart, offset: ifdStart, endian: byteOrder
        ) else { return tags }

        // ---- Creative style ------------------------------------------------------------
        if let entry = ifd.entry(for: creativeStyle),
           let value = entry.stringValue(endian: byteOrder) {
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "\0").union(.whitespaces)
            )
            if !trimmed.isEmpty { tags["CreativeStyle"] = .string(trimmed) }
        }

        // ---- Lens info -----------------------------------------------------------------
        if let value = scalar(ifd, lensType, endian: byteOrder) {
            tags["LensType"] = .int(value)
            if let name = sonyLensTypeNames[UInt16(clamping: value)] {
                tags["LensTypeName"] = .string(name)
            }
        }

        // ---- 0x01xx range --------------------------------------------------------------
        if let v = scalar(ifd, quality, endian: byteOrder) { tags["Quality"] = .int(v) }
        if let entry = ifd.entry(for: flashExposureComp), entry.type == .srational,
           let (num, den) = entry.srationalValue(endian: byteOrder), den != 0 {
            tags["FlashExposureComp"] = .double(Double(num) / Double(den))
        }
        if let v = scalar(ifd, teleconverter, endian: byteOrder) { tags["Teleconverter"] = .int(v) }
        if let v = scalar(ifd, whiteBalanceFineTune, endian: byteOrder) { tags["WhiteBalanceFineTune"] = .int(v) }
        if let v = scalar(ifd, multiBurstMode, endian: byteOrder) { tags["MultiBurstMode"] = .int(v) }
        if let v = scalar(ifd, multiBurstImageWidth, endian: byteOrder) { tags["MultiBurstImageWidth"] = .int(v) }
        if let v = scalar(ifd, multiBurstImageHeight, endian: byteOrder) { tags["MultiBurstImageHeight"] = .int(v) }
        if let v = scalar(ifd, panorama, endian: byteOrder) { tags["Panorama"] = .int(v) }

        // ---- 0x2xxx range --------------------------------------------------------------
        if let v = scalar(ifd, rating, endian: byteOrder) { tags["Rating"] = .int(v) }
        if let v = scalar(ifd, contrast, endian: byteOrder) { tags["Contrast"] = .int(v) }
        if let v = scalar(ifd, saturation, endian: byteOrder) { tags["Saturation"] = .int(v) }
        if let v = scalar(ifd, sharpness, endian: byteOrder) { tags["Sharpness"] = .int(v) }
        if let v = scalar(ifd, brightness, endian: byteOrder) { tags["Brightness"] = .int(v) }
        if let v = scalar(ifd, longExposureNR2, endian: byteOrder) { tags["LongExposureNoiseReduction"] = .int(v) }
        if let v = scalar(ifd, highISONoiseReduction, endian: byteOrder) { tags["HighISONoiseReduction"] = .int(v) }
        if let v = scalar(ifd, hdr, endian: byteOrder) { tags["HDR"] = .int(v) }
        if let v = scalar(ifd, multiFrameNoiseReduction, endian: byteOrder) { tags["MultiFrameNoiseReduction"] = .int(v) }
        if let v = scalar(ifd, pictureEffect, endian: byteOrder) { tags["PictureEffect"] = .int(v) }
        if let v = scalar(ifd, softSkinEffect, endian: byteOrder) { tags["SoftSkinEffect"] = .int(v) }
        if let v = scalar(ifd, vignettingCorrection, endian: byteOrder) { tags["VignettingCorrection"] = .int(v) }
        if let v = scalar(ifd, lateralChromaticAberration, endian: byteOrder) { tags["LateralChromaticAberration"] = .int(v) }
        if let v = scalar(ifd, distortionCorrectionSetting, endian: byteOrder) { tags["DistortionCorrectionSetting"] = .int(v) }
        if let v = signedArray(ifd, wbShiftABGM, endian: byteOrder), v.count >= 2 {
            tags["WBShiftAB_GM"] = .intArray(Array(v.prefix(2)))
        }
        if let v = scalar(ifd, autoPortraitFramed, endian: byteOrder) { tags["AutoPortraitFramed"] = .int(v) }
        if let v = scalar(ifd, flashAction, endian: byteOrder) { tags["FlashAction"] = .int(v) }
        if let v = scalar(ifd, electronicFrontCurtainShutter, endian: byteOrder) { tags["ElectronicFrontCurtainShutter"] = .int(v) }
        if let v = scalar(ifd, multiFrameNREffect, endian: byteOrder) { tags["MultiFrameNREffect"] = .int(v) }
        if let v = signedArray(ifd, focusLocation, endian: byteOrder), v.count >= 4 {
            tags["FocusLocation"] = .intArray(Array(v.prefix(4)))
        }
        if let v = scalar(ifd, rawFileType, endian: byteOrder) { tags["RAWFileType"] = .int(v) }
        if let v = scalar(ifd, prioritySetInAWB, endian: byteOrder) { tags["PrioritySetInAWB"] = .int(v) }
        if let v = scalar(ifd, meteringMode2, endian: byteOrder) { tags["MeteringMode2"] = .int(v) }
        if let v = scalar(ifd, shadows, endian: byteOrder) { tags["Shadows"] = .int(v) }
        if let v = scalar(ifd, highlights, endian: byteOrder) { tags["Highlights"] = .int(v) }
        if let v = scalar(ifd, fade, endian: byteOrder) { tags["Fade"] = .int(v) }
        if let v = scalar(ifd, sharpnessRange, endian: byteOrder) { tags["SharpnessRange"] = .int(v) }
        if let v = scalar(ifd, clarity, endian: byteOrder) { tags["Clarity"] = .int(v) }
        if let v = scalar(ifd, jpegHEIFSwitch, endian: byteOrder) { tags["JPEG-HEIFSwitch"] = .int(v) }
        if let v = signedArray(ifd, focusLocation2, endian: byteOrder), v.count >= 4 {
            tags["FocusLocation2"] = .intArray(Array(v.prefix(4)))
        }

        // ---- 0xB0xx range --------------------------------------------------------------
        if let v = scalar(ifd, sceneMode, endian: byteOrder) { tags["SceneMode"] = .int(v) }
        if let v = scalar(ifd, colorTemperature, endian: byteOrder) { tags["ColorTemperature"] = .int(v) }
        if let v = scalar(ifd, colorCompensationFilter, endian: byteOrder) { tags["ColorCompensationFilter"] = .int(v) }
        if let v = scalar(ifd, zoneMatching, endian: byteOrder) { tags["ZoneMatching"] = .int(v) }
        if let v = scalar(ifd, dynamicRangeOptimizer, endian: byteOrder) { tags["DynamicRangeOptimizer"] = .int(v) }
        if let v = scalar(ifd, imageStabilization, endian: byteOrder) { tags["ImageStabilization"] = .int(v) }
        if let v = scalar(ifd, colorMode, endian: byteOrder) { tags["ColorMode"] = .int(v) }
        if let entry = ifd.entry(for: fullImageSize), entry.type == .short {
            let v = entry.uint16Values(endian: byteOrder)
            if v.count >= 2 { tags["FullImageSize"] = .string("\(v[1])x\(v[0])") }
        }
        if let entry = ifd.entry(for: previewImageSize), entry.type == .short {
            let v = entry.uint16Values(endian: byteOrder)
            if v.count >= 2 { tags["PreviewImageSize"] = .string("\(v[1])x\(v[0])") }
        }
        if let v = scalar(ifd, macro, endian: byteOrder) { tags["Macro"] = .int(v) }
        if let v = scalar(ifd, exposureMode, endian: byteOrder) { tags["ExposureMode"] = .int(v) }
        if let v = scalar(ifd, focusMode, endian: byteOrder) { tags["FocusMode"] = .int(v) }
        if let v = scalar(ifd, afAreaMode, endian: byteOrder) { tags["AFAreaMode"] = .int(v) }
        if let v = scalar(ifd, afIlluminator, endian: byteOrder) { tags["AFIlluminator"] = .int(v) }
        if let v = scalar(ifd, quality16, endian: byteOrder) { tags["Quality"] = .int(v) }
        if let v = scalar(ifd, flashLevel, endian: byteOrder) { tags["FlashLevel"] = .int(v) }
        if let v = scalar(ifd, releaseMode, endian: byteOrder) { tags["ReleaseMode"] = .int(v) }
        if let v = scalar(ifd, antiBlur, endian: byteOrder) { tags["AntiBlur"] = .int(v) }
        // 0xB04E is an older alias; don't let it clobber the 0x2008 reading above.
        if tags["LongExposureNoiseReduction"] == nil,
           let v = scalar(ifd, longExposureNR, endian: byteOrder) { tags["LongExposureNoiseReduction"] = .int(v) }
        if let v = scalar(ifd, dynamicRangeOptimizer2, endian: byteOrder) { tags["DynamicRangeOptimizerSetting"] = .int(v) }
        if let v = scalar(ifd, intelligentAuto, endian: byteOrder) { tags["IntelligentAuto"] = .int(v) }
        if let v = scalar(ifd, whiteBalance, endian: byteOrder) { tags["WhiteBalance"] = .int(v) }

        return tags
    }

    // MARK: - Helpers

    /// Read a scalar integer from a Sony tag regardless of its declared integer
    /// width or signedness (byte/short/long, signed or unsigned). Returns nil for
    /// absent or non-integer (string/rational/undefined) entries. Tolerating the
    /// width matters: e.g. `HighISONoiseReduction` is int16u while many siblings
    /// are int32u, and a fixed-width read would silently drop the mismatched ones.
    private static func scalar(_ ifd: IFD, _ tag: UInt16, endian: ByteOrder) -> Int? {
        guard let e = ifd.entry(for: tag) else { return nil }
        var r = BinaryReader(data: e.valueData)
        switch e.type {
        case .byte:   return (try? r.readUInt8()).map { Int($0) }
        case .sbyte:  return (try? r.readUInt8()).map { Int(Int8(bitPattern: $0)) }
        case .short:  return (try? r.readUInt16(endian: endian)).map { Int($0) }
        case .sshort: return (try? r.readInt16(endian: endian)).map { Int($0) }
        case .long:   return (try? r.readUInt32(endian: endian)).map { Int($0) }
        case .slong:  return (try? r.readInt32(endian: endian)).map { Int($0) }
        default:      return nil
        }
    }

    /// Read every element of an integer array tag, per the entry's declared width
    /// and signedness. Returns nil for absent or non-integer entries.
    private static func signedArray(_ ifd: IFD, _ tag: UInt16, endian: ByteOrder) -> [Int]? {
        guard let e = ifd.entry(for: tag) else { return nil }
        var r = BinaryReader(data: e.valueData)
        var out: [Int] = []
        for _ in 0..<Int(e.count) {
            let v: Int?
            switch e.type {
            case .byte:   v = (try? r.readUInt8()).map { Int($0) }
            case .sbyte:  v = (try? r.readUInt8()).map { Int(Int8(bitPattern: $0)) }
            case .short:  v = (try? r.readUInt16(endian: endian)).map { Int($0) }
            case .sshort: v = (try? r.readInt16(endian: endian)).map { Int($0) }
            case .long:   v = (try? r.readUInt32(endian: endian)).map { Int($0) }
            case .slong:  v = (try? r.readInt32(endian: endian)).map { Int($0) }
            default:      return nil
            }
            guard let vv = v else { break }
            out.append(vv)
        }
        return out.isEmpty ? nil : out
    }

    /// Determine the `tiffStart` to feed `IFDParser` so that out-of-line value
    /// pointers land inside `data`. Returns 0 for block-relative pointers, or
    /// `-makerNoteTIFFOffset` for TIFF-absolute pointers (Sony5). Walks the IFD
    /// header (always readable inline) and checks which base keeps every
    /// out-of-line value within bounds, preferring block-relative on a tie.
    private static func resolveOffsetBase(
        data: Data, ifdStart: Int, endian: ByteOrder, makerNoteTIFFOffset: Int
    ) -> Int {
        // Without a base offset, the two interpretations coincide.
        guard makerNoteTIFFOffset > 0 else { return 0 }

        var reader = BinaryReader(data: data)
        guard (try? reader.seek(to: ifdStart)) != nil,
              let count = try? reader.readUInt16(endian: endian) else { return 0 }

        let blobLen = data.count
        var blockRelativeOK = true
        var absoluteOK = true
        var sawOutOfLine = false

        for _ in 0..<count {
            guard let _ = try? reader.readUInt16(endian: endian),          // tag
                  let typeRaw = try? reader.readUInt16(endian: endian),
                  let valueCount = try? reader.readUInt32(endian: endian),
                  let valueOrOffset = try? reader.readBytes(4) else { return 0 }

            guard let type = TIFFDataType(rawValue: typeRaw) else { continue }
            let totalSize = Int(valueCount) * type.unitSize
            guard totalSize > 4 else { continue }   // inline — base-independent

            sawOutOfLine = true
            var offsetReader = BinaryReader(data: valueOrOffset)
            guard let pointer = try? offsetReader.readUInt32(endian: endian) else { return 0 }
            let ptr = Int(pointer)

            if ptr < 0 || ptr + totalSize > blobLen { blockRelativeOK = false }
            let absIdx = ptr - makerNoteTIFFOffset
            if absIdx < 0 || absIdx + totalSize > blobLen { absoluteOK = false }
        }

        if !sawOutOfLine { return 0 }
        if blockRelativeOK { return 0 }
        if absoluteOK { return -makerNoteTIFFOffset }
        return 0
    }

    /// Human-readable names for common Sony LensType IDs. Curated from ExifTool's table —
    /// not exhaustive, focused on FE-mount lenses commonly used by Scandinavian press
    /// photographers plus a handful of A-mount staples. Add IDs as they show up in real files.
    static let sonyLensTypeNames: [UInt16: String] = [
        0:    "Minolta AF 28-85mm F3.5-4.5",
        1:    "Minolta AF 80-200mm F2.8 HS-APO G",
        2:    "Minolta AF 28-70mm F2.8 G",
        16:   "Sony 70-200mm F2.8 G SSM",
        18:   "Sony DT 18-250mm F3.5-6.3",
        25:   "Sony DT 18-200mm F3.5-6.3",
        27:   "Sony 70-400mm F4-5.6 G SSM",
        32:   "Sony 500mm F4 G SSM",
        33:   "Sony FE 24-70mm F4 ZA OSS",
        49:   "Sony FE 55mm F1.8 ZA",
        50:   "Sony FE 28-70mm F3.5-5.6 OSS",
        51:   "Sony FE 35mm F2.8 ZA",
        53:   "Sony FE 24-240mm F3.5-6.3 OSS",
        54:   "Sony FE 70-200mm F4 G OSS",
        56:   "Sony FE 16-35mm F4 ZA OSS",
        57:   "Sony FE 90mm F2.8 Macro G OSS",
        58:   "Sony FE 28mm F2",
        59:   "Sony FE 28-135mm F4 G OSS",
        61:   "Sony LA-EA1/3 Adapter",
        62:   "Sony LA-EA2/4 Adapter",
        63:   "Sony FE 35mm F1.4 ZA",
        64:   "Sony FE 24-70mm F2.8 GM",
        65:   "Sony FE 70-200mm F2.8 GM OSS",
        66:   "Sony FE 85mm F1.4 GM",
        67:   "Sony FE 50mm F1.8",
        68:   "Sony FE 50mm F2.8 Macro",
        69:   "Sony FE 100mm F2.8 STF GM OSS",
        70:   "Sony FE 100-400mm F4.5-5.6 GM OSS",
        71:   "Sony FE 16-35mm F2.8 GM",
        72:   "Sony FE 12-24mm F4 G",
        73:   "Sony FE 400mm F2.8 GM OSS",
        74:   "Sony FE 24mm F1.4 GM",
        75:   "Sony FE 135mm F1.8 GM",
        76:   "Sony FE 200-600mm F5.6-6.3 G OSS",
        77:   "Sony FE 600mm F4 GM OSS",
        78:   "Sony FE 35mm F1.8",
        79:   "Sony FE 20mm F1.8 G",
        80:   "Sony FE 12-24mm F2.8 GM",
        81:   "Sony FE 50mm F1.2 GM",
        82:   "Sony FE 14mm F1.8 GM",
        83:   "Sony FE 24-70mm F2.8 GM II",
        84:   "Sony FE 70-200mm F2.8 GM OSS II",
    ]
}
