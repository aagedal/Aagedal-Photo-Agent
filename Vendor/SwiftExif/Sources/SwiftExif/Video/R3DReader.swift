import Foundation

/// Reader for RED RAW (.R3D) clip-header metadata.
///
/// R3D is RED's own length-prefixed container, big-endian throughout — *not*
/// ISOBMFF. The first atom (`RED2`, or `RED1` on older firmware) is a fixed
/// 1202-byte clip header that carries every piece of clip-level metadata; the
/// remaining atoms (`RDI`, `RDA`, …) are video / audio frame chunks we don't
/// need for metadata. Tag IDs are the same 16-bit codes ExifTool's
/// `Image::ExifTool::Red` table documents.
///
/// File layout used here:
///
///     uint32 size      // 1202 (0x000004B2) for RED2
///     char[4] type     // "RED2" or "RED1"
///     byte[size-8] payload
///
/// `payload` layout (offsets relative to start of file):
///
///     0x08..0x3F : 4-byte sentinel (version/flags) + 16-byte clip GUID +
///                  16-byte reel GUID + 16 bytes of additional UUIDs
///     0x40..0x47 : 4-byte version field + "rdi"+0x01 type tag
///     0x48..0x5B : 20-byte rdi (image-track) header
///     0x5C..0x6F : 4-byte "rda"+0x01 + 16-byte audio-track header
///     0x70..0x8F : two "rdx" sub-atoms with the "RED " marker (skip)
///     0x90..0x92 : 3-byte preamble before TLV records
///     0x93..end  : TLV records, then trailing zero padding to 1202 bytes
///
/// The 3-byte preamble at 0x90 differs by camera model (`04 11 00` on KOMODO,
/// `04 0d 00` on V-RAPTOR) — likely a record count. We treat it as opaque
/// header bytes and start the TLV scan at 0x93.
public struct R3DReader: Sendable {

    /// True when `data` looks like an R3D container — checks for "RED2" /
    /// "RED1" magic at offset 4.
    public static func isR3D(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let s = data.startIndex
        let m0 = data[s + 4], m1 = data[s + 5], m2 = data[s + 6], m3 = data[s + 7]
        // "RED1" or "RED2"
        return m0 == 0x52 && m1 == 0x45 && m2 == 0x44 && (m3 == 0x31 || m3 == 0x32)
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isR3D(data) else {
            throw MetadataError.invalidVideo("Not a RED RAW (R3D) file")
        }
        var metadata = VideoMetadata(format: .r3d)
        metadata.formatLongName = "RED RAW"
        // RED is the manufacturer of every R3D file — RED doesn't store it
        // as a TLV the way Sony/BMD do, so we set it unconditionally.
        updateCamera(&metadata) { $0.deviceManufacturer = "RED" }

        let s = data.startIndex
        // Outer atom size, capped at the actual file length so a truncated
        // header doesn't run us off the end.
        let red2Size = Int(readUInt32BE(data, at: s)) // value at offsets 0..3
        let payloadEnd = min(data.count, red2Size)
        guard payloadEnd >= 0x94 else { return metadata }

        // --- rdi (image track) header at 0x44+4 (skip 4-byte version + "rdi"+0x01 type). ---
        // Layout (20 bytes), big-endian throughout:
        //   uint32 padding   (always 0)
        //   uint32 width     (5760 for 6K, 7680 for 8K)
        //   uint32 height    (3240 for 6K 16:9, 4320 for 8K 16:9)
        //   uint32 ?         (timebase / sample duration?)
        //   uint32 ?         (24000 on 24p clips — looks like a PTS scale)
        if payloadEnd >= 0x5C {
            let rdiBase = s + 0x48
            let w = Int(readUInt32BE(data, at: rdiBase + 4))
            let h = Int(readUInt32BE(data, at: rdiBase + 8))
            if w > 0 { metadata.videoWidth = w }
            if h > 0 { metadata.videoHeight = h }
        }

        // --- rda (audio track) header at 0x60. Layout (16 bytes):
        //     uint64 sample_count, uint32 sample_rate, uint32 ?
        if payloadEnd >= 0x70 {
            let rdaBase = s + 0x60
            let sampleRate = Int(readUInt32BE(data, at: rdaBase + 8))
            if sampleRate > 0 {
                var audio = AudioStream(index: 0)
                audio.sampleRate = sampleRate
                metadata.audioStreams.append(audio)
                metadata.audioSampleRate = sampleRate
            }
        }

        // --- TLV records start at offset 0x93 (after a 3-byte preamble). ---
        var slateNames: [String] = []
        var slateContents: [String] = []
        var dateCreated: String?
        var timeCreated: String?

        var offset = 0x93
        while offset + 3 <= payloadEnd {
            let len = Int(data[s + offset])
            // Length 0 marks end of records (the rest of the RED2 atom is
            // zero-padding to the 1202-byte boundary).
            if len == 0 { break }
            // A record must be at least 4 bytes (1 len + 2 tag + 1 value)
            // and must not run past the atom payload. The 64-byte ceiling
            // is a defensive cap — the largest real-world TLV we've seen
            // is the 28-byte original-filename string; anything bigger
            // means we've stepped off the end of the records section into
            // padding or a malformed file.
            guard len >= 4, len <= 64, offset + len <= payloadEnd else { break }
            let tag = (UInt16(data[s + offset + 1]) << 8) | UInt16(data[s + offset + 2])
            let valueStart = offset + 3
            let valueEnd = offset + len
            let value = data.subdata(in: (s + valueStart)..<(s + valueEnd))

            decode(
                tag: tag,
                value: value,
                metadata: &metadata,
                slateNames: &slateNames,
                slateContents: &slateContents,
                dateCreated: &dateCreated,
                timeCreated: &timeCreated
            )

            offset = valueEnd
        }

        if let d = dateCreated, let t = timeCreated,
           let date = parseRedDate(date: d, time: t) {
            metadata.creationDate = date
            updateCamera(&metadata) { $0.creationDate = date }
        }

        if !slateNames.isEmpty {
            updateCamera(&metadata) {
                $0.userMetaNames.append(contentsOf: slateNames)
                $0.userMetaContents.append(contentsOf: slateContents)
            }
        }

        return metadata
    }

    // MARK: - TLV decoding

    private static func decode(
        tag: UInt16,
        value: Data,
        metadata: inout VideoMetadata,
        slateNames: inout [String],
        slateContents: inout [String],
        dateCreated: inout String?,
        timeCreated: inout String?
    ) {
        switch tag {

        // --- 0x10xx: ASCII strings (null-terminated) ---
        case 0x1006:
            if let s = decodeString(value) { updateCamera(&metadata) { $0.deviceSerialNumber = s } }
        case 0x1019:
            if let s = decodeString(value) { addSlate("red_camera_type", s, &slateNames, &slateContents) }
        case 0x101a:
            if let s = decodeString(value) { addSlate("red_reel_number", s, &slateNames, &slateContents) }
        case 0x101b:
            if let s = decodeString(value) { addSlate("red_take", s, &slateNames, &slateContents) }
        case 0x1023:
            dateCreated = decodeString(value)
        case 0x1024:
            timeCreated = decodeString(value)
        case 0x1025:
            if let s = decodeString(value) { addSlate("red_firmware_version", s, &slateNames, &slateContents) }
        case 0x1029:
            if let s = decodeString(value) {
                metadata.timecodes.append(Timecode(value: s, source: .redR3D))
                if metadata.timecode == nil { metadata.timecode = s }
            }
        case 0x102a:
            if let s = decodeString(value) { addSlate("red_storage_type", s, &slateNames, &slateContents) }
        case 0x1030:
            if let s = decodeString(value) { addSlate("red_storage_format_date", s, &slateNames, &slateContents) }
        case 0x1031:
            if let s = decodeString(value) { addSlate("red_storage_format_time", s, &slateNames, &slateContents) }
        case 0x1032:
            if let s = decodeString(value) { addSlate("red_storage_serial", s, &slateNames, &slateContents) }
        case 0x1033:
            if let s = decodeString(value) { addSlate("red_storage_model", s, &slateNames, &slateContents) }
        case 0x1036:
            if let s = decodeString(value) { addSlate("red_aspect_ratio", s, &slateNames, &slateContents) }
        case 0x1056:
            if let s = decodeString(value) { addSlate("red_original_filename", s, &slateNames, &slateContents) }
        case 0x1070:
            if let s = decodeString(value) { updateCamera(&metadata) { $0.lensModelName = s } }
        case 0x107c:
            if let s = decodeString(value) { addSlate("red_camera_operator", s, &slateNames, &slateContents) }
        case 0x1086:
            if let s = decodeString(value) { addSlate("red_video_format", s, &slateNames, &slateContents) }
        case 0x10a0:
            if let s = decodeString(value) { updateCamera(&metadata) { $0.deviceModelName = s } }
        case 0x10a1:
            if let s = decodeString(value) { addSlate("red_sensor", s, &slateNames, &slateContents) }
        case 0x10ad:
            // Provisional name — the RED slate carries two `HH:MM:SS:FF`
            // strings that aren't documented in ExifTool's table. Surface
            // both as timecodes so callers get the values without us
            // pretending to know which is record vs playback.
            if let s = decodeString(value) {
                metadata.timecodes.append(Timecode(value: s, source: .redR3D))
                if metadata.timecode == nil { metadata.timecode = s }
                addSlate("red_record_timecode", s, &slateNames, &slateContents)
            }
        case 0x10ae:
            if let s = decodeString(value) {
                metadata.timecodes.append(Timecode(value: s, source: .redR3D))
                addSlate("red_playback_timecode", s, &slateNames, &slateContents)
            }
        case 0x10be:
            if let s = decodeString(value) { addSlate("red_quality", s, &slateNames, &slateContents) }

        // --- 0x20xx: float32 BE in first 4 bytes (with 1 trailing byte). ---
        case 0x200d:
            if let f = decodeFloat32BE(value) {
                addSlate("red_color_temperature_k", String(format: "%.0f", f), &slateNames, &slateContents)
            }
        case 0x2066:
            if let f = decodeFloat32BE(value), f > 0 {
                let rate = Double(f)
                if metadata.frameRate == nil { metadata.frameRate = rate }
                updateCamera(&metadata) { $0.captureFps = rate }
            }

        // --- 0x40xx: packed shorts (CropArea) / single uint16 ---
        case 0x4037:
            // CropArea: 4 bytes prefix (origin x/y) + uint16 width +
            // uint16 height + 1 trailing byte. Format the result the way
            // ImageMagick/X11 geometry strings read: "WxH+X+Y".
            if value.count >= 8 {
                let xy = value.startIndex
                let x = (UInt16(value[xy]) << 8) | UInt16(value[xy + 1])
                let y = (UInt16(value[xy + 2]) << 8) | UInt16(value[xy + 3])
                let w = (UInt16(value[xy + 4]) << 8) | UInt16(value[xy + 5])
                let h = (UInt16(value[xy + 6]) << 8) | UInt16(value[xy + 7])
                if w > 0 && h > 0 {
                    addSlate(
                        "red_crop_area",
                        "\(w)x\(h)+\(x)+\(y)",
                        &slateNames, &slateContents
                    )
                }
            }
        case 0x403b:
            if let n = decodeUInt16BE(value) {
                addSlate("red_iso", "\(n)", &slateNames, &slateContents)
            }

        // --- 0x60xx: per-id decoders (uint16 in first 2 bytes for the ones we know) ---
        case 0x606c:
            if let n = decodeUInt16BE(value) {
                addSlate("red_focus_distance_mm", "\(n)", &slateNames, &slateContents)
            }

        default:
            break
        }
    }

    // MARK: - Type helpers

    private static func decodeString(_ value: Data) -> String? {
        // RED writes ASCII strings null-terminated; trim the trailing 0
        // and any leftover padding. Empty strings (as V-RAPTOR's
        // CameraOperator often is) collapse to nil so we don't bloat the
        // slate with blank entries.
        guard !value.isEmpty else { return nil }
        var bytes = Array(value)
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        let s = String(decoding: bytes, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    private static func decodeFloat32BE(_ value: Data) -> Float? {
        guard value.count >= 4 else { return nil }
        let i = value.startIndex
        let raw = (UInt32(value[i]) << 24)
            | (UInt32(value[i + 1]) << 16)
            | (UInt32(value[i + 2]) << 8)
            | UInt32(value[i + 3])
        return Float(bitPattern: raw)
    }

    private static func decodeUInt16BE(_ value: Data) -> UInt16? {
        guard value.count >= 2 else { return nil }
        let i = value.startIndex
        return (UInt16(value[i]) << 8) | UInt16(value[i + 1])
    }

    private static func parseRedDate(date: String, time: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: date + time)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let s = offset
        return (UInt32(data[s]) << 24)
            | (UInt32(data[s + 1]) << 16)
            | (UInt32(data[s + 2]) << 8)
            | UInt32(data[s + 3])
    }

    private static func addSlate(
        _ name: String,
        _ content: String,
        _ names: inout [String],
        _ contents: inout [String]
    ) {
        guard !content.isEmpty else { return }
        names.append(name)
        contents.append(content)
    }

    /// Lazily materialise `metadata.camera` so individual decoders don't have
    /// to nil-check before assigning. Mirrors `MP4Parser.updateCamera`.
    private static func updateCamera(_ metadata: inout VideoMetadata, _ mutate: (inout CameraMetadata) -> Void) {
        var cam = metadata.camera ?? CameraMetadata()
        mutate(&cam)
        metadata.camera = cam
    }
}
