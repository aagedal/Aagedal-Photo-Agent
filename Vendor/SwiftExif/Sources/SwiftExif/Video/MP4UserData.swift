import Foundation

/// User-data parsing for MP4Parser: the udta/meta/ilst tree (including the
/// QuickTime mdta keys/values pair), GPS atoms, the XMP/NRT uuid box, and
/// the BRAW per-frame `bmdf` header reused by `BRAWFrameReader`.
///
/// Extracted from MP4Parser.swift to keep that file scannable. No behavior
/// change — every method here was previously a `private static` member of
/// `MP4Parser`; cross-file access is granted by relaxing those to internal
/// (the default visibility for `static func` in an extension).
extension MP4Parser {

    // MARK: - User Data (udta -> meta -> ilst)

    static func parseUDTA(_ data: Data, into metadata: inout VideoMetadata) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        if let meta = children.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // QuickTime user-data timecode atoms written by Sony/Panasonic/ARRI
        // broadcast camcorders directly under moov > udta (not under ilst):
        //   ©TIM / @TIM — UTF-8 timecode string (HH:MM:SS:FF)
        //   tmcd       — same 4-byte frame counter as the tmcd track form,
        //                using the following TimecodeSampleDescription
        //                layout. Rare in practice; ffprobe ignores it.
        //
        // ISOBMFF/QuickTime user-data text atoms have the layout
        // `UInt16 textSize + UInt16 language + UTF-8 text`. Some writers put
        // the raw UTF-8 string directly instead — detect both.
        for child in children {
            let type = child.type
            let isTimText = (type == "\u{00A9}TIM" || type == "@TIM")
            guard isTimText else { continue }
            if let tc = decodeUDTATextAtom(child.data) {
                metadata.recordTimecode(tc, source: .quicktimeUdta)
            }
        }
    }

    /// Decode a QuickTime user-data text atom payload, handling both the
    /// `UInt16 length + UInt16 language + UTF-8` shape and the bare-UTF-8
    /// shape some muxers emit. Returns nil when the payload doesn't look
    /// like printable text.
    static func decodeUDTATextAtom(_ data: Data) -> String? {
        guard data.count >= 1 else { return nil }

        // Prefer the `length + language + text` shape when the declared
        // length fits inside the payload. QuickTime uses this exact layout
        // for every ©xxx atom under moov > udta.
        if data.count >= 4 {
            let s = data.startIndex
            let len = (Int(data[s]) << 8) | Int(data[s + 1])
            if len > 0, data.count >= 4 + len {
                let textRange = (s + 4)..<(s + 4 + len)
                if let str = String(data: Data(data[textRange]), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    return str
                }
            }
        }

        // Fallback: raw UTF-8 (a handful of older Panasonic P2 files do this).
        if let str = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)),
           !str.isEmpty,
           str.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-:;. ".contains($0)) }) {
            return str
        }

        return nil
    }

    static func parseMetaBox(_ data: Data, into metadata: inout VideoMetadata) {
        // ISOBMFF (HEIF, iTunes) treats `meta` as a FullBox with a 4-byte
        // version+flags header in front of the children. QuickTime — used
        // by Blackmagic RAW and some camera-original .mov writers — emits
        // `meta` as a regular Box where children start at offset 0.
        // Detect by sniffing: in the FullBox layout, bytes 4..7 are the first
        // child's *size* (a binary number), and in the QuickTime layout
        // they're the first child's *type* (ASCII). When 4..7 looks like an
        // ASCII box type, we're in QT mode and the 4-byte skip is wrong.
        guard data.count >= 8 else { return }
        let firstChildTypeRange = data.startIndex + 4 ..< data.startIndex + 8
        let isQuickTimeLayout = isLikelyBoxType(data.subdata(in: firstChildTypeRange))
        let payloadStart = isQuickTimeLayout ? data.startIndex : data.startIndex + 4
        let metaPayload = data.suffix(from: payloadStart)
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: Data(metaPayload)) else { return }

        if let ilst = children.first(where: { $0.type == "ilst" }) {
            parseILST(ilst.data, into: &metadata)
            // QuickTime mdta-style metadata: ilst entries are keyed by 1-based index into
            // the `keys` table. Walk that path to recover Apple Live Photo IDs and similar
            // namespaced values.
            if let keysBox = children.first(where: { $0.type == "keys" }) {
                let keys = parseQuickTimeKeys(keysBox.data)
                parseMDTAValues(ilst.data, keys: keys, into: &metadata)
            }
        }

        // Check for xml box (XMP)
        if let xml = children.first(where: { $0.type == "xml " }) {
            if let xmpData = try? XMPReader.readFromXML(xml.data) {
                metadata.xmp = xmpData
            }
        }
    }

    /// Parse the QuickTime `keys` box into an array of namespaced key strings, indexed 1-based
    /// (the encoding ilst uses to point at them).
    static func parseQuickTimeKeys(_ data: Data) -> [String] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        var keys: [String] = []
        do {
            _ = try reader.readUInt32BigEndian() // version + flags
            let entryCount = try reader.readUInt32BigEndian()
            for _ in 0..<entryCount {
                guard reader.remainingCount >= 8 else { break }
                let keySize = try reader.readUInt32BigEndian()
                guard keySize >= 8, Int(keySize) - 8 <= reader.remainingCount else { break }
                _ = try reader.readBytes(4) // key_namespace (e.g. "mdta")
                let valueLength = Int(keySize) - 8
                let valueBytes = try reader.readBytes(valueLength)
                keys.append(String(data: valueBytes, encoding: .utf8) ?? "")
            }
        } catch {
            // Best-effort.
        }
        return keys
    }

    /// Walk an ilst whose entries are keyed by 1-based index into the QuickTime `keys` table
    /// and pull out the values we care about.
    static func parseMDTAValues(_ ilstData: Data, keys: [String], into metadata: inout VideoMetadata) {
        guard !keys.isEmpty,
              let items = try? ISOBMFFBoxReader.parseBoxes(from: ilstData) else { return }

        // Slate metadata harvested from Blackmagic-RAW `mdta` keys. Built up
        // across the loop, then folded into metadata.camera (creating it if
        // the container has none). Order matters (userMetaNames/Contents are
        // emitted as parallel arrays), so push in scan order.
        var bmdSlateNames: [String] = []
        var bmdSlateContents: [String] = []

        for item in items {
            // Each item's box "type" is actually a 4-byte big-endian index into keys.
            let typeBytes = item.type.unicodeScalars.compactMap { UInt8(exactly: $0.value) }
            guard typeBytes.count == 4 else { continue }
            let index = (UInt32(typeBytes[0]) << 24)
                      | (UInt32(typeBytes[1]) << 16)
                      | (UInt32(typeBytes[2]) << 8)
                      |  UInt32(typeBytes[3])
            guard index >= 1, Int(index) <= keys.count else { continue }
            let key = keys[Int(index) - 1]

            guard let dataBox = (try? ISOBMFFBoxReader.parseBoxes(from: item.data))?
                    .first(where: { $0.type == "data" }),
                  dataBox.data.count >= 8 else { continue }
            // data box layout (after the box header is stripped by parseBoxes):
            //   type_indicator(4) + locale(4) + payload
            let typeIndicator = dataBox.data
                .prefix(4)
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payload = dataBox.data.suffix(from: dataBox.data.startIndex + 8)

            switch key {
            case "com.apple.quicktime.content.identifier":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload) {
                    metadata.contentIdentifier = s
                }

            // --- Blackmagic RAW clip metadata (BRAW writes mdta keys without a namespace) ---

            case "manufacturer":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload) {
                    updateCamera(&metadata) { $0.deviceManufacturer = s }
                }
            case "camera_type":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload) {
                    updateCamera(&metadata) { $0.deviceModelName = s }
                }
            case "camera_id":
                // A UUID, but it's the only stable per-body identifier BRAW emits.
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload) {
                    updateCamera(&metadata) { $0.deviceSerialNumber = s }
                }
            case "lens_type":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload),
                   !s.isEmpty {
                    updateCamera(&metadata) { $0.lensModelName = s }
                }
            case "viewing_gamma":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload) {
                    updateCamera(&metadata) { $0.captureGammaEquation = s }
                }
            case "offspeed_frame_time":
                // Sensor (off-speed) capture rate. The mvhd/stts-derived
                // VideoMetadata.frameRate stays as the *project* rate; this
                // surfaces as camera.captureFps so consumers can tell the two
                // apart (a 24p clip captured at 112 fps reports frameRate=24,
                // captureFps=112).
                if let t = decodeMDTAFloat(typeIndicator: typeIndicator, payload: payload),
                   t > 0 {
                    updateCamera(&metadata) { $0.captureFps = 1.0 / t }
                }

            // BMD slate fields without a CameraMetadata home — surface as
            // userMetaNames/userMetaContents pairs alongside Sony NRT user
            // descriptive metadata.
            case "firmware_version", "braw_compression_ratio", "viewing_gamut",
                 "shutter_type", "clip_number", "reel_name", "scene", "shot_type",
                 "take", "take_type", "production_name", "director",
                 "camera_number", "camera_operator", "date_recorded",
                 "environment", "day_night", "location", "filters",
                 "post_3dlut_mode", "post_3dlut_embedded_name",
                 "post_3dlut_embedded_title", "post_3dlut_embedded_bmd_gamma",
                 "frameguide_aspect_ratio", "encoder_device_manufacturer",
                 "time_lapse_interval", "anamorphic":
                if let s = decodeMDTAString(typeIndicator: typeIndicator, payload: payload),
                   !s.isEmpty {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append(s)
                }
            case "viewing_bmdgen":
                if let n = decodeMDTAInt(typeIndicator: typeIndicator, payload: payload) {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append("Generation \(n)")
                }
            case "offspeed", "offspeed_is_constant", "anamorphic_enable",
                 "good_take", "gamut_compression_enable",
                 "analog_gain_is_constant", "ois_enable", "highlight_recovery",
                 "lens_shading_enable", "lens_distortion_correction_enable",
                 "lens_chromatic_aberration_correction_enable":
                if let n = decodeMDTAInt(typeIndicator: typeIndicator, payload: payload) {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append(n == 0 ? "false" : "true")
                }
            case "post_3dlut_embedded_size", "rotation",
                 "tone_curve_video_black_level", "braw_codec_bitrate":
                // Plain integers (not booleans). `post_3dlut_embedded_size`
                // is the LUT cube edge (e.g. 33 → a 33×33×33 cube),
                // `rotation` is in degrees, `braw_codec_bitrate` is a
                // 32-bit unsigned byterate (see decodeMDTAInt).
                if let n = decodeMDTAInt(typeIndicator: typeIndicator, payload: payload) {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append("\(n)")
                }
            case "analog_gain", "sensor_line_time",
                 "sensor_photosite_pitch_in_micrometres",
                 "tone_curve_contrast", "tone_curve_saturation",
                 "tone_curve_midpoint", "tone_curve_highlights",
                 "tone_curve_shadows", "tone_curve_black_level",
                 "tone_curve_white_level":
                if let v = decodeMDTAFloat(typeIndicator: typeIndicator, payload: payload) {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append(String(format: "%g", v))
                }
            case "post_3dlut_embedded_data":
                // ~432 KB of LUT binary. Don't dump the bytes into a string
                // field; surface the size so consumers know the LUT is
                // present and how big it is.
                if typeIndicator == 22 {
                    bmdSlateNames.append(key)
                    bmdSlateContents.append("\(payload.count) bytes")
                }
            case "sensor_area_captured", "crop_origin", "crop_size", "safe_area":
                // BMD-specific type 71 = pair of float32 BE values, used here
                // for pixel rectangles. sensor_area_captured reads as
                // "12288x5112" on the Pyxis 12K (matches Resolve's "Sensor
                // Area Captured" field). crop_origin is x/y, crop_size is
                // w/h, safe_area is w/h.
                if let pair = decodeMDTAFloatPair(typeIndicator: typeIndicator, payload: payload) {
                    bmdSlateNames.append(key)
                    let (a, b) = pair
                    let isOrigin = key == "crop_origin"
                    let separator = isOrigin ? "," : "x"
                    bmdSlateContents.append("\(formatBMDDimension(a))\(separator)\(formatBMDDimension(b))")
                }

            default:
                break
            }
        }

        if !bmdSlateNames.isEmpty {
            // Preserve any pre-existing user-meta entries (e.g. from a Sony
            // NRT sidecar that was merged earlier) by appending.
            updateCamera(&metadata) {
                $0.userMetaNames.append(contentsOf: bmdSlateNames)
                $0.userMetaContents.append(contentsOf: bmdSlateContents)
            }
        }
    }

    /// Apply a mutation to `metadata.camera`, lazily materialising the value
    /// when the container hadn't populated it yet.
    static func updateCamera(_ metadata: inout VideoMetadata, _ mutate: (inout CameraMetadata) -> Void) {
        var cam = metadata.camera ?? CameraMetadata()
        mutate(&cam)
        metadata.camera = cam
    }

    /// Heuristic: is this 4-byte slice likely an ISOBMFF box type rather than
    /// a binary length? Box types are conventionally lowercase letters, sometimes
    /// with digits, the QuickTime copyright sentinel `©` (0xA9), or a trailing
    /// space. Length fields parsed from FullBox headers are binary numbers and
    /// almost always have one or more zero bytes in their high positions.
    static func isLikelyBoxType(_ bytes: Data) -> Bool {
        guard bytes.count == 4 else { return false }
        for b in bytes {
            let isLower = b >= 0x61 && b <= 0x7A
            let isUpper = b >= 0x41 && b <= 0x5A
            let isDigit = b >= 0x30 && b <= 0x39
            let isSpace = b == 0x20
            let isCopyright = b == 0xA9 // QuickTime ©nam, ©day, etc.
            if !(isLower || isUpper || isDigit || isSpace || isCopyright) {
                return false
            }
        }
        return true
    }

    /// Decode an Apple `data` box payload as a UTF-8 string when the type
    /// indicator says it's text (1) or the value happens to be ASCII.
    static func decodeMDTAString(typeIndicator: UInt32, payload: Data) -> String? {
        if typeIndicator == 1 {
            return String(data: payload, encoding: .utf8)
        }
        // Some writers emit type 0 for short strings — try UTF-8 anyway.
        return String(data: payload, encoding: .utf8)
    }

    /// Decode `data` payload as a float (type 23 = float32 BE, 24 = float64 BE).
    static func decodeMDTAFloat(typeIndicator: UInt32, payload: Data) -> Double? {
        switch typeIndicator {
        case 23 where payload.count == 4:
            let bits = payload.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float(bitPattern: bits))
        case 24 where payload.count == 8:
            let bits = payload.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            return Double(bitPattern: bits)
        default:
            return nil
        }
    }

    /// Decode a Blackmagic-RAW type-71 payload (two float32 BE values) as
    /// (x, y) or (width, height). BMD uses this for sensor_area_captured,
    /// crop_origin/size, and safe_area. Apple's standard `data` type table
    /// doesn't define 71 — it's a BMD extension specific to BRAW.
    static func decodeMDTAFloatPair(typeIndicator: UInt32, payload: Data) -> (Double, Double)? {
        guard typeIndicator == 71, payload.count == 8 else { return nil }
        let a = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let b = payload.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (Double(Float(bitPattern: a)), Double(Float(bitPattern: b)))
    }

    /// Sensor / crop dimensions are stored as floats (e.g. 12288.0) but read
    /// most naturally as integers. Drop a trailing `.0`; keep fractional
    /// digits when the value isn't whole.
    static func formatBMDDimension(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        return String(format: "%g", v)
    }

    /// Decode `data` payload as an integer (types 21, 67, 75, 76, 77, plus
    /// the unsigned 22). Width follows the payload length; the high bit drives
    /// sign extension for signed types. Apple type 22 and BMD type 77 (used
    /// for `braw_codec_bitrate`, a 32-bit byterate) are unsigned.
    static func decodeMDTAInt(typeIndicator: UInt32, payload: Data) -> Int64? {
        guard [21, 22, 67, 75, 76, 77].contains(Int(typeIndicator)),
              !payload.isEmpty, payload.count <= 8 else { return nil }
        var n: UInt64 = 0
        for b in payload { n = (n << 8) | UInt64(b) }
        let isSigned = typeIndicator != 22 && typeIndicator != 77
        if isSigned, let first = payload.first, first & 0x80 != 0 {
            // Sign-extend using the actual payload width.
            let mask = (UInt64(1) << (payload.count * 8)) &- 1
            n |= ~mask
        }
        return Int64(bitPattern: n)
    }

    /// Walk the `brhq` sample entry inside `stsd` and harvest the three
    /// BRAW-specific codec-config atoms — `bfdn` (BRAW format definition
    /// id, e.g. 1001), `ctrn` (color-transform version), and `bver` (BRAW
    /// codec version). Each is a 12-byte box wrapping a single uint32 BE.
    /// The values land in `camera.userMetaNames`/`userMetaContents` so they
    /// surface next to the moov.meta slate.
    static func parseBRAWCodecExtensions(_ stsdData: Data, into metadata: inout VideoMetadata) {
        // Mirror parseVisualSampleEntry's walk: stsd FullBox header (4) +
        // entry_count (4), then the first sample entry. The 4-byte type at
        // entryStart+4 is the codec FourCC; child boxes start 78 bytes
        // past the 8-byte SampleEntry box header (per ISO/IEC 14496-12).
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        let entryStart = reader.offset
        guard let entrySize32 = try? reader.readUInt32BigEndian(),
              let codecBytes = try? reader.readBytes(4),
              codecBytes.starts(with: Data("br".utf8)) else { return }
        let entryEnd = entryStart + Int(entrySize32)
        let childrenStart = entryStart + 8 + 78
        guard childrenStart < entryEnd, entryEnd <= stsdData.count else { return }
        let childrenData = Data(
            stsdData[(stsdData.startIndex + childrenStart) ..< (stsdData.startIndex + entryEnd)]
        )
        guard let kids = try? ISOBMFFBoxReader.parseBoxes(from: childrenData) else { return }

        var slateNames: [String] = []
        var slateContents: [String] = []
        for kid in kids {
            guard kid.data.count >= 4 else { continue }
            let n: UInt32 = kid.data.prefix(4)
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            switch kid.type {
            case "bfdn":
                slateNames.append("braw_codec_bfdn")
                slateContents.append("\(n)")
            case "ctrn":
                slateNames.append("braw_codec_ctrn")
                slateContents.append("\(n)")
            case "bver":
                slateNames.append("braw_codec_bver")
                slateContents.append("\(n)")
            default:
                break
            }
        }
        guard !slateNames.isEmpty else { return }
        updateCamera(&metadata) {
            $0.userMetaNames.append(contentsOf: slateNames)
            $0.userMetaContents.append(contentsOf: slateContents)
        }
    }

    /// Decoded contents of a BRAW per-frame `bmdf` header. All fields are
    /// optional because individual atoms can be absent on a given camera
    /// body / firmware combo (e.g. lens strings are empty when no
    /// electronic lens is attached). Used both by the slate path
    /// (`parseBRAWFirstFrameAttributes`, frame 0 only) and by
    /// `BRAWFrameReader.readAttributes` (every frame).
    internal struct BRAWFramePayload: Sendable {
        var shutterAngle: String?
        var aperture: String?
        var focalLength: String?
        var focusDistance: String?
        var iso: Int?
        var whiteBalanceKelvin: Int?
        var whiteBalanceTint: Int?
    }

    /// Decode the BRAW per-frame `bmdf` header from a Data window starting
    /// at the first byte of the box (`[size BE][type 'bmdf'][children…]`).
    ///
    /// The header is a sequence of small typed atoms; we decode:
    ///
    ///   `shtv`  size=32  utf-8 padded — shutter angle (e.g. "180°")
    ///   `aptr`  size=32  utf-8 padded — aperture (e.g. "f2.7")
    ///   `fcln`  size=32  utf-8 padded — focal length (e.g. "135mm")
    ///   `dsnc`  size=32  utf-8 padded — focus distance (e.g. "2430mm")
    ///   `isoe`  size=12   uint32 BE  — ISO equivalent (e.g. 400, 800)
    ///   `wkel`  size=12   uint32 BE  — white balance in Kelvin
    ///   `wtin`  size=10    int16 BE  — white balance tint (typically ±50)
    ///
    /// These aren't in `moov.meta` and aren't documented by the public BRAW
    /// SDK; we discovered them by reverse-engineering Cinema Camera 6K /
    /// PYXIS 6K / PYXIS 12K samples. Other atoms in the same header
    /// (`srte`, `innd`, `agpf`, `asct`, `asti`, `expo`, `shdp`, `dcp[ugrb]`,
    /// `skip`) carry per-frame state we haven't yet mapped.
    ///
    /// Returns `nil` when no decodable atom is present; otherwise returns
    /// a payload with whichever fields the camera populated.
    internal static func decodeBRAWFrameHeader(_ window: Data) -> BRAWFramePayload? {
        // Locate an atom by its 4-char type. Returns the payload range
        // within `window`. The 4 bytes preceding the type field are the
        // box size; payload size = size - 8.
        func locate(_ atom: String) -> Range<Data.Index>? {
            guard let r = window.range(of: Data(atom.utf8)),
                  r.lowerBound >= window.startIndex + 4 else { return nil }
            let sizeStart = r.lowerBound - 4
            let size = Int(readUInt32BE(window, at: sizeStart))
            guard size >= 8 else { return nil }
            let payloadStart = r.upperBound
            let payloadEnd = payloadStart + (size - 8)
            guard payloadEnd <= window.endIndex else { return nil }
            return payloadStart..<payloadEnd
        }

        // BMD pads a fixed-size buffer with NULs after the UTF-8 string;
        // trim at the first NUL and reject empty strings (which appear on
        // bodies without electronic lens contacts).
        func decodePaddedString(_ payload: Range<Data.Index>) -> String? {
            let bytes = window[payload]
            let endIdx = bytes.firstIndex(of: 0) ?? bytes.endIndex
            let trimmed = bytes[bytes.startIndex..<endIdx]
            guard let s = String(data: Data(trimmed), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }

        var p = BRAWFramePayload()
        if let r = locate("shtv") { p.shutterAngle = decodePaddedString(r) }
        if let r = locate("aptr") { p.aperture = decodePaddedString(r) }
        if let r = locate("fcln") { p.focalLength = decodePaddedString(r) }
        if let r = locate("dsnc") { p.focusDistance = decodePaddedString(r) }
        if let r = locate("isoe"), r.count == 4 {
            p.iso = Int(readUInt32BE(window, at: r.lowerBound))
        }
        if let r = locate("wkel"), r.count == 4 {
            p.whiteBalanceKelvin = Int(readUInt32BE(window, at: r.lowerBound))
        }
        if let r = locate("wtin"), r.count == 2 {
            let bits = (UInt16(window[r.lowerBound]) << 8)
                     |  UInt16(window[r.lowerBound + 1])
            p.whiteBalanceTint = Int(Int16(bitPattern: bits))
        }
        // All-nil payload: nothing to surface.
        if p.shutterAngle == nil && p.aperture == nil && p.focalLength == nil
           && p.focusDistance == nil && p.iso == nil
           && p.whiteBalanceKelvin == nil && p.whiteBalanceTint == nil {
            return nil
        }
        return p
    }

    /// Slice the `bmdf` window out of `fullData` for the chunk at the
    /// given absolute file offset. The `bmdf` box's first 4 bytes declare
    /// its size — typically 256 bytes on smaller-resolution clips, 1024
    /// on PYXIS 12K. Cap at 4 KiB so we never walk into image data.
    /// Returns `nil` when the offset isn't inside the file.
    internal static func brawFrameWindow(
        at chunkOffset: UInt64, in fullData: Data
    ) -> Data? {
        // `chunkOffset` is a raw 64-bit value straight from a `co64` box, so a
        // crafted file can set it past Int.max — where `Int(chunkOffset)` traps
        // and crashes the parser. Bound it in UInt64 space first; afterwards the
        // Int math stays in range (mirrors CRMReader.sliceFile / parseTmcd).
        guard chunkOffset <= UInt64(Int.max) else { return nil }
        let s = Int(chunkOffset)
        // Subtraction, not `s + 8`: s can be up to Int.max, so the addition
        // would overflow. `fullData.count - 8` is negative for tiny files,
        // which s (>= 0) correctly fails.
        guard s <= fullData.count - 8 else { return nil }
        let bmdfSize = readUInt32BE(fullData, at: fullData.startIndex + s)
        let windowSize = min(max(Int(bmdfSize), 256), 4096)
        guard s <= fullData.count - windowSize else { return nil }
        return fullData.subdata(in: (fullData.startIndex + s)..<(fullData.startIndex + s + windowSize))
    }

    /// Read frame 0's `bmdf` header for the BRAW slate path. Across the
    /// three test clips the per-frame values are identical, so frame 0
    /// yields the clip-level default — no per-frame iteration in the
    /// `read` flow. (`BRAWFrameReader.readAttributes` walks every frame.)
    /// Surfaces as slate user-meta entries; we don't promote to dedicated
    /// `CameraMetadata` fields because that struct is shared with other
    /// formats (Sony NRT, MXF) and ISO/WB/lens-strings aren't part of its
    /// public surface today.
    static func parseBRAWFirstFrameAttributes(
        _ trakData: Data, fullData: Data, into metadata: inout VideoMetadata
    ) {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data),
              let stsd = stblChildren.first(where: { $0.type == "stsd" }) else { return }

        // Gate on a BRAW codec FourCC ("br" prefix — brhq / brst / brlt /…).
        guard let codec = parseFirstStsdCodec(stsd.data),
              codec.hasPrefix("br") else { return }

        // First chunk offset (== first sample, since BRAW writes one sample
        // per chunk). Prefer co64 for files >4 GiB.
        let chunkOffset: UInt64? = {
            if let co64 = stblChildren.first(where: { $0.type == "co64" }),
               let off = parseCO64First(co64.data) {
                return off
            }
            if let stco = stblChildren.first(where: { $0.type == "stco" }),
               let off = parseSTCOFirst(stco.data) {
                return UInt64(off)
            }
            return nil
        }()
        guard let offset = chunkOffset,
              let window = brawFrameWindow(at: offset, in: fullData),
              let payload = decodeBRAWFrameHeader(window) else { return }

        // Order of slate appends matches the bmdf walk order (shtv → aptr
        // → fcln → dsnc → isoe → wkel → wtin) so consumers reading the
        // arrays sequentially see the values in their natural layout.
        var slateNames: [String] = []
        var slateContents: [String] = []
        if let s = payload.shutterAngle { slateNames.append("shutter_angle"); slateContents.append(s) }
        if let s = payload.aperture { slateNames.append("aperture"); slateContents.append(s) }
        if let s = payload.focalLength { slateNames.append("focal_length"); slateContents.append(s) }
        if let s = payload.focusDistance { slateNames.append("focus_distance"); slateContents.append(s) }
        if let v = payload.iso { slateNames.append("iso"); slateContents.append("\(v)") }
        if let v = payload.whiteBalanceKelvin { slateNames.append("white_balance_kelvin"); slateContents.append("\(v)") }
        if let v = payload.whiteBalanceTint { slateNames.append("white_balance_tint"); slateContents.append("\(v)") }

        guard !slateNames.isEmpty else { return }
        updateCamera(&metadata) {
            $0.userMetaNames.append(contentsOf: slateNames)
            $0.userMetaContents.append(contentsOf: slateContents)
        }
    }

    /// Read the FourCC of the first sample entry from an stsd box payload,
    /// skipping the FullBox version+flags and entry_count. Used to gate
    /// BRAW-specific extraction off the codec ID without re-walking stsd.
    internal static func parseFirstStsdCodec(_ stsdData: Data) -> String? {
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // version+flags
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8,
              (try? reader.readUInt32BigEndian()) != nil,
              let typeBytes = try? reader.readBytes(4) else { return nil }
        return String(data: typeBytes, encoding: .ascii)
    }

    /// Big-endian uint32 read from a Data slice at an absolute index.
    /// Caller guarantees `index + 4 <= data.endIndex`.
    internal static func readUInt32BE(_ data: Data, at index: Data.Index) -> UInt32 {
        return (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            |  UInt32(data[index + 3])
    }

    /// Detect Blackmagic RAW per-frame motion-data tracks (gyroscope,
    /// accelerometer) by their key-namespace strings inside an `mebx`
    /// sample entry. Presence-only — we don't decode the per-frame vec3
    /// samples. Substring scan is cheaper than walking
    /// mebx → keys → keyd and equally reliable: the namespace strings
    /// `com.blackmagicdesign.motiondata.gyroscope` /
    /// `com.blackmagicdesign.motiondata.accelerometer` are unique to BMD.
    static func detectBRAWMotionTracks(in stsdData: Data, into metadata: inout VideoMetadata) {
        guard stsdData.range(of: Data("mebx".utf8)) != nil else { return }
        var names: [String] = []
        if stsdData.range(of: Data("com.blackmagicdesign.motiondata.gyroscope".utf8)) != nil {
            names.append("has_gyroscope_motion_data")
        }
        if stsdData.range(of: Data("com.blackmagicdesign.motiondata.accelerometer".utf8)) != nil {
            names.append("has_accelerometer_motion_data")
        }
        guard !names.isEmpty else { return }
        updateCamera(&metadata) { cam in
            for n in names {
                cam.userMetaNames.append(n)
                cam.userMetaContents.append("true")
            }
        }
    }

    static func parseILST(_ data: Data, into metadata: inout VideoMetadata) {
        guard let items = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        for item in items {
            // Each item contains a "data" sub-box
            guard let dataBox = (try? ISOBMFFBoxReader.parseBoxes(from: item.data))?.first(where: { $0.type == "data" }) else {
                continue
            }

            // data box: type_indicator (4 bytes) + locale (4 bytes) + payload
            guard dataBox.data.count > 8 else { continue }
            let payload = dataBox.data.suffix(from: dataBox.data.startIndex + 8)

            // Get type indicator (first 4 bytes, big-endian UInt32)
            var typeReader = BinaryReader(data: dataBox.data)
            let typeIndicator = (try? typeReader.readUInt32BigEndian()) ?? 0

            // Map item type to metadata field
            let rawType = item.type

            // QuickTime keys use byte 0xA9 (©) which maps to \u{00A9} in isoLatin1
            let key: String
            if rawType.count == 4 && rawType.unicodeScalars.first?.value == 0xA9 {
                key = String(rawType.dropFirst())
            } else {
                key = rawType
            }

            switch key {
            case "nam":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.title = s
                }
            case "ART":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.artist = s
                }
            case "cmt":
                if typeIndicator == 1, let s = String(data: payload, encoding: .utf8) {
                    metadata.comment = s
                }
            case "day":
                // Date — just store as-is in comment for now
                break
            case "xyz":
                // GPS: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD+DDD.DDDD+AAAA.AA/"
                if let s = String(data: payload, encoding: .utf8) {
                    parseGPSXYZ(s, into: &metadata)
                }
            default:
                break
            }
        }
    }

    // MARK: - GPS from ©xyz

    static func parseGPSXYZ(_ string: String, into metadata: inout VideoMetadata) {
        // Format: "+DD.DDDD+DDD.DDDD/" or "+DD.DDDD-DDD.DDDD+AAAA.AA/"
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        guard !cleaned.isEmpty else { return }

        // Split on +/- boundaries, keeping the sign
        var components: [String] = []
        var current = ""
        for char in cleaned {
            if (char == "+" || char == "-") && !current.isEmpty {
                components.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { components.append(current) }

        if components.count >= 2 {
            metadata.gpsLatitude = Double(components[0])
            metadata.gpsLongitude = Double(components[1])
        }
        if components.count >= 3 {
            metadata.gpsAltitude = Double(components[2])
        }
    }

    // MARK: - UUID (XMP / embedded XML)

    static func parseUUIDBox(_ data: Data, into metadata: inout VideoMetadata) {
        guard data.count > 16 else { return }
        let uuid = data.prefix(16)
        let payload = Data(data.suffix(from: data.startIndex + 16))

        if uuid == xmpUUID {
            if let xmpData = try? XMPReader.readFromXML(payload) {
                metadata.xmp = xmpData
            }
            return
        }

        // Some Sony MP4 cameras embed NonRealTimeMeta inside a uuid box.
        // The user-type UUID varies between firmware versions, so content-sniff
        // instead of matching a fixed UUID.
        if looksLikeNRT(payload) {
            if let cam = try? NRTXMLParser.parse(payload) {
                metadata.camera = cam
            }
        }
    }

    static func looksLikeNRT(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let scanLimit = min(data.count, 4096)
        guard let head = String(data: data.prefix(scanLimit), encoding: .utf8) else {
            return false
        }
        return head.contains("NonRealTimeMeta")
    }
}
