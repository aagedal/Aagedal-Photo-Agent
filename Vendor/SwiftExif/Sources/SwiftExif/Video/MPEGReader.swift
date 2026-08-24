import Foundation

/// Reader for MPEG Program Streams (.mpg/.mpeg/.vob) and MPEG Transport
/// Streams (.ts/.m2ts). Pulls coarse video facts from the first video
/// Sequence Header.
///
/// Program Streams (PS): payload is a sequence of pack headers
/// (0x00 0x00 0x01 0xBA) followed by PES packets; video elementary stream
/// data is embedded in PES packets 0x000001E0..0x000001EF.
///
/// Transport Streams (TS): 188-byte packets, each starting with 0x47. Video
/// packets carry ES data in their payload; packets marked `payload_unit_start`
/// begin with a PES header that precedes the ES data.
///
/// Both forms lift the first MPEG-1/2 video sequence header (start code
/// 0x000001B3), which gives us width, height, frame rate, aspect ratio and
/// bit rate. For H.264/H.265 TS streams we currently only report the codec
/// identity — parsing the SPS is beyond scope here.
public struct MPEGReader: Sendable {

    /// Quick sniff: MPEG-PS starts with a pack header (0x00 0x00 0x01 0xBA);
    /// plain MPEG-TS has 188-byte packets with 0x47 sync at 0 / 188 / 376 /
    /// 564; Blu-ray M2TS prepends a 4-byte TP_extra_header to each packet,
    /// producing 192-byte packets with 0x47 at 4 / 196 / 388 / 580.
    public static func isMPEG(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex

        // Program stream
        if data[s] == 0x00 && data[s + 1] == 0x00 && data[s + 2] == 0x01 && data[s + 3] == 0xBA {
            return true
        }

        // Transport stream (plain MPEG-TS, 188-byte packets).
        if data[s] == 0x47 && data.count >= 188 * 4 {
            if data[s + 188] == 0x47
                && data[s + 376] == 0x47
                && data[s + 564] == 0x47 {
                return true
            }
        }

        // M2TS / Blu-ray BDAV: 192-byte packets with a 4-byte timestamp prefix.
        if data.count >= 192 * 4 {
            if data[s + 4] == 0x47
                && data[s + 196] == 0x47
                && data[s + 388] == 0x47
                && data[s + 580] == 0x47 {
                return true
            }
        }

        return false
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMPEG(data) else {
            throw MetadataError.invalidVideo("Not an MPEG-PS/TS file")
        }

        var metadata = VideoMetadata(format: .mpg)

        if data.count >= 4 {
            let s = data.startIndex
            if data[s] == 0x47 {
                metadata.formatLongName = "MPEG-TS (MPEG-2 Transport Stream)"
                parseTransportStream(data, into: &metadata, packetOffset: 0, packetStride: 188)
            } else if data.count >= 192 * 4,
                      data[s + 4] == 0x47,
                      data[s + 196] == 0x47 {
                // M2TS: 4-byte TP_extra_header + 188-byte TS packet = 192-byte stride.
                metadata.formatLongName = "BDAV / M2TS"
                parseTransportStream(data, into: &metadata, packetOffset: 4, packetStride: 192)
            } else {
                metadata.formatLongName = "MPEG-PS (MPEG Program Stream)"
                parseProgramStream(data, into: &metadata)
            }
        }

        // Surface the first video/audio stream to the top-level fields.
        if let v = metadata.videoStreams.first {
            if metadata.videoWidth == nil { metadata.videoWidth = v.width }
            if metadata.videoHeight == nil { metadata.videoHeight = v.height }
            if metadata.videoCodec == nil { metadata.videoCodec = v.codec }
            if metadata.frameRate == nil { metadata.frameRate = v.frameRate }
        }

        // MPEG-1/2 is always 4:2:0 8-bit. H.264/H.265 TS streams are typically
        // 4:2:0 8-bit too (the few 10-bit streams out there would need SPS
        // parsing to be sure) — mark those as unknown for now.
        for i in 0..<metadata.videoStreams.count {
            let codec = metadata.videoStreams[i].codec ?? ""
            if codec == "mpeg2video" || codec == "mpeg1video" {
                if metadata.videoStreams[i].chromaSubsampling == nil {
                    metadata.videoStreams[i].chromaSubsampling = "4:2:0"
                }
                if metadata.videoStreams[i].bitDepth == nil {
                    metadata.videoStreams[i].bitDepth = 8
                }
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

        return metadata
    }

    // MARK: - Program Stream

    /// Scan a bounded window for the first MPEG-1/2 video sequence header start
    /// code (00 00 01 B3) and decode it.
    ///
    /// We don't try to reconstruct PES structure — finding the start code is
    /// sufficient to pull stream-level facts and the scan window is cheap.
    private static let psScanWindow = 16 * 1024 * 1024

    private static func parseProgramStream(_ data: Data, into metadata: inout VideoMetadata) {
        let scanEnd = min(data.count, psScanWindow)
        let header = findSequenceHeader(data, from: 0, end: scanEnd)
        if let (w, h, fps, bitRate, aspect) = header {
            var stream = VideoStream(index: 0)
            stream.codec = "mpeg2video"
            stream.codecName = "MPEG-2 Video"
            stream.width = w
            stream.height = h
            stream.frameRate = fps
            if w > 0, h > 0, let aspect, aspect.0 > 0, aspect.1 > 0,
               aspect != (w, h) {
                stream.displayWidth = aspect.0
                stream.displayHeight = aspect.1
            }
            metadata.videoStreams.append(stream)
            if bitRate > 0 {
                metadata.bitRate = bitRate
            }
        }
    }

    // MARK: - Transport Stream

    /// Walk TS packets, decoding PAT/PMT and scanning video PES payloads for
    /// the first MPEG-1/2 sequence header.
    ///
    /// - `packetOffset`: byte offset to the first packet in the stream (0 for
    ///   plain TS, 4 for M2TS with a TP_extra_header prefix).
    /// - `packetStride`: distance between packet starts (188 for plain TS,
    ///   192 for M2TS).
    private static func parseTransportStream(
        _ data: Data,
        into metadata: inout VideoMetadata,
        packetOffset: Int,
        packetStride: Int
    ) {
        // Walk up to ~9 MB of packet payload, enough to cover PAT/PMT and the
        // first SPS / sequence header / ADTS frame on every PID in any
        // typical stream.
        let available = max(0, data.count - packetOffset)
        let maxPackets = min(available / packetStride, 48_000)
        let packetPayloadSize = 188
        var videoPIDs: [Int: TSStreamInfo] = [:]
        var audioPIDs: [Int: TSStreamInfo] = [:]
        var subtitlePIDs: [Int: TSStreamInfo] = [:]
        var pcrPid: Int? = nil
        var firstPCR: Double? = nil
        var lastPCR: Double? = nil

        // Pass 1: find PAT → PMT → elementary stream types. Track PSI programs
        // explicitly: PAT entries map programNumber → PMT PID; PMT scans then
        // collect each program's elementary PIDs. SDT (PID 0x0011) supplies
        // service / provider names where the broadcaster set them.
        var pmtToProgram: [Int: Int] = [:]
        var programTable: [Int: MPEGProgram] = [:]
        var sdtEntries: [SDTEntry] = []
        for i in 0..<maxPackets {
            let packetStart = packetOffset + i * packetStride
            let (pid, unitStart, _, payloadStart) = parseTSHeaderExtended(data, at: packetStart)
            guard pid >= 0, let payloadStart else { continue }
            if pid == 0, unitStart {
                for entry in parsePAT(data, from: payloadStart, end: packetStart + packetPayloadSize) {
                    if pmtToProgram[entry.pmtPID] == nil {
                        pmtToProgram[entry.pmtPID] = entry.programNumber
                        programTable[entry.programNumber] = MPEGProgram(
                            programNumber: entry.programNumber, pmtPID: entry.pmtPID)
                    }
                }
                continue
            }
            if pid == 0x0011, unitStart, sdtEntries.isEmpty {
                sdtEntries = parseSDT(data, from: payloadStart, end: packetStart + packetPayloadSize)
                continue
            }
            if let progNum = pmtToProgram[pid], unitStart {
                let beforeVideo = Set(videoPIDs.keys)
                let beforeAudio = Set(audioPIDs.keys)
                let beforeSub = Set(subtitlePIDs.keys)
                parsePMT(data, from: payloadStart, end: packetStart + packetPayloadSize,
                         videoPIDs: &videoPIDs, audioPIDs: &audioPIDs,
                         subtitlePIDs: &subtitlePIDs, pcrPid: &pcrPid)
                // Attribute newly-discovered elementary PIDs to this program.
                let added = (Set(videoPIDs.keys).subtracting(beforeVideo))
                    .union(Set(audioPIDs.keys).subtracting(beforeAudio))
                    .union(Set(subtitlePIDs.keys).subtracting(beforeSub))
                if !added.isEmpty, var prog = programTable[progNum] {
                    prog.elementaryPIDs.append(contentsOf: added.sorted())
                    programTable[progNum] = prog
                }
            }
        }

        // Pass 2: PES reassembly per video/audio PID + PCR / PTS tracking.
        for i in 0..<maxPackets {
            let packetStart = packetOffset + i * packetStride
            let (pid, unitStart, adaptationLen, payloadStart) =
                parseTSHeaderExtended(data, at: packetStart)
            guard pid >= 0 else { continue }

            // PCR carried in the adaptation field.
            if let pcrPid, pid == pcrPid, adaptationLen > 0 {
                if let pcr = parsePCRFromAdaptation(data, packetStart: packetStart, adaptationLen: adaptationLen) {
                    if firstPCR == nil { firstPCR = pcr }
                    lastPCR = pcr
                }
            }

            guard let payloadStart else { continue }
            let payloadEnd = packetStart + packetPayloadSize

            if videoPIDs[pid] != nil {
                accumulatePES(
                    data, payloadStart: payloadStart, payloadEnd: payloadEnd,
                    unitStart: unitStart, info: &videoPIDs[pid]!, isVideo: true
                )
            } else if audioPIDs[pid] != nil {
                accumulatePES(
                    data, payloadStart: payloadStart, payloadEnd: payloadEnd,
                    unitStart: unitStart, info: &audioPIDs[pid]!, isVideo: false
                )
            }
        }

        // Pass 3: tail-walk to capture the closing PCR. The head walk
        // capped at 48 000 packets, so for files larger than ~9 MB the
        // last PCR seen above is somewhere near the start. Re-scan the
        // last 9 MB to pick up the actual final PCR for an accurate
        // duration. Files under the head cap need no tail pass.
        if pcrPid != nil, available > maxPackets * packetStride {
            let tailBytes = min(available, 48_000 * packetStride)
            let tailStart = packetOffset + available - tailBytes
            // Realign to the next packet boundary.
            let alignDelta = (tailStart - packetOffset) % packetStride
            let alignedStart = tailStart - alignDelta
            let tailPackets = (packetOffset + available - alignedStart) / packetStride
            for i in 0..<tailPackets {
                let packetStart = alignedStart + i * packetStride
                let (pid, _, adaptationLen, _) = parseTSHeaderExtended(data, at: packetStart)
                if pid == pcrPid, adaptationLen > 0 {
                    if let pcr = parsePCRFromAdaptation(data, packetStart: packetStart, adaptationLen: adaptationLen) {
                        lastPCR = pcr
                    }
                }
            }
        }

        // Flush any residual PES buffers and run codec extractors so even
        // streams where the closing access unit was only seen mid-walk
        // surface their fields.
        for (pid, var info) in videoPIDs where !info.done && !info.pesBuffer.isEmpty {
            applyVideoExtractor(&info)
            videoPIDs[pid] = info
        }
        for (pid, var info) in audioPIDs where !info.done && !info.pesBuffer.isEmpty {
            applyAudioExtractor(&info)
            audioPIDs[pid] = info
        }

        // Duration from PCR bookends. Handle 33-bit PCR wrap (~26 h).
        if let f = firstPCR, let l = lastPCR {
            var duration = l - f
            if duration < 0 {
                duration += Double(1 << 33) / 90_000.0
            }
            if duration > 0 {
                metadata.duration = duration
            }
        }

        // Publish PSI programs (PAT/PMT/SDT join). Multi-program TS captures
        // (DVB / ATSC OTA) carry multiple services in one file — we expose
        // each so consumers can pick a specific channel.
        if !programTable.isEmpty {
            let sdtByID = Dictionary(uniqueKeysWithValues: sdtEntries.map { ($0.serviceID, $0) })
            metadata.mpegPrograms = programTable.values
                .sorted { $0.programNumber < $1.programNumber }
                .map { var p = $0
                    if let sdt = sdtByID[p.programNumber] {
                        p.serviceName = sdt.serviceName
                        p.providerName = sdt.providerName
                    }
                    return p
                }
        }

        // Publish streams. Preserve PAT/PMT discovery order.
        var nextIndex = 0
        for (_, info) in videoPIDs.sorted(by: { $0.key < $1.key }) {
            var stream = VideoStream(index: nextIndex); nextIndex += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.profile = info.profile
            stream.width = info.width
            stream.height = info.height
            stream.frameRate = info.frameRate
            if let br = info.bitRate, br > 0 { stream.bitRate = br }
            if let dw = info.displayWidth, let dh = info.displayHeight,
               dw != info.width || dh != info.height {
                stream.displayWidth = dw
                stream.displayHeight = dh
            }
            if let sar = info.sampleAspect { stream.pixelAspectRatio = sar }
            stream.chromaSubsampling = info.chromaSubsampling
            stream.bitDepth = info.bitDepth
            stream.chromaLocation = info.chromaLocation
            stream.colorInfo = info.color
            stream.fieldOrder = info.fieldOrder
            // SEI-derived metadata: HDR side-data (mdcv/clli), CTA-708 captions
            // signalling, and HEVC time_code timestamps.
            stream.hdr = info.hdr
            if let tc = info.timecode { stream.timecode = tc }
            if info.hasClosedCaptions { stream.hasClosedCaptions = true }
            if info.hasAlphaChannel { stream.hasAlphaChannel = true }
            // Per-stream bit rate from PES byte / PTS-span if not advertised.
            if stream.bitRate == nil,
               let f = info.firstPTS, let l = info.lastPTS, l > f, info.byteCount > 0 {
                stream.bitRate = Int(Double(info.byteCount) * 8.0 / (l - f))
            }
            metadata.videoStreams.append(stream)
            if metadata.bitRate == nil, let br = info.bitRate, br > 0 {
                metadata.bitRate = br
            }
        }

        var audioIdx = 0
        for (_, info) in audioPIDs.sorted(by: { $0.key < $1.key }) {
            var stream = AudioStream(index: audioIdx); audioIdx += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.profile = info.profile
            stream.sampleRate = info.sampleRate
            stream.channels = info.channels
            stream.channelLayout = info.channelLayout
            stream.language = info.language
            if let br = info.bitRate, br > 0 { stream.bitRate = br }
            if stream.bitRate == nil,
               let f = info.firstPTS, let l = info.lastPTS, l > f, info.byteCount > 0 {
                stream.bitRate = Int(Double(info.byteCount) * 8.0 / (l - f))
            }
            metadata.audioStreams.append(stream)
            if metadata.audioCodec == nil { metadata.audioCodec = info.codec }
        }

        var subIdx = 0
        for (_, info) in subtitlePIDs.sorted(by: { $0.key < $1.key }) {
            var stream = SubtitleStream(index: subIdx); subIdx += 1
            stream.codec = info.codec
            stream.codecName = info.codecName
            stream.language = info.language
            stream.isHearingImpaired = info.isHearingImpaired
            metadata.subtitleStreams.append(stream)
        }

        // File-level bit rate falls out of duration + file size when the
        // container didn't advertise one explicitly. Use Data byte count
        // as a stand-in for fileSize here — the public read path overrides
        // metadata.fileSize from the URL afterwards anyway.
        if metadata.bitRate == nil, let duration = metadata.duration, duration > 0 {
            let bytes = Int64(data.count)
            metadata.bitRate = Int(Double(bytes) * 8.0 / duration)
        }

        // Per-stream duration: MPEG-TS doesn't have a track-header duration
        // the way MP4 does. ffprobe walks every PES packet's PTS to compute
        // exact per-stream span (so streams can differ by a few hundred ms
        // depending on which packet ends last) — that's a full-file scan we
        // don't want to do up-front. Propagate the file-level duration to
        // each stream as a sensible default so consumers don't see nil.
        if let formatDur = metadata.duration, formatDur > 0 {
            for i in metadata.videoStreams.indices where metadata.videoStreams[i].duration == nil {
                metadata.videoStreams[i].duration = formatDur
            }
            for i in metadata.audioStreams.indices where metadata.audioStreams[i].duration == nil {
                metadata.audioStreams[i].duration = formatDur
            }
            for i in metadata.subtitleStreams.indices where metadata.subtitleStreams[i].duration == nil {
                metadata.subtitleStreams[i].duration = formatDur
            }
        }
    }

    /// Per-PID PES accumulator. On a unit-start packet, flush the
    /// accumulated payload via the codec extractor and start a fresh PES
    /// buffer at the byte after the PES header. Tracks PTS bookends and
    /// total byte counts for per-stream bit-rate calculation — those keep
    /// growing even after codec extraction has succeeded, so we can divide
    /// total bytes by total PTS span at the end.
    private static func accumulatePES(
        _ data: Data,
        payloadStart: Int,
        payloadEnd: Int,
        unitStart: Bool,
        info: inout TSStreamInfo,
        isVideo: Bool
    ) {
        if unitStart {
            // Flush any prior PES buffer before resetting (only matters
            // when we haven't yet extracted codec params).
            if !info.done, !info.pesBuffer.isEmpty {
                if isVideo { applyVideoExtractor(&info) }
                else { applyAudioExtractor(&info) }
            }
            info.pesBuffer.removeAll(keepingCapacity: true)
            // Decode the PES header at payloadStart; consume PTS when present.
            if let parsed = parsePESHeader(data, at: payloadStart, end: payloadEnd) {
                if let pts = parsed.pts {
                    if info.firstPTS == nil { info.firstPTS = pts }
                    info.lastPTS = pts
                }
                let esStart = parsed.esStart
                if esStart < payloadEnd {
                    if !info.done {
                        appendToPES(&info, data: data, from: esStart, end: payloadEnd)
                    } else {
                        // Just count bytes for per-stream bit-rate calc.
                        info.byteCount += payloadEnd - esStart
                    }
                }
            }
            info.pesUnitStarted = true
        } else if info.pesUnitStarted {
            if !info.done {
                appendToPES(&info, data: data, from: payloadStart, end: payloadEnd)
            } else {
                info.byteCount += payloadEnd - payloadStart
            }
        }

        // Try to extract codec params eagerly. Some codecs (ADTS, AC-3)
        // give us everything from a single sync frame and don't need a
        // full PES.
        if !info.done, info.pesBuffer.count >= 32 {
            if isVideo { applyVideoExtractor(&info) }
            else { applyAudioExtractor(&info) }
        }

        // Cap memory.
        if info.pesBuffer.count > pesAccumulatorCap {
            info.pesBuffer.removeFirst(info.pesBuffer.count - pesAccumulatorCap)
        }
    }

    private static func appendToPES(
        _ info: inout TSStreamInfo,
        data: Data,
        from start: Int,
        end: Int
    ) {
        guard start < end, end <= data.count else { return }
        let chunk = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
        info.pesBuffer.append(chunk)
        info.byteCount += chunk.count
    }

    /// Run the H.264 / H.265 / MPEG-2 SPS / sequence-header extractor
    /// over the accumulated PES buffer. Sets `done` once all fields the
    /// codec advertises have been collected.
    private static func applyVideoExtractor(_ info: inout TSStreamInfo) {
        guard !info.done else { return }
        let buf = info.pesBuffer
        switch info.codec {
        case "avc1":
            if extractH264Fields(from: buf, into: &info) {
                info.sequenceHeaderParsed = true
                info.done = true
            }
        case "hvc1":
            if extractHEVCFields(from: buf, into: &info) {
                info.sequenceHeaderParsed = true
                info.done = true
            }
        case "mpeg1video", "mpeg2video":
            if extractMPEGVideoFields(from: buf, into: &info) {
                info.sequenceHeaderParsed = true
                info.done = true
            }
        default:
            break
        }
    }

    private static func applyAudioExtractor(_ info: inout TSStreamInfo) {
        guard !info.done else { return }
        let buf = info.pesBuffer
        switch info.codec {
        case "aac":
            if let f = MPEGBitstream.parseAACADTS(buf) {
                applyAACFields(f, to: &info)
                info.done = true
            } else if let f = MPEGBitstream.parseAACLATM(buf) {
                applyAACFields(f, to: &info)
                info.done = true
            }
        case "ac3":
            if let f = MPEGBitstream.parseAC3(buf) {
                applyAC3Fields(f, to: &info)
                info.done = true
            }
        case "eac3":
            if let f = MPEGBitstream.parseEAC3(buf) {
                applyAC3Fields(f, to: &info)
                info.done = true
            }
        default:
            break
        }
    }

    private static func applyAACFields(_ f: MPEGBitstream.ADTSFields, to info: inout TSStreamInfo) {
        if let p = f.profile {
            info.profile = p
            info.codecName = "AAC \(p)"
        }
        if let sr = f.sampleRate { info.sampleRate = sr }
        if let ch = f.channels { info.channels = ch }
        if let cl = f.channelLayout { info.channelLayout = cl }
    }

    private static func applyAC3Fields(_ f: MPEGBitstream.AC3Fields, to info: inout TSStreamInfo) {
        if let sr = f.sampleRate { info.sampleRate = sr }
        if let ch = f.channels { info.channels = ch }
        if let cl = f.channelLayout { info.channelLayout = cl }
        if info.bitRate == nil, let br = f.bitRate, br > 0 { info.bitRate = br }
    }

    /// Walk the accumulated PES buffer looking for an H.264 SPS NAL
    /// (`nal_unit_type == 7`) and decode it. Returns true on success.
    private static func extractH264Fields(from buf: Data, into info: inout TSStreamInfo) -> Bool {
        var seiRBSPs: [Data] = []
        var spsFound = false
        for range in MPEGBitstream.annexBNALRanges(buf) {
            guard !range.isEmpty else { continue }
            let nalHeader = buf[buf.startIndex + range.lowerBound]
            let nalType = Int(nalHeader & 0x1F)
            // SPS = 7, SEI = 6.
            if nalType == 7, !spsFound {
                let rbspLower = range.lowerBound + 1
                let rbspUpper = range.upperBound
                guard rbspLower < rbspUpper else { continue }
                let raw = buf.subdata(in: buf.startIndex + rbspLower ..< buf.startIndex + rbspUpper)
                let rbsp = MPEGBitstream.stripEmulationPrevention(raw)
                if let f = MPEGBitstream.parseH264SPS(rbsp) {
                    applyH264Fields(f, to: &info)
                    spsFound = true
                }
            } else if nalType == 6 {
                let rbspLower = range.lowerBound + 1
                let rbspUpper = range.upperBound
                guard rbspLower < rbspUpper else { continue }
                let raw = buf.subdata(in: buf.startIndex + rbspLower ..< buf.startIndex + rbspUpper)
                seiRBSPs.append(MPEGBitstream.stripEmulationPrevention(raw))
            }
        }
        if !seiRBSPs.isEmpty {
            applySEI(MPEGBitstream.parseSEIMessages(seiRBSPs, forHEVC: false), to: &info)
            info.seiSearched = true
        }
        return spsFound
    }

    private static func extractHEVCFields(from buf: Data, into info: inout TSStreamInfo) -> Bool {
        var seiRBSPs: [Data] = []
        var spsFound = false
        for range in MPEGBitstream.annexBNALRanges(buf) {
            guard range.upperBound - range.lowerBound >= 2 else { continue }
            let header0 = buf[buf.startIndex + range.lowerBound]
            let nalType = Int((header0 >> 1) & 0x3F)
            // HEVC NAL header is 2 bytes; SPS=33, PREFIX_SEI=39, SUFFIX_SEI=40.
            if nalType == 33, !spsFound {
                let rbspLower = range.lowerBound + 2
                let rbspUpper = range.upperBound
                guard rbspLower < rbspUpper else { continue }
                let raw = buf.subdata(in: buf.startIndex + rbspLower ..< buf.startIndex + rbspUpper)
                let rbsp = MPEGBitstream.stripEmulationPrevention(raw)
                if let f = MPEGBitstream.parseHEVCSPS(rbsp) {
                    applyHEVCFields(f, to: &info)
                    spsFound = true
                }
            } else if nalType == 39 || nalType == 40 {
                let rbspLower = range.lowerBound + 2
                let rbspUpper = range.upperBound
                guard rbspLower < rbspUpper else { continue }
                let raw = buf.subdata(in: buf.startIndex + rbspLower ..< buf.startIndex + rbspUpper)
                seiRBSPs.append(MPEGBitstream.stripEmulationPrevention(raw))
            }
        }
        if !seiRBSPs.isEmpty {
            applySEI(MPEGBitstream.parseSEIMessages(seiRBSPs, forHEVC: true), to: &info)
            info.seiSearched = true
        }
        return spsFound
    }

    /// Merge SEI-derived metadata into a stream's accumulated state.
    private static func applySEI(_ sei: MPEGBitstream.SEIData, to info: inout TSStreamInfo) {
        if sei.masteringDisplay != nil || sei.contentLightLevel != nil {
            var hdr = info.hdr ?? HDRMetadata()
            if let md = sei.masteringDisplay { hdr.masteringDisplay = md }
            if let cll = sei.contentLightLevel { hdr.contentLightLevel = cll }
            info.hdr = hdr
        }
        if sei.hasClosedCaptions { info.hasClosedCaptions = true }
        if let tc = sei.timecode { info.timecode = tc }
        if sei.hasAlphaChannel { info.hasAlphaChannel = true }
    }

    private static func extractMPEGVideoFields(from buf: Data, into info: inout TSStreamInfo) -> Bool {
        guard let header = findSequenceHeader(buf, from: 0, end: buf.count) else { return false }
        let (w, h, fps, br, aspect) = header
        info.width = w
        info.height = h
        info.frameRate = fps
        if br > 0, info.bitRate == nil { info.bitRate = br }
        if let aspect, aspect.0 > 0, aspect.1 > 0, aspect != (w, h) {
            info.displayWidth = aspect.0
            info.displayHeight = aspect.1
        }
        // Optional sequence_extension that follows sets progressive_sequence
        // and finer chroma_format / size_extension. Best-effort.
        applyMPEG2SequenceExtension(from: buf, into: &info)
        return true
    }

    private static func applyH264Fields(_ f: MPEGBitstream.H264SPSFields, to info: inout TSStreamInfo) {
        if let p = f.profile { info.profile = p }
        if let w = f.width, w > 0 { info.width = w }
        if let h = f.height, h > 0 { info.height = h }
        if let cs = f.chromaSubsampling { info.chromaSubsampling = cs }
        if let bd = f.bitDepth { info.bitDepth = bd }
        if let sar = f.sampleAspect { info.sampleAspect = sar }
        if let dar = f.displayAspect { info.displayWidth = dar.0; info.displayHeight = dar.1 }
        if let fps = f.frameRate, fps > 0 { info.frameRate = fps }
        if let color = f.color { info.color = color }
        if let cl = f.chromaLocation { info.chromaLocation = cl }
        if let order = f.fieldOrder { info.fieldOrder = order }
    }

    private static func applyHEVCFields(_ f: MPEGBitstream.HEVCSPSFields, to info: inout TSStreamInfo) {
        if let p = f.profile { info.profile = p }
        if let w = f.width, w > 0 { info.width = w }
        if let h = f.height, h > 0 { info.height = h }
        if let cs = f.chromaSubsampling { info.chromaSubsampling = cs }
        if let bd = f.bitDepth { info.bitDepth = bd }
        if let sar = f.sampleAspect { info.sampleAspect = sar }
        if let dar = f.displayAspect { info.displayWidth = dar.0; info.displayHeight = dar.1 }
        if let fps = f.frameRate, fps > 0 { info.frameRate = fps }
        if let color = f.color { info.color = color }
        if let cl = f.chromaLocation { info.chromaLocation = cl }
    }

    /// Best-effort MPEG-2 sequence_extension scan. Looks for the
    /// `00 00 01 B5` extension start code followed by `1` (sequence
    /// extension identifier in the high nibble of the next byte) and
    /// pulls out progressive_sequence, chroma_format, and the
    /// horizontal/vertical_size_extension bits.
    private static func applyMPEG2SequenceExtension(from buf: Data, into info: inout TSStreamInfo) {
        let n = buf.count
        var i = 0
        while i + 8 < n {
            if buf[buf.startIndex + i] == 0,
               buf[buf.startIndex + i + 1] == 0,
               buf[buf.startIndex + i + 2] == 1,
               buf[buf.startIndex + i + 3] == 0xB5 {
                let b4 = buf[buf.startIndex + i + 4]
                if (b4 >> 4) == 0x1 {
                    // sequence_extension layout (after the 4-bit ID):
                    //   8 bits profile_and_level
                    //   1 bit progressive_sequence
                    //   2 bits chroma_format
                    //   2 bits horizontal_size_extension
                    //   2 bits vertical_size_extension
                    let b5 = buf[buf.startIndex + i + 5]
                    let progressive = (b5 & 0x08) != 0
                    let chromaFmt = (b5 >> 1) & 0x03
                    if progressive { info.fieldOrder = .progressive }
                    switch chromaFmt {
                    case 1: info.chromaSubsampling = "4:2:0"
                    case 2: info.chromaSubsampling = "4:2:2"
                    case 3: info.chromaSubsampling = "4:4:4"
                    default: break
                    }
                    return
                }
            }
            i += 1
        }
    }

    /// Parse a PES header at the given offset. Returns the offset at
    /// which ES data starts, plus the optional PTS (in seconds at 90 kHz).
    private static func parsePESHeader(_ data: Data, at offset: Int, end: Int) -> (esStart: Int, pts: Double?)? {
        guard offset + 9 <= end else { return nil }
        let s = data.startIndex + offset
        guard data[s] == 0x00, data[s + 1] == 0x00, data[s + 2] == 0x01 else { return nil }
        let flags = data[s + 7]
        let headerDataLen = Int(data[s + 8])
        let esStart = offset + 9 + headerDataLen
        var pts: Double? = nil
        let ptsFlags = (flags & 0xC0) >> 6
        if ptsFlags != 0, headerDataLen >= 5, offset + 9 + 5 <= end {
            let p0 = UInt64(data[s + 9])
            let p1 = UInt64(data[s + 10])
            let p2 = UInt64(data[s + 11])
            let p3 = UInt64(data[s + 12])
            let p4 = UInt64(data[s + 13])
            // 33-bit PTS reassembled across 5 bytes per ISO/IEC 13818-1.
            let raw = ((p0 >> 1) & 0x07) << 30
                | (p1 << 22)
                | ((p2 >> 1) & 0x7F) << 15
                | (p3 << 7)
                | ((p4 >> 1) & 0x7F)
            pts = Double(raw) / 90_000.0
        }
        return esStart < end ? (esStart, pts) : nil
    }

    /// Decode a 6-byte PCR field from the adaptation field of a TS
    /// packet. Returns the PCR in seconds, or nil when the PCR_flag
    /// isn't set or the bytes aren't present.
    private static func parsePCRFromAdaptation(_ data: Data, packetStart: Int, adaptationLen: Int) -> Double? {
        // adaptation_field begins at packetStart + 4; byte 0 is the
        // length, byte 1 is the flags byte. PCR field needs 6 bytes
        // after the flags byte → total ≥ length(1) + flags(1) + 6 = 8.
        guard adaptationLen >= 8 else { return nil }
        let s = data.startIndex + packetStart + 4
        guard s + 8 <= data.endIndex else { return nil }
        let flags = data[s + 1]
        guard (flags & 0x10) != 0 else { return nil } // PCR_flag
        let p0 = UInt64(data[s + 2])
        let p1 = UInt64(data[s + 3])
        let p2 = UInt64(data[s + 4])
        let p3 = UInt64(data[s + 5])
        let p4 = UInt64(data[s + 6])
        let p5 = UInt64(data[s + 7])
        let pcrBase = (p0 << 25) | (p1 << 17) | (p2 << 9) | (p3 << 1) | ((p4 >> 7) & 0x1)
        let pcrExt = ((p4 & 0x01) << 8) | p5
        return Double(pcrBase) / 90_000.0 + Double(pcrExt) / 27_000_000.0
    }

    /// Parse a 188-byte TS packet header. Returns (pid,
    /// payloadUnitStart, total adaptation-field bytes including the
    /// length byte, payloadOffset-or-nil). `adaptationLen == 0` means
    /// no adaptation field; `payloadOffset == nil` means the packet has
    /// no payload (adaptation-field-only or out-of-bounds).
    private static func parseTSHeaderExtended(_ data: Data, at packetStart: Int)
        -> (pid: Int, payloadUnitStart: Bool, adaptationLen: Int, payloadOffset: Int?)
    {
        guard packetStart + 4 <= data.count, data[data.startIndex + packetStart] == 0x47 else {
            return (-1, false, 0, nil)
        }
        let s = data.startIndex + packetStart
        let flags1 = data[s + 1]
        let flags2 = data[s + 2]
        let adaptationByte = data[s + 3]

        let payloadUnitStart = (flags1 & 0x40) != 0
        let pid = (Int(flags1 & 0x1F) << 8) | Int(flags2)
        let hasAdaptation = (adaptationByte & 0x20) != 0
        let hasPayload = (adaptationByte & 0x10) != 0

        var adaptationLen = 0
        var payloadOffset = 4
        if hasAdaptation {
            guard packetStart + 4 + 1 <= data.count else { return (pid, payloadUnitStart, 0, nil) }
            adaptationLen = Int(data[s + 4]) + 1 // include the length byte itself
            payloadOffset = 4 + adaptationLen
        }
        if !hasPayload || payloadOffset >= 188 {
            return (pid, payloadUnitStart, adaptationLen, nil)
        }
        return (pid, payloadUnitStart, adaptationLen, packetStart + payloadOffset)
    }

    private struct TSStreamInfo {
        var codec: String?
        var codecName: String?
        var profile: String?
        var level: String?
        var width: Int?
        var height: Int?
        var frameRate: Double?
        var bitRate: Int?
        var displayWidth: Int?
        var displayHeight: Int?
        var sampleAspect: (Int, Int)?
        var language: String?
        var isHearingImpaired: Bool?
        var sequenceHeaderParsed: Bool = false
        // Codec-parameter extraction state.
        var chromaSubsampling: String?
        var bitDepth: Int?
        var chromaLocation: String?
        var color: VideoColorInfo?
        var fieldOrder: VideoFieldOrder?
        // Audio-only fields.
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
        // PES reassembly state — accumulated PES payload bytes for the
        // current access unit, plus a flag set once we've seen the first
        // unit-start so we know when to flush.
        var pesBuffer: Data = Data()
        var pesUnitStarted: Bool = false
        // Per-stream timing for ffprobe-parity per-stream bit rate.
        var firstPTS: Double?
        var lastPTS: Double?
        var byteCount: Int = 0
        var done: Bool = false
        // SEI-derived video metadata (HDR, captions, timecode, alpha) — we
        // accumulate across PES buffers because individual SEI NALs may carry
        // different payload types. Marked done once we've seen at least one
        // mastering-display payload (the typical placeholder for "all the
        // HDR info has shown up").
        var hdr: HDRMetadata?
        var hasClosedCaptions: Bool = false
        var timecode: String?
        var hasAlphaChannel: Bool = false
        var seiSearched: Bool = false
    }

    /// Cap on the per-PID PES accumulator. The first SPS / PPS / IDR
    /// access unit in any sane H.264/H.265 stream is well under this; the
    /// cap exists purely to bound memory on bizarre encoders that hold
    /// codec parameters back behind hundreds of KB of B-frames.
    private static let pesAccumulatorCap: Int = 256 * 1024

    /// PAT body layout (after the pointer field, once we've skipped it):
    ///   table_id(1) + section_syntax(1) + section_length(2) + transport_stream_id(2) +
    ///   version(1) + section_number(1) + last_section(1) +
    ///   [program_number(2) + reserved+PMT_PID(2)]*
    ///
    /// Returns each (programNumber, pmtPID) pair so callers can distinguish
    /// multiple programs in the same TS. Program 0 is the network-information
    /// table and is skipped.
    private static func parsePAT(_ data: Data, from start: Int, end: Int) -> [(programNumber: Int, pmtPID: Int)] {
        guard start < end else { return [] }
        var s = start
        // Pointer field
        let pointer = Int(data[data.startIndex + s])
        s += 1 + pointer
        guard s + 8 <= end else { return [] }
        let sectionLength = (Int(data[data.startIndex + s + 1] & 0x0F) << 8) | Int(data[data.startIndex + s + 2])
        let sectionEnd = min(s + 3 + sectionLength - 4, end) // exclude 4-byte CRC

        var entries: [(Int, Int)] = []
        var off = s + 8
        while off + 4 <= sectionEnd {
            let programNumber = (Int(data[data.startIndex + off]) << 8) | Int(data[data.startIndex + off + 1])
            let pmtPid = (Int(data[data.startIndex + off + 2] & 0x1F) << 8) | Int(data[data.startIndex + off + 3])
            if programNumber != 0 { entries.append((programNumber, pmtPid)) }
            off += 4
        }
        return entries
    }

    // MARK: - DVB SDT (Service Description Table)

    /// Parsed SDT entry — one DVB service per transport stream. Maps
    /// programNumber → (serviceName, providerName) so the caller can join
    /// to the PAT/PMT tree.
    private struct SDTEntry {
        let serviceID: Int
        var serviceName: String?
        var providerName: String?
    }

    /// SDT (PID 0x0011, table_id 0x42 for "actual TS"). Layout:
    ///   pointer + table_id(1) + section_syntax+length(2) +
    ///   transport_stream_id(2) + version(1) + section_number(1) +
    ///   last_section(1) + original_network_id(2) + reserved(1) +
    ///   [service_id(2) + reserved+EIT_flags(1) + running+free_CA+
    ///    descriptors_loop_length(2) + descriptors]*
    private static func parseSDT(_ data: Data, from start: Int, end: Int) -> [SDTEntry] {
        guard start < end else { return [] }
        var s = start
        let pointer = Int(data[data.startIndex + s])
        s += 1 + pointer
        guard s + 11 <= end else { return [] }
        // table_id 0x42 = SDT actual TS, 0x46 = SDT other TS. Accept both.
        let tableID = data[data.startIndex + s]
        guard tableID == 0x42 || tableID == 0x46 else { return [] }
        let sectionLength = (Int(data[data.startIndex + s + 1] & 0x0F) << 8) | Int(data[data.startIndex + s + 2])
        let sectionEnd = min(s + 3 + sectionLength - 4, end)
        var off = s + 11

        var entries: [SDTEntry] = []
        while off + 5 <= sectionEnd {
            let serviceID = (Int(data[data.startIndex + off]) << 8) | Int(data[data.startIndex + off + 1])
            let descLen = (Int(data[data.startIndex + off + 3] & 0x0F) << 8) | Int(data[data.startIndex + off + 4])
            let descStart = off + 5
            let descEnd = min(descStart + descLen, sectionEnd)
            var entry = SDTEntry(serviceID: serviceID)
            // Walk descriptors: 0x48 (service_descriptor) carries provider/service names.
            var d = descStart
            while d + 2 <= descEnd {
                let tag = data[data.startIndex + d]
                let len = Int(data[data.startIndex + d + 1])
                let bodyStart = d + 2
                let bodyEnd = min(bodyStart + len, descEnd)
                if tag == 0x48, bodyEnd - bodyStart >= 3 {
                    // service_descriptor:
                    //   service_type(1) + provider_name_length(1) + provider_name(N) +
                    //   service_name_length(1) + service_name(M)
                    let provLen = Int(data[data.startIndex + bodyStart + 1])
                    let provNameStart = bodyStart + 2
                    let provNameEnd = min(provNameStart + provLen, bodyEnd)
                    if provNameEnd <= bodyEnd {
                        entry.providerName = decodeDVBString(
                            data.subdata(in: data.startIndex + provNameStart ..< data.startIndex + provNameEnd))
                        let svcLenOff = provNameEnd
                        if svcLenOff < bodyEnd {
                            let svcLen = Int(data[data.startIndex + svcLenOff])
                            let svcStart = svcLenOff + 1
                            let svcEnd = min(svcStart + svcLen, bodyEnd)
                            if svcEnd <= bodyEnd {
                                entry.serviceName = decodeDVBString(
                                    data.subdata(in: data.startIndex + svcStart ..< data.startIndex + svcEnd))
                            }
                        }
                    }
                }
                d = bodyEnd
            }
            entries.append(entry)
            off = descEnd
        }
        return entries
    }

    /// DVB strings (EN 300 468) start with an optional control byte naming
    /// the encoding. 0x01–0x0B select ISO-8859-2..-15; 0x10 + 2 bytes selects
    /// a 16-bit ISO-8859 code page; 0x11 = UCS-2; 0x14–0x15 = UTF-16; 0x15 = UTF-8.
    /// Without a control byte, default to ISO-6937 (we approximate with Latin-1
    /// since true ISO-6937 needs a translation table for combining diacritics).
    private static func decodeDVBString(_ bytes: Data) -> String? {
        guard !bytes.isEmpty else { return nil }
        let first = bytes[bytes.startIndex]
        if first == 0x15 {
            return String(data: bytes.dropFirst(), encoding: .utf8)
        }
        if first == 0x11 {
            return String(data: bytes.dropFirst(), encoding: .utf16BigEndian)
        }
        if first >= 0x01 && first <= 0x0B {
            // ISO-8859-(5+first-1). Fall back to Latin-1 — close enough for
            // ASCII-range channel names which is what 99% of real-world SDTs use.
            return String(data: bytes.dropFirst(), encoding: .isoLatin1)
        }
        if first < 0x20 {
            // Unknown control byte — strip it.
            return String(data: bytes.dropFirst(), encoding: .isoLatin1)
        }
        return String(data: bytes, encoding: .isoLatin1)
    }

    private static func parsePMT(
        _ data: Data,
        from start: Int,
        end: Int,
        videoPIDs: inout [Int: TSStreamInfo],
        audioPIDs: inout [Int: TSStreamInfo],
        subtitlePIDs: inout [Int: TSStreamInfo],
        pcrPid: inout Int?
    ) {
        guard start < end else { return }
        var s = start
        let pointer = Int(data[data.startIndex + s])
        s += 1 + pointer
        guard s + 12 <= end else { return }

        let sectionLength = (Int(data[data.startIndex + s + 1] & 0x0F) << 8) | Int(data[data.startIndex + s + 2])
        let sectionEnd = min(s + 3 + sectionLength - 4, end)

        // PCR_PID at offset s+8..9 (13 bits, top 3 bits are reserved).
        if pcrPid == nil {
            let pid = (Int(data[data.startIndex + s + 8] & 0x1F) << 8)
                | Int(data[data.startIndex + s + 9])
            if pid != 0x1FFF { pcrPid = pid }
        }

        // Program_info_length at offset s+10..11
        let programInfoLength = (Int(data[data.startIndex + s + 10] & 0x0F) << 8) | Int(data[data.startIndex + s + 11])
        var off = s + 12 + programInfoLength
        while off + 5 <= sectionEnd {
            let streamType = data[data.startIndex + off]
            let pid = (Int(data[data.startIndex + off + 1] & 0x1F) << 8) | Int(data[data.startIndex + off + 2])
            let esInfoLen = (Int(data[data.startIndex + off + 3] & 0x0F) << 8) | Int(data[data.startIndex + off + 4])

            let descriptorStart = off + 5
            let descriptorEnd = min(descriptorStart + esInfoLen, sectionEnd)
            let esDescriptors = parseESDescriptors(data, from: descriptorStart, end: descriptorEnd)

            switch streamType {
            case 0x01, 0x02:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "mpeg2video"
                info.codecName = "MPEG-2 Video"
                applyMaxBitRate(esDescriptors, to: &info)
                videoPIDs[pid] = info
            case 0x1B:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "avc1"
                info.codecName = "H.264 / AVC"
                applyMaxBitRate(esDescriptors, to: &info)
                videoPIDs[pid] = info
            case 0x24:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "hvc1"
                info.codecName = "H.265 / HEVC"
                applyMaxBitRate(esDescriptors, to: &info)
                videoPIDs[pid] = info
            case 0x10:
                var info = videoPIDs[pid] ?? TSStreamInfo()
                info.codec = "mp4v"
                info.codecName = "MPEG-4 Visual"
                // No bitstream parser yet for MPEG-4 Visual — keep the
                // codec-only behaviour by marking it pre-parsed.
                info.sequenceHeaderParsed = true
                applyMaxBitRate(esDescriptors, to: &info)
                videoPIDs[pid] = info
            case 0x03, 0x04:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "mp3"
                info.codecName = "MPEG-1/2 Layer III"
                info.language = esDescriptors.language
                applyMaxBitRate(esDescriptors, to: &info)
                audioPIDs[pid] = info
            case 0x0F, 0x11:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "aac"
                info.codecName = "AAC"
                info.language = esDescriptors.language
                applyMaxBitRate(esDescriptors, to: &info)
                audioPIDs[pid] = info
            case 0x81:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "ac3"
                info.codecName = "Dolby Digital (AC-3)"
                info.language = esDescriptors.language
                applyMaxBitRate(esDescriptors, to: &info)
                audioPIDs[pid] = info
            case 0x87:
                var info = audioPIDs[pid] ?? TSStreamInfo()
                info.codec = "eac3"
                info.codecName = "Dolby Digital Plus (E-AC-3)"
                info.language = esDescriptors.language
                applyMaxBitRate(esDescriptors, to: &info)
                audioPIDs[pid] = info
            case 0x82:
                // HDMV PGS (Blu-ray graphic subtitles).
                var info = subtitlePIDs[pid] ?? TSStreamInfo()
                info.codec = "hdmv_pgs"
                info.codecName = "PGS (Blu-ray)"
                info.language = esDescriptors.language
                subtitlePIDs[pid] = info
            case 0x92:
                // HDMV IGS (Blu-ray interactive graphics) — not subtitles, skip.
                break
            case 0x06:
                // Private data — resolve to DVB subtitles / teletext via
                // descriptors when present.
                if let kind = esDescriptors.privateKind {
                    var info = subtitlePIDs[pid] ?? TSStreamInfo()
                    switch kind {
                    case .dvbSubtitle:
                        info.codec = "dvb_subtitle"
                        info.codecName = "DVB Subtitles"
                    case .teletext:
                        info.codec = "dvb_teletext"
                        info.codecName = "DVB Teletext"
                    case .ac3:
                        // Some muxers carry AC-3 on private stream type 0x06
                        // with an AC-3 descriptor. Route it to audio.
                        var a = audioPIDs[pid] ?? TSStreamInfo()
                        a.codec = "ac3"
                        a.codecName = "Dolby Digital (AC-3)"
                        a.language = esDescriptors.language
                        applyMaxBitRate(esDescriptors, to: &a)
                        audioPIDs[pid] = a
                        off += 5 + esInfoLen
                        continue
                    }
                    info.language = esDescriptors.language
                    if esDescriptors.isHearingImpaired == true {
                        info.isHearingImpaired = true
                    }
                    subtitlePIDs[pid] = info
                }
            default:
                break
            }

            off += 5 + esInfoLen
        }
    }

    /// Fields we extract from an elementary stream's descriptor loop.
    private struct ESDescriptorInfo {
        var language: String?
        var privateKind: PrivateStreamKind?
        var isHearingImpaired: Bool?
        /// Maximum bit-rate (bits/s) from the ISO/IEC 13818-1 maximum_bitrate
        /// descriptor (tag 0x0E). For H.264/H.265/AAC/AC-3 streams this is
        /// usually the only bit-rate the container advertises.
        var maxBitRate: Int?
    }

    private enum PrivateStreamKind {
        case dvbSubtitle
        case teletext
        case ac3
    }

    private static func applyMaxBitRate(_ desc: ESDescriptorInfo, to info: inout TSStreamInfo) {
        if info.bitRate == nil, let mbr = desc.maxBitRate, mbr > 0 {
            info.bitRate = mbr
        }
    }

    /// Walk the descriptor loop that follows every ES entry in the PMT.
    /// Recognises:
    ///   - ISO 639 language descriptor (tag 0x0A) — 3-byte ISO code per entry.
    ///   - DVB subtitle descriptor (tag 0x59) — marks subtitle streams; the
    ///     per-language `subtitling_type` byte distinguishes SDH variants
    ///     (0x20-0x24 hard-of-hearing, 0x30-0x31 sign-language) from the
    ///     plain subtitle types (0x01-0x06).
    ///   - Teletext descriptor (tag 0x56) — marks teletext streams; each
    ///     entry's `teletext_type` nibble flags value 0x05 as the
    ///     hearing-impaired subtitle page.
    ///   - AC-3 descriptor (tag 0x6A) — present on DVB private-stream AC-3.
    private static func parseESDescriptors(_ data: Data, from start: Int, end: Int) -> ESDescriptorInfo {
        var info = ESDescriptorInfo()
        guard start < end, end <= data.count else { return info }
        var off = start
        while off + 2 <= end {
            let tag = data[data.startIndex + off]
            let length = Int(data[data.startIndex + off + 1])
            let valueStart = off + 2
            let valueEnd = valueStart + length
            guard valueEnd <= end else { break }

            switch tag {
            case 0x0A: // ISO 639 language descriptor — first 3 bytes are the language code.
                if length >= 3 {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    if let lang = String(data: bytes, encoding: .ascii)?
                        .lowercased()
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       lang.count == 3 {
                        info.language = lang
                    }
                }
            case 0x56: // Teletext descriptor — 5-byte entries.
                info.privateKind = .teletext
                if length >= 3, info.language == nil {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    info.language = String(data: bytes, encoding: .ascii)?.lowercased()
                }
                var entryOff = valueStart
                while entryOff + 5 <= valueEnd {
                    // Top 5 bits of byte 3 are the teletext_type. 0x05 = subtitle
                    // page for the hearing impaired (ETSI EN 300 468 §6.2.42).
                    let teletextType = data[data.startIndex + entryOff + 3] >> 3
                    if teletextType == 0x05 {
                        info.isHearingImpaired = true
                    }
                    entryOff += 5
                }
            case 0x59: // DVB subtitling descriptor — 8-byte entries.
                info.privateKind = .dvbSubtitle
                if length >= 3, info.language == nil {
                    let bytes = data[data.startIndex + valueStart ..< data.startIndex + valueStart + 3]
                    info.language = String(data: bytes, encoding: .ascii)?.lowercased()
                }
                var entryOff = valueStart
                while entryOff + 8 <= valueEnd {
                    // Byte 3 is subtitling_type. 0x20-0x24 mark hard-of-hearing
                    // subtitles; 0x30/0x31 mark sign-language interpretation
                    // (ETSI EN 300 468 §6.2.41, table 26).
                    let subType = data[data.startIndex + entryOff + 3]
                    if (0x20...0x24).contains(subType) || subType == 0x30 || subType == 0x31 {
                        info.isHearingImpaired = true
                    }
                    entryOff += 8
                }
            case 0x6A: // DVB AC-3 descriptor
                info.privateKind = .ac3
            case 0x0E:
                // Maximum bitrate descriptor (ISO/IEC 13818-1 §2.6.26):
                // 2 reserved bits + 22-bit maximum_bitrate in 50 bytes/s units
                // → bits/s = value * 50 * 8 = value * 400.
                if length >= 3 {
                    let s = data.startIndex + valueStart
                    let raw = (UInt32(data[s] & 0x3F) << 16)
                        | (UInt32(data[s + 1]) << 8)
                        | UInt32(data[s + 2])
                    if raw > 0 {
                        info.maxBitRate = Int(raw) * 400
                    }
                }
            default:
                break
            }

            off = valueEnd
        }
        return info
    }

    /// Skip the PES header when a packet's payload begins with 0x000001 start code.
    /// Returns the offset of ES data after the PES header, or nil if the input
    /// doesn't look like a PES start.
    private static func skipPESHeader(_ data: Data, at offset: Int, end: Int) -> Int? {
        guard offset + 9 <= end else { return nil }
        let s = data.startIndex + offset
        guard data[s] == 0x00, data[s + 1] == 0x00, data[s + 2] == 0x01 else { return nil }
        let headerDataLen = Int(data[s + 8])
        let esOffset = offset + 9 + headerDataLen
        return esOffset < end ? esOffset : nil
    }

    // MARK: - Sequence Header

    /// Scan `data[start..<end]` for an MPEG-1/2 video sequence header
    /// (start code 0x000001B3) and return (width, height, fps, bit-rate bps,
    /// display-aspect (width, height)?).
    ///
    /// Sequence header layout after the start code:
    ///   12 bits horizontal_size
    ///   12 bits vertical_size
    ///    4 bits aspect_ratio_information
    ///    4 bits frame_rate_code
    ///   18 bits bit_rate (in 400 bps units)
    ///    1 bit marker
    ///   10 bits vbv_buffer_size
    ///    1 bit constrained_parameters_flag
    private static func findSequenceHeader(_ data: Data, from start: Int, end: Int)
        -> (Int, Int, Double, Int, (Int, Int)?)?
    {
        let bound = min(end, data.count)
        guard start >= 0, start + 4 <= bound else { return nil }

        var i = start
        let raw = data
        while i + 4 <= bound {
            if raw[raw.startIndex + i] == 0x00
                && raw[raw.startIndex + i + 1] == 0x00
                && raw[raw.startIndex + i + 2] == 0x01
                && raw[raw.startIndex + i + 3] == 0xB3 {
                let headerStart = i + 4
                guard headerStart + 8 <= bound else { return nil }
                let b0 = raw[raw.startIndex + headerStart]
                let b1 = raw[raw.startIndex + headerStart + 1]
                let b2 = raw[raw.startIndex + headerStart + 2]
                let b3 = raw[raw.startIndex + headerStart + 3]
                let b4 = raw[raw.startIndex + headerStart + 4]
                let b5 = raw[raw.startIndex + headerStart + 5]
                let b6 = raw[raw.startIndex + headerStart + 6]

                let width = (Int(b0) << 4) | Int(b1 >> 4)
                let height = (Int(b1 & 0x0F) << 8) | Int(b2)
                let aspectCode = Int(b3 >> 4)
                let frameRateCode = Int(b3 & 0x0F)
                let bitRate400 = (Int(b4) << 10) | (Int(b5) << 2) | Int(b6 >> 6)

                let fps = frameRate(fromCode: frameRateCode)
                let aspect = displayAspect(
                    width: width,
                    height: height,
                    code: aspectCode
                )
                return (width, height, fps, bitRate400 * 400, aspect)
            }
            i += 1
        }
        return nil
    }

    private static func frameRate(fromCode code: Int) -> Double {
        switch code {
        case 1: return 24000.0 / 1001.0 // 23.976
        case 2: return 24.0
        case 3: return 25.0
        case 4: return 30000.0 / 1001.0 // 29.97
        case 5: return 30.0
        case 6: return 50.0
        case 7: return 60000.0 / 1001.0
        case 8: return 60.0
        default: return 0
        }
    }

    /// MPEG-2 aspect_ratio_information (Table 6-3):
    ///   1 = square pixels (SAR 1:1) → display aspect = width:height
    ///   2 = 4:3 display aspect
    ///   3 = 16:9 display aspect
    ///   4 = 2.21:1 display aspect
    private static func displayAspect(width: Int, height: Int, code: Int) -> (Int, Int)? {
        switch code {
        case 2: return (4, 3)
        case 3: return (16, 9)
        case 4: return (221, 100)
        default: return nil
        }
    }
}
