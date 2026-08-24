import Foundation

/// Reader for Matroska / WebM containers.
///
/// Matroska uses EBML (Extensible Binary Meta Language) framing. Each element
/// is `<vint id><vint length><payload>`, where VINTs are unsigned integers whose
/// length is encoded in a leading marker bit.
///
/// Scope: we pull top-level container facts (duration, timescale), Tracks
/// (video codec, dimensions, frame rate, colour, audio codec/samplerate) and
/// a handful of Segment/Info fields. We do not parse Cluster/BlockGroup data.
public struct MatroskaReader: Sendable {

    private static let ebmlHeaderID: UInt64 = 0x1A45DFA3

    /// Maximum number of bytes to walk when searching an element payload for
    /// a sub-element. Matroska header metadata (Segment/Info + Tracks) is
    /// tiny compared to media data, but we now also sniff early Cluster blocks
    /// to recover DTS / AC-3 frame-header bit_rate values when the muxer
    /// didn't write a per-track BPS SimpleTag. MakeMKV-style remuxes group all
    /// blocks for one track into its own run of clusters, so a first-audio
    /// track can live hundreds of MB into the segment — we widen the window
    /// accordingly. The file is memory-mapped so the added bytes cost address
    /// space, not RAM.
    private static let maxHeaderScan = 512 * 1024 * 1024

    /// True when the data begins with the EBML header magic.
    public static func isMatroska(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x1A && data[s + 1] == 0x45
            && data[s + 2] == 0xDF && data[s + 3] == 0xA3
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMatroska(data) else {
            throw MetadataError.invalidVideo("Not a Matroska file — missing EBML header")
        }

        var format: VideoFormat = .mkv
        var metadata = VideoMetadata(format: format)

        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 2 {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  size <= UInt64(Int.max) else { break }

            let declaredSize = Int(size)
            let remaining = reader.remainingCount
            let payloadStart = reader.offset
            switch id {
            case Self.ebmlHeaderID:
                // EBML header is tiny (~30 bytes) — require it to fit in our data.
                guard declaredSize <= remaining else { return metadata }
                let end = payloadStart + declaredSize
                let docType = readEBMLDocType(data, from: payloadStart, end: end)
                if docType == "webm" { format = .webm }
                if (try? reader.seek(to: end)) == nil { return metadata }

            case 0x18538067: // Segment
                // The Segment's declared size covers the entire file and can
                // legitimately exceed what we have loaded (callers may pass a
                // bounded prefix to avoid RAM blow-ups on Blu-ray-sized MKVs).
                // `parseSegment` caps its own walk at `maxHeaderScan`, so we
                // only need enough bytes for that — clamp to what's available.
                let effectiveSize = min(declaredSize, remaining)
                let scanEnd = min(payloadStart + effectiveSize, payloadStart + maxHeaderScan)
                parseSegment(data, from: payloadStart, end: scanEnd, into: &metadata)
                // Segment is usually the last top-level element — stop after it.
                metadata.format = format
                return metadata

            default:
                guard declaredSize <= remaining else { return metadata }
                if (try? reader.seek(to: payloadStart + declaredSize)) == nil { return metadata }
            }
        }

        metadata.format = format
        return metadata
    }

    // MARK: - Segment walker

    private static func parseSegment(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var timestampScale: UInt64 = 1_000_000 // nanoseconds per tick (Matroska default)
        var trackRefs: [TrackRef] = []
        var tagsBlocks: [(start: Int, end: Int)] = []
        var clusterBlocks: [(start: Int, end: Int)] = []
        var chaptersBlocks: [(start: Int, end: Int)] = []

        while reader.offset < end, reader.remainingCount >= 2 {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let childStart = reader.offset
            let childEnd = childStart + Int(size)

            switch id {
            case 0x1549A966: // Info
                parseInfo(data, from: childStart, end: childEnd,
                          timestampScale: &timestampScale, into: &metadata)
            case 0x1654AE6B: // Tracks
                parseTracks(data, from: childStart, end: childEnd,
                            into: &metadata, refs: &trackRefs)
            case 0x1254C367: // Tags — deferred: the Tag targets reference TrackUIDs
                             // which we only know after Tracks has been walked.
                tagsBlocks.append((childStart, childEnd))
            case 0x1F43B675: // Cluster — we want enough for audio-frame
                             // sync-word sniffing (DTS / AC-3 bit_rate).
                             // MakeMKV clusters one track at a time, so the
                             // cap needs to cover an entire Interstellar-class
                             // remux (up to 14 audio tracks interleaved into
                             // separate cluster runs).
                if clusterBlocks.count < 64 {
                    clusterBlocks.append((childStart, childEnd))
                }
            case 0x1043A770: // Chapters (top-level in Segment)
                chaptersBlocks.append((childStart, childEnd))
            case 0x1C53BB6B, 0x1941A469: // Cues, Attachments
                break
            default:
                break
            }

            if (try? reader.seek(to: childEnd)) == nil { return }
        }

        for (s, e) in tagsBlocks {
            parseTags(data, from: s, end: e, refs: trackRefs, into: &metadata)
        }

        // Chapter markers (0x1043A770). Parsed after Tracks so that in the
        // future we can map chapter TrackUIDs back to stream indices if we
        // want per-track chapters — for now we flatten every EditionEntry into
        // the single top-level `chapters` list, mirroring ffprobe behaviour.
        for (s, e) in chaptersBlocks {
            parseChapters(data, from: s, end: e, into: &metadata)
        }

        // Clear stale shared BPS / NUMBER_OF_FRAMES tags BEFORE the cluster
        // walker runs — otherwise every audio track looks like it already has
        // a bit rate and the walker skips them. The walker only fills gaps.
        invalidateSharedStaleStats(in: &metadata)

        // Walk a bounded window of Clusters to recover per-track DTS / AC-3
        // frame-header bit_rate fields for MakeMKV-style remuxes that carry
        // no reliable BPS tag. Stops as soon as every pending audio track has
        // been populated.
        if !clusterBlocks.isEmpty {
            applyAudioFrameHeaderBitRates(
                data: data,
                clusters: clusterBlocks,
                refs: trackRefs,
                into: &metadata
            )
        }

        // Fold Duration (ticks) × TimestampScale (ns/tick) into seconds.
        if let ticks = metadata.duration {
            metadata.duration = ticks * Double(timestampScale) / 1_000_000_000
        }

        // parseTrackEntry parks DefaultDuration (ns/frame) as a positive value
        // in stream.frameRate; the deprecated Video>FrameRate element is parked
        // as a negative float. Fold both back into positive fps here.
        for i in 0..<metadata.videoStreams.count {
            guard let v = metadata.videoStreams[i].frameRate else { continue }
            if v < 0 {
                metadata.videoStreams[i].frameRate = -v
            } else if v > 0 {
                metadata.videoStreams[i].frameRate = 1_000_000_000.0 / v
            }
        }
        if let fps = metadata.videoStreams.first?.frameRate {
            metadata.frameRate = fps
        }

        // Fill top-level summary fields from the first video/audio stream.
        if let v = metadata.videoStreams.first {
            if metadata.videoWidth == nil { metadata.videoWidth = v.width }
            if metadata.videoHeight == nil { metadata.videoHeight = v.height }
            if metadata.videoCodec == nil { metadata.videoCodec = v.codec }
            if metadata.fieldOrder == nil { metadata.fieldOrder = v.fieldOrder }
            if metadata.colorInfo == nil { metadata.colorInfo = v.colorInfo }
            if metadata.bitDepth == nil { metadata.bitDepth = v.bitDepth }
            if metadata.chromaSubsampling == nil { metadata.chromaSubsampling = v.chromaSubsampling }
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
        }

        // Now that all video streams know their bit depth, fill in conservative
        // defaults for codecs where the bitstream carries the real info.
        for i in 0..<metadata.videoStreams.count {
            let codec = metadata.videoStreams[i].codec ?? ""
            if metadata.videoStreams[i].chromaSubsampling == nil {
                metadata.videoStreams[i].chromaSubsampling = defaultChromaSubsampling(forCodec: codec)
            }
            if metadata.videoStreams[i].bitDepth == nil,
               let depth = defaultBitDepth(forCodec: codec) {
                metadata.videoStreams[i].bitDepth = depth
            }
            if metadata.videoStreams[i].pixelFormat == nil {
                metadata.videoStreams[i].pixelFormat = PixelFormatDerivation.derive(
                    chromaSubsampling: metadata.videoStreams[i].chromaSubsampling,
                    bitDepth: metadata.videoStreams[i].bitDepth,
                    fullRange: metadata.videoStreams[i].colorInfo?.fullRange,
                    codec: codec
                )
            }
            if metadata.videoStreams[i].avgFrameRate == nil,
               let fps = metadata.videoStreams[i].frameRate {
                metadata.videoStreams[i].avgFrameRate = fps
                if metadata.videoStreams[i].rFrameRate == nil {
                    metadata.videoStreams[i].rFrameRate = fps
                }
            }
        }
        if metadata.chromaSubsampling == nil {
            metadata.chromaSubsampling = metadata.videoStreams.first?.chromaSubsampling
        }
        if metadata.bitDepth == nil {
            metadata.bitDepth = metadata.videoStreams.first?.bitDepth
        }

        if let a = metadata.audioStreams.first {
            if metadata.audioCodec == nil { metadata.audioCodec = a.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = a.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = a.channels }
        }

        // Synthesize channel layouts from counts where the container doesn't
        // provide one explicitly (Matroska rarely does).
        for i in 0..<metadata.audioStreams.count {
            if metadata.audioStreams[i].channelLayout == nil,
               let c = metadata.audioStreams[i].channels {
                metadata.audioStreams[i].channelLayout = defaultLayout(forChannels: c)
            }
        }

        // Default DisplayWidth/Height to PixelWidth/Height (square pixels) when
        // the container omits them — ffprobe behaves the same way and reports
        // SAR=1:1 + DAR=PixelW:PixelH (reduced) in that case.
        for i in 0..<metadata.videoStreams.count {
            let v = metadata.videoStreams[i]
            if v.displayWidth == nil, let w = v.width {
                metadata.videoStreams[i].displayWidth = w
            }
            if v.displayHeight == nil, let h = v.height {
                metadata.videoStreams[i].displayHeight = h
            }
            if let w = metadata.videoStreams[i].width,
               let h = metadata.videoStreams[i].height,
               let dw = metadata.videoStreams[i].displayWidth,
               let dh = metadata.videoStreams[i].displayHeight,
               w > 0, h > 0, dw > 0, dh > 0,
               metadata.videoStreams[i].pixelAspectRatio == nil {
                let parNum = dw * h
                let parDen = dh * w
                let g = gcdInt(parNum, parDen)
                metadata.videoStreams[i].pixelAspectRatio = (parNum / g, parDen / g)
            }
        }
        if let v = metadata.videoStreams.first {
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = v.pixelAspectRatio }
        }

        // Cross-check NUMBER_OF_FRAMES against duration × avg_frame_rate per
        // track. When the tag is more than 2 frames off the implied count it
        // came from a previous edit and should be dropped.
        for i in 0..<metadata.videoStreams.count {
            guard let n = metadata.videoStreams[i].frameCount,
                  let fps = metadata.videoStreams[i].avgFrameRate ?? metadata.videoStreams[i].frameRate,
                  let dur = metadata.duration, dur > 0, fps > 0 else { continue }
            let expected = Int((dur * fps).rounded())
            if abs(n - expected) > 2 {
                metadata.videoStreams[i].frameCount = expected
            }
        }

        // Implausibly high frame rates (e.g. ffprobe's r_frame_rate=1000/1 for
        // single-image MJPEG cover tracks) come from DefaultDuration values
        // that no longer match a real cadence — clamp them to 1/duration.
        for i in 0..<metadata.videoStreams.count {
            if let fps = metadata.videoStreams[i].frameRate, fps > 1000,
               let dur = metadata.duration, dur > 0 {
                let approx = 1.0 / dur
                metadata.videoStreams[i].frameRate = approx
                metadata.videoStreams[i].avgFrameRate = approx
                metadata.videoStreams[i].rFrameRate = approx
            }
        }
        if let first = metadata.videoStreams.first?.frameRate {
            metadata.frameRate = first
        }

        // Container-level bit rate: use file size × 8 / duration when no
        // explicit element gave us one. Mirrors ffprobe `format.bit_rate`.
        // VideoMetadata.read fills `fileSize` after we return, so fall back to
        // the parser's own data length here.
        let containerBytes = metadata.fileSize ?? Int64(data.count)
        if metadata.bitRate == nil,
           let dur = metadata.duration, dur > 0, containerBytes > 0 {
            metadata.bitRate = Int(Double(containerBytes) * 8.0 / dur)
        }
    }

    /// Greatest common divisor for the PAR/DAR reduction step.
    private static func gcdInt(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    /// Drop per-track BPS / NUMBER_OF_FRAMES / NUMBER_OF_BYTES values that
    /// were copied verbatim across tracks — the textbook signature of a
    /// MakeMKV → ffmpeg-trim pipeline that never refreshed `_STATISTICS_TAGS`.
    /// We only invalidate values that appear on more than one track AND on a
    /// stream where the value is implausible for the codec (e.g. 51 Mbps on a
    /// DTS audio stream): keeping the video bitrate when it stands alone is
    /// the right call, since it's still a useful approximation when the
    /// container has nothing else to offer.
    private static func invalidateSharedStaleStats(in metadata: inout VideoMetadata) {
        // Tally how many tracks share each non-nil bitrate value.
        var bitRateCounts: [Int: Int] = [:]
        for v in metadata.videoStreams {
            if let br = v.bitRate { bitRateCounts[br, default: 0] += 1 }
        }
        for a in metadata.audioStreams {
            if let br = a.bitRate { bitRateCounts[br, default: 0] += 1 }
        }
        let staleBitRates = Set(bitRateCounts.filter { $0.value > 1 }.keys)

        // Audio bitrates copied from a video track are always wrong — wipe
        // them outright when they match the staleness signature, regardless
        // of magnitude. Implausibly high audio bitrates (>= 5 Mbps for any
        // mainstream consumer codec) get the same treatment defensively.
        for i in 0..<metadata.audioStreams.count {
            guard let br = metadata.audioStreams[i].bitRate else { continue }
            if staleBitRates.contains(br) || br > 5_000_000 {
                metadata.audioStreams[i].bitRate = nil
            }
        }
        // Cover-art / attached-picture video tracks (e.g. V_MJPEG) almost
        // never carry a meaningful per-frame BPS — when they share the value
        // with the main video track it is definitely stale.
        for i in 0..<metadata.videoStreams.count {
            guard let br = metadata.videoStreams[i].bitRate else { continue }
            if staleBitRates.contains(br), i > 0 {
                metadata.videoStreams[i].bitRate = nil
            }
        }

        // NUMBER_OF_FRAMES copied across multiple tracks is the same story.
        var frameCountCounts: [Int: Int] = [:]
        for v in metadata.videoStreams {
            if let fc = v.frameCount { frameCountCounts[fc, default: 0] += 1 }
        }
        let staleFrameCounts = Set(frameCountCounts.filter { $0.value > 1 }.keys)
        for i in 0..<metadata.videoStreams.count {
            if let fc = metadata.videoStreams[i].frameCount,
               staleFrameCounts.contains(fc) {
                metadata.videoStreams[i].frameCount = nil
            }
        }
    }

    private static func defaultChromaSubsampling(forCodec codec: String) -> String? {
        switch codec {
        case "V_VP8", "V_VP9", "V_AV1", "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC",
             "V_MPEG4/ISO/ASP", "V_MPEG2", "V_MPEG1":
            return "4:2:0"
        case "V_MJPEG":
            // ffmpeg's MJPEG cover-art tracks default to yuvj444p; the JPEG
            // data is in the cluster, not CodecPrivate, so this is the closest
            // we can get without decoding a frame.
            return "4:4:4"
        default:
            return nil
        }
    }

    private static func defaultBitDepth(forCodec codec: String) -> Int? {
        switch codec {
        case "V_VP8", "V_MPEG4/ISO/ASP", "V_MPEG2", "V_MPEG1", "V_MJPEG":
            return 8
        default:
            return nil
        }
    }

    private static func chromaLabelFor(x: UInt64, y: UInt64) -> String? {
        switch (x, y) {
        case (2, 2): return "4:2:0"
        case (2, 1): return "4:2:2"
        case (1, 1): return "4:4:4"
        case (0, 0): return nil
        default: return nil
        }
    }

    private static func defaultLayout(forChannels n: Int) -> String? {
        switch n {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "2.1"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return n > 0 ? "\(n) channels" : nil
        }
    }

    private static func parseInfo(
        _ data: Data,
        from start: Int,
        end: Int,
        timestampScale: inout UInt64,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let valueStart = reader.offset
            switch id {
            case 0x2AD7B1: // TimestampScale (uint)
                if let v = readUIntPayload(data, offset: valueStart, size: Int(size)) {
                    timestampScale = v
                }
            case 0x4489: // Duration (float)
                if let v = readFloatPayload(data, offset: valueStart, size: Int(size)) {
                    metadata.duration = v
                }
            case 0x7BA9: // Title (utf8)
                if let v = readStringPayload(data, offset: valueStart, size: Int(size)) {
                    metadata.title = v
                }
            case 0x4D80: // MuxingApp (utf8)
                break
            case 0x5741: // WritingApp (utf8)
                break
            case 0x4461: // DateUTC (int, ns since 2001-01-01)
                if let ns = readSIntPayload(data, offset: valueStart, size: Int(size)) {
                    // Matroska epoch is 2001-01-01 00:00:00 UTC.
                    let mkvEpoch = Date(timeIntervalSince1970: 978_307_200)
                    metadata.creationDate = Date(timeInterval: TimeInterval(ns) / 1_000_000_000,
                                                  since: mkvEpoch)
                }
            default:
                break
            }

            if (try? reader.seek(to: valueStart + Int(size))) == nil { return }
        }
    }

    private enum TrackKind { case video, audio, subtitle }
    private struct TrackRef {
        let uid: UInt64
        let kind: TrackKind
        let index: Int
        /// Matroska `TrackNumber` (0xD7) — the small int that appears in every
        /// SimpleBlock/Block header. Needed when walking Clusters to match a
        /// frame back to its TrackEntry.
        var trackNumber: UInt64
    }

    private static func parseTracks(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata,
        refs: inout [TrackRef]
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }

            let entryStart = reader.offset
            let entryEnd = entryStart + Int(size)

            if id == 0xAE {
                parseTrackEntry(data, from: entryStart, end: entryEnd,
                                into: &metadata, refs: &refs)
            }

            if (try? reader.seek(to: entryEnd)) == nil { return }
        }
    }

    private static func parseTrackEntry(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata,
        refs: inout [TrackRef]
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var trackType: UInt64 = 0
        var trackUID: UInt64 = 0
        var trackNumber: UInt64 = 0
        var codecID: String?
        var codecPrivate: Data?
        var defaultDurationNs: UInt64 = 0
        var language: String?
        var trackName: String?
        var flagDefault: Bool?
        var flagForced: Bool?
        var flagHearingImpaired: Bool?
        var videoBlockStart: Int?
        var videoBlockEnd: Int?
        var audioBlockStart: Int?
        var audioBlockEnd: Int?

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            switch id {
            case 0x83: // TrackType
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    trackType = v
                }
            case 0x73C5: // TrackUID
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    trackUID = v
                }
            case 0xD7: // TrackNumber — referenced by SimpleBlock / Block headers
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    trackNumber = v
                }
            case 0x86: // CodecID
                codecID = readStringPayload(data, offset: vStart, size: vSize)
            case 0x63A2: // CodecPrivate — codec-specific decoder config
                if vSize > 0, vStart + vSize <= data.count {
                    codecPrivate = Data(
                        data[data.startIndex + vStart ..< data.startIndex + vStart + vSize]
                    )
                }
            case 0x23E383: // DefaultDuration (uint, ns)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    defaultDurationNs = v
                }
            case 0x22B59C: // Language (ASCII)
                language = readStringPayload(data, offset: vStart, size: vSize)
            case 0x536E: // Name (UTF-8)
                trackName = readStringPayload(data, offset: vStart, size: vSize)
            case 0x88: // FlagDefault
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagDefault = v != 0 }
            case 0x55AA: // FlagForced
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagForced = v != 0 }
            case 0x55AB: // FlagHearingImpaired (Matroska v4)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { flagHearingImpaired = v != 0 }
            case 0xE0: // Video (master)
                videoBlockStart = vStart
                videoBlockEnd = vStart + vSize
            case 0xE1: // Audio (master)
                audioBlockStart = vStart
                audioBlockEnd = vStart + vSize
            default:
                break
            }

            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }

        // MKV spec: FlagDefault default = 1 when element is absent. FlagForced
        // and FlagHearingImpaired default to 0. Normalise here so downstream
        // consumers don't have to replicate the defaulting rule.
        let isDefault = flagDefault ?? true
        let isForced = flagForced ?? false
        let isSDH = flagHearingImpaired ?? false

        switch trackType {
        case 1: // Video
            metadata.streamOrder.append(.video(metadata.videoStreams.count))
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.codec = codecID
            stream.codecName = codecLongNameMatroska(codecID)
            stream.title = trackName
            stream.isDefault = isDefault
            stream.isForced = isForced
            if let s = videoBlockStart, let e = videoBlockEnd {
                parseVideoBlock(data, from: s, end: e, into: &stream)
            }
            if let priv = codecPrivate, let id = codecID {
                applyMatroskaCodecPrivate(id: id, data: priv, into: &stream)
            }
            // V_MJPEG cover-art tracks usually omit CodecPrivate (the JPEG
            // payload sits in clusters). Apply the conventional defaults so
            // the JSON output matches ffprobe even when no SOF marker can
            // be parsed up-front.
            if codecID == "V_MJPEG" {
                if stream.profile == nil { stream.profile = "Baseline" }
                if stream.colorInfo == nil {
                    stream.colorInfo = VideoColorInfo(fullRange: true)
                } else if stream.colorInfo?.fullRange == nil {
                    stream.colorInfo?.fullRange = true
                }
                if stream.chromaLocation == nil { stream.chromaLocation = "center" }
            }
            // Store DefaultDuration as ns for now; parseSegment converts to fps
            // after this finishes so we know the Segment's TimestampScale.
            if defaultDurationNs > 0 {
                stream.frameRate = Double(defaultDurationNs)
            }
            // V_MJPEG tracks in Matroska are almost always cover-art attachments
            // muxed as a video stream. ffprobe only flags disposition.attached_pic
            // when another tag marks it so — keep the flag present (false by
            // default) so JSON consumers always see the key.
            if stream.isAttachedPic == nil {
                stream.isAttachedPic = false
            }
            // Matroska spec: FlagInterlaced/FieldOrder default to "undetermined"
            // when absent. For VP8/VP9/AV1 the codecs have no interlaced mode,
            // and for HEVC/H.264 the common case is progressive — real-world
            // writers only emit these elements for interlaced source. Default
            // to progressive so downstream consumers get Progressive/Interlaced
            // instead of nil. Cover-art MJPEG tracks keep nil (not video essence).
            if stream.fieldOrder == nil, codecID != "V_MJPEG" {
                stream.fieldOrder = .progressive
            }
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .video, index: stream.index, trackNumber: trackNumber))
            }
            metadata.videoStreams.append(stream)

        case 2: // Audio
            metadata.streamOrder.append(.audio(metadata.audioStreams.count))
            var stream = AudioStream(index: metadata.audioStreams.count)
            stream.codec = codecID
            stream.codecName = codecLongNameMatroska(codecID)
            stream.language = language
            stream.title = trackName
            stream.isDefault = isDefault
            stream.profile = audioProfileFor(codecID: codecID)
            if let s = audioBlockStart, let e = audioBlockEnd {
                parseAudioBlock(data, from: s, end: e, into: &stream)
            }
            // Refine DTS profile now that bit depth is known (MakeMKV leaves the
            // codec id as A_DTS for plain DTS, DTS-HD MA and DTS-HD HRA alike;
            // the container-declared BitDepth is the cleanest tell).
            if codecID == "A_DTS", let bd = stream.bitDepth, bd > 0, bd < 32 {
                stream.profile = "DTS-HD MA"
            }
            // A_VORBIS rarely populates the Audio master's Channels /
            // SamplingFrequency — mkvtoolnix omits them since the Vorbis
            // identification header is authoritative. Parse it out of
            // CodecPrivate (Xiph-laced setup packets) to recover both.
            if codecID == "A_VORBIS", let priv = codecPrivate {
                applyVorbisCodecPrivate(priv, into: &stream)
            }
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .audio, index: stream.index, trackNumber: trackNumber))
            }
            metadata.audioStreams.append(stream)

        case 0x11: // Subtitle (Matroska TrackType value 17)
            metadata.streamOrder.append(.subtitle(metadata.subtitleStreams.count))
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            stream.codec = codecID
            stream.codecName = subtitleLongNameMatroska(codecID)
            stream.language = language
            stream.title = trackName
            stream.isDefault = isDefault
            stream.isForced = isForced
            stream.isHearingImpaired = isSDH
            if trackUID != 0 {
                refs.append(TrackRef(uid: trackUID, kind: .subtitle, index: stream.index, trackNumber: trackNumber))
            }
            metadata.subtitleStreams.append(stream)

        default:
            break
        }
    }

    /// Profile label derived purely from the Matroska CodecID. MakeMKV and
    /// other remuxers often leave DTS-HD MA tracks as plain `A_DTS`, so the
    /// caller (parseTrackEntry) refines DTS further once bit depth is known.
    private static func audioProfileFor(codecID: String?) -> String? {
        guard let id = codecID else { return nil }
        switch id {
        case "A_DTS": return "DTS"
        case "A_DTS/EXPRESS": return "DTS Express"
        case "A_DTS/LOSSLESS": return "DTS-HD MA"
        case "A_AC3": return "AC-3"
        case "A_EAC3": return "E-AC-3"
        case "A_TRUEHD": return "TrueHD"
        default: return nil
        }
    }

    // MARK: - Tags (per-track SimpleTag values)

    /// Walk `Tags` master: a sequence of `Tag` entries. Each Tag carries a
    /// Targets master (listing one or more TagTrackUIDs) plus any number of
    /// SimpleTag name/value pairs. FFmpeg and mkvtoolnix encode per-track
    /// `BPS`, `DURATION`, `NUMBER_OF_FRAMES`, `NUMBER_OF_BYTES` here — it's
    /// the only place a declared bitrate appears in most MKV/WebM files.
    private static func parseTags(
        _ data: Data,
        from start: Int,
        end: Int,
        refs: [TrackRef],
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            if id == 0x7373 { // Tag
                parseTag(data, from: vStart, end: vStart + vSize,
                         refs: refs, into: &metadata)
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    private static func parseTag(
        _ data: Data,
        from start: Int,
        end: Int,
        refs: [TrackRef],
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var targetUIDs: [UInt64] = []
        var simpleTags: [(name: String, value: String)] = []

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x63C0: // Targets
                targetUIDs = readTagTargetUIDs(data, from: vStart, end: vStart + vSize)
            case 0x67C8: // SimpleTag
                if let pair = readSimpleTag(data, from: vStart, end: vStart + vSize) {
                    simpleTags.append(pair)
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }

        // A Tag without a TagTrackUID targets the Segment itself — apply its
        // COMMENT/DESCRIPTION/TITLE pairs to the top-level metadata.
        if targetUIDs.isEmpty {
            for (name, value) in simpleTags {
                applySegmentTag(name: name, value: value, in: &metadata)
            }
            return
        }

        for uid in targetUIDs {
            guard let ref = refs.first(where: { $0.uid == uid }) else { continue }
            for (name, value) in simpleTags {
                applyTrackTag(name: name, value: value, to: ref, in: &metadata)
            }
        }
    }

    /// Segment-level SimpleTag → top-level `VideoMetadata` field mapping.
    /// `COMMENT`/`COMMENTS`/`DESCRIPTION` all carry long-form free text;
    /// Matroska muxers use whichever one they feel like, so accept all three.
    private static func applySegmentTag(
        name: String,
        value: String,
        in metadata: inout VideoMetadata
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch name.uppercased() {
        case "COMMENT", "COMMENTS", "DESCRIPTION":
            if metadata.comment == nil { metadata.comment = trimmed }
        case "TITLE":
            if metadata.title == nil { metadata.title = trimmed }
        case "ARTIST", "AUTHOR":
            if metadata.artist == nil { metadata.artist = trimmed }
        default:
            break
        }
    }

    private static func readTagTargetUIDs(_ data: Data, from start: Int, end: Int) -> [UInt64] {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        var out: [UInt64] = []
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            if id == 0x63C5 { // TagTrackUID
                if let v = readUIntPayload(data, offset: vStart, size: vSize), v != 0 {
                    out.append(v)
                }
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return out }
        }
        return out
    }

    /// Read a SimpleTag's `TagName` + `TagString`. Nested SimpleTags are
    /// ignored — Matroska allows them but no mainstream muxer writes nested
    /// BPS/DURATION.
    private static func readSimpleTag(
        _ data: Data,
        from start: Int,
        end: Int
    ) -> (name: String, value: String)? {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        var name: String?
        var value: String?
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x45A3: // TagName
                name = readStringPayload(data, offset: vStart, size: vSize)
            case 0x4487: // TagString
                value = readStringPayload(data, offset: vStart, size: vSize)
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { break }
        }
        guard let n = name, let v = value else { return nil }
        return (n, v)
    }

    private static func applyTrackTag(
        name: String,
        value: String,
        to ref: TrackRef,
        in metadata: inout VideoMetadata
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.uppercased() {
        case "BPS":
            guard let bps = Int(trimmed), bps > 0 else { return }
            switch ref.kind {
            case .video:
                guard ref.index < metadata.videoStreams.count else { return }
                if metadata.videoStreams[ref.index].bitRate == nil {
                    metadata.videoStreams[ref.index].bitRate = bps
                }
            case .audio:
                guard ref.index < metadata.audioStreams.count else { return }
                if metadata.audioStreams[ref.index].bitRate == nil {
                    metadata.audioStreams[ref.index].bitRate = bps
                }
            case .subtitle:
                break // SubtitleStream has no bitRate.
            }
        case "NUMBER_OF_FRAMES":
            guard let n = Int(trimmed), n > 0 else { return }
            if ref.kind == .video, ref.index < metadata.videoStreams.count,
               metadata.videoStreams[ref.index].frameCount == nil {
                metadata.videoStreams[ref.index].frameCount = n
            }
        default:
            break
        }
    }

    /// Apply Matroska `CodecPrivate` bytes to a video stream when the codec
    /// carries a known decoder-configuration record. The bytes are identical
    /// to the corresponding ISOBMFF boxes (hvcC / avcC / av1C), so we read the
    /// same offsets here — profile/bit-depth/chroma surface without pulling
    /// in the full MP4 parser.
    private static func applyMatroskaCodecPrivate(
        id: String,
        data: Data,
        into stream: inout VideoStream
    ) {
        switch id {
        case "V_MPEGH/ISO/HEVC":
            // The bytes are an HEVCDecoderConfigurationRecord, identical to the
            // payload of an MP4 `hvcC` box. Defer to the MP4 parser so the NAL
            // arrays (SPS VUI for color signalling; prefix SEI for MaxCLL /
            // MaxFALL / mastering display) get walked the same way for both
            // containers. Snapshot fields the MKV `Tracks` already populated so
            // the hvcC fallback can't overwrite them — `Tracks` data is more
            // authoritative when both sources disagree.
            let previousProfile = stream.profile
            let previousBitDepth = stream.bitDepth
            let previousChroma = stream.chromaSubsampling
            MP4Parser.parseHVCC(data, into: &stream)
            if let p = previousProfile { stream.profile = p }
            if let bd = previousBitDepth { stream.bitDepth = bd }
            if let cs = previousChroma { stream.chromaSubsampling = cs }

        case "V_MPEG4/ISO/AVC":
            // Same bytes as MP4 avcC — profile lives at byte 1.
            guard data.count >= 4 else { return }
            let profileIDC = data[data.startIndex + 1]
            if stream.profile == nil {
                stream.profile = avcProfileLabel(profileIDC)
            }
            if stream.bitDepth == nil { stream.bitDepth = 8 }
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }

        case "V_MJPEG":
            // CodecPrivate is a complete JPEG frame (thumbnail). Mine the
            // Start-Of-Frame marker for profile / precision / chroma info.
            parseMJPEGCodecPrivate(data: data, into: &stream)

        case "V_AV1":
            // Same bytes as MP4 av1C.
            guard data.count >= 3 else { return }
            let byte1 = data[data.startIndex + 1]
            let byte2 = data[data.startIndex + 2]
            let seqProfile = Int((byte1 & 0xE0) >> 5)
            let highBitDepth = (byte2 >> 6) & 0x01
            let twelveBit = (byte2 >> 5) & 0x01
            let monochrome = (byte2 >> 4) & 0x01
            let ssx = (byte2 >> 3) & 0x01
            let ssy = (byte2 >> 2) & 0x01

            if stream.bitDepth == nil {
                stream.bitDepth = twelveBit == 1 ? 12 : (highBitDepth == 1 ? 10 : 8)
            }
            if stream.chromaSubsampling == nil {
                if monochrome == 1 {
                    stream.chromaSubsampling = "4:0:0"
                } else if ssx == 1 && ssy == 1 {
                    stream.chromaSubsampling = "4:2:0"
                } else if ssx == 1 && ssy == 0 {
                    stream.chromaSubsampling = "4:2:2"
                } else if ssx == 0 && ssy == 0 {
                    stream.chromaSubsampling = "4:4:4"
                }
            }
            if stream.profile == nil {
                switch seqProfile {
                case 0: stream.profile = "Main"
                case 1: stream.profile = "High"
                case 2: stream.profile = "Professional"
                default: break
                }
            }

        default:
            break
        }
    }

    /// Walk the early Clusters for each `SimpleBlock` / `Block` element
    /// belonging to a DTS / AC-3 audio track and parse the first frame's
    /// sync-word header to recover bit_rate. ffprobe does the equivalent via
    /// the demuxer — we do it once at container-open time, skipping clusters
    /// as soon as every track that needs data has been populated.
    private static func applyAudioFrameHeaderBitRates(
        data: Data,
        clusters: [(start: Int, end: Int)],
        refs: [TrackRef],
        into metadata: inout VideoMetadata
    ) {
        // Short-circuit: only proceed if at least one audio track is a codec
        // family whose bit rate isn't already known.
        var pending: [UInt64: Int] = [:] // TrackNumber → audio stream index
        for ref in refs {
            guard ref.kind == .audio, ref.trackNumber > 0 else { continue }
            guard ref.index < metadata.audioStreams.count else { continue }
            let codec = metadata.audioStreams[ref.index].codec ?? ""
            let needsBitRate = metadata.audioStreams[ref.index].bitRate == nil
            let isSyncCodec = codec == "A_AC3" || codec == "A_EAC3"
                || codec.hasPrefix("A_DTS")
            // ffprobe deliberately omits bit_rate for lossless DTS-HD MA
            // streams (their rate is variable). Our MatroskaReader already
            // refines the DTS profile from the container's BitDepth element —
            // honour the refined label and skip bit-rate extraction for MA.
            let profile = metadata.audioStreams[ref.index].profile
            let isLosslessDTS = codec.hasPrefix("A_DTS") && profile == "DTS-HD MA"
            if needsBitRate, isSyncCodec, !isLosslessDTS {
                pending[ref.trackNumber] = ref.index
            }
        }
        if pending.isEmpty { return }

        outer: for (cStart, cEnd) in clusters {
            // A closure can't `break outer`, so use a mutable flag.
            var stop = false
            walkClusterBlocks(data: data, from: cStart, end: cEnd) { trackNumber, frame in
                guard !stop, let streamIdx = pending[trackNumber] else { return }
                let codec = metadata.audioStreams[streamIdx].codec ?? ""
                let bitRate: Int?
                if codec == "A_AC3" || codec == "A_EAC3" {
                    bitRate = parseAC3BitRate(frame)
                } else if codec.hasPrefix("A_DTS") {
                    bitRate = parseDTSBitRate(frame)
                } else {
                    bitRate = nil
                }
                if let br = bitRate, br > 0 {
                    metadata.audioStreams[streamIdx].bitRate = br
                    pending.removeValue(forKey: trackNumber)
                    if pending.isEmpty { stop = true }
                }
            }
            if pending.isEmpty { break outer }
        }
    }

    /// Walk a Cluster master and invoke `body` for each contained SimpleBlock
    /// / BlockGroup > Block with the resolved `(TrackNumber, frameBytes)`.
    /// `frameBytes` is a slice pointing at the first frame's payload; lacing
    /// isn't interpreted — we only need the first codec sync word.
    private static func walkClusterBlocks(
        data: Data,
        from start: Int,
        end: Int,
        body: (_ trackNumber: UInt64, _ frame: Data) -> Void
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            switch id {
            case 0xA3: // SimpleBlock
                if let (trackNumber, frame) = readBlockHeader(data: data, start: vStart, size: vSize) {
                    body(trackNumber, frame)
                }
            case 0xA0: // BlockGroup — contains a Block (0xA1) inside
                var inner = BinaryReader(data: data)
                (try? inner.seek(to: vStart)) ?? ()
                let bgEnd = vStart + vSize
                while inner.offset < bgEnd {
                    guard let innerID = try? readEBMLID(&inner),
                          let innerSize = try? readVINT(&inner),
                          inner.offset + Int(innerSize) <= bgEnd else { break }
                    let bStart = inner.offset
                    let bSize = Int(innerSize)
                    if innerID == 0xA1, // Block
                       let (trackNumber, frame) = readBlockHeader(data: data, start: bStart, size: bSize) {
                        body(trackNumber, frame)
                    }
                    if (try? inner.seek(to: bStart + bSize)) == nil { break }
                }
            case 0xE7: // Cluster Timecode
                break
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    /// Decode a SimpleBlock / Block header: VINT TrackNumber + Int16 timecode
    /// + UInt8 flags + [lacing info + frame data]. Returns the track number
    /// and a slice pointing at the start of the first frame's bytes.
    private static func readBlockHeader(
        data: Data,
        start: Int,
        size: Int
    ) -> (UInt64, Data)? {
        guard size > 4 else { return nil }
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        guard let trackNumber = try? readVINT(&reader) ?? 0 else { return nil }
        // Timecode + flags.
        guard (try? reader.skip(3)) != nil else { return nil }
        let framesStart = reader.offset
        let remaining = start + size - framesStart
        guard remaining > 0, framesStart + remaining <= data.count else { return nil }
        let slice = data[(data.startIndex + framesStart) ..< (data.startIndex + framesStart + remaining)]
        return (trackNumber, Data(slice))
    }

    /// AC-3 frame header (ATSC A/52 §5.4.1): 16-bit sync word `0x0B77`, then 2
    /// bytes CRC, then `fscod`(2) | `frmsizecod`(6). We ignore the sync search
    /// beyond the first 4 KiB — the first frame is always at the start of a
    /// Matroska audio block.
    private static func parseAC3BitRate(_ frame: Data) -> Int? {
        guard frame.count >= 5 else { return nil }
        let s = frame.startIndex
        // Search for 0x0B77 within the first few bytes (some muxers leave a
        // tiny prefix; in practice the sync is at offset 0).
        var offset = -1
        for i in 0..<min(frame.count - 4, 8) {
            if frame[s + i] == 0x0B, frame[s + i + 1] == 0x77 {
                offset = i
                break
            }
        }
        guard offset >= 0, offset + 5 < frame.count else { return nil }
        let byte4 = frame[s + offset + 4] // fscod + frmsizecod
        let frmsizecod = Int(byte4 & 0x3F)
        // Each entry in the frame-size table encodes a bit rate directly
        // (independent of sample rate); index = frmsizecod >> 1.
        let ac3Bitrates = [
             32_000,  40_000,  48_000,  56_000,  64_000,  80_000,  96_000, 112_000,
            128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 384_000, 448_000,
            512_000, 576_000, 640_000
        ]
        let idx = frmsizecod >> 1
        guard idx < ac3Bitrates.count else { return nil }
        return ac3Bitrates[idx]
    }

    /// DTS core frame header (ETSI TS 102 114 §5.3.1): 32-bit sync `0x7FFE8001`
    /// followed by a dense bit-packed header whose fields are (counting the
    /// first bit after sync as 0):
    ///   FT     (1)  — bit 0
    ///   SHORT  (5)  — bits 1-5
    ///   CPF    (1)  — bit 6
    ///   NBLKS  (7)  — bits 7-13
    ///   FSIZE  (14) — bits 14-27
    ///   AMODE  (6)  — bits 28-33
    ///   SFREQ  (4)  — bits 34-37
    ///   RATE   (5)  — bits 38-42  ← the bit-rate index we want
    /// Note: an earlier edition of this reader used SHORT = 6 bits (matching a
    /// few non-normative references) and that shifted every subsequent field by
    /// one bit. The corrected 5-bit SHORT lines up with ffmpeg's libavcodec
    /// `dca_core.c` and gives the right `dca_bit_rates` index.
    private static func parseDTSBitRate(_ frame: Data) -> Int? {
        guard frame.count >= 12 else { return nil }
        let s = frame.startIndex
        var syncOffset = -1
        for i in 0..<min(frame.count - 10, 32) {
            if frame[s + i] == 0x7F, frame[s + i + 1] == 0xFE,
               frame[s + i + 2] == 0x80, frame[s + i + 3] == 0x01 {
                syncOffset = i
                break
            }
        }
        guard syncOffset >= 0, syncOffset + 10 <= frame.count else { return nil }
        // Load 8 bytes after the 4-byte sync into a big-endian UInt64 —
        // covers all header fields up through RATE + plenty of padding.
        var packed: UInt64 = 0
        for i in 0..<8 {
            packed = (packed << 8) | UInt64(frame[s + syncOffset + 4 + i])
        }
        // RATE occupies header bits 38-42. In `packed` (bit 63 = header bit 0),
        // header bit N = packed bit (63 - N). So RATE = bits 25..21 of packed.
        let rateIdx = Int((packed >> 21) & 0x1F)
        // ETSI TS 102 114 Table 5-7. A value of 29 is "open"; 30 = variable;
        // 31 = lossless. We treat those as unknown and return nil.
        let dtsBitrates: [Int?] = [
             32_000,   56_000,   64_000,   96_000,  112_000,  128_000,  192_000,  224_000,
            256_000,  320_000,  384_000,  448_000,  512_000,  576_000,  640_000,  768_000,
            960_000, 1024_000, 1152_000, 1280_000, 1344_000, 1408_000, 1411_200, 1472_000,
           1536_000, 1920_000, 2048_000, 3072_000, 3840_000, nil,      nil,      nil
        ]
        guard rateIdx < dtsBitrates.count else { return nil }
        return dtsBitrates[rateIdx]
    }

    /// A Vorbis `CodecPrivate` in Matroska is the three Vorbis setup packets
    /// concatenated using Xiph lacing. We only need the first packet (the
    /// "identification header") whose fixed-offset layout gives us channels
    /// and sample rate:
    ///   byte 0..6  : "\x01vorbis" magic
    ///   byte 7..10 : vorbis_version (UInt32 LE, always 0)
    ///   byte 11    : audio_channels (UInt8)
    ///   byte 12..15: audio_sample_rate (UInt32 LE)
    ///   byte 16..27: bitrate_max / nominal / min (3 × UInt32 LE)
    /// The Xiph lacing prefix is: a single count byte (0x02 = 3 packets) then
    /// N-1 lacing lengths (each a run of 0xFF bytes terminated by a byte <
    /// 0xFF). The identification header is conventionally the first of the
    /// three packets — we find it by scanning for its magic.
    private static func applyVorbisCodecPrivate(_ data: Data, into stream: inout AudioStream) {
        let magic: [UInt8] = [0x01, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73] // "\x01vorbis"
        guard data.count >= magic.count + 16 else { return }
        let bytes = [UInt8](data)
        // Search for the identification header within the first few hundred
        // bytes — well beyond any plausible Xiph lacing length prefix.
        let searchLimit = min(bytes.count - (magic.count + 16), 1024)
        for i in 0...searchLimit {
            var matched = true
            for (j, b) in magic.enumerated() where bytes[i + j] != b {
                matched = false
                break
            }
            if !matched { continue }
            let base = i + magic.count + 4 // skip magic + vorbis_version
            let ch = Int(bytes[base])
            let sr = UInt32(bytes[base + 1])
                | (UInt32(bytes[base + 2]) << 8)
                | (UInt32(bytes[base + 3]) << 16)
                | (UInt32(bytes[base + 4]) << 24)
            if stream.channels == nil, ch > 0 { stream.channels = ch }
            if stream.sampleRate == nil, sr > 0 { stream.sampleRate = Int(sr) }
            // Nominal bitrate lives at base + 9..13 (UInt32 LE); a value of
            // zero means "unknown" per the Vorbis spec.
            if stream.bitRate == nil, base + 13 <= bytes.count {
                let br = UInt32(bytes[base + 9])
                    | (UInt32(bytes[base + 10]) << 8)
                    | (UInt32(bytes[base + 11]) << 16)
                    | (UInt32(bytes[base + 12]) << 24)
                if br > 0, br < (1 << 28) { stream.bitRate = Int(br) }
            }
            return
        }
    }

    /// HEVC profile_idc → label. Mirrors MP4Parser.hevcProfileName — duplicated
    /// here to keep MatroskaReader self-contained rather than depending on
    /// ISOBMFF internals.
    private static func hevcProfileLabel(profileIDC: Int, chromaFormatIDC: Int, bitDepth: Int) -> String? {
        switch profileIDC {
        case 1: return "Main"
        case 2: return "Main 10"
        case 3: return "Main Still Picture"
        case 4:
            let chroma: String
            switch chromaFormatIDC {
            case 0: return "Monochrome \(bitDepth)"
            case 1: chroma = "4:2:0"
            case 2: chroma = "4:2:2"
            case 3: chroma = "4:4:4"
            default: return "Range Extensions"
            }
            return "Main \(chroma) \(bitDepth)"
        default: return nil
        }
    }

    /// AVC profile_idc → label. Mirrors MP4Parser.avcProfileName.
    private static func avcProfileLabel(_ profileIDC: UInt8) -> String? {
        switch profileIDC {
        case 66: return "Constrained Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        default: return nil
        }
    }

    /// Walk the JPEG bitstream stored in a `V_MJPEG` Matroska track's
    /// CodecPrivate to surface profile, precision, and chroma subsampling.
    /// The bitstream is segmented into markers (`0xFFxx`); the first
    /// Start-Of-Frame (SOF0..SOF3) describes the picture in plain bytes.
    /// MJPEG is full-range by definition, and chroma sample siting is "center".
    private static func parseMJPEGCodecPrivate(data: Data, into stream: inout VideoStream) {
        guard data.count >= 4 else { return }
        let s = data.startIndex
        var i = s
        let end = data.endIndex
        while i + 1 < end {
            guard data[i] == 0xFF else { i += 1; continue }
            // Skip fill bytes (0xFF) and standalone markers without payload.
            var marker = data[i + 1]
            i += 2
            while marker == 0xFF, i < end { marker = data[i]; i += 1 }
            // Standalone markers (SOI/EOI/RSTx) carry no length field.
            if marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7) {
                continue
            }
            guard i + 1 < end else { return }
            let segLen = Int(data[i]) << 8 | Int(data[i + 1])
            guard segLen >= 2, i + segLen <= end else { return }

            // SOF0..SOF3 / SOF5..SOF7 / SOF9..SOFB / SOFD..SOFF — Start-Of-Frame.
            // Skip DHT (0xC4), JPG (0xC8), DAC (0xCC), DNL (0xDC).
            let isSOF = (marker >= 0xC0 && marker <= 0xCF)
                && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isSOF, segLen >= 8 {
                let precision = Int(data[i + 2])
                let nf = Int(data[i + 7])
                if stream.bitDepth == nil, precision > 0 {
                    stream.bitDepth = precision
                }
                if stream.profile == nil {
                    switch marker {
                    case 0xC0: stream.profile = "Baseline"
                    case 0xC1: stream.profile = "Extended Sequential"
                    case 0xC2: stream.profile = "Progressive"
                    case 0xC3: stream.profile = "Lossless"
                    default: stream.profile = "Baseline"
                    }
                }
                // Chroma subsampling: per-component HiVi nibbles tell us how the
                // luma and chroma planes are sampled. Component 0 is luma; the
                // ratio of its HxV to the chroma components defines the format.
                if stream.chromaSubsampling == nil, nf >= 1 {
                    if nf == 1 {
                        stream.chromaSubsampling = "4:0:0"
                    } else if 8 + nf * 3 <= segLen {
                        let yH = Int(data[i + 8 + 1] >> 4)
                        let yV = Int(data[i + 8 + 1] & 0x0F)
                        if yH == 1, yV == 1 {
                            stream.chromaSubsampling = "4:4:4"
                        } else if yH == 2, yV == 1 {
                            stream.chromaSubsampling = "4:2:2"
                        } else if yH == 2, yV == 2 {
                            stream.chromaSubsampling = "4:2:0"
                        } else if yH == 1, yV == 2 {
                            stream.chromaSubsampling = "4:4:0"
                        } else if yH == 4, yV == 1 {
                            stream.chromaSubsampling = "4:1:1"
                        }
                    }
                }
                // MJPEG is JPEG-style full range and chroma is centre-sampled
                // (matching ffprobe's default of "center" for MJPEG).
                if stream.colorInfo == nil {
                    stream.colorInfo = VideoColorInfo(fullRange: true)
                } else if stream.colorInfo?.fullRange == nil {
                    stream.colorInfo?.fullRange = true
                }
                if stream.chromaLocation == nil {
                    stream.chromaLocation = "center"
                }
                return
            }
            i += segLen
        }
    }

    private static func subtitleLongNameMatroska(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "S_TEXT/UTF8": return "SubRip (SRT)"
        case "S_TEXT/ASCII": return "Plain text"
        case "S_TEXT/SSA": return "SSA"
        case "S_TEXT/ASS": return "ASS"
        case "S_TEXT/USF": return "Universal Subtitle Format"
        case "S_TEXT/WEBVTT": return "WebVTT"
        case "S_VOBSUB": return "VobSub"
        case "S_HDMV/PGS": return "PGS (Blu-ray)"
        case "S_HDMV/TEXTST": return "HDMV Text Subtitles"
        case "S_KATE": return "Kate"
        case "S_IMAGE/BMP": return "Image Subtitles (BMP)"
        default: return id
        }
    }

    /// Parse the `Video` master element.
    private static func parseVideoBlock(
        _ data: Data,
        from start: Int,
        end: Int,
        into stream: inout VideoStream
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            switch id {
            case 0xB0: // PixelWidth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.width = Int(v) }
            case 0xBA: // PixelHeight
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.height = Int(v) }
            case 0x54B0: // DisplayWidth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.displayWidth = Int(v) }
            case 0x54BA: // DisplayHeight
                if let v = readUIntPayload(data, offset: vStart, size: vSize) { stream.displayHeight = Int(v) }
            case 0x9A: // FlagInterlaced (0=undetermined,1=interlaced,2=progressive)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    if stream.fieldOrder == nil {
                        stream.fieldOrder = (v == 2) ? .progressive : (v == 1) ? .unknown : nil
                    }
                }
            case 0x55B2: // BitsPerChannel (per-component bit depth, matches ffprobe bits_per_raw_sample)
                if let v = readUIntPayload(data, offset: vStart, size: vSize), v > 0 {
                    stream.bitDepth = Int(v)
                }
            case 0x9D: // FieldOrder (0=progressive,1=tff,6=bff,9=tff(swapped),14=bff(swapped))
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    switch v {
                    case 0: stream.fieldOrder = .progressive
                    case 1, 9: stream.fieldOrder = .topFieldFirst
                    case 6, 14: stream.fieldOrder = .bottomFieldFirst
                    default: stream.fieldOrder = .unknown
                    }
                }
            case 0x55B0: // Colour (master)
                var info = stream.colorInfo ?? VideoColorInfo()
                var chroma: (x: UInt64, y: UInt64)?
                var siting: (h: UInt64?, v: UInt64?) = (nil, nil)
                var md: HDRMasteringDisplay?
                var cll: HDRContentLightLevel?
                parseMatroskaColour(data, from: vStart, end: vStart + vSize,
                                    info: &info, chroma: &chroma, siting: &siting,
                                    masteringDisplay: &md, contentLightLevel: &cll)
                stream.colorInfo = info
                if let ch = chroma {
                    stream.chromaSubsampling = chromaLabelFor(x: ch.x, y: ch.y)
                }
                if let loc = chromaLocationLabel(horz: siting.h, vert: siting.v) {
                    stream.chromaLocation = loc
                }
                if md != nil || cll != nil {
                    if stream.hdr == nil { stream.hdr = HDRMetadata() }
                    if let md  { stream.hdr?.masteringDisplay = md }
                    if let cll { stream.hdr?.contentLightLevel = cll }
                }
            case 0x2383E3: // FrameRate (deprecated float fps; keep only if nothing better)
                if stream.frameRate == nil,
                   let v = readFloatPayload(data, offset: vStart, size: vSize) {
                    // Encoded directly as fps (not ns) — flag by using negative marker.
                    // parseSegment converts positive values (ns) → fps; negative we negate.
                    stream.frameRate = -v
                }
            default:
                break
            }

            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    private static func parseMatroskaColour(
        _ data: Data,
        from start: Int,
        end: Int,
        info: inout VideoColorInfo,
        chroma: inout (x: UInt64, y: UInt64)?,
        siting: inout (h: UInt64?, v: UInt64?),
        masteringDisplay: inout HDRMasteringDisplay?,
        contentLightLevel: inout HDRContentLightLevel?
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x55B1: // MatrixCoefficients
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.matrix = Int(v)
                }
            case 0x55B9: // Range (0=unspec,1=broadcast,2=full,3=derived)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    if v == 2 { info.fullRange = true }
                    else if v == 1 { info.fullRange = false }
                }
            case 0x55BA: // TransferCharacteristics
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.transfer = Int(v)
                }
            case 0x55BB: // Primaries
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    info.primaries = Int(v)
                }
            case 0x55B4: // ChromaSubsamplingHorz (# of samples to combine horizontally)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = chroma ?? (x: 0, y: 0)
                    c.x = v
                    chroma = c
                }
            case 0x55B5: // ChromaSubsamplingVert
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = chroma ?? (x: 0, y: 0)
                    c.y = v
                    chroma = c
                }
            case 0x55B7: // ChromaSitingHorz
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    siting.h = v
                }
            case 0x55B8: // ChromaSitingVert
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    siting.v = v
                }
            case 0x55BC: // MaxCLL — CTA-861.3 peak frame brightness (cd/m^2)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = contentLightLevel ?? HDRContentLightLevel(maxCLL: 0, maxFALL: 0)
                    c.maxCLL = Int(v)
                    contentLightLevel = c
                }
            case 0x55BD: // MaxFALL — CTA-861.3 peak frame-average brightness (cd/m^2)
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    var c = contentLightLevel ?? HDRContentLightLevel(maxCLL: 0, maxFALL: 0)
                    c.maxFALL = Int(v)
                    contentLightLevel = c
                }
            case 0x55D0: // MasteringMetadata (SMPTE ST 2086, master element)
                parseMatroskaMasteringMetadata(data, from: vStart, end: vStart + vSize,
                                               masteringDisplay: &masteringDisplay)
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    /// Matroska `MasteringMetadata` (0x55D0) master element. Holds SMPTE ST 2086
    /// mastering-display chromaticities and luminance bounds. Unlike MP4's
    /// `mdcv` box (uint16 × 0.00002 / uint32 × 0.0001), Matroska stores these
    /// as IEEE floats already in CIE 1931 xy units and cd/m^2 — no scaling.
    /// Any subset of children may be present; missing fields default to 0
    /// (mirrors how `parseMDCVBox` decodes an all-zero record).
    private static func parseMatroskaMasteringMetadata(
        _ data: Data,
        from start: Int,
        end: Int,
        masteringDisplay: inout HDRMasteringDisplay?
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var md = masteringDisplay ?? HDRMasteringDisplay(
            redX: 0, redY: 0,
            greenX: 0, greenY: 0,
            blueX: 0, blueY: 0,
            whitePointX: 0, whitePointY: 0,
            maxLuminance: 0, minLuminance: 0
        )
        var sawAny = masteringDisplay != nil

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)

            if let v = readFloatPayload(data, offset: vStart, size: vSize) {
                switch id {
                case 0x55D1: md.redX = v;         sawAny = true
                case 0x55D2: md.redY = v;         sawAny = true
                case 0x55D3: md.greenX = v;       sawAny = true
                case 0x55D4: md.greenY = v;       sawAny = true
                case 0x55D5: md.blueX = v;        sawAny = true
                case 0x55D6: md.blueY = v;        sawAny = true
                case 0x55D7: md.whitePointX = v;  sawAny = true
                case 0x55D8: md.whitePointY = v;  sawAny = true
                case 0x55D9: md.maxLuminance = v; sawAny = true
                case 0x55DA: md.minLuminance = v; sawAny = true
                default: break
                }
            }

            if (try? reader.seek(to: vStart + vSize)) == nil { break }
        }

        if sawAny { masteringDisplay = md }
    }

    /// Matroska ChromaSitingHorz/Vert values map to ffprobe chroma_location.
    /// Per Matroska spec, each axis uses:
    ///   0 = unspecified, 1 = collocated (left/top), 2 = half-way (center)
    /// So (horz, vert) combines as:
    ///   (1,1) → topleft   (left + top,   HEVC default for 4:2:0)
    ///   (1,2) → left      (left + half,  MPEG-2 default for 4:2:0)
    ///   (2,1) → top       (half + top)
    ///   (2,2) → center    (half + half,  MJPEG / MPEG-1 default)
    /// When only one axis is signalled, fall back to the "collocated" interpretation
    /// on the unspecified axis for H.264/HEVC so topleft/left files that only write
    /// ChromaSitingHorz don't collapse to nil.
    private static func chromaLocationLabel(horz: UInt64?, vert: UInt64?) -> String? {
        switch (horz ?? 0, vert ?? 0) {
        case (1, 1): return "topleft"
        case (1, 2): return "left"
        case (2, 1): return "top"
        case (2, 2): return "center"
        case (1, 0): return "topleft"  // AVC/HEVC default vertical = top
        case (2, 0): return "top"
        case (0, 1): return "topleft"
        case (0, 2): return "left"
        default: return nil
        }
    }

    private static func parseAudioBlock(
        _ data: Data,
        from start: Int,
        end: Int,
        into stream: inout AudioStream
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0xB5: // SamplingFrequency (float)
                if let v = readFloatPayload(data, offset: vStart, size: vSize) {
                    stream.sampleRate = Int(v)
                }
            case 0x9F: // Channels
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    stream.channels = Int(v)
                }
            case 0x6264: // BitDepth
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    stream.bitDepth = Int(v)
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }
    }

    // MARK: - Chapters

    /// Walk the Chapters master (0x1043A770). Each Chapters element contains
    /// one or more EditionEntry children; the non-hidden ones carry the list
    /// of ChapterAtoms we surface. Matches ffprobe's rule of skipping
    /// `EditionFlagHidden=1` editions so they never show up in the flat list.
    ///
    /// ChapterTimeStart / ChapterTimeEnd are nanosecond uints independent of
    /// the Segment's TimestampScale.
    private static func parseChapters(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let childStart = reader.offset
            let childEnd = childStart + Int(size)
            if id == 0x45B9 { // EditionEntry
                parseEditionEntry(data, from: childStart, end: childEnd, into: &metadata)
            }
            if (try? reader.seek(to: childEnd)) == nil { return }
        }

        // Stable sort by start time (most muxers already write them in order,
        // but we don't rely on that).
        metadata.chapters.sort { $0.startTime < $1.startTime }
        // Renumber so indices are contiguous even when we skipped hidden
        // chapters or editions.
        for i in 0..<metadata.chapters.count {
            metadata.chapters[i].index = i
        }
    }

    private static func parseEditionEntry(
        _ data: Data,
        from start: Int,
        end: Int,
        into metadata: inout VideoMetadata
    ) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var editionHidden = false
        var atoms: [(start: Int, end: Int)] = []
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x45BD: // EditionFlagHidden
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    editionHidden = v != 0
                }
            case 0xB6: // ChapterAtom
                atoms.append((vStart, vStart + vSize))
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { return }
        }

        guard !editionHidden else { return }
        for (s, e) in atoms {
            if let chapter = readChapterAtom(data, from: s, end: e,
                                             index: metadata.chapters.count) {
                metadata.chapters.append(chapter)
            }
        }
    }

    /// Decode a single ChapterAtom. Nested ChapterAtoms (sub-chapters) are
    /// flattened alongside their parents — ffprobe reports them the same way.
    private static func readChapterAtom(
        _ data: Data,
        from start: Int,
        end: Int,
        index: Int
    ) -> VideoChapter? {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()

        var uid: UInt64?
        var startTime: UInt64?
        var endTime: UInt64?
        var hidden = false
        var title: String?
        var language: String?

        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x73C4: // ChapterUID
                uid = readUIntPayload(data, offset: vStart, size: vSize)
            case 0x91: // ChapterTimeStart (ns)
                startTime = readUIntPayload(data, offset: vStart, size: vSize)
            case 0x92: // ChapterTimeEnd (ns, optional)
                endTime = readUIntPayload(data, offset: vStart, size: vSize)
            case 0x98: // ChapterFlagHidden
                if let v = readUIntPayload(data, offset: vStart, size: vSize) {
                    hidden = v != 0
                }
            case 0x80: // ChapterDisplay
                let display = readChapterDisplay(data, from: vStart, end: vStart + vSize)
                if title == nil { title = display.title }
                if language == nil { language = display.language }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { break }
        }

        guard !hidden, let ns = startTime else { return nil }
        let start = Double(ns) / 1_000_000_000.0
        let endSeconds: TimeInterval? = endTime.map { Double($0) / 1_000_000_000.0 }
        return VideoChapter(
            index: index,
            id: uid,
            startTime: start,
            endTime: endSeconds,
            title: title,
            language: language
        )
    }

    /// Extract the first `ChapString` / language pair from a ChapterDisplay.
    /// Matroska permits multiple ChapterDisplays per language; ffprobe picks
    /// the first one that appears, so we do too.
    private static func readChapterDisplay(
        _ data: Data,
        from start: Int,
        end: Int
    ) -> (title: String?, language: String?) {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        var title: String?
        var language: String?
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let vStart = reader.offset
            let vSize = Int(size)
            switch id {
            case 0x85: // ChapString
                if title == nil {
                    title = readStringPayload(data, offset: vStart, size: vSize)
                }
            case 0x437C: // ChapLanguage (ISO 639-2/T)
                if language == nil {
                    language = readStringPayload(data, offset: vStart, size: vSize)
                }
            case 0x437D: // ChapLanguageBCP47 — preferred when present
                if let bcp = readStringPayload(data, offset: vStart, size: vSize),
                   !bcp.isEmpty {
                    language = bcp
                }
            default:
                break
            }
            if (try? reader.seek(to: vStart + vSize)) == nil { break }
        }
        return (title, language)
    }

    // MARK: - EBML primitives

    /// Read an EBML element ID (VINT with the marker bits preserved).
    static func readEBMLID(_ reader: inout BinaryReader) throws -> UInt64 {
        guard reader.remainingCount >= 1 else { throw MetadataError.unexpectedEndOfData }
        let first = try reader.readUInt8()
        guard first != 0 else { throw MetadataError.invalidVideo("EBML ID byte 0") }
        var width = 0
        for i in 0..<8 {
            if first & (0x80 >> i) != 0 {
                width = i + 1
                break
            }
        }
        guard width > 0 else { throw MetadataError.invalidVideo("EBML ID invalid length") }
        var id: UInt64 = UInt64(first)
        for _ in 1..<width {
            let b = try reader.readUInt8()
            id = (id << 8) | UInt64(b)
        }
        return id
    }

    /// Read an EBML VINT (unknown-size sentinel returns nil).
    static func readVINT(_ reader: inout BinaryReader) throws -> UInt64? {
        guard reader.remainingCount >= 1 else { throw MetadataError.unexpectedEndOfData }
        let first = try reader.readUInt8()
        guard first != 0 else { throw MetadataError.invalidVideo("EBML VINT byte 0") }
        var width = 0
        for i in 0..<8 {
            if first & (0x80 >> i) != 0 {
                width = i + 1
                break
            }
        }
        guard width > 0 else { throw MetadataError.invalidVideo("EBML VINT invalid length") }

        let marker = UInt8(0x80) >> (width - 1)
        var value: UInt64 = UInt64(first & ~marker)
        // All-ones payload = unknown size.
        var isUnknown = (value == (1 << (7 - (width - 1))) - 1)
        for _ in 1..<width {
            let b = try reader.readUInt8()
            value = (value << 8) | UInt64(b)
            if b != 0xFF { isUnknown = false }
        }
        return isUnknown ? nil : value
    }

    // MARK: - Payload readers

    private static func readUIntPayload(_ data: Data, offset: Int, size: Int) -> UInt64? {
        guard size > 0, size <= 8, offset + size <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<size {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    private static func readSIntPayload(_ data: Data, offset: Int, size: Int) -> Int64? {
        guard let u = readUIntPayload(data, offset: offset, size: size), size > 0 else { return nil }
        let shift = 64 - size * 8
        let signed = Int64(bitPattern: u << shift) >> shift
        return signed
    }

    private static func readFloatPayload(_ data: Data, offset: Int, size: Int) -> Double? {
        guard offset + size <= data.count else { return nil }
        if size == 4 {
            let bits = (UInt32(data[data.startIndex + offset]) << 24)
                | (UInt32(data[data.startIndex + offset + 1]) << 16)
                | (UInt32(data[data.startIndex + offset + 2]) << 8)
                | UInt32(data[data.startIndex + offset + 3])
            return Double(Float(bitPattern: bits))
        }
        if size == 8 {
            var bits: UInt64 = 0
            for i in 0..<8 {
                bits = (bits << 8) | UInt64(data[data.startIndex + offset + i])
            }
            return Double(bitPattern: bits)
        }
        return nil
    }

    private static func readStringPayload(_ data: Data, offset: Int, size: Int) -> String? {
        guard offset + size <= data.count else { return nil }
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + size]
        // Strip trailing NULs (common in CodecID/Language).
        let trimmed = slice.prefix(while: { $0 != 0 })
        return String(data: Data(trimmed), encoding: .utf8)
    }

    private static func readEBMLDocType(_ data: Data, from start: Int, end: Int) -> String? {
        var reader = BinaryReader(data: data)
        (try? reader.seek(to: start)) ?? ()
        while reader.offset < end {
            guard let id = try? readEBMLID(&reader),
                  let size = try? readVINT(&reader),
                  reader.offset + Int(size) <= end else { break }
            let s = reader.offset
            let sz = Int(size)
            if id == 0x4282 { // DocType
                return readStringPayload(data, offset: s, size: sz)
            }
            if (try? reader.seek(to: s + sz)) == nil { return nil }
        }
        return nil
    }

    // MARK: - Codec naming

    private static func codecLongNameMatroska(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "V_MPEG4/ISO/AVC": return "H.264 / AVC"
        case "V_MPEGH/ISO/HEVC": return "H.265 / HEVC"
        case "V_AV1": return "AV1"
        case "V_VP8": return "VP8"
        case "V_VP9": return "VP9"
        case "V_MPEG4/ISO/ASP": return "MPEG-4 ASP"
        case "V_MPEG2": return "MPEG-2 Video"
        case "V_MPEG1": return "MPEG-1 Video"
        case "V_PRORES": return "Apple ProRes"
        case "V_MJPEG": return "Motion JPEG"
        case "V_THEORA": return "Theora"
        case "V_MS/VFW/FOURCC": return "VfW (FourCC)"
        case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG4/LC/SBR": return "AAC"
        case "A_AC3": return "Dolby Digital (AC-3)"
        case "A_EAC3": return "Dolby Digital Plus (E-AC-3)"
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS": return "DTS"
        case "A_FLAC": return "FLAC"
        case "A_OPUS": return "Opus"
        case "A_VORBIS": return "Vorbis"
        case "A_MPEG/L3": return "MP3"
        case "A_MPEG/L2": return "MP2"
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE": return "PCM"
        case "A_TRUEHD": return "TrueHD"
        default: return id
        }
    }
}
