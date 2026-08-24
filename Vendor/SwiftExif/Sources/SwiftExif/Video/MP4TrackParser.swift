import Foundation

/// Track parsing for MP4Parser: trak walking, tkhd / mdhd / hdlr / edts,
/// stsd dispatch into the visual / audio / data / subtitle / tmcd paths,
/// timecode-track decoding, edit-list duration, and the small box helpers
/// used by sample-table reads (stsc / stsz / stts / stco / co64 entry-point
/// shortcuts).
///
/// Extracted from MP4Parser.swift to keep that file scannable. No behavior
/// change — `private static` helpers that were file-local in the source
/// are now `static` so they're reachable from this extension across files.
extension MP4Parser {

    // MARK: - Track Parsing

    static func parseTrak(
        _ data: Data,
        movieTimescale: UInt32,
        chapterTrackIDs: Set<UInt32> = [],
        into metadata: inout VideoMetadata
    ) {
        guard let children = try? ISOBMFFBoxReader.parseBoxes(from: data) else { return }

        // tkhd provides track-level display dimensions, flags, and the track
        // ID we compare against the chapter-track exclusion set below.
        var trackWidth: Int?
        var trackHeight: Int?
        var tkhdIsDefault: Bool?
        var tkhdRotation: Int?
        if let tkhd = children.first(where: { $0.type == "tkhd" }) {
            if let dims = parseTKHDDimensions(tkhd.data) {
                trackWidth = dims.width
                trackHeight = dims.height
            }
            tkhdIsDefault = parseTKHDIsDefault(tkhd.data)
            tkhdRotation = parseTKHDRotation(tkhd.data)
        }
        // parseTKHDTrackID walks the trak looking for tkhd itself — cheap
        // enough; we already parsed the children but the function is shared
        // with the timecode + chapter-track paths in `parse()`.
        let trackID: UInt32? = parseTKHDTrackID(data)

        // A text track referenced from a video track's `tref > chap` list is
        // a chapter-title track, not a user-facing subtitle. Bail out before
        // the handler dispatch so it never lands in `subtitleStreams`. (The
        // chapter titles themselves are harvested separately in `parse()`.)
        let isChapterTextTrack: Bool = trackID.map(chapterTrackIDs.contains(_:)) ?? false

        // `edts > elst` trims the visible essence window inside the mdhd
        // duration — ffmpeg uses it to hide B-frame decoder pre-roll and to
        // support seamless concatenation. When present, the sum of each entry's
        // segment_duration (in *movie* timescale) is the effective track
        // duration; ignoring it over-reports the media duration and deflates
        // per-stream bitrate accordingly. We recover it here and plumb it as
        // `editedDuration` below.
        var editedDuration: TimeInterval?
        if movieTimescale > 0,
           let edts = children.first(where: { $0.type == "edts" }),
           let edtsChildren = try? ISOBMFFBoxReader.parseBoxes(from: edts.data),
           let elst = edtsChildren.first(where: { $0.type == "elst" }) {
            if let total = parseELSTSegmentDuration(elst.data), total > 0 {
                editedDuration = Double(total) / Double(movieTimescale)
            }
        }

        // Disposition flags from trak.udta.kind (ISO/IEC 14496-12 + DASH Role
        // scheme, "urn:mpeg:dash:role:2011"). This is how ffmpeg records
        // -disposition:s:N forced / caption / main on an MP4 subtitle track;
        // tx3g displayFlags (3GPP TS 26.245 §5.16) is the alternative path.
        let dispositions = parseTrackKindDispositions(children)

        guard let mdia = children.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data) else {
            return
        }

        // mdhd: per-track timescale + duration + language.
        var trackDuration: TimeInterval?
        var language: String?
        var trackTimescale: UInt32 = 0
        if let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) {
            if let info = parseMDHD(mdhd.data) {
                trackDuration = info.duration
                language = info.language
                trackTimescale = info.timescale
            }
        }

        // `trackDuration` stays on the raw mdhd value — ffprobe reports that
        // for a stream's `duration` field and computes `avg_frame_rate` as
        // `samples / mdhd_duration`. Only the bitrate calc prefers
        // `editedDuration` (mirroring ffprobe, which sums the packet bytes
        // that land inside the edit-list window).

        // hdlr → track handler type ("vide", "soun").
        var handlerType = ""
        if let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
           hdlr.data.count >= 12 {
            handlerType = String(
                data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
                encoding: .ascii
            ) ?? ""
        }

        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data)
        else { return }

        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stsdBox = stblChildren.first(where: { $0.type == "stsd" })

        let frameCount = stszBox.flatMap(parseSTSZSampleCount)
        let sttsFrames = sttsBox.flatMap(parseSTTSSampleCount)
        let trackBytes = stszBox.flatMap(parseSTSZTotalBytes)
        let dominantSampleDelta = sttsBox.flatMap(parseSTTSDominantDelta)

        // Prefer stsz; stts is a sum of per-run counts but some muxers only populate one.
        let samples = frameCount ?? sttsFrames

        let fps: Double? = {
            guard let samples, samples > 0, let trackDuration, trackDuration > 0 else {
                return nil
            }
            return Double(samples) / trackDuration
        }()

        // Real (decoder cadence) frame rate: timescale / dominant sample delta.
        // ffprobe surfaces this as `r_frame_rate` and it's stable across files
        // with a partial trailing sample (where samples/duration would slip).
        let rFrameRate: Double? = {
            guard trackTimescale > 0, let delta = dominantSampleDelta, delta > 0 else { return nil }
            return Double(trackTimescale) / Double(delta)
        }()

        // Per-stream bitrate fallback: total essence bytes × 8 / duration.
        // Priority order matches ffprobe:
        //   1. edit-list-corrected duration (strips B-frame pre-roll, seamless
        //      concatenation joins, and any other explicit trim)
        //   2. stts-derived essence duration (samples × dominant_delta /
        //      timescale) — stable when mdhd has a partial trailing sample
        //   3. raw mdhd duration
        let derivedTrackBitRate: Int? = {
            guard let bytes = trackBytes else { return nil }
            if let edited = editedDuration, edited > 0 {
                return Int(Double(bytes) * 8.0 / edited)
            }
            if let samples, samples > 0,
               let delta = dominantSampleDelta, delta > 0,
               trackTimescale > 0 {
                let essenceDur = Double(samples) * Double(delta) / Double(trackTimescale)
                if essenceDur > 0 { return Int(Double(bytes) * 8.0 / essenceDur) }
            }
            if let dur = trackDuration, dur > 0 {
                return Int(Double(bytes) * 8.0 / dur)
            }
            return nil
        }()

        if handlerType == "vide", let stsdBox {
            metadata.streamOrder.append(.video(metadata.videoStreams.count))
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.duration = trackDuration
            stream.frameCount = samples
            // Legacy `frameRate` and `avgFrameRate` both report the essence
            // average (samples / duration). `rFrameRate` is the decoder
            // cadence (timescale / dominant sample delta) — equal to avg when
            // stts has a single, uniform entry.
            stream.frameRate = fps
            stream.avgFrameRate = fps
            stream.rFrameRate = rFrameRate ?? fps
            stream.isDefault = tkhdIsDefault
            stream.rotation = tkhdRotation
            parseVisualSampleEntry(stsdBox.data, into: &stream)
            // Blackmagic RAW: pull the three uint32 codec-config atoms
            // (bfdn / ctrn / bver) out of the BRAW sample entry's child
            // boxes and surface them next to the moov.meta clip slate.
            // BRAW uses one FourCC per quality preset — `brhq` (High
            // Quality), `brst` (Standard), `brlt` (Light), plus likely
            // others for Q0/Q1/Q3/Q5 and constant-bitrate ratios — all
            // sharing the "br" prefix.
            if stream.codec?.hasPrefix("br") == true {
                parseBRAWCodecExtensions(stsdBox.data, into: &metadata)
            }
            // ffprobe always computes per-stream bit_rate from actual packet
            // sizes in the edit-list window (not from the encoder-declared
            // `btrt` value, which goes stale after lossless trim). Mirror that
            // priority: stsz-derived over btrt whenever stsz has data. Fall
            // back to btrt/esds only when stsz is missing (e.g. fragmented
            // movies with no sample count we can sum).
            if let derived = derivedTrackBitRate, derived > 0 {
                stream.bitRate = derived
            }

            if stream.width == nil, let trackWidth, trackWidth > 0 {
                stream.width = trackWidth
            }
            if stream.height == nil, let trackHeight, trackHeight > 0 {
                stream.height = trackHeight
            }
            // tkhd carries display-aspect-corrected, post-rotation dimensions
            // per ISO/IEC 14496-12 §8.3.2 ("after all visual effects applied").
            // Only fall back when the sample entry (pasp) hasn't already set
            // display dims, and only when they actually differ from the pixel
            // grid. Because tkhd is already post-rotation, no swap is needed
            // here even when `tkhdRotation` is ±90.
            if stream.displayWidth == nil, let trackWidth, trackWidth > 0,
               stream.width.map({ $0 != trackWidth }) ?? false {
                stream.displayWidth = trackWidth
            }
            if stream.displayHeight == nil, let trackHeight, trackHeight > 0,
               stream.height.map({ $0 != trackHeight }) ?? false {
                stream.displayHeight = trackHeight
            }

            // MP4/MOV convention: absence of a `fiel` atom means progressive.
            // Cameras and modern encoders (HEVC, AV1, VVC) routinely omit it.
            // ffmpeg's mov demuxer treats untagged streams the same way.
            if stream.fieldOrder == nil { stream.fieldOrder = .progressive }

            metadata.videoStreams.append(stream)

            if metadata.videoWidth == nil, let w = stream.width, w > 0 {
                metadata.videoWidth = w
            }
            if metadata.videoHeight == nil, let h = stream.height, h > 0 {
                metadata.videoHeight = h
            }
            if metadata.videoCodec == nil { metadata.videoCodec = stream.codec }
            if metadata.frameRate == nil { metadata.frameRate = stream.frameRate }
            if metadata.fieldOrder == nil { metadata.fieldOrder = stream.fieldOrder }
            if metadata.colorInfo == nil { metadata.colorInfo = stream.colorInfo }
            if metadata.bitDepth == nil { metadata.bitDepth = stream.bitDepth }
            if metadata.chromaSubsampling == nil { metadata.chromaSubsampling = stream.chromaSubsampling }
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = stream.pixelAspectRatio }
            if metadata.displayWidth == nil { metadata.displayWidth = stream.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = stream.displayHeight }
        } else if handlerType == "soun", let stsdBox {
            metadata.streamOrder.append(.audio(metadata.audioStreams.count))
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.duration = trackDuration
            stream.language = language
            stream.isDefault = tkhdIsDefault
            parseAudioSampleEntry(stsdBox.data, into: &stream)
            // Uncompressed PCM has a deterministic bit rate
            // (sample_rate × channels × bit_depth) — use that verbatim
            // regardless of what `esds` / `btrt` / stsz happen to compute,
            // because stsz-over-duration introduces rounding noise and
            // ffprobe reports the exact mathematical value.
            if let codec = stream.codec, isUncompressedPCMCodec(codec),
               let sr = stream.sampleRate, sr > 0,
               let ch = stream.channels, ch > 0,
               let bd = stream.bitDepth, bd > 0 {
                stream.bitRate = sr * ch * bd
            } else if let derived = derivedTrackBitRate, derived > 0 {
                // Compressed audio: match ffprobe priority — packet-sum over
                // edited duration, falling back to esds/btrt only when stsz
                // is unusable (typical of fragmented MP4).
                stream.bitRate = derived
            }
            if stream.bitRate == nil,
               let sr = stream.sampleRate, sr > 0,
               let ch = stream.channels, ch > 0,
               let bd = stream.bitDepth, bd > 0 {
                stream.bitRate = sr * ch * bd
            }
            metadata.audioStreams.append(stream)

            if metadata.audioCodec == nil { metadata.audioCodec = stream.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = stream.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = stream.channels }
        } else if isSubtitleHandler(handlerType), !isChapterTextTrack, let stsdBox {
            metadata.streamOrder.append(.subtitle(metadata.subtitleStreams.count))
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            stream.duration = trackDuration
            stream.language = language
            parseSubtitleSampleEntry(stsdBox.data, handlerType: handlerType, into: &stream)
            if dispositions.isDefault { stream.isDefault = true }
            if dispositions.isForced { stream.isForced = true }
            if dispositions.isHearingImpaired { stream.isHearingImpaired = true }
            metadata.subtitleStreams.append(stream)
        } else if isDataHandler(handlerType) || isChapterTextTrack {
            // Anything ffprobe reports with `codec_type=data`: timecode
            // (`tmcd`), Apple metadata (`meta`/`mdta`), GoPro GPMF (`gpmd`),
            // embedded thumbnails (`pict`), and the QuickTime text tracks
            // referenced via `tref:chap` for chapter titles. We expose them
            // so per-stream listings line up 1:1 with ffprobe's count.
            metadata.streamOrder.append(.data(metadata.dataStreams.count))
            var stream = DataStream(index: metadata.dataStreams.count, handlerType: handlerType)
            stream.duration = trackDuration
            stream.language = language
            stream.isDefault = tkhdIsDefault
            if let stsdBox {
                parseDataSampleEntry(stsdBox.data, into: &stream)
                // Blackmagic RAW emits per-frame gyroscope and accelerometer
                // streams as `mebx` timed-metadata tracks. We don't decode
                // the per-frame samples (out of scope for the slate pass);
                // just flag presence so consumers know the streams exist.
                detectBRAWMotionTracks(in: stsdBox.data, into: &metadata)
            }
            stream.codecName = stream.codecName ?? dataHandlerLongName(handlerType, isChapter: isChapterTextTrack)
            metadata.dataStreams.append(stream)
        }
    }

    /// Handler types that carry timed metadata payloads rather than rendered
    /// audio/video/subtitle samples. ffprobe groups all of these under
    /// `codec_type=data`.
    static func isDataHandler(_ type: String) -> Bool {
        switch type {
        case "tmcd", "meta", "mdta", "gpmd", "pict", "url ", "data":
            return true
        default:
            return false
        }
    }

    /// Best-effort human label for a data-track handler. Used when the
    /// stsd sample-entry inspection didn't produce a more specific name.
    static func dataHandlerLongName(_ type: String, isChapter: Bool) -> String? {
        if isChapter { return "QuickTime Chapter" }
        switch type {
        case "tmcd": return "QuickTime Timecode"
        case "meta", "mdta": return "QuickTime Metadata"
        case "gpmd": return "GoPro GPMF"
        case "pict": return "Image"
        default: return nil
        }
    }

    /// Pull the FourCC from the first sample entry in `stsd` for data
    /// tracks. The ISOBMFF SampleEntry layout is shared, so the same
    /// "skip FullBox header + entry_count + entry_size" recipe used for
    /// audio / subtitle tracks works here too.
    static func parseDataSampleEntry(_ stsdData: Data, into stream: inout DataStream) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        _ = try? reader.readUInt32BigEndian() // entry_size
        guard let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }
        stream.codec = codec
    }

    /// ISOBMFF handler types that advertise subtitle / timed-text / closed-
    /// caption content:
    ///   "subt" — generic subtitle (WebVTT / TTML / 3GPP timed text)
    ///   "text" — QuickTime text track
    ///   "sbtl" — subtitles (also produced by older Apple tools)
    ///   "clcp" — closed captions
    static func isSubtitleHandler(_ type: String) -> Bool {
        type == "subt" || type == "text" || type == "sbtl" || type == "clcp"
    }

    /// Inspect the first SampleEntry in `stsd` to capture the subtitle codec
    /// FourCC (tx3g / wvtt / stpp / c608 / c708 / text / …) and, for 3GPP
    /// timed-text / QuickTime text tracks, the forced-display bit from
    /// `displayFlags`.
    static func parseSubtitleSampleEntry(
        _ stsdData: Data,
        handlerType: String,
        into stream: inout SubtitleStream
    ) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count
        guard reader.remainingCount >= 8 else { return }
        _ = try? reader.readUInt32BigEndian() // entry_size
        guard let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        stream.codec = codec
        stream.codecName = subtitleLongName(forFourCC: codec, handler: handlerType) ?? codec

        // TextSampleEntry (tx3g, QuickTime text) extends SampleEntry with a
        // 32-bit displayFlags field. Per 3GPP TS 26.245 §5.16, bit 0x40000000
        // = "all samples are forced". ffmpeg writes forced tracks via the
        // `kind` box instead (handled in parseTrak); this path catches
        // muxers that follow the 3GPP spec.
        if codec == "tx3g" || codec == "text" {
            // Skip SampleEntry base: reserved[6] + data_reference_index(2).
            guard (try? reader.readBytes(8)) != nil,
                  let displayFlags = try? reader.readUInt32BigEndian() else { return }
            if (displayFlags & 0x40000000) != 0 {
                stream.isForced = true
            }
        }
    }

    /// DASH Role scheme dispositions recorded on a `trak` via `udta > kind`.
    private struct TrackDispositions {
        var isDefault = false
        var isForced = false
        var isHearingImpaired = false
    }

    /// Walk `trak > udta > kind` boxes, mapping recognised DASH Role values
    /// ("main", "forced-subtitle", "caption", "sign") and TV-Anytime audio
    /// purpose code 4 to subtitle disposition flags.
    private static func parseTrackKindDispositions(
        _ trakChildren: [ISOBMFFBox]
    ) -> TrackDispositions {
        var result = TrackDispositions()
        guard let udta = trakChildren.first(where: { $0.type == "udta" }),
              let udtaChildren = try? ISOBMFFBoxReader.parseBoxes(from: udta.data) else {
            return result
        }
        for kind in udtaChildren where kind.type == "kind" {
            guard let (scheme, value) = parseKindBox(kind.data) else { continue }
            switch scheme {
            case "urn:mpeg:dash:role:2011", "urn:mpeg:dash:role:2012":
                switch value {
                case "main": result.isDefault = true
                case "forced-subtitle": result.isForced = true
                case "caption", "sign": result.isHearingImpaired = true
                default: break
                }
            case "urn:tva:metadata:cs:AudioPurposeCS:2007" where value == "4":
                result.isHearingImpaired = true
            default: break
            }
        }
        return result
    }

    /// Decode a `kind` FullBox payload into (schemeURI, value). Both fields
    /// are NUL-terminated UTF-8 strings per ISO/IEC 14496-12.
    static func parseKindBox(_ data: Data) -> (scheme: String, value: String)? {
        // FullBox header: version(1) + flags(3).
        guard data.count > 4 else { return nil }
        let payload = data[data.startIndex + 4 ..< data.endIndex]
        let parts = payload.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let scheme = String(data: Data(parts[0]), encoding: .utf8),
              let value = String(data: Data(parts[1]), encoding: .utf8) else {
            return nil
        }
        return (scheme, value)
    }

    static func subtitleLongName(forFourCC fourCC: String, handler: String) -> String? {
        switch fourCC {
        case "tx3g": return "3GPP Timed Text"
        case "wvtt": return "WebVTT"
        case "stpp": return "TTML"
        case "text": return "QuickTime Text"
        case "c608": return "CEA-608 Closed Captions"
        case "c708": return "CEA-708 Closed Captions"
        default:
            if handler == "clcp" { return "Closed Captions" }
            if handler == "subt" { return "Subtitles" }
            return nil
        }
    }

    /// QuickTime timecode (`tmcd`) track extraction. The trak's stsd sample
    /// entry describes the frame rate + drop-frame/wrap flags; the first
    /// media sample in mdat is a 32-bit frame counter. We locate the sample
    /// via stco (32-bit chunk offsets) or co64 (64-bit) and reach into the
    /// full file blob to read those 4 bytes.
    ///
    /// QuickTime File Format § "Timecode Media Information" — see
    /// https://developer.apple.com/documentation/quicktime-file-format/timecode_sample_description
    static func parseTmcdTrackTimecode(_ trakData: Data, fullData: Data) -> String? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              hdlr.data.count >= 12 else { return nil }

        let handlerType = String(
            data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
            encoding: .ascii
        ) ?? ""
        guard handlerType == "tmcd" else { return nil }

        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data) else { return nil }

        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }),
              let entry = parseTmcdSampleEntry(stsd.data) else { return nil }

        // Find first chunk offset. Prefer co64 (64-bit) when present.
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
              offset + 4 <= UInt64(fullData.count) else { return nil }

        let s = fullData.startIndex + Int(offset)
        let counter = (UInt32(fullData[s]) << 24)
            | (UInt32(fullData[s + 1]) << 16)
            | (UInt32(fullData[s + 2]) << 8)
            | UInt32(fullData[s + 3])

        return formatTimecode(
            frameCounter: counter,
            numFrames: entry.numFrames,
            dropFrame: entry.dropFrame
        )
    }

    private struct TmcdSampleEntry {
        let dropFrame: Bool
        let numFrames: Int // frames per second (rounded up: 30 for 29.97, 24 for 23.98)
    }

    /// Decode a `tmcd` SampleEntry from stsd. Layout:
    ///   FullBox header (8 bytes: size + type)
    ///   Reserved(6) + data_reference_index(2)           // SampleEntry
    ///   Reserved(4)                                     // TimeCodeSampleEntry
    ///   Flags(4)  — bit 0 = drop frame, bit 1 = 24h max, bit 2 = negative ok,
    ///               bit 3 = counter
    ///   TimeScale(4)
    ///   FrameDuration(4)
    ///   NumberOfFrames(1)
    ///   Reserved(1)
    private static func parseTmcdSampleEntry(_ stsdData: Data) -> TmcdSampleEntry? {
        guard stsdData.count >= 8 + 8 + 4 + 4 + 4 + 4 + 2 else { return nil }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox flags/version
        _ = try? reader.readUInt32BigEndian() // entry_count
        // Skip the SampleEntry size+type (8 bytes) and the 8 bytes of
        // reserved+data_reference_index + extra reserved.
        guard let entrySize = try? reader.readUInt32BigEndian(),
              let typeBytes = try? reader.readBytes(4),
              let fourCC = String(data: typeBytes, encoding: .ascii),
              fourCC == "tmcd",
              entrySize >= 34 else { return nil }
        _ = try? reader.readBytes(6) // reserved
        _ = try? reader.readUInt16BigEndian() // data_reference_index
        _ = try? reader.readUInt32BigEndian() // reserved

        guard let flags = try? reader.readUInt32BigEndian(),
              let _ = try? reader.readUInt32BigEndian(), // timescale (unused — numFrames is enough)
              let _ = try? reader.readUInt32BigEndian(), // frame duration
              let numFrames = try? reader.readUInt8() else { return nil }
        let dropFrame = (flags & 0x01) != 0
        return TmcdSampleEntry(dropFrame: dropFrame, numFrames: Int(numFrames))
    }

    /// `stco`: FullBox header(4) + entry_count(4) + entry_count × 32-bit offsets.
    static func parseSTCOFirst(_ data: Data) -> UInt32? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // flags+version
        guard let count = try? reader.readUInt32BigEndian(), count > 0,
              let first = try? reader.readUInt32BigEndian() else { return nil }
        return first
    }

    /// `co64`: FullBox header(4) + entry_count(4) + entry_count × 64-bit offsets.
    static func parseCO64First(_ data: Data) -> UInt64? {
        guard data.count >= 16 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian(), count > 0,
              let first = try? reader.readUInt64BigEndian() else { return nil }
        return first
    }

    /// Format a tmcd frame counter to HH:MM:SS:FF (or HH:MM:SS;FF for
    /// drop-frame). Drop-frame arithmetic per SMPTE 12M: skip two frames at
    /// the start of every minute except every tenth minute, for 29.97 fps.
    static func formatTimecode(frameCounter: UInt32, numFrames: Int, dropFrame: Bool) -> String? {
        guard numFrames > 0 else { return nil }
        var frames = Int(frameCounter)
        let fps = numFrames

        if dropFrame {
            // Drop-frame: commonly 29.97 (numFrames=30) or 59.94 (numFrames=60).
            // Drop `dropCount` frames at the top of every minute except every 10th.
            let dropCount = fps / 15 // 30fps → 2 drops, 60fps → 4 drops
            let framesPer10Min = fps * 60 * 10 - dropCount * 9
            let framesPerMin = fps * 60 - dropCount
            let d = frames / framesPer10Min
            let m = frames % framesPer10Min
            if m > dropCount {
                frames = frames + dropCount * 9 * d + dropCount * ((m - dropCount) / framesPerMin)
            } else {
                frames = frames + dropCount * 9 * d
            }
        }

        let totalSeconds = frames / fps
        let ff = frames % fps
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = (totalSeconds / 3600) % 24

        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    static func parseTKHDDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 4 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3)

        let dimensionOffset: Int
        if version == 0 {
            dimensionOffset = 4 + 76
        } else {
            dimensionOffset = 4 + 88
        }
        guard data.count >= dimensionOffset + 8,
              (try? reader.seek(to: dimensionOffset)) != nil,
              let widthFP = try? reader.readUInt32BigEndian(),
              let heightFP = try? reader.readUInt32BigEndian() else { return nil }

        return (Int(widthFP >> 16), Int(heightFP >> 16))
    }

    /// Decode the display rotation from the `tkhd` 3x3 transformation matrix
    /// (ISO/IEC 14496-12 §8.3.2). The matrix is stored in 16.16 fixed-point
    /// for the upper-left 2x2 (a, b, c, d) and 2.30 fixed-point for the
    /// translation/perspective row, but only `a` and `b` are needed to
    /// recover the rotation angle: `θ = -atan2(b, a)`.
    ///
    /// Matches ffprobe's `side_data_list[].rotation` convention:
    /// - identity → returns nil (no side data emitted)
    /// - portrait phone video (recorded sideways) → -90
    /// - upside-down → -180 (or equivalently 180)
    /// - 90° CCW → 90
    ///
    /// Matrix offset depends on the FullBox version: 40 bytes from the start
    /// for v0 (32-bit times), 52 bytes for v1 (64-bit times).
    static func parseTKHDRotation(_ data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let s = data.startIndex
        let version = data[s]
        let matrixOffset = (version == 1) ? 52 : 40
        guard data.count >= matrixOffset + 8 else { return nil }

        func readSignedFixed(_ relOffset: Int) -> Double {
            let p = s + matrixOffset + relOffset
            let raw = (UInt32(data[p]) << 24)
                | (UInt32(data[p + 1]) << 16)
                | (UInt32(data[p + 2]) << 8)
                | UInt32(data[p + 3])
            return Double(Int32(bitPattern: raw)) / 65536.0
        }

        let a = readSignedFixed(0)
        let b = readSignedFixed(4)
        if a == 0 && b == 0 { return nil }

        let degrees = -atan2(b, a) * 180.0 / .pi
        let rounded = Int(degrees.rounded())
        return rounded == 0 ? nil : rounded
    }

    /// tkhd `track_ID` (UInt32). Layout:
    ///   FullBox header(4) + creation_time/mod_time (8 in v0, 16 in v1) + track_ID(4)
    static func parseTKHDTrackID(_ trakData: Data) -> UInt32? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
              tkhd.data.count >= 4 else { return nil }
        let data = tkhd.data
        let s = data.startIndex
        let version = data[s]
        let offset = (version == 1) ? (4 + 16) : (4 + 8)
        guard data.count >= offset + 4 else { return nil }
        return (UInt32(data[s + offset]) << 24)
            | (UInt32(data[s + offset + 1]) << 16)
            | (UInt32(data[s + offset + 2]) << 8)
            | UInt32(data[s + offset + 3])
    }

    /// `trak > tref > tmcd` carries the list of tmcd trackIDs this track uses
    /// for timecode (QuickTime File Format § Track Reference). Returns an
    /// empty array when no such reference exists.
    static func parseTrefTmcd(_ trakData: Data) -> [UInt32] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tref = trakChildren.first(where: { $0.type == "tref" }),
              let trefChildren = try? ISOBMFFBoxReader.parseBoxes(from: tref.data),
              let tmcdRef = trefChildren.first(where: { $0.type == "tmcd" }) else { return [] }
        let payload = tmcdRef.data
        let count = payload.count / 4
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let s = payload.startIndex + i * 4
            let v = (UInt32(payload[s]) << 24)
                | (UInt32(payload[s + 1]) << 16)
                | (UInt32(payload[s + 2]) << 8)
                | UInt32(payload[s + 3])
            out.append(v)
        }
        return out
    }

    /// Return the four-byte handler type on a trak (`vide`, `soun`, `tmcd`, …),
    /// or nil when the trak lacks mdia/hdlr.
    internal static func trakHandlerType(_ trakData: Data) -> String? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              hdlr.data.count >= 12 else { return nil }
        return String(
            data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
            encoding: .ascii
        )
    }

    /// tkhd flags live in the bottom 24 bits of the FullBox header. Bit 0 =
    /// track_enabled (the only one ffprobe consults for `disposition.default`).
    /// Bits 1 / 2 / 3 carry in_movie / in_preview / in_poster respectively but
    /// don't influence ffprobe's default-track flag.
    static func parseTKHDIsDefault(_ data: Data) -> Bool? {
        guard data.count >= 4 else { return nil }
        let s = data.startIndex
        let flags = (UInt32(data[s + 1]) << 16) | (UInt32(data[s + 2]) << 8) | UInt32(data[s + 3])
        return (flags & 0x1) != 0
    }

    /// mdhd (media header): returns duration in seconds (using this track's timescale),
    /// the timescale itself (so callers can compute r_frame_rate from stts), and
    /// the ISO 639-2/T language code if set.
    internal static func parseMDHD(_ data: Data) -> (duration: TimeInterval?, language: String?, timescale: UInt32)? {
        guard data.count >= 4 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3)

        let timescale: UInt32
        let duration: UInt64
        if version == 0 {
            guard data.count >= 24,
                  (try? reader.skip(8)) != nil, // creation + modification
                  let ts = try? reader.readUInt32BigEndian(),
                  let dur = try? reader.readUInt32BigEndian() else {
                return nil
            }
            timescale = ts
            duration = UInt64(dur)
        } else {
            guard data.count >= 36,
                  (try? reader.skip(16)) != nil, // creation + modification
                  let ts = try? reader.readUInt32BigEndian(),
                  let dur = try? reader.readUInt64BigEndian() else {
                return nil
            }
            timescale = ts
            duration = dur
        }

        // Language is 15 bits packed as three 5-bit values, each + 0x60 = ASCII letter.
        let langRaw = try? reader.readUInt16BigEndian()
        var language: String?
        if let raw = langRaw, raw != 0, (raw & 0x8000) == 0 {
            let c0 = UInt8(((raw >> 10) & 0x1F) + 0x60)
            let c1 = UInt8(((raw >> 5) & 0x1F) + 0x60)
            let c2 = UInt8((raw & 0x1F) + 0x60)
            if let s = String(bytes: [c0, c1, c2], encoding: .ascii),
               s.allSatisfy({ $0.isLetter }) {
                language = s
            }
        }

        let seconds: TimeInterval? = (timescale > 0) ? Double(duration) / Double(timescale) : nil
        return (seconds, language, timescale)
    }

    /// Sum every `segment_duration` in an `elst` FullBox and return the total
    /// in **movie timescale** ticks. An elst can have one entry (the common
    /// B-frame pre-roll trim) or many (ffmpeg's seamless concatenation).
    /// Entries whose media_time is -1 are pure "empty edits" (dwell time
    /// before the first frame) — they still count towards the visible window.
    /// Layout per ISO/IEC 14496-12:
    ///   version(1) + flags(3) + entry_count(4) + entries
    ///   v0 entry: segment_duration(4) + media_time(4) + media_rate_int(2) + media_rate_frac(2)
    ///   v1 entry: segment_duration(8) + media_time(8) + media_rate_int(2) + media_rate_frac(2)
    static func parseELSTSegmentDuration(_ data: Data) -> UInt64? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        guard let version = try? reader.readUInt8() else { return nil }
        _ = try? reader.readBytes(3) // flags
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var total: UInt64 = 0
        for _ in 0..<min(entryCount, 1 << 16) {
            let segDur: UInt64
            if version == 1 {
                guard let v = try? reader.readUInt64BigEndian() else { break }
                segDur = v
                guard (try? reader.readUInt64BigEndian()) != nil else { break } // media_time
            } else {
                guard let v = try? reader.readUInt32BigEndian() else { break }
                segDur = UInt64(v)
                guard (try? reader.readUInt32BigEndian()) != nil else { break } // media_time
            }
            guard (try? reader.readUInt32BigEndian()) != nil else { break } // media_rate
            total &+= segDur
        }
        return total
    }

    /// stsz payload layout: version+flags(4) + sample_size(4) + sample_count(4).
    /// When sample_size is non-zero all samples share a size and sample_count is exact.
    static func parseSTSZSampleCount(_ box: ISOBMFFBox) -> Int? {
        guard box.data.count >= 12 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4) // version + flags
        _ = try? reader.readUInt32BigEndian() // sample_size
        return (try? reader.readUInt32BigEndian()).map(Int.init)
    }

    /// Sum the byte lengths of every sample in a track. When `sample_size` in
    /// the stsz header is non-zero, all samples share that size — multiply.
    /// Otherwise iterate the per-sample table. Used to derive per-stream
    /// bitrate when no `btrt` / `esds` field provides one.
    static func parseSTSZTotalBytes(_ box: ISOBMFFBox) -> Int64? {
        guard box.data.count >= 12 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4) // version + flags
        guard let uniformSize = try? reader.readUInt32BigEndian(),
              let count = try? reader.readUInt32BigEndian() else { return nil }
        if uniformSize > 0 {
            return Int64(uniformSize) * Int64(count)
        }
        var total: Int64 = 0
        let cap = min(count, 1 << 24)
        for _ in 0..<cap {
            guard let sz = try? reader.readUInt32BigEndian() else { break }
            total &+= Int64(sz)
        }
        return total > 0 ? total : nil
    }

    /// stts payload: version+flags(4) + entry_count(4) + [sample_count(4) + sample_delta(4)]*.
    /// Sum the sample_count fields to approximate the frame count.
    static func parseSTTSSampleCount(_ box: ISOBMFFBox) -> Int? {
        guard box.data.count >= 8 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var total: UInt64 = 0
        for _ in 0..<min(entryCount, 1 << 20) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  (try? reader.skip(4)) != nil else {
                break
            }
            total &+= UInt64(sc)
        }
        return total > 0 ? Int(total) : nil
    }

    /// Pick the most-common sample delta across stts entries. ffprobe uses
    /// this to compute `r_frame_rate` — the cadence the decoder ticks at,
    /// independent of any partial trailing sample that nudges samples/duration
    /// off the integer rate.
    static func parseSTTSDominantDelta(_ box: ISOBMFFBox) -> UInt32? {
        guard box.data.count >= 8 else { return nil }
        var reader = BinaryReader(data: box.data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var counts: [UInt32: UInt64] = [:]
        for _ in 0..<min(entryCount, 1 << 20) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  let sd = try? reader.readUInt32BigEndian() else { break }
            guard sd > 0 else { continue }
            counts[sd, default: 0] &+= UInt64(sc)
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

}
