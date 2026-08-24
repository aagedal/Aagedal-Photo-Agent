import Foundation

/// Parser for Canon MakerNote data.
/// Canon MakerNotes use standard IFD format starting immediately (no header prefix).
/// Offsets are relative to the start of the MakerNote data.
///
/// Tag IDs and array indices match ExifTool's `Canon.pm` (Phil Harvey). Indices into the
/// CameraSettings/ShotInfo/AFInfo2/FileInfo/SensorInfo arrays use the same numbering as
/// ExifTool, where index 0 holds the byte-count marker and the named fields start at 1.
struct CanonMakerNote: Sendable {

    // Top-level Canon MakerNote tag IDs
    private static let cameraSettings: UInt16   = 0x0001
    private static let focalLength: UInt16      = 0x0002
    private static let shotInfo: UInt16         = 0x0004
    private static let serialNumber: UInt16     = 0x0006
    private static let firmwareVersion: UInt16  = 0x0007
    private static let fileNumber: UInt16       = 0x0008
    private static let ownerName: UInt16        = 0x0009
    private static let serialNumberAlt: UInt16  = 0x000C
    private static let modelID: UInt16          = 0x0010
    private static let afInfo2: UInt16          = 0x0026
    private static let fileInfo: UInt16         = 0x0093
    private static let lensModel: UInt16        = 0x0095
    private static let internalSerial: UInt16   = 0x0096
    private static let sensorInfo: UInt16       = 0x00E0

    /// Parse a raw Canon MakerNote blob (e.g. the JPEG/TIFF `0x927C` value),
    /// whose IFD starts immediately with offsets relative to the blob start.
    static func parse(data: Data, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        guard let (ifd, _) = try? IFDParser.parseIFD(
            data: data, tiffStart: 0, offset: 0, endian: byteOrder
        ) else { return [:] }
        return interpret(ifd: ifd, byteOrder: byteOrder)
    }

    /// Interpret an already-parsed Canon MakerNote IFD into named tags. Used by
    /// the CR3/CRM pipeline, where the MakerNotes arrive as the `CMT3` IFD with
    /// its out-of-line values already resolved, rather than as a raw blob.
    static func interpret(ifd: IFD, byteOrder: ByteOrder) -> [String: MakerNoteValue] {
        var tags: [String: MakerNoteValue] = [:]

        // ---- Scalar / string tags ------------------------------------------------------
        if let entry = ifd.entry(for: serialNumber),
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }
        if let entry = ifd.entry(for: firmwareVersion),
           let value = entry.stringValue(endian: byteOrder) {
            tags["FirmwareVersion"] = .string(value)
        }
        if let entry = ifd.entry(for: ownerName),
           let value = entry.stringValue(endian: byteOrder) {
            tags["OwnerName"] = .string(value)
        }
        if let entry = ifd.entry(for: lensModel),
           let value = entry.stringValue(endian: byteOrder) {
            tags["LensModel"] = .string(value)
        }
        if let entry = ifd.entry(for: internalSerial),
           let value = entry.stringValue(endian: byteOrder) {
            tags["InternalSerialNumber"] = .string(value)
        }
        if let entry = ifd.entry(for: modelID),
           let value = entry.uint32Value(endian: byteOrder) {
            tags["ModelID"] = .uint(UInt(value))
        }
        if let entry = ifd.entry(for: fileNumber),
           let value = entry.uint32Value(endian: byteOrder) {
            // Canon FileNumber encodes Folder*10000 + Image (e.g. 100_5678 -> 1005678).
            tags["FileNumber"] = .uint(UInt(value))
            let folder = Int(value) / 10000
            let image  = Int(value) % 10000
            if folder > 0 {
                tags["FileIndex"] = .string(String(format: "%03d-%04d", folder, image))
            }
        }
        if let entry = ifd.entry(for: serialNumberAlt),
           tags["SerialNumber"] == nil,
           let value = entry.stringValue(endian: byteOrder) {
            tags["SerialNumber"] = .string(value)
        }

        // ---- Array tags ----------------------------------------------------------------
        if let entry = ifd.entry(for: cameraSettings), entry.type == .short {
            parseCameraSettings(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: focalLength), entry.type == .short {
            parseFocalLength(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: shotInfo), entry.type == .short {
            parseShotInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: afInfo2), entry.type == .short {
            parseAFInfo2(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: fileInfo), entry.type == .short {
            parseFileInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }
        if let entry = ifd.entry(for: sensorInfo), entry.type == .short {
            parseSensorInfo(entry.uint16Values(endian: byteOrder), into: &tags)
        }

        return tags
    }

    // MARK: - CameraSettings (tag 0x0001)

    /// Index map matches ExifTool's CanonCameraSettings table. Most fields are signed Int16.
    private static func parseCameraSettings(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        if let v = signed(1)  { tags["MacroMode"]          = .int(Int(v)) }
        if let v = signed(2), v != 0 { tags["SelfTimer"]   = .int(Int(v)) }
        if let v = signed(3)  { tags["Quality"]            = .int(Int(v)) }
        if let v = signed(4)  { tags["CanonFlashMode"]     = .int(Int(v)) }
        if let v = signed(5)  { tags["ContinuousDrive"]    = .int(Int(v)) }
        if let v = signed(7)  { tags["FocusMode"]          = .int(Int(v)) }
        if let v = signed(9)  { tags["RecordMode"]         = .int(Int(v)) }
        if let v = signed(10) { tags["CanonImageSize"]     = .int(Int(v)) }
        if let v = signed(11) { tags["EasyMode"]           = .int(Int(v)) }
        if let v = signed(12) { tags["DigitalZoom"]        = .int(Int(v)) }
        if let v = signed(13) { tags["Contrast"]           = .int(Int(v)) }
        if let v = signed(14) { tags["Saturation"]         = .int(Int(v)) }
        if let v = signed(15), v != sentinel { tags["Sharpness"] = .int(Int(v)) }
        // CameraISO (16) is log/flag-encoded — see Canon.pm CameraISO(). 0x7fff means "n/a".
        if values.count > 16, let iso = cameraISO(values[16]) { tags["CameraISO"] = .int(iso) }
        if let v = signed(17) { tags["MeteringMode"]       = .int(Int(v)) }
        if let v = signed(18) { tags["FocusRange"]         = .int(Int(v)) }
        if let v = signed(19) { tags["AFPoint"]            = .int(Int(v)) }
        if let v = signed(20) { tags["CanonExposureMode"]  = .int(Int(v)) }
        if values.count > 22 {
            // LensType is an *unsigned* 16-bit Canon lens ID (e.g. 61182 marks an RF lens);
            // a raw signed Int16 mangles it. Look up the name in our subset of Canon.pm's
            // %canonLensTypes when known; the specific RF lens is also in LensModel (0x0095).
            let id = Int(values[22])
            tags["LensType"] = .int(id)
            if let name = lensTypeNames[id] { tags["LensTypeName"] = .string(name) }
        }
        if values.count > 25 {
            // Focal-length triplet: stored in "focal units per mm" — divide by units to get mm.
            let units = max(Int(values[25]), 1)
            tags["MaxFocalLength"] = .double(Double(values[23]) / Double(units))
            tags["MinFocalLength"] = .double(Double(values[24]) / Double(units))
            tags["FocalUnits"]     = .int(units)
        }
        // MaxAperture (26) / MinAperture (27) are Canon hex-EV codes — see Canon.pm.
        if values.count > 26, let a = apertureValue(values[26]) { tags["MaxAperture"] = .double(a) }
        if values.count > 27, let a = apertureValue(values[27]) { tags["MinAperture"] = .double(a) }
        if let v = signed(34) { tags["ImageStabilization"] = .int(Int(v)) }
    }

    /// 0x7fff is Canon's "n/a" sentinel for several signed Int16 CameraSettings fields.
    private static let sentinel = Int16(bitPattern: 0x7fff)

    // MARK: - FocalLength (tag 0x0002)

    /// This tag (Canon.pm FocalLength table, FIRST_ENTRY 0) is NOT prefixed with a count word.
    /// values[0] = FocalType (1=Fixed, 2=Zoom), values[1] = focal length in focal units.
    /// values[2]/[3] (FocalPlaneXSize/YSize) are intentionally not surfaced: they are only
    /// valid for a handful of old PowerShot/EOS models and need a 1/1000-inch→mm conversion,
    /// so on modern bodies the raw words are meaningless (see the Condition in Canon.pm).
    private static func parseFocalLength(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        if values.count > 0, values[0] > 0 { tags["FocalType"] = .int(Int(values[0])) }
        if values.count > 1, values[1] > 0 {
            let units = (tags["FocalUnits"].flatMap { if case .int(let u) = $0 { return u } else { return nil } }) ?? 1
            tags["FocalLength"] = .double(Double(values[1]) / Double(max(units, 1)))
        }
    }

    // MARK: - ShotInfo (tag 0x0004)

    /// Indices match ExifTool's CanonShotInfo. Values are Int16 except where noted.
    /// Note: ShutterCount is NOT in ShotInfo for most modern EOS bodies — use FileInfo (0x0093) instead.
    private static func parseShotInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        // AutoISO/BaseISO are log-encoded (Canon.pm: exp($val/32*log(2))*100 …), not raw ISO.
        if values.count > 1 { tags["AutoISO"] = .int(autoISO(values[1])) }
        if values.count > 2, let iso = baseISO(values[2]) { tags["BaseISO"] = .int(iso) }
        if let v = signed(3)  { tags["MeasuredEV"]           = .double(Double(v) / 32.0 + 5.0) }
        if let v = signed(7)  { tags["WhiteBalance"]         = .int(Int(v)) }
        if let v = signed(8)  { tags["SlowShutter"]          = .int(Int(v)) }
        if let v = signed(9), v >= 0 { tags["SequenceNumber"] = .int(Int(v)) }
        if let v = signed(12), v != 0 {
            // Encoded as Celsius + 128. Sentinel 0 means "unset".
            tags["CameraTemperature"] = .int(Int(v) - 128)
        }
        if let v = signed(13), v != -1 { tags["FlashGuideNumber"] = .double(Double(v) / 32.0) }
        if let v = signed(14) { tags["AFPointsInFocus"]      = .int(Int(v)) }
        // FlashExposureComp/AEBBracketValue are Canon hex-EV codes (CanonEv), not plain /32.
        if let v = signed(15) { tags["FlashExposureComp"]    = .double(canonEv(Int(v))) }
        if let v = signed(16) { tags["AutoExposureBracketing"] = .int(Int(v)) }
        if let v = signed(17) { tags["AEBBracketValue"]      = .double(canonEv(Int(v))) }
        if let v = signed(18) { tags["ControlMode"]          = .int(Int(v)) }
        // FocusDistance is stored unsigned in cm; convert to metres (Canon.pm ValueConv $val/100).
        if values.count > 20, values[19] > 0 {
            tags["FocusDistanceUpper"] = .double(Double(values[19]) / 100.0)
            tags["FocusDistanceLower"] = .double(Double(values[20]) / 100.0)
        }
        if let v = signed(33) { tags["FlashOutput"]          = .int(Int(v)) }
    }

    // MARK: - AFInfo2 (tag 0x0026)

    /// AFInfo2 is a ProcessSerialData record (Canon.pm), so the sequence index *is* the field
    /// position — index 0 is AFInfoSize, not a count word. Layout:
    /// 0: AFInfoSize (bytes), 1: AFAreaMode, 2: NumAFPoints, 3: ValidAFPoints,
    /// 4: CanonImageWidth, 5: CanonImageHeight, 6: AFImageWidth, 7: AFImageHeight, then
    /// per-point Width/Height/X/Y arrays. (Previously these were read one slot too late.)
    /// We surface the scalar header — per-point arrays are model-specific and rarely consumed.
    private static func parseAFInfo2(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        if let v = signed(1) { tags["AFAreaMode"]      = .int(Int(v)) }
        if let v = signed(2) { tags["NumAFPoints"]     = .int(Int(v)) }
        if let v = signed(3) { tags["ValidAFPoints"]   = .int(Int(v)) }
        if let v = signed(4), v > 0 { tags["CanonImageWidth"]  = .int(Int(v)) }
        if let v = signed(5), v > 0 { tags["CanonImageHeight"] = .int(Int(v)) }
        if let v = signed(6), v > 0 { tags["AFImageWidth"]  = .int(Int(v)) }
        if let v = signed(7), v > 0 { tags["AFImageHeight"] = .int(Int(v)) }
    }

    // MARK: - FileInfo (tag 0x0093)

    /// Modern EOS bodies store the actual shutter count in FileInfo[1] as a 32-bit value
    /// (two consecutive UInt16 words, low-word first). Other interesting fields:
    /// 3: BracketMode, 4: BracketValue, 5: BracketShotNumber, 6: RawJpgQuality,
    /// 7: RawJpgSize, 8: NoiseReduction, 19: LiveViewShooting.
    private static func parseFileInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        func signed(_ idx: Int) -> Int16? {
            guard idx < values.count else { return nil }
            return Int16(bitPattern: values[idx])
        }
        // FileNumber is a 32-bit value spanning indices 1 and 2 (low/high).
        if values.count > 2 {
            let combined = UInt32(values[1]) | (UInt32(values[2]) << 16)
            if combined > 0 { tags["ShutterCount"] = .int(Int(combined)) }
        }
        if let v = signed(3) { tags["BracketMode"]        = .int(Int(v)) }
        // Canon.pm `4 => 'BracketValue'` is a plain integer (no EV conversion).
        if let v = signed(4) { tags["BracketValue"]       = .int(Int(v)) }
        if let v = signed(5) { tags["BracketShotNumber"]  = .int(Int(v)) }
        if let v = signed(6) { tags["RawJpgQuality"]      = .int(Int(v)) }
        if let v = signed(7) { tags["RawJpgSize"]         = .int(Int(v)) }
        // Canon.pm index 8 is LongExposureNoiseReduction2; -1 is the "n/a" sentinel.
        if let v = signed(8), v != -1 { tags["LongExposureNoiseReduction2"] = .int(Int(v)) }
        if let v = signed(19) { tags["LiveViewShooting"]  = .int(Int(v)) }
        // FocusDistance (unsigned cm → metres). On bodies that fill these in, FileInfo is the
        // higher-priority source and overrides the ShotInfo copy parsed earlier.
        if values.count > 21, values[20] > 0 {
            tags["FocusDistanceUpper"] = .double(Double(values[20]) / 100.0)
            tags["FocusDistanceLower"] = .double(Double(values[21]) / 100.0)
        }
    }

    // MARK: - SensorInfo (tag 0x00E0)

    /// 1: SensorWidth, 2: SensorHeight, 5..8: SensorLeft/Top/Right/Bottom (active area).
    private static func parseSensorInfo(_ values: [UInt16], into tags: inout [String: MakerNoteValue]) {
        if values.count > 1, values[1] > 0 { tags["SensorWidth"]        = .int(Int(values[1])) }
        if values.count > 2, values[2] > 0 { tags["SensorHeight"]       = .int(Int(values[2])) }
        if values.count > 8 {
            tags["SensorLeftBorder"]   = .int(Int(values[5]))
            tags["SensorTopBorder"]    = .int(Int(values[6]))
            tags["SensorRightBorder"]  = .int(Int(values[7]))
            tags["SensorBottomBorder"] = .int(Int(values[8]))
        }
    }

    // MARK: - ExifTool Canon.pm conversions (GPL/Artistic, Phil Harvey)

    /// Canon hex-based EV decode (Canon.pm `CanonEv`): the low 5 bits are a fraction code,
    /// with 0x0c → 1/3 stop and 0x14 → 2/3 stop; everything else is in 1/32 increments.
    private static func canonEv(_ raw: Int) -> Double {
        let sign: Double = raw < 0 ? -1 : 1
        var val = abs(raw)
        let lowBits = val & 0x1f
        var frac = Double(lowBits)
        val -= lowBits
        if lowBits == 0x0c {                    // 1/3-stop code
            frac = Double(0x20) / 3.0
        } else if lowBits == 0x14 {             // 2/3-stop code
            frac = Double(0x40) / 3.0
        }
        return sign * (Double(val) + frac) / Double(0x20)
    }

    /// CanonShotInfo AutoISO (Canon.pm): `exp($val/32*log(2))*100`, rounded to a whole ISO.
    private static func autoISO(_ raw: UInt16) -> Int {
        let v = Double(Int16(bitPattern: raw))
        return Int((exp(v / 32.0 * log(2.0)) * 100.0).rounded())
    }

    /// CanonShotInfo BaseISO (Canon.pm): `exp($val/32*log(2))*100/32`; 0 means "unset".
    private static func baseISO(_ raw: UInt16) -> Int? {
        let signedRaw = Int16(bitPattern: raw)
        guard signedRaw != 0 else { return nil }
        return Int((exp(Double(signedRaw) / 32.0 * log(2.0)) * 100.0 / 32.0).rounded())
    }

    /// CameraSettings CameraISO (Canon.pm `CameraISO`): 0x7fff → n/a; if bit 0x4000 is set the
    /// low 14 bits are the ISO speed, otherwise a few fixed codes map to a numeric speed.
    private static func cameraISO(_ raw: UInt16) -> Int? {
        if raw == 0x7fff { return nil }
        if raw & 0x4000 != 0 { return Int(raw & 0x3fff) }
        switch raw {
        case 16: return 50
        case 17: return 100
        case 18: return 200
        case 19: return 400
        case 20: return 800
        default: return nil   // 0/14/15 are 'n/a'/'Auto' strings in ExifTool — no numeric value
        }
    }

    /// CameraSettings Max/MinAperture (Canon.pm): `exp(CanonEv($val)*log(2)/2)` = 2^(EV/2).
    private static func apertureValue(_ raw: UInt16) -> Double? {
        let v = Int16(bitPattern: raw)
        guard v > 0 else { return nil }
        return pow(2.0, canonEv(Int(v)) / 2.0)
    }

    /// Subset of Canon.pm's `%canonLensTypes`, keyed by the unsigned 16-bit lens ID. 61182 is the
    /// shared marker for native RF lenses (the specific model is also reported via LensModel),
    /// and 65535 is Canon's "n/a" sentinel. Extend as needed for EF/EF-S coverage.
    private static let lensTypeNames: [Int: String] = [
        61182: "Canon RF 50mm F1.2L USM or other Canon RF Lens",
        65535: "n/a",
    ]
}
