import Foundation

/// Minimal Material eXchange Format (SMPTE 377-1) reader.
///
/// MXF files are structured as a sequence of KLV triplets:
///   - K: 16-byte SMPTE universal label (UL)
///   - L: BER-encoded length
///   - V: value
///
/// SwiftExif's needs are narrow — we only want clip-level metadata that
/// Sony XDCAM/XAVC cameras carry in MXF files. Specifically:
///   1. The Sony NonRealTimeMeta XML payload (RDD-18), which is stored as a
///      KLV whose value is a UTF-8 XML blob; and
///   2. (optionally) raw video frame rate / dimensions exposed via Essence
///      Descriptors (not implemented here — most Sony workflows supply these
///      via the NRT XML anyway).
///
/// This reader skips unknown KLVs and is tolerant of truncated files.
public struct MXFReader: Sendable {

    /// Bytes at the start of every MXF file: the Partition Pack key
    /// (SMPTE 377-1, section 6.3) — the first 11 bytes are a fixed prefix.
    private static let mxfPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
        0x0D, 0x01, 0x02
    ]

    /// Check whether a data blob looks like an MXF file.
    public static func isMXF(_ data: Data) -> Bool {
        guard data.count >= mxfPrefix.count else { return false }
        for (i, b) in mxfPrefix.enumerated() where data[data.startIndex + i] != b {
            return false
        }
        return true
    }

    /// Upper bound on a KLV value we're willing to fully materialize.
    ///
    /// Metadata-bearing KLVs (NRT XML, C2PA manifest stores) are at most a few
    /// MB; raw essence KLVs in a 40 GB XDCAM clip can be many gigabytes. We
    /// peek at the first 64 bytes of every KLV to decide whether it's worth
    /// reading fully, and cap a full read at this size so a malformed length
    /// field on a giant KLV can't OOM us even if our heuristic mis-fires.
    private static let maxMetadataKLVSize = 32 * 1024 * 1024

    /// How many bytes of each KLV value to peek at before deciding whether
    /// it's metadata we care about. Must be large enough to fit an XML
    /// declaration plus the `<NonRealTimeMeta` opening tag, which can appear
    /// a couple hundred bytes in when long xmlns attributes are present.
    private static let klvPeekBytes = 512

    /// Parse an MXF file into a VideoMetadata, extracting camera metadata
    /// where possible.
    ///
    /// The KLV scan only fully materializes values that pass a cheap
    /// content-type peek — essence (video/audio) KLVs, which can be GBs each
    /// in XDCAM/XAVC files, are skipped via a seek without copying into RAM.
    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isMXF(data) else {
            throw MetadataError.invalidVideo("Not an MXF file — missing partition pack prefix")
        }

        var metadata = VideoMetadata(format: .mxf)
        // Seed for fallback-duration derivation. Many MXF writers (Sony MXF
        // OP1a, IMF) leave the picture descriptor's ContainerDuration at zero
        // and carry the real clip length on a Sequence / Track set instead.
        var maxSetDurationUnits: UInt64 = 0
        var setEditRateNum: UInt32 = 0
        var setEditRateDen: UInt32 = 0
        // Ordinal of the next TimecodeComponent we decode. MaterialPackage
        // comes first in header metadata, FilePackage(s) after.
        var timecodeComponentsSeen = 0
        // SMPTE ST 377-4 Multi-Channel Audio labelling state (Primer Pack
        // tag map + per-subdescriptor parsed fields + per-track SubDescriptors
        // UID arrays). Filled inside the loop, resolved after the loop.
        var mca = MCAState()

        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 17 {
            guard let key = try? reader.readBytes(16) else { break }
            guard let length = try? readBERLength(&reader) else { break }
            guard length <= reader.remainingCount else { break }

            let valueStart = reader.offset
            let peekCount = min(length, klvPeekBytes)
            guard let peek = try? reader.slice(from: valueStart, count: peekCount) else { break }

            let keyIsC2PA = isC2PAKey(key)
            let peekIsXML = looksLikeNRTXML(peek)
            let peekIsJUMBF = looksLikeJUMBF(peek, totalLength: length)
            let keyIsPictureDescriptor = isPictureEssenceDescriptorKey(key)
            let keyIsSoundDescriptor = isSoundEssenceDescriptorKey(key)
            let keyIsDurationSet = isDurationBearingSetKey(key)
            let keyIsTimecodeComponent = isTimecodeComponentKey(key)
            let keyIsPrimerPack = isPrimerPackKey(key)
            let mcaKind = mcaSubDescriptorKind(key)
            let isMetadata = keyIsC2PA || peekIsXML || peekIsJUMBF
                || keyIsPictureDescriptor || keyIsSoundDescriptor
                || keyIsDurationSet || keyIsTimecodeComponent
                || keyIsPrimerPack || (mcaKind != nil)

            // Skip anything that doesn't look like metadata, plus anything
            // larger than the hard cap (defensive — metadata payloads are
            // never this big).
            guard isMetadata, length <= maxMetadataKLVSize else {
                // Advance past the KLV without copying its value.
                if (try? reader.seek(to: valueStart + length)) == nil { break }
                continue
            }

            guard let value = try? reader.readBytes(length) else { break }

            // Sony NRT XML: RDD-18 clip metadata surfaced through MXF.
            if peekIsXML {
                if let cam = try? NRTXMLParser.parse(value) {
                    metadata.camera = cam
                }
            }

            // C2PA manifest store: either under the registered SMPTE UL or in
            // a "Dark" KLV whose value starts with a JUMBF "jumb" box.
            if metadata.c2pa == nil, keyIsC2PA || peekIsJUMBF {
                extractC2PA(fromKLVValue: value, into: &metadata)
            }

            // Picture/Sound essence descriptors: parse each local-tag → value
            // set to extract resolution, frame rate, scan type, colour.
            if keyIsPictureDescriptor {
                var stream = VideoStream(index: metadata.videoStreams.count)
                parsePictureDescriptor(value, into: &stream, duration: &metadata.duration)
                if stream.width != nil || stream.height != nil || stream.frameRate != nil {
                    metadata.videoStreams.append(stream)
                    if metadata.videoWidth == nil { metadata.videoWidth = stream.width }
                    if metadata.videoHeight == nil { metadata.videoHeight = stream.height }
                    if metadata.videoCodec == nil { metadata.videoCodec = stream.codec }
                    if metadata.frameRate == nil { metadata.frameRate = stream.frameRate }
                    if metadata.fieldOrder == nil { metadata.fieldOrder = stream.fieldOrder }
                    if metadata.bitDepth == nil { metadata.bitDepth = stream.bitDepth }
                    if metadata.colorInfo == nil { metadata.colorInfo = stream.colorInfo }
                    if metadata.displayWidth == nil { metadata.displayWidth = stream.displayWidth }
                    if metadata.displayHeight == nil { metadata.displayHeight = stream.displayHeight }
                }
            }

            if keyIsDurationSet {
                if let dur = parseSetDuration(value), dur > maxSetDurationUnits {
                    maxSetDurationUnits = dur
                }
                if setEditRateDen == 0, let rate = parseTrackEditRate(value) {
                    setEditRateNum = rate.num
                    setEditRateDen = rate.den
                }
            }

            // TimecodeComponent: one instance per Package. MaterialPackage is
            // always emitted before SourcePackage in the header metadata, so
            // the first TimecodeComponent we see is the Material Package
            // timecode (what ffprobe surfaces as `format.tags.timecode`) and
            // subsequent ones are File/Source Package timecodes the camera
            // stamped on the essence. When the two agree the additional entry
            // is still recorded so consumers can see the source split; when
            // they disagree `recordTimecode` emits a mismatch warning.
            if keyIsTimecodeComponent, let tc = parseTimecodeComponent(value) {
                let source: TimecodeSource = timecodeComponentsSeen == 0
                    ? .mxfMaterialPackage
                    : .mxfFilePackage
                metadata.recordTimecode(tc, source: source)
                timecodeComponentsSeen += 1
            }

            if keyIsSoundDescriptor {
                var stream = AudioStream(index: metadata.audioStreams.count)
                parseSoundDescriptor(value, into: &stream)
                // BWF/AES-3/GenericSound descriptors default to PCM when no
                // explicit codec UL was present (tag 0x3D06 absent). ffprobe
                // reports `pcm_s<bit-depth><endianness>` here; surface the
                // container-level codec at least, so per-stream consumers see
                // "pcm_s16le" rather than a missing field.
                if stream.codec == nil {
                    let bd = stream.bitDepth ?? 16
                    stream.codec = "pcm_s\(bd)le"
                    stream.codecName = "Linear PCM (\(bd)-bit LE)"
                }
                if stream.sampleRate != nil || stream.channels != nil {
                    metadata.audioStreams.append(stream)
                    // Capture the SubDescriptors strong-reference array so we
                    // can later resolve which MCA channel labels belong to
                    // this track.
                    let subUIDs = extractSubDescriptorUIDs(from: value, primer: mca.primer)
                    mca.soundDescriptorSubUIDs.append(subUIDs)
                    if metadata.audioCodec == nil { metadata.audioCodec = stream.codec }
                    if metadata.audioSampleRate == nil { metadata.audioSampleRate = stream.sampleRate }
                    if metadata.audioChannels == nil { metadata.audioChannels = stream.channels }
                }
            }

            if keyIsPrimerPack {
                mca.primer.ingest(value)
            }

            if let kind = mcaKind,
               let parsed = parseMCASubDescriptor(value, kind: kind, primer: mca.primer),
               let uid = parsed.instanceUID {
                switch kind {
                case 0x6B: mca.channels[uid] = parsed
                case 0x6C: mca.soundfields[uid] = parsed
                case 0x6D: mca.groupsOfGroups[uid] = parsed
                default: break
                }
            }
        }

        // Fallback: Sony XDCAM/XAVC writers often wrap NRT XML inside an
        // RP 2057 XML Document Set whose value is a local-tag/length/value
        // sequence — the XML bytes therefore live *inside* a KLV value, not
        // at its start, so the top-level peek misses them. Do a bounded
        // substring scan of the header metadata region to catch these.
        if metadata.camera == nil || metadata.camera?.isEmpty == true {
            if let xml = findEmbeddedNRTXML(in: data) {
                if let cam = try? NRTXMLParser.parse(xml), !cam.isEmpty {
                    metadata.camera = cam
                }
            }
        }
        // ARRI ALEXA / AMIRA carry slate, lens, camera, medium, frameline,
        // and viewing-LUT metadata as JSON blobs in custom KLV metadata
        // sets. The blob signature `\x80\x7B LL LL {` is unambiguous; scan
        // the same header region NRT XML uses and merge any decoded fields.
        let arriBlobs = ARRIJSONParser.findEmbeddedJSONBlobs(in: data)
        if !arriBlobs.isEmpty {
            var cam = metadata.camera ?? CameraMetadata()
            ARRIJSONParser.merge(arriBlobs, into: &cam)
            if !cam.isEmpty { metadata.camera = cam }
        }
        // Surface any Sony NRT LtcChangeTable start timecode. Dedupes
        // against MXF Material / File package values via recordTimecode.
        metadata.ingestNRTTimecode()

        // Resolve MCA labelling now that all subdescriptors and sound
        // descriptors have been collected.
        let labeling = assembleAudioLabeling(state: mca)
        if !labeling.isEmpty {
            metadata.mcaAudioLabeling = labeling
            // Back-fill each AudioStream with the per-track summary symbols.
            for ch in labeling.channels {
                guard let trackIndex = ch.trackIndex,
                      trackIndex < metadata.audioStreams.count else { continue }
                metadata.audioStreams[trackIndex].mcaChannelLabel = ch.symbol
                metadata.audioStreams[trackIndex].mcaChannelName = ch.name
                if let sgUID = ch.soundfieldGroupLinkID,
                   let sg = labeling.soundfieldGroups.first(where: { $0.linkID == sgUID }) {
                    metadata.audioStreams[trackIndex].mcaSoundfieldGroup = sg.symbol
                    if let ggUID = sg.groupOfGroupsLinkIDs.first,
                       let gg = labeling.groupsOfSoundfieldGroups.first(where: { $0.linkID == ggUID }) {
                        metadata.audioStreams[trackIndex].mcaGroupOfSoundfieldGroups = gg.symbol
                    }
                }
            }
        }

        for i in 0..<metadata.videoStreams.count {
            // ISOBMFF-style colour-range default: most broadcast MXF essence is
            // limited-range YUV, matching ffprobe's `tv` default.
            if metadata.videoStreams[i].colorInfo == nil {
                metadata.videoStreams[i].colorInfo = VideoColorInfo(fullRange: false)
            } else if metadata.videoStreams[i].colorInfo?.fullRange == nil {
                metadata.videoStreams[i].colorInfo?.fullRange = false
            }
            // ffprobe's chroma_location for AVC/HEVC 4:2:0 and 4:2:2 defaults
            // to "left" when the bitstream doesn't specify otherwise — mirror
            // that for MXF (AVC-Intra / HEVC-Intra broadcast essence).
            if metadata.videoStreams[i].chromaLocation == nil,
               let sub = metadata.videoStreams[i].chromaSubsampling,
               sub == "4:2:0" || sub == "4:2:2" {
                metadata.videoStreams[i].chromaLocation = "left"
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
            // Derive PAR/DAR per stream (square pixels when displayWidth/Height
            // weren't set by the picture descriptor).
            if let w = metadata.videoStreams[i].width,
               let h = metadata.videoStreams[i].height, w > 0, h > 0 {
                if metadata.videoStreams[i].displayWidth == nil {
                    metadata.videoStreams[i].displayWidth = w
                }
                if metadata.videoStreams[i].displayHeight == nil {
                    metadata.videoStreams[i].displayHeight = h
                }
                if metadata.videoStreams[i].pixelAspectRatio == nil,
                   let dw = metadata.videoStreams[i].displayWidth,
                   let dh = metadata.videoStreams[i].displayHeight, dw > 0, dh > 0 {
                    let parNum = dw * h
                    let parDen = dh * w
                    let g = gcdMXF(parNum, parDen)
                    metadata.videoStreams[i].pixelAspectRatio = (parNum / g, parDen / g)
                }
            }
            // ffprobe's MXF demuxer marks every track as default — there is no
            // per-track "default" bit in MXF, only per-package selection.
            if metadata.videoStreams[i].isDefault == nil {
                metadata.videoStreams[i].isDefault = false
            }
            if metadata.videoStreams[i].isAttachedPic == nil {
                metadata.videoStreams[i].isAttachedPic = false
            }
        }
        for i in 0..<metadata.audioStreams.count {
            if metadata.audioStreams[i].isDefault == nil {
                metadata.audioStreams[i].isDefault = false
            }
            // PCM audio bit-rate fallback: sample_rate × channels × bit_depth.
            if metadata.audioStreams[i].bitRate == nil,
               let sr = metadata.audioStreams[i].sampleRate, sr > 0,
               let ch = metadata.audioStreams[i].channels, ch > 0,
               let bd = metadata.audioStreams[i].bitDepth, bd > 0 {
                metadata.audioStreams[i].bitRate = sr * ch * bd
            }
        }
        if let v = metadata.videoStreams.first {
            if metadata.pixelAspectRatio == nil { metadata.pixelAspectRatio = v.pixelAspectRatio }
            if metadata.displayWidth == nil { metadata.displayWidth = v.displayWidth }
            if metadata.displayHeight == nil { metadata.displayHeight = v.displayHeight }
        }
        // MXF carries timecode on a Material Package TimecodeComponent plus
        // one or more File/Source Package TimecodeComponents. ffprobe only
        // surfaces the first at `format.tags.timecode` and leaves per-stream
        // tags empty; we mirror the scalar `timecode` field to the Material
        // value for backward compat and expose every other TimecodeComponent
        // via `timecodes` with source=.mxfFilePackage so callers can spot
        // Material vs File disagreements (see parse loop above).
        // Duration fallback: convert largest MaterialPackage/Track/Sequence
        // Duration (in edit units) into seconds using the track's EditRate.
        // Falls back to the first video stream's frameRate when the edit rate
        // wasn't captured, since most narrative MXF is 24/25/29.97/50 fps.
        if metadata.duration == nil || metadata.duration == 0 {
            if maxSetDurationUnits > 0 {
                let editRate: Double? = {
                    if setEditRateDen > 0, setEditRateNum > 0 {
                        return Double(setEditRateNum) / Double(setEditRateDen)
                    }
                    return metadata.videoStreams.first?.frameRate
                }()
                if let rate = editRate, rate > 0 {
                    metadata.duration = Double(maxSetDurationUnits) / rate
                }
            }
        }

        // Per-track duration: MXF descriptors don't carry an mdhd-style
        // per-track duration the way MP4 does — every track shares the
        // package's edit-list timeline, so the file-level duration applies
        // to each stream. ffprobe propagates it the same way.
        if let formatDur = metadata.duration, formatDur > 0 {
            for i in metadata.videoStreams.indices where metadata.videoStreams[i].duration == nil {
                metadata.videoStreams[i].duration = formatDur
            }
            for i in metadata.audioStreams.indices where metadata.audioStreams[i].duration == nil {
                metadata.audioStreams[i].duration = formatDur
            }
        }

        // Container bit_rate fallback (matches ffprobe `format.bit_rate`).
        let containerBytes = metadata.fileSize ?? Int64(data.count)
        if metadata.bitRate == nil,
           let dur = metadata.duration, dur > 0, containerBytes > 0 {
            metadata.bitRate = Int(Double(containerBytes) * 8.0 / dur)
        }

        // Format promotion: any MXF clip whose picture essence is Sony X-OCN
        // (codec UL matched in `codecNameForUL`) or whose NRT XML labels the
        // clip with an X-OCN videoCodec gets promoted from `.mxf` to
        // `.xocn`. Mirrors how MP4Parser promotes Nikon NR3D MP4 to
        // `.nikonRaw` so downstream filtering can target Sony cinema RAW
        // without inspecting codec strings.
        let codecIsXocn = metadata.videoStreams.contains(where: { $0.codec == "xocn" })
        let labelIsXocn: Bool = {
            guard let label = metadata.camera?.videoCodecLabel else { return false }
            return label.uppercased().contains("X-OCN")
        }()
        if codecIsXocn || labelIsXocn {
            metadata.format = .xocn
        }

        return metadata
    }

    private static func gcdMXF(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    // MARK: - Embedded-NRT fallback

    /// Upper bound on how many bytes we're willing to substring-scan for
    /// `<NonRealTimeMeta`. MXF header metadata lives at the top of the file
    /// (well under 16 MB even for multi-track broadcast clips), and memory
    /// mapping keeps this cheap.
    private static let nrtScanWindow = 16 * 1024 * 1024

    /// Locate a `<?xml … <NonRealTimeMeta … </NonRealTimeMeta>` document
    /// anywhere in the first `nrtScanWindow` bytes of the file and return
    /// it as a standalone UTF-8 buffer. Returns nil if no complete document
    /// is found.
    static func findEmbeddedNRTXML(in data: Data) -> Data? {
        let scanLimit = min(data.count, nrtScanWindow)
        guard scanLimit > 0 else { return nil }

        let haystack = data.prefix(scanLimit)
        let openTag  = Data("<NonRealTimeMeta".utf8)
        let closeTag = Data("</NonRealTimeMeta>".utf8)
        let xmlDecl  = Data("<?xml".utf8)

        guard let openRange = haystack.range(of: openTag) else { return nil }
        guard let closeRange = haystack.range(of: closeTag, in: openRange.upperBound..<haystack.endIndex) else {
            return nil
        }
        // Prefer starting at a preceding <?xml declaration within ~200 bytes
        // of the open tag; fall back to the open tag itself otherwise.
        let searchStart = max(haystack.startIndex, openRange.lowerBound - 256)
        let declRange = haystack.range(of: xmlDecl, in: searchStart..<openRange.lowerBound)
        let start = declRange?.lowerBound ?? openRange.lowerBound
        let end = closeRange.upperBound
        return Data(haystack[start..<end])
    }

    // MARK: - C2PA

    /// SMPTE UL assigned to the C2PA manifest store in MXF (see C2PA spec, MXF annex).
    /// The final byte varies across drafts; we match on the first 13 bytes only.
    private static let c2paULPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
        0x0D, 0x01, 0x03, 0x01, 0x20,
    ]

    private static func isC2PAKey(_ key: Data) -> Bool {
        guard key.count >= c2paULPrefix.count else { return false }
        for (i, b) in c2paULPrefix.enumerated() where key[key.startIndex + i] != b {
            return false
        }
        return true
    }

    /// True if the peek bytes look like the start of a JUMBF "jumb" box
    /// whose declared size is self-consistent with the total KLV length.
    ///
    /// `totalLength` is the full KLV value length (the peek is only the first
    /// few hundred bytes of that value) — the size field in the jumb header
    /// is allowed to extend beyond the peek window, but must fit inside the
    /// value as a whole.
    private static func looksLikeJUMBF(_ peek: Data, totalLength: Int) -> Bool {
        guard peek.count >= 8 else { return false }
        let bytes = [UInt8](peek.prefix(min(peek.count, 32)))
        // Fast path: first box is "jumb" at offset 4.
        if bytes.count >= 8,
           bytes[4] == 0x6A, bytes[5] == 0x75, bytes[6] == 0x6D, bytes[7] == 0x62 {
            let size = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
            if size >= 8 && Int(size) <= totalLength { return true }
        }
        // Slow path: scan the peek window for a valid jumb box header.
        return C2PAReader.findJUMBFStart(in: peek) != nil
    }

    private static func extractC2PA(fromKLVValue value: Data, into metadata: inout VideoMetadata) {
        // Find the JUMBF start offset (handles payloads that begin with a
        // small prefix before the jumb box).
        let jumbfData: Data
        if let offset = C2PAReader.findJUMBFStart(in: value) {
            jumbfData = Data(value.suffix(from: value.startIndex + offset))
        } else {
            jumbfData = value
        }

        do {
            if let c2pa = try C2PAReader.parseManifestStore(from: jumbfData) {
                metadata.c2pa = c2pa
            }
        } catch {
            metadata.warnings.append("MXF C2PA parse error: \(error)")
        }
    }

    // MARK: - BER length

    /// Decode a SMPTE ST 379 / BER-encoded length field.
    /// Short form: one byte, top bit clear, value = byte.
    /// Long form: first byte 0x80 | N, followed by N big-endian bytes.
    static func readBERLength(_ reader: inout BinaryReader) throws -> Int {
        let first = try reader.readUInt8()
        if first & 0x80 == 0 {
            return Int(first)
        }
        let byteCount = Int(first & 0x7F)
        guard byteCount > 0 && byteCount <= 8 else {
            throw MetadataError.invalidVideo("Invalid BER length: \(byteCount) bytes")
        }
        var length: UInt64 = 0
        for _ in 0..<byteCount {
            let b = try reader.readUInt8()
            length = (length << 8) | UInt64(b)
        }
        guard length <= UInt64(Int.max) else {
            throw MetadataError.invalidVideo("BER length overflow")
        }
        return Int(length)
    }

    // MARK: - Essence Descriptors
    //
    // MXF header metadata is a set of "local sets" — each metadata set's value
    // is a sequence of 2-byte local tag + 2-byte BER length + payload. Local
    // tags are mapped to full SMPTE universal labels (ULs) via a Primer Pack
    // at the start of the header metadata.
    //
    // The industry has converged on a de-facto stable set of static local tags
    // that most MXF writers use (SMPTE RP 210). We parse those directly here —
    // which avoids having to locate the Primer Pack first and correctly
    // decodes every MXF file we've encountered from Sony, Panasonic, Canon,
    // ARRI, Grass Valley, FFmpeg, and Avid.

    /// Universal label (UL) prefix for picture-essence descriptor sets:
    /// Generic/CDCI/RGBA/MPEG/AVC/JPEG2000/WAVE-descended descriptors all begin
    /// with this 13-byte prefix (byte 13 is the essence coding kind).
    ///
    /// - 06.0E.2B.34.02.53.01.01 = SMPTE metadata dictionary, variable-length
    /// - 0D.01.01.01.01.01.2?    = generic picture essence descriptor family
    private static let pictureDescriptorPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
        0x0D, 0x01, 0x01, 0x01, 0x01, 0x01,
    ]

    /// byte 14 = descriptor kind. Picture descriptors span:
    ///   0x25 = FileDescriptor (abstract) — skipped
    ///   0x27 = GenericPictureEssenceDescriptor
    ///   0x28 = CDCIEssenceDescriptor
    ///   0x29 = RGBAEssenceDescriptor
    ///   0x41 = GenericDataEssenceDescriptor
    ///   0x51 = MPEGVideoDescriptor
    ///   0x5B = AVCSubDescriptor (via parent)
    ///   0x62 = ProResEssenceDescriptor (SMPTE 2067-40)
    private static func isPictureEssenceDescriptorKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        let kind = key[s + 14]
        return kind == 0x27 || kind == 0x28 || kind == 0x29 || kind == 0x51 || kind == 0x62
    }

    /// byte 14 = 0x42 (GenericSoundEssenceDescriptor) or 0x48 (AES-3/BWF).
    private static func isSoundEssenceDescriptorKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        let kind = key[s + 14]
        return kind == 0x42 || kind == 0x47 || kind == 0x48
    }

    /// Header-metadata sets that carry a Duration field at local tag 0x0202.
    /// MaterialPackage / SourcePackage / Track / Sequence all qualify. We pull
    /// the largest Duration we find across these sets — for a sealed MXF clip
    /// that value is the clip length in edit units of the track's edit rate.
    private static func isDurationBearingSetKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        let kind = key[s + 14]
        // 0x0F Sequence, 0x2F Preface, 0x36 MaterialPackage, 0x37 SourcePackage
        // 0x3A StaticTrack, 0x3B Track, 0x3C EventTrack, 0x11 SourceClip.
        return kind == 0x0F || kind == 0x36 || kind == 0x37
            || kind == 0x3A || kind == 0x3B || kind == 0x3C || kind == 0x11
    }

    /// TimecodeComponent set (SMPTE 377M §G.2.42). Byte 14 = 0x14.
    private static func isTimecodeComponentKey(_ key: Data) -> Bool {
        guard key.count >= 15 else { return false }
        let s = key.startIndex
        for (i, b) in pictureDescriptorPrefix.enumerated() where key[s + i] != b { return false }
        return key[s + 14] == 0x14
    }

    /// Decode a TimecodeComponent set to a `HH:MM:SS:FF` (or `HH:MM:SS;FF`
    /// drop-frame) string. Local tags (SMPTE RP 210):
    ///   0x1501 — StartTimecode (Position, Int64, in edit units)
    ///   0x1502 — RoundedTimecodeBase (UInt16, nominal fps)
    ///   0x1503 — DropFrame (Boolean, 1 byte)
    static func parseTimecodeComponent(_ data: Data) -> String? {
        var start: Int64?
        var base: UInt16?
        var drop = false
        walkLocalSet(data) { tag, value in
            switch tag {
            case 0x1501 where value.count >= 8:
                var raw: UInt64 = 0
                let s = value.startIndex
                for i in 0..<8 { raw = (raw << 8) | UInt64(value[s + i]) }
                start = Int64(bitPattern: raw)
            case 0x1502 where value.count >= 2:
                let s = value.startIndex
                base = (UInt16(value[s]) << 8) | UInt16(value[s + 1])
            case 0x1503 where value.count >= 1:
                drop = value[value.startIndex] != 0
            default: break
            }
        }
        guard let startFrames = start, startFrames >= 0,
              let fpsRaw = base, fpsRaw > 0 else { return nil }
        var frames = Int(startFrames)
        let fps = Int(fpsRaw)

        if drop {
            // Same SMPTE 12M drop-frame arithmetic as the QuickTime tmcd path.
            let dropCount = fps / 15
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
        let sep = drop ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, sep, ff)
    }

    /// Pull the largest `Duration` (local tag 0x0202, UInt64) value out of a
    /// metadata set. Returns nil if the set carries no usable duration.
    static func parseSetDuration(_ data: Data) -> UInt64? {
        var best: UInt64 = 0
        walkLocalSet(data) { tag, value in
            guard tag == 0x0202, value.count >= 8 else { return }
            if let v = parseUInt64(value), v > best, v < UInt64(Int.max) {
                best = v
            }
        }
        return best > 0 ? best : nil
    }

    /// EditRate (local tag 0x4B01) on a Generic Track — used together with
    /// Sequence Duration (0x0202) to convert edit units into seconds.
    static func parseTrackEditRate(_ data: Data) -> (num: UInt32, den: UInt32)? {
        var rate: (num: UInt32, den: UInt32)?
        walkLocalSet(data) { tag, value in
            if tag == 0x4B01, let r = parseRational(value), r.den > 0 {
                rate = r
            }
        }
        return rate
    }

    /// Walk the local set `(tag, length, value)` triplets inside a picture
    /// essence descriptor and surface the fields we care about.
    static func parsePictureDescriptor(
        _ data: Data,
        into stream: inout VideoStream,
        duration: inout TimeInterval?
    ) {
        var sampleRateNum: UInt32 = 0
        var sampleRateDen: UInt32 = 0
        var containerDuration: UInt64 = 0
        var frameLayout: UInt8?
        var fieldDominance: UInt8?
        var horizontalSubsampling: UInt32 = 0
        var verticalSubsampling: UInt32 = 0
        var aspectRatioNum: UInt32 = 0
        var aspectRatioDen: UInt32 = 0

        walkLocalSet(data) { tag, value in
            switch tag {
            case 0x3001:
                if let r = parseRational(value) {
                    sampleRateNum = r.num
                    sampleRateDen = r.den
                }
            case 0x3002:
                if let d = parseUInt64(value) { containerDuration = d }
            case 0x3202: // StoredHeight (UInt32)
                if let v = parseUInt32(value) { stream.height = Int(v) }
            case 0x3203: // StoredWidth (UInt32)
                if let v = parseUInt32(value) { stream.width = Int(v) }
            case 0x3208: // DisplayHeight
                if let v = parseUInt32(value) { stream.displayHeight = Int(v) }
            case 0x3209: // DisplayWidth
                if let v = parseUInt32(value) { stream.displayWidth = Int(v) }
            case 0x320C: // FrameLayout (UInt8)
                if value.count >= 1 { frameLayout = value[value.startIndex] }
            case 0x3212: // FieldDominance (UInt8) — 1=top-first, 2=bottom-first
                if value.count >= 1 { fieldDominance = value[value.startIndex] }
            case 0x320E: // AspectRatio (Rational) — display aspect ratio.
                if let r = parseRational(value), r.num > 0, r.den > 0 {
                    aspectRatioNum = r.num
                    aspectRatioDen = r.den
                }
            case 0x3201: // PictureEssenceCoding (UL)
                if let codec = codecNameForUL(value) {
                    stream.codec = codec.codec
                    stream.codecName = codec.longName
                }
                // Profile inferred from the AVC-Intra class byte (UL byte
                // 14), per SMPTE ST 2019-1:
                //   0x2?   — High 10 Intra (class 50/100/200, 4:2:0 10-bit)
                //   0x3?   — High 4:2:2 Intra (class 50/100/200, 10-bit)
                // We fold all subclasses into the top-level ffprobe name.
                if value.count >= 16, stream.profile == nil {
                    let kind = value[value.startIndex + 11]
                    let variant = value[value.startIndex + 13]
                    let byte14 = value[value.startIndex + 14]
                    if kind == 0x02, variant == 0x32 {
                        switch byte14 & 0xF0 {
                        case 0x20: stream.profile = "High 10 Intra"
                        case 0x30: stream.profile = "High 4:2:2 Intra"
                        default: break
                        }
                    }
                }
            case 0x3301: // ComponentDepth (UInt32)
                if let v = parseUInt32(value) { stream.bitDepth = Int(v) }
            case 0x3302: // HorizontalSubsampling (UInt32) — chroma horz subsampling
                if let v = parseUInt32(value) { horizontalSubsampling = v }
            case 0x3308: // VerticalSubsampling (UInt32)
                if let v = parseUInt32(value) { verticalSubsampling = v }
            case 0x3219: // CodingEquations (UL) — matrix coefficients
                var info = stream.colorInfo ?? VideoColorInfo()
                info.matrix = colorULCode(value, kind: .matrix)
                stream.colorInfo = info
            case 0x3210: // CaptureGamma (UL) — transfer characteristic
                var info = stream.colorInfo ?? VideoColorInfo()
                info.transfer = colorULCode(value, kind: .transfer)
                stream.colorInfo = info
            case 0x321A, 0x321D: // ColorPrimaries (UL)
                var info = stream.colorInfo ?? VideoColorInfo()
                info.primaries = colorULCode(value, kind: .primaries)
                stream.colorInfo = info
            default:
                break
            }
        }

        if sampleRateDen > 0, sampleRateNum > 0 {
            let fps = Double(sampleRateNum) / Double(sampleRateDen)
            stream.frameRate = fps
            if containerDuration > 0 {
                let secs = Double(containerDuration) / fps
                if duration == nil || duration == 0 { duration = secs }
                stream.duration = secs
                stream.frameCount = Int(containerDuration)
            }
        }

        if let fl = frameLayout {
            stream.fieldOrder = fieldOrderFromLayout(fl, dominance: fieldDominance)
            // FrameLayout 1 (SeparateFields) / 2 (OneField) report StoredHeight
            // as the *field* height. ffprobe reports the *frame* height, so
            // double ours to match when the fields encode a full interlaced
            // frame. DisplayHeight follows suit only when it isn't already set
            // to the full-frame value.
            if (fl == 1 || fl == 4), let h = stream.height, h > 0 {
                stream.height = h * 2
                if stream.displayHeight == h { stream.displayHeight = h * 2 }
            }
        }

        // CDCI essence descriptors carry explicit subsampling ratios. 4:2:0 is
        // signalled as (horiz=2, vert=2), 4:2:2 as (2,1), 4:4:4 as (1,1).
        switch (horizontalSubsampling, verticalSubsampling) {
        case (2, 2): stream.chromaSubsampling = "4:2:0"
        case (2, 1): stream.chromaSubsampling = "4:2:2"
        case (1, 1): stream.chromaSubsampling = "4:4:4"
        default: break
        }

        // MXF AspectRatio (0x320E) is the *display* aspect ratio of the
        // finished frame. ffprobe reports display_aspect_ratio directly from
        // this value (e.g. "16:9" for 1440×1080 anamorphic SD, even though
        // DisplayWidth/Height report 1440×1080). We override here so the
        // reader's DAR reflects the authoritative anamorphic flag.
        if aspectRatioDen > 0, aspectRatioNum > 0,
           let w = stream.width, let h = stream.height, w > 0, h > 0 {
            // `aspectRatioNum/Den` (UInt32) and `w`/`h` (UInt32-derived, with `h`
            // possibly doubled above) are all attacker-controlled. Two ~2^32
            // operands multiply to ~2^64, which overflows Int64 and *traps* — a
            // crafted descriptor declaring 0xFFFFFFFF dimensions and aspect ratio
            // would crash the parser. Multiply with overflow reporting and skip
            // this (non-essential) DAR/SAR derivation on absurd values instead.
            let arNum = Int64(aspectRatioNum), arDen = Int64(aspectRatioDen)
            let (darNumerator, darOvf) = Int64(h).multipliedReportingOverflow(by: arNum)
            if !darOvf {
                stream.displayWidth = Int(darNumerator / arDen)
                stream.displayHeight = h
            }
            // SAR = (DAR × height) / (pixel_width). The denominator folds in
            // DAR_den because the RHS is (DAR_num/DAR_den × height / width).
            let (sarNum, sarOvf1) = arNum.multipliedReportingOverflow(by: Int64(h))
            let (sarDen, sarOvf2) = arDen.multipliedReportingOverflow(by: Int64(w))
            if !sarOvf1, !sarOvf2 {
                let g = gcdMXFInt(Int(sarNum), Int(sarDen))
                if g > 0 {
                    stream.pixelAspectRatio = (Int(sarNum) / g, Int(sarDen) / g)
                }
            }
        }
    }

    private static func gcdMXFInt(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }

    static func parseSoundDescriptor(_ data: Data, into stream: inout AudioStream) {
        walkLocalSet(data) { tag, value in
            switch tag {
            case 0x3001:
                if let r = parseRational(value), r.den > 0 {
                    // Sample rate = num/den (often 48000/1).
                    stream.sampleRate = Int(r.num / max(r.den, 1))
                }
            case 0x3D03: // AudioSamplingRate (Rational)
                if let r = parseRational(value), r.den > 0 {
                    stream.sampleRate = Int(r.num / max(r.den, 1))
                }
            case 0x3D06: // SoundEssenceCompression (UL)
                if let codec = codecNameForUL(value) {
                    stream.codec = codec.codec
                    stream.codecName = codec.longName
                }
            case 0x3D07: // ChannelCount (UInt32)
                if let v = parseUInt32(value) { stream.channels = Int(v) }
            case 0x3D01: // QuantizationBits (UInt32)
                if let v = parseUInt32(value) { stream.bitDepth = Int(v) }
            default:
                break
            }
        }

        if stream.channelLayout == nil, let ch = stream.channels {
            stream.channelLayout = defaultChannelLayout(forChannels: ch)
        }
    }

    private static func defaultChannelLayout(forChannels n: Int) -> String? {
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

    static func walkLocalSet(_ data: Data, _ body: (UInt16, Data) -> Void) {
        var reader = BinaryReader(data: data)
        while reader.remainingCount >= 4 {
            guard let tag = try? reader.readUInt16BigEndian(),
                  let len = try? reader.readUInt16BigEndian() else { return }
            let length = Int(len)
            guard length <= reader.remainingCount else { return }
            guard let value = try? reader.readBytes(length) else { return }
            body(tag, value)
        }
    }

    static func parseUInt32(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        var r = BinaryReader(data: data)
        return try? r.readUInt32BigEndian()
    }

    private static func parseUInt64(_ data: Data) -> UInt64? {
        guard data.count >= 8 else { return nil }
        var r = BinaryReader(data: data)
        return try? r.readUInt64BigEndian()
    }

    private static func parseRational(_ data: Data) -> (num: UInt32, den: UInt32)? {
        guard data.count >= 8 else { return nil }
        var r = BinaryReader(data: data)
        guard let n = try? r.readUInt32BigEndian(),
              let d = try? r.readUInt32BigEndian() else { return nil }
        return (n, d)
    }

    /// FrameLayout (SMPTE 377-1 table 13):
    ///   0 = full-frame (progressive), 1 = separated fields (interlaced),
    ///   2 = single field (odd/even), 3 = mixed,
    ///   4 = segmented frame (PsF — progressive stored as fields).
    /// Field order for interlaced layouts is resolved from FieldDominance
    /// (SMPTE 377-1 §G.2.51: 1 = top-first, 2 = bottom-first). Broadcast MXF
    /// defaults to top-field-first when FieldDominance is absent — that's what
    /// MediaInfo and ffprobe report for untagged interlaced essence.
    private static func fieldOrderFromLayout(_ layout: UInt8, dominance: UInt8?) -> VideoFieldOrder {
        switch layout {
        case 0, 4: return .progressive
        case 1, 3:
            switch dominance {
            case 2: return .bottomFieldFirst
            default: return .topFieldFirst
            }
        case 2: return .topFieldFirst
        default: return .unknown
        }
    }

    /// Map a picture/sound essence coding UL to short + long codec names.
    /// MXF codec ULs cluster around two kind bytes:
    ///   - byte 11 == 0x04 : SMPTE 335/RP-224 compressed-video registry
    ///   - byte 11 == 0x02 : SMPTE 2019/2067 AVC/HEVC/JPEG-2000/PCM-family
    /// We match on the distinguishing byte (byte 13 for 0x04, byte 13-14 for
    /// 0x02) because the surrounding octets are structural.
    private static func codecNameForUL(_ ul: Data) -> (codec: String, longName: String)? {
        guard ul.count >= 16 else { return nil }
        let s = ul.startIndex
        let kind = ul[s + 11]
        let variant = ul[s + 13]

        // ARRIRAW (SMPTE-registered as picture coding
        // urn:smpte:ul:060e2b34.0401010d.04010201.02010103). It sits in a
        // different sub-registry than the kind=0x04/0x02 codecs the rest of
        // this function handles (byte 11 == 0x01), so match the trailing
        // 8-byte item designator directly to avoid cross-registry collisions.
        if ul[s + 8] == 0x04, ul[s + 9] == 0x01,
           ul[s + 10] == 0x02, ul[s + 11] == 0x01,
           ul[s + 12] == 0x02, ul[s + 13] == 0x01,
           ul[s + 14] == 0x01, ul[s + 15] == 0x03 {
            return ("arriraw", "ARRIRAW")
        }

        // Sony X-OCN: vendor-private essence-coding UL in the Sony cinema-RAW
        // sub-registry. The full UL observed on F55/VENICE-family clips is
        //   060e2b34.0401.0106.0e06.0401.0206.06xx
        // where byte 15 is the codec-class variant
        // (LT=0x01 — confirmed; ST/XT inferred from the NRT `videoCodec`
        // attribute and Sony's published codec ladder).
        if ul[s + 0] == 0x06, ul[s + 1] == 0x0E, ul[s + 2] == 0x2B, ul[s + 3] == 0x34,
           ul[s + 4] == 0x04, ul[s + 5] == 0x01,
           ul[s + 8] == 0x0E, ul[s + 9] == 0x06,
           ul[s + 10] == 0x04, ul[s + 11] == 0x01,
           ul[s + 12] == 0x02 {
            let variant = ul[s + 15]
            let longName: String
            switch variant {
            case 0x01: longName = "Sony X-OCN LT"
            case 0x02: longName = "Sony X-OCN ST"
            case 0x03: longName = "Sony X-OCN XT"
            default:   longName = "Sony X-OCN"
            }
            return ("xocn", longName)
        }

        // Video registry (SMPTE 335 / RP 224 / RP 2008).
        if kind == 0x04 {
            switch variant {
            case 0x01: return ("mpeg2video", "MPEG-2 Video")
            case 0x02: return ("dv", "DV")
            case 0x0A: return ("j2k", "JPEG 2000")
            case 0x20: return ("mpeg4", "MPEG-4 Visual")
            case 0x41: return ("apch", "Apple ProRes")
            case 0x31: return ("avc1", "H.264 / AVC")
            case 0x32: return ("hvc1", "H.265 / HEVC")
            default: break
            }
        }
        // SMPTE ST 2019-1 AVC-Intra / 2067-40 ProRes / JPEG-2000 (kind 0x02).
        if kind == 0x02 {
            let byte14 = ul[s + 14]
            switch variant {
            case 0x32: // AVC in MXF (SMPTE ST 381-3 / RP 2008)
                return ("avc1", "H.264 / AVC")
            case 0x33: // HEVC in MXF (SMPTE ST 2067-51)
                return ("hvc1", "H.265 / HEVC")
            case 0x0A: // JPEG 2000 in MXF (SMPTE ST 422)
                return ("j2k", "JPEG 2000")
            case 0x01: // MPEG-2 Video (MXF SMPTE ST 381-1)
                return ("mpeg2video", "MPEG-2 Video")
            case 0x41:
                return ("apch", "Apple ProRes")
            case 0x02: // PCM / WAVE / AES-3 sound essence family
                _ = byte14 // reserved for future distinction
                return ("pcm_s16le", "PCM (WAVE/AES-3)")
            case 0x7F: // LinearPCM (another SMPTE label)
                return ("pcm_s16le", "Linear PCM")
            default: break
            }
        }
        return nil
    }

    private enum ColorULKind { case matrix, transfer, primaries }

    /// SMPTE ST 2067-21 / H.273 UL mapping — translates MXF ULs to H.273 codes
    /// so VideoColorInfo speaks the same vocabulary as MP4/MKV.
    private static func colorULCode(_ ul: Data, kind: ColorULKind) -> Int? {
        guard ul.count >= 16 else { return nil }
        let s = ul.startIndex
        let last = ul[s + 14]
        switch kind {
        case .primaries:
            switch last {
            case 0x01: return 1 // ITU-R BT.709
            case 0x04: return 6 // BT.601 625
            case 0x06: return 9 // BT.2020
            case 0x07: return 12 // SMPTE 428 (XYZ)
            default: return nil
            }
        case .transfer:
            switch last {
            case 0x01: return 1 // BT.709
            case 0x02: return 4 // BT.470M
            case 0x04: return 6 // BT.601
            case 0x05: return 8 // Linear
            case 0x06: return 14 // BT.2020 10-bit
            case 0x08: return 16 // SMPTE ST 2084 (PQ)
            case 0x0B: return 18 // ARIB STD-B67 (HLG)
            default: return nil
            }
        case .matrix:
            switch last {
            case 0x01: return 1 // BT.709
            case 0x02: return 5 // BT.470BG / BT.601 625
            case 0x03: return 6 // BT.601 525
            case 0x06: return 9 // BT.2020 non-constant luminance
            default: return nil
            }
        }
    }

    // MARK: - Heuristics

    /// True if the payload looks like a Sony NonRealTimeMeta XML document.
    private static func looksLikeNRTXML(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        // Find first non-whitespace byte — accepts BOM'd files and files that
        // start with an XML declaration.
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D && b != 0xEF && b != 0xBB && b != 0xBF {
                break
            }
            i = data.index(after: i)
        }
        guard i < data.endIndex, data[i] == 0x3C /* '<' */ else { return false }

        // Bounded substring search for "NonRealTimeMeta" — scan the first ~4 KB
        // to keep cost low on large MXF essence payloads.
        let scanLimit = min(data.count, 4096)
        let haystack = data.prefix(scanLimit)
        guard let text = String(data: haystack, encoding: .utf8) else { return false }
        return text.contains("NonRealTimeMeta")
    }
}
