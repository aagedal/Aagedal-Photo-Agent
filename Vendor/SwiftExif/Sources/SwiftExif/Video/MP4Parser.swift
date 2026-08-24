import Foundation

/// Parses MP4/MOV/M4V video files to extract metadata.
/// Reuses ISOBMFFBoxReader for box-level parsing.
public struct MP4Parser: Sendable {

    // Seconds between 1904-01-01 and 1970-01-01 (QuickTime epoch to Unix epoch)
    private static let epochOffset: TimeInterval = 2082844800

    // XMP UUID prefix: BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
    static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    /// Parse video metadata from data.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        // Parse top-level boxes, but skip mdat payload to save memory
        let boxes = try parseTopLevelBoxes(data)

        // Determine format from ftyp. Legacy QuickTime / Blackmagic RAW files
        // omit ftyp entirely (the file starts with `wide` + `mdat`, with the
        // moov tail-placed); fall back to .mov so the rest of the parse can
        // proceed. Callers that know the extension override metadata.format
        // to a more specific value (e.g. .braw) afterwards.
        let format: VideoFormat
        if let ftyp = boxes.first(where: { $0.type == "ftyp" }) {
            format = detectFormat(from: ftyp)
        } else {
            format = .mov
        }

        var metadata = VideoMetadata(format: format)

        // Find moov box
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw MetadataError.invalidVideo("Missing moov box")
        }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov.data)

        // Parse mvhd (movie header). Returns the movie timescale, which is
        // needed later by `edts > elst` entries (their segment_duration field
        // is expressed in movie timescale, not media timescale).
        var movieTimescale: UInt32 = 0
        if let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) {
            movieTimescale = parseMVHD(mvhd.data, into: &metadata)
        }

        // Pre-compute the set of track IDs that serve as QuickTime chapter
        // text tracks — they're the target of any `tref > chap` reference
        // anywhere in the movie. Must be excluded from `subtitleStreams`
        // (ffprobe filters them the same way: `-select_streams s` returns
        // zero even though the handler is "text"/"subt").
        //
        // The reference can live on any trak — DaVinci Resolve writes it on
        // video + audio + every subtitle track; ffmpeg's mov muxer writes it
        // on audio + subtitles but NOT on the video track. Scan them all.
        var chapterReferencedTrackIDs = Set<UInt32>()
        for trak in moovChildren where trak.type == "trak" {
            for tid in parseTrefChap(trak.data) {
                chapterReferencedTrackIDs.insert(tid)
            }
        }

        // Parse tracks
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            parseTrak(
                trak.data,
                movieTimescale: movieTimescale,
                chapterTrackIDs: chapterReferencedTrackIDs,
                into: &metadata
            )
        }

        // QuickTime timecode track (`tmcd`): the sample entry in stsd gives
        // the frame rate + drop-frame flag and the first media sample in mdat
        // is a 32-bit frame counter. Needs the original data blob for the
        // mdat read, so we walk the trak list here rather than in parseTrak.
        //
        // ffprobe surfaces the decoded timecode in two places: the clip-level
        // `format.tags.timecode` (via the first tmcd track) and, per stream,
        // the video track that cross-references a tmcd track via `tref.tmcd`.
        // Mirror that behaviour here.
        var tmcdTimecodes: [UInt32: String] = [:]
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            guard trakHandlerType(trak.data) == "tmcd",
                  let tid = parseTKHDTrackID(trak.data),
                  let tc = parseTmcdTrackTimecode(trak.data, fullData: data) else { continue }
            tmcdTimecodes[tid] = tc
        }
        if !tmcdTimecodes.isEmpty {
            // Record the first tmcd-track value as the clip-level primary.
            // Using `recordTimecode` keeps the `timecodes` provenance array
            // and the legacy scalar `timecode` field in sync.
            if let first = tmcdTimecodes.first?.value {
                metadata.recordTimecode(first, source: .tmcdTrack)
            }
            // ffprobe only sets the per-stream `timecode` tag on a video track
            // when that track has an explicit `tref > tmcd` reference to a
            // timecode track. Recordings without the cross-reference (e.g.
            // Atomos Ninja ProRes RAW) surface timecode only at
            // `format.tags.timecode`. Mirror that exactly — no fallback.
            var videoIdx = 0
            for trak in moovChildren.filter({ $0.type == "trak" }) {
                guard trakHandlerType(trak.data) == "vide" else { continue }
                defer { videoIdx += 1 }
                guard videoIdx < metadata.videoStreams.count,
                      metadata.videoStreams[videoIdx].timecode == nil else { continue }
                let refs = parseTrefTmcd(trak.data)
                if let tid = refs.first(where: { tmcdTimecodes[$0] != nil }),
                   let tc = tmcdTimecodes[tid] {
                    metadata.videoStreams[videoIdx].timecode = tc
                    // Flag disagreement between this video track's
                    // tref-linked tmcd and the clip-level primary. ffprobe
                    // reports both values in its streams/format blocks;
                    // we mirror that plus a warning so callers can act on
                    // the divergence rather than silently picking one.
                    if let clip = metadata.timecode, clip != tc {
                        metadata.warnings.append(
                            "timecode mismatch: clip=\(clip) vs videoStream[\(videoIdx)]=\(tc)"
                        )
                    }
                }
            }
        }

        // Blackmagic RAW: the per-frame interpretation header at the start
        // of every video chunk in mdat carries clip-level defaults that
        // aren't in moov.meta — ISO equivalent (`isoe`), white-balance
        // Kelvin (`wkel`), and white-balance tint (`wtin`). The values are
        // identical for every frame in the clips we've inspected (camera
        // bakes them once at record-start), so reading frame 0 is enough.
        for trak in moovChildren.filter({ $0.type == "trak" }) {
            guard trakHandlerType(trak.data) == "vide" else { continue }
            parseBRAWFirstFrameAttributes(
                trak.data, fullData: data, into: &metadata
            )
        }

        // Chapter markers. Two paths, both standard:
        //   1. QuickTime text-track chapters — the video track carries
        //      `tref > chap` pointing at one or more text/subt tracks whose
        //      samples are the chapter titles. Apple's QuickTime, Compressor,
        //      and iTunes all write this form.
        //   2. Nero-style `udta > chpl` — a flat list of (start, title) pairs
        //      written by x264/ffmpeg/MP4Box pipelines.
        // ffprobe reports whichever is present; when both exist the chap
        // track wins (per-sample granularity beats a flat list). Mirror that.
        let chapterTracks = parseChapterTracks(moovChildren, fullData: data)
        if !chapterTracks.isEmpty {
            metadata.chapters = chapterTracks
        } else if let udta = moovChildren.first(where: { $0.type == "udta" }),
                  let chpl = (try? ISOBMFFBoxReader.parseBoxes(from: udta.data))?
                      .first(where: { $0.type == "chpl" }) {
            metadata.chapters = parseCHPL(chpl.data)
        }

        // Parse udta -> meta -> ilst (QuickTime metadata)
        if let udta = moovChildren.first(where: { $0.type == "udta" }) {
            parseUDTA(udta.data, into: &metadata)
        }

        // Some writers place mdta-style metadata directly under `moov` rather
        // than wrapped in `udta` — Blackmagic RAW does this with its full
        // camera/clip slate (camera_type, viewing_gamma, offspeed_frame_time …).
        // ffmpeg's mov demuxer reads this same shape.
        if let meta = moovChildren.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // Check for top-level meta box (some files put XMP here)
        if let meta = boxes.first(where: { $0.type == "meta" }) {
            parseMetaBox(meta.data, into: &metadata)
        }

        // Check for XMP in uuid boxes
        for uuid in boxes.filter({ $0.type == "uuid" }) {
            parseUUIDBox(uuid.data, into: &metadata)
        }

        // Once XMP has been attached (via ilst, top-level meta, or the XMP
        // uuid), pull xmpDM:startTimeCode / altTimeCode out and record them
        // as provenance-tagged timecodes. A mismatch with an already-recorded
        // tmcd/udta value surfaces as a `warnings` entry.
        metadata.ingestXMPTimecodes()
        // Sony NRT blobs arrive via the NRT uuid box above; fold any start
        // timecode into the provenance array the same way.
        metadata.ingestNRTTimecode()

        // Parse C2PA manifest store if present (top-level jumb or uuid-wrapped JUMBF).
        if let jumbfData = C2PAReader.extractJUMBFFromISOBMFF(boxes) {
            do {
                if let c2pa = try C2PAReader.parseManifestStore(from: jumbfData) {
                    metadata.c2pa = c2pa
                }
            } catch {
                metadata.warnings.append("C2PA parse error: \(error)")
            }
        }

        // Derive ffprobe-compatible fields the parser can't read directly:
        // color range / chroma siting defaults, pixelFormat, avg/rFrameRate.
        for i in 0..<metadata.videoStreams.count {
            // ISOBMFF color: when no `colr` box is present, ffprobe assumes
            // limited-range YUV ("tv") for the H.264/H.265/AV1/VP9 codecs that
            // dominate Apple/Adobe pipelines, and tv for ProRes too. Mirror
            // that behaviour so JSON output isn't blank on every other clip.
            if isLimitedRangeDefaultCodec(metadata.videoStreams[i].codec) {
                if metadata.videoStreams[i].colorInfo == nil {
                    metadata.videoStreams[i].colorInfo = VideoColorInfo(fullRange: false)
                } else if metadata.videoStreams[i].colorInfo?.fullRange == nil {
                    metadata.videoStreams[i].colorInfo?.fullRange = false
                }
            }
            // Chroma siting: ffprobe surfaces a default for the H.264/HEVC
            // family when the bitstream omits chroma_sample_loc_type — "left"
            // for 4:2:0 (matches MPEG-2/AVC), "topleft" for APV. AV1/VP9
            // routinely report nothing here, so we leave them alone rather
            // than fabricating a value.
            if metadata.videoStreams[i].chromaLocation == nil,
               let codec = metadata.videoStreams[i].codec {
                switch codec {
                case "avc1", "avc3",
                     "hvc1", "hev1", "hev2", "dvh1", "dvhe":
                    if metadata.videoStreams[i].chromaSubsampling == "4:2:0" {
                        metadata.videoStreams[i].chromaLocation = "left"
                    }
                case "apv1":
                    metadata.videoStreams[i].chromaLocation = "topleft"
                default:
                    break
                }
            }
            if metadata.videoStreams[i].pixelFormat == nil {
                metadata.videoStreams[i].pixelFormat = PixelFormatDerivation.derive(
                    chromaSubsampling: metadata.videoStreams[i].chromaSubsampling,
                    bitDepth: metadata.videoStreams[i].bitDepth,
                    fullRange: metadata.videoStreams[i].colorInfo?.fullRange,
                    codec: metadata.videoStreams[i].codec
                )
            }
            if metadata.videoStreams[i].avgFrameRate == nil,
               let fps = metadata.videoStreams[i].frameRate {
                metadata.videoStreams[i].avgFrameRate = fps
                if metadata.videoStreams[i].rFrameRate == nil {
                    metadata.videoStreams[i].rFrameRate = fps
                }
            }
            // Pixel/display aspect ratio: default to square pixels when no
            // pasp box was present and tkhd didn't override. ffprobe always
            // emits SAR/DAR for video tracks.
            //
            // `displayWidth`/`displayHeight` follow ffprobe's convention: final
            // rendered shape after PAR and rotation. The pasp branch and the
            // tkhd fallback already write in that orientation; the defaults
            // below apply a quarter-turn swap when neither fired and rotation
            // is ±90. The PAR computation then un-rotates back to coded
            // orientation — PAR is intrinsic to the encoded pixel grid and
            // rotation doesn't change individual pixels.
            if let w = metadata.videoStreams[i].width,
               let h = metadata.videoStreams[i].height, w > 0, h > 0 {
                let rotation = metadata.videoStreams[i].rotation ?? 0
                let isQuarterTurn = abs(rotation) == 90
                if metadata.videoStreams[i].displayWidth == nil {
                    metadata.videoStreams[i].displayWidth = isQuarterTurn ? h : w
                }
                if metadata.videoStreams[i].displayHeight == nil {
                    metadata.videoStreams[i].displayHeight = isQuarterTurn ? w : h
                }
                if metadata.videoStreams[i].pixelAspectRatio == nil,
                   let dw = metadata.videoStreams[i].displayWidth,
                   let dh = metadata.videoStreams[i].displayHeight, dw > 0, dh > 0 {
                    let codedDW = isQuarterTurn ? dh : dw
                    let codedDH = isQuarterTurn ? dw : dh
                    let parNum = codedDW * h
                    let parDen = codedDH * w
                    let g = gcdMP4(parNum, parDen)
                    metadata.videoStreams[i].pixelAspectRatio = (parNum / g, parDen / g)
                }
            }
            // Default-track flag: ISOBMFF doesn't have a per-track "default"
            // bit the way Matroska does, so ffprobe marks only the first track
            // of each kind as default. Match that.
            if metadata.videoStreams[i].isDefault == nil {
                metadata.videoStreams[i].isDefault = (i == 0)
            }
            if metadata.videoStreams[i].isAttachedPic == nil {
                metadata.videoStreams[i].isAttachedPic = false
            }
        }
        // Mirror per-stream PAR/DAR up to top-level metadata.
        if let v = metadata.videoStreams.first {
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = v.pixelAspectRatio }
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
        }
        for i in 0..<metadata.audioStreams.count {
            if metadata.audioStreams[i].isDefault == nil {
                metadata.audioStreams[i].isDefault = (i == 0)
            }
        }

        // Format-level duration: keep mvhd, but cap it at max(audio, video
        // stream durations) if mvhd is larger. Real-world files routinely
        // declare mvhd as the longest mdhd of *any* track, including subtitle
        // / chapter tracks whose declared length exceeds the playable a/v
        // essence — ChapterMarkerDualSubtitle.mp4 has subtitle2 mdhd=98.691s
        // but audio/video both end at ~71.16s, and ffprobe reports 71.146s.
        // We don't blindly use max(av) instead, because for healthy files
        // mvhd is *smaller* than the longest av stream (mvhd respects the
        // edit-list-trimmed window while audio mdhd reports the raw essence)
        // and ffprobe still prefers the mvhd value in that case.
        let avDurations = metadata.videoStreams.compactMap(\.duration)
                        + metadata.audioStreams.compactMap(\.duration)
        if let avMax = avDurations.max(), avMax > 0,
           let mvhd = metadata.duration, mvhd > avMax {
            metadata.duration = avMax
        }

        // Container bit_rate fallback (matches ffprobe `format.bit_rate`).
        let containerBytes = metadata.fileSize ?? Int64(data.count)
        if metadata.bitRate == nil,
           let dur = metadata.duration, dur > 0, containerBytes > 0 {
            metadata.bitRate = Int(Double(containerBytes) * 8.0 / dur)
        }

        // Sony RTMD summary — populated when an `rtmd` timed-metadata track
        // is present (Alpha A1 / A7S III / FX3 / FX30 etc). Reads only the
        // first rtmd sample, so it stays cheap. Per-frame harvest lives
        // behind the `rtmd-frames` CLI subcommand.
        if RTMDReader.hasRTMDTrack(in: data) {
            metadata.rtmd = RTMDSummary(
                imuSampleRateHz: RTMDReader.estimateIMUSampleRate(in: data),
                firstFrame: RTMDReader.firstFrameSnapshot(from: data)
            )
        }

        return metadata
    }

    /// ISOBMFF audio FourCCs that carry uncompressed PCM samples. Their bit
    /// rate is deterministic (sample_rate × channels × bit_depth), so we
    /// prefer that formula over stsz-sum-over-duration which introduces tiny
    /// rounding noise from the final partial sample.
    static func isUncompressedPCMCodec(_ codec: String) -> Bool {
        switch codec {
        case "sowt", "twos", "lpcm", "ipcm", "in24", "in32",
             "fl32", "fl64", "raw ", "NONE":
            return true
        default:
            return false
        }
    }

    private static func gcdMP4(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// Codecs that ffprobe treats as limited-range YUV ("tv") when no explicit
    /// color_range box is present. Used to fill in `color_range` and the
    /// "left" `chroma_location` default for plain H.264/H.265 clips.
    private static func isLimitedRangeDefaultCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        switch codec {
        case "avc1", "avc3",
             "hvc1", "hev1", "hev2", "dvh1", "dvhe",
             "vvc1", "vvi1",
             "av01",
             "vp08", "vp09",
             "apch", "apcn", "apcs", "apco", "ap4h", "ap4x", "apv1",
             "mp4v":
            return true
        default:
            return false
        }
    }

    // MARK: - Top-Level Parsing (skips mdat)

    private static func parseTopLevelBoxes(_ data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        var boxes: [ISOBMFFBox] = []

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let boxSize: Int
            if size32 == 1 {
                guard reader.remainingCount >= 8 else { break }
                let size64 = try reader.readUInt64BigEndian()
                // `Int(size64)` traps when a malformed largesize exceeds Int.max.
                // Guard the cast and require room for the 16-byte extended header.
                guard size64 >= 16, size64 <= UInt64(Int.max) else { break }
                boxSize = Int(size64)
            } else if size32 == 0 {
                boxSize = data.count - boxStart
            } else {
                boxSize = Int(size32)
            }

            let headerSize = (size32 == 1) ? 16 : 8
            let payloadSize = boxSize - headerSize
            guard payloadSize >= 0 else { break }

            if type == "mdat" {
                // Skip mdat payload — can be gigabytes of media data. Compare via
                // subtraction, not `boxStart + boxSize`: a largesize near Int.max
                // would overflow that addition and trap. `boxStart <= data.count`
                // always holds, so `data.count - boxStart` is non-negative.
                guard boxSize <= data.count - boxStart else { break } // mdat extends past EOF
                try reader.seek(to: boxStart + boxSize)
                boxes.append(ISOBMFFBox(type: "mdat", data: Data()))
            } else {
                // Subtraction form, not `reader.offset + payloadSize`: avoids an
                // Int-overflow trap when payloadSize is near Int.max.
                guard payloadSize <= data.count - reader.offset else { break }
                let payload = try reader.readBytes(payloadSize)
                boxes.append(ISOBMFFBox(type: type, data: payload))
            }
        }

        return boxes
    }

    // MARK: - Format Detection

    private static func detectFormat(from ftyp: ISOBMFFBox) -> VideoFormat {
        guard ftyp.data.count >= 4 else { return .mp4 }
        let brand = String(data: ftyp.data.prefix(4), encoding: .ascii) ?? ""
        switch brand {
        case "qt  ": return .mov
        case "M4V ", "M4VH", "M4VP": return .m4v
        default: return .mp4
        }
    }

    // MARK: - mvhd (Movie Header)

    @discardableResult
    private static func parseMVHD(_ data: Data, into metadata: inout VideoMetadata) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        var reader = BinaryReader(data: data)

        // FullBox: version (1 byte) + flags (3 bytes)
        guard let version = try? reader.readUInt8() else { return 0 }
        _ = try? reader.readBytes(3) // flags

        if version == 0 {
            // Version 0: 32-bit fields
            guard data.count >= 20 else { return 0 }
            guard let creationTime = try? reader.readUInt32BigEndian(),
                  let modTime = try? reader.readUInt32BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt32BigEndian() else { return 0 }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
            return timescale
        } else {
            // Version 1: 64-bit fields
            guard data.count >= 32 else { return 0 }
            guard let creationTime = try? reader.readUInt64BigEndian(),
                  let modTime = try? reader.readUInt64BigEndian(),
                  let timescale = try? reader.readUInt32BigEndian(),
                  let duration = try? reader.readUInt64BigEndian() else { return 0 }

            if creationTime > 0 {
                metadata.creationDate = Date(timeIntervalSince1970: Double(creationTime) - epochOffset)
            }
            if modTime > 0 {
                metadata.modificationDate = Date(timeIntervalSince1970: Double(modTime) - epochOffset)
            }
            if timescale > 0 {
                metadata.duration = Double(duration) / Double(timescale)
            }
            return timescale
        }
    }


}
