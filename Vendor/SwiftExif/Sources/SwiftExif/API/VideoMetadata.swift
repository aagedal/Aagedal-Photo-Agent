import Foundation

/// Metadata for video container files (MP4, MOV, M4V, MXF, MKV, WebM, AVI, MPEG-PS/TS).
/// Reading is supported for all container formats; writing is currently only supported
/// for MP4/MOV/M4V (see `writeToData()` for details).
public struct VideoMetadata: Sendable {
    public var format: VideoFormat
    /// Human-readable container name, ffprobe-compatible (e.g. "QuickTime / MOV",
    /// "MP4 (MPEG-4 Part 14)", "Matroska / WebM", "AVI (Audio Video Interleave)",
    /// "MXF (Material eXchange Format)", "MPEG-TS (MPEG-2 Transport Stream)").
    public var formatLongName: String?
    /// File size in bytes (when read from a file or data blob).
    public var fileSize: Int64?
    /// Clip-level timecode (HH:MM:SS:FF) when the container embeds a dedicated
    /// timecode track (e.g. QuickTime `tmcd`). This is the "primary" value
    /// ffprobe surfaces at `format.tags.timecode`; for a full list of every
    /// timecode the container carries (with provenance) see `timecodes`.
    public var timecode: String?
    /// All timecode values found in the container, tagged with the source
    /// that produced each one (tmcd track, QuickTime udta, XMP, MXF Material
    /// vs File package, Sony NRT). Callers can spot disagreements by diffing
    /// entries; a warning is appended to `warnings` whenever two sources
    /// disagree on the clip-level value.
    public var timecodes: [Timecode]
    public var duration: TimeInterval?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// Primary video stream width (in pixels). Populated from the first video track.
    public var videoWidth: Int?
    /// Primary video stream height (in pixels). Populated from the first video track.
    public var videoHeight: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var frameRate: Double?
    /// Scan type of the primary video stream.
    public var fieldOrder: VideoFieldOrder?
    /// Color-space metadata for the primary video stream.
    public var colorInfo: VideoColorInfo?
    /// Bit depth per color component of the primary video stream.
    public var bitDepth: Int?
    /// Chroma subsampling notation for the primary video stream (e.g. "4:2:0").
    public var chromaSubsampling: String?
    /// Pixel aspect ratio of the primary video stream, expressed as (horizontal, vertical).
    public var pixelAspectRatio: (Int, Int)?
    /// Display width of the primary video stream (PAR-adjusted) if advertised by the container.
    public var displayWidth: Int?
    /// Display height of the primary video stream (PAR-adjusted) if advertised by the container.
    public var displayHeight: Int?
    /// Sample rate (Hz) of the primary audio stream.
    public var audioSampleRate: Int?
    /// Channel count of the primary audio stream.
    public var audioChannels: Int?
    /// Per-track video streams (for multi-track files).
    public var videoStreams: [VideoStream]
    /// Per-track audio streams (for multi-track files).
    public var audioStreams: [AudioStream]
    /// Per-track subtitle / timed-text / closed-caption streams.
    public var subtitleStreams: [SubtitleStream]
    /// Per-track data streams (timecode `tmcd`, Apple `meta`/`mdta`, GoPro
    /// `gpmd`, embedded `pict` thumbnails, chapter-text tracks, …).
    /// Anything ffprobe surfaces with `codec_type=data`.
    public var dataStreams: [DataStream]
    /// Stream emission order matching the trak iteration order in the file.
    /// Each entry locates a typed stream by kind + index. Empty for parsers
    /// that haven't been migrated yet — consumers fall back to the legacy
    /// type-grouped emission in that case.
    public var streamOrder: [StreamKind]
    /// Chapter markers declared by the container (MP4/MOV `chpl` or QuickTime
    /// text-track chapters; Matroska `Chapters` master element). Ordered by
    /// `startTime`. Empty when the container exposes no chapter information.
    public var chapters: [VideoChapter]
    /// Overall container bit rate in bits/second, when the container advertises one.
    public var bitRate: Int?
    public var title: String?
    public var artist: String?
    public var comment: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    /// Apple Live Photo `com.apple.quicktime.content.identifier` UUID. When the same UUID
    /// appears on a HEIC's Apple MakerNote `ContentIdentifier` and on the matching MOV's
    /// QuickTime metadata, the two files form a Live Photo pair.
    public var contentIdentifier: String?
    public var xmp: XMPData?
    /// Parsed C2PA manifests (if the video is C2PA-signed).
    public var c2pa: C2PAData?
    /// Camera/clip metadata from Sony NonRealTimeMeta (embedded or sidecar XML).
    public var camera: CameraMetadata?
    /// SMPTE ST 377-4 / ST 2020-1 Multi-Channel Audio labelling carried by
    /// MXF files with bmxtools-style audio metadata. Channels resolve to
    /// AudioStream slots by `trackIndex`; soundfield groups and groups-of-
    /// groups link to channels via UUIDs. `nil` for containers that don't
    /// support MCA labelling (everything except MXF, today).
    public var mcaAudioLabeling: MCAAudioLabeling?
    /// Sony RTMD (Real-Time Metadata) clip summary, populated when an MP4/MOV
    /// carries an `rtmd` timed-metadata track (Sony Alpha A1, A7S III, FX3,
    /// FX30, …). Carries the IMU sample rate plus a first-frame snapshot of
    /// ISO / exposure / lens / GPS. The full per-frame stream is exposed via
    /// the `rtmd-frames` CLI subcommand.
    public var rtmd: RTMDSummary?
    /// PSI (Program-Specific Information) programs found in an MPEG-TS file:
    /// PAT entries plus their PMT-described elementary PIDs and any service
    /// name / provider learned from the DVB SDT. Empty for non-TS containers.
    public var mpegPrograms: [MPEGProgram] = []
    /// Embedded JPEG thumbnail (small — typically 160×120). Populated for
    /// Canon Cinema RAW Light (CRM/CRL) clips from the THMB box; future
    /// formats with embedded thumbnails can populate this too.
    public var embeddedThumbnailJPEG: Data?
    /// Embedded JPEG preview image (larger — typically 1620×1080). Populated
    /// for Canon Cinema RAW Light (CRM/CRL) clips from the PRVW box.
    public var embeddedPreviewJPEG: Data?
    /// Per-frame timed metadata, when the container carries a per-frame
    /// metadata stream. Currently populated for Canon Cinema RAW Light from
    /// the CTMD track; one entry per CTMD sample. Empty for other formats.
    public var cameraTimeline: [CRMReader.CTMDFrame]
    public var warnings: [String]

    /// The original file data (needed for writing back).
    internal var originalData: Data?

    public init(format: VideoFormat) {
        self.format = format
        self.warnings = []
        self.videoStreams = []
        self.audioStreams = []
        self.subtitleStreams = []
        self.dataStreams = []
        self.streamOrder = []
        self.timecodes = []
        self.chapters = []
        self.cameraTimeline = []
    }

    // MARK: - Reading

    /// Read video metadata from a file URL.
    ///
    /// If the URL points at an MXF file or a container with a Sony NonRealTimeMeta
    /// sidecar (e.g. `CLIP.MXF` next to `CLIP.XML`), the sidecar is auto-discovered
    /// and merged into `camera`.
    ///
    /// Memory behaviour: Matroska/WebM files are read via a bounded prefix
    /// (`matroskaReadCap`, 512 MB) since the parser only scans that far and never
    /// looks at the tail — critical when importing Blu-ray-sized MKVs from an
    /// external volume where `.mappedIfSafe` falls back to an in-RAM load. Other
    /// containers use `.alwaysMapped` to force mmap (again, external volumes are
    /// treated as "unsafe" by `.mappedIfSafe` and would otherwise load wholly
    /// into RAM). `originalData` is retained only for formats whose writer needs
    /// it (MP4/MOV/M4V); dropping it elsewhere keeps multi-file imports from
    /// accumulating gigabytes of mapped address space.
    public static func read(from url: URL) throws -> VideoMetadata {
        let data = try loadContainerData(from: url)
        var metadata = try parseContainer(data)
        // Blackmagic RAW shares the QuickTime container layout but has no
        // ftyp brand the parser can latch onto — it'd come back tagged as
        // .mov. Promote it to .braw based on the path so the long-name and
        // any downstream consumers see the correct format.
        if url.pathExtension.lowercased() == "braw" {
            metadata.format = .braw
            metadata.formatLongName = defaultFormatLongName(.braw)
        }
        // ARRIRAW arrives wrapped in MXF and shares the .mxf extension with
        // generic broadcast MXF, so the path-extension trick used for BRAW
        // doesn't apply. Promote based on a codec sniff: MXFReader maps the
        // SMPTE-registered ARRIRAW picture coding UL to "arriraw", so we
        // upgrade the container format whenever any video stream carries it.
        if metadata.format == .mxf,
           metadata.videoStreams.contains(where: { $0.codec == "arriraw" }) {
            metadata.format = .arriraw
            metadata.formatLongName = defaultFormatLongName(.arriraw)
        }
        // Nikon RAW Video — Nikon Z8/Z9 (post-RED-acquisition) write a
        // Nikon-specific MP4 with `ftyp niko` and the `NR3D` video codec
        // FourCC, often labelled "RED RAW" in Nikon's marketing. The
        // bitstream is N-RAW (Nikon's existing RAW codec), wholly
        // unrelated to RED's REDCODE / R3D format. Detect by codec —
        // the file usually carries a `.R3D` extension that collides
        // with real RED clips.
        if (metadata.format == .mp4 || metadata.format == .mov || metadata.format == .m4v),
           metadata.videoStreams.contains(where: { $0.codec == "NR3D" }) {
            metadata.format = .nikonRaw
            metadata.formatLongName = defaultFormatLongName(.nikonRaw)
        }
        // Canon Cinema RAW Light (.CRM master + .CRL proxy). Both share an
        // ISOBMFF container with `ftyp` brand `crx ` and a Canon metadata
        // UUID inside `moov` (identical to CR3 still images, distinguished
        // by the CNCV "CanonCRM" prefix). MP4Parser tags them .mp4 first;
        // we promote based on the brand probe and run the CRM reader to
        // harvest CMT1-4 + per-frame CTMD records.
        if (metadata.format == .mp4 || metadata.format == .mov),
           CRMReader.isCanonCinemaRAW(data) {
            // .CRL is the lower-bitrate proxy companion to .CRM; the
            // container layout is identical, only the extension and the
            // long-name distinguish them.
            metadata.format = (url.pathExtension.lowercased() == "crl") ? .crl : .crm
            metadata.formatLongName = defaultFormatLongName(metadata.format)
            if let result = try? CRMReader.read(data) {
                CRMReader.merge(result, into: &metadata)
            }
        }
        // Retain the source data only for formats we can write back. For
        // read-only formats (MKV, WebM, MXF, AVI, MPEG) holding a reference
        // to a multi-GB Data serves no purpose and prevents the OS from
        // reclaiming its pages as soon as the caller is done with metadata.
        switch metadata.format {
        case .mp4, .mov, .m4v:
            metadata.originalData = data
        case .mxf, .mkv, .webm, .avi, .mpg, .braw, .arriraw, .r3d, .nikonRaw, .xocn, .crm, .crl, .ivf:
            metadata.originalData = nil
        }
        if metadata.fileSize == nil {
            if let attrSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 {
                metadata.fileSize = attrSize
            } else {
                metadata.fileSize = Int64(data.count)
            }
        }
        if metadata.formatLongName == nil { metadata.formatLongName = defaultFormatLongName(metadata.format) }

        // Auto-probe NRT sidecar if no embedded camera metadata is present.
        if metadata.camera == nil || metadata.camera?.isEmpty == true {
            if let sidecarURL = NRTXMLParser.sidecarURL(for: url) {
                if let sidecarData = try? Data(contentsOf: sidecarURL),
                   let cam = try? NRTXMLParser.parse(sidecarData) {
                    metadata.camera = cam
                }
            }
        }
        // Merge any NRT start timecode into the provenance-tagged array.
        // Safe to re-invoke when the container parser already ingested it —
        // `recordTimecode` dedupes on (value, source).
        metadata.ingestNRTTimecode()

        return metadata
    }

    /// Read video metadata from data.
    public static func read(from data: Data) throws -> VideoMetadata {
        var metadata = try parseContainer(data)
        // Same NR3D codec promotion as `read(from: url)` — needed for the
        // data-only entry point so callers loading bytes get the right
        // format tag without having to re-inspect codec themselves.
        if (metadata.format == .mp4 || metadata.format == .mov || metadata.format == .m4v),
           metadata.videoStreams.contains(where: { $0.codec == "NR3D" }) {
            metadata.format = .nikonRaw
            metadata.formatLongName = defaultFormatLongName(.nikonRaw)
        }
        // Canon Cinema RAW Light — same promotion as the URL entry point but
        // without an extension to distinguish master vs proxy, so we always
        // tag .crm here.
        if (metadata.format == .mp4 || metadata.format == .mov),
           CRMReader.isCanonCinemaRAW(data) {
            metadata.format = .crm
            metadata.formatLongName = defaultFormatLongName(.crm)
            if let result = try? CRMReader.read(data) {
                CRMReader.merge(result, into: &metadata)
            }
        }
        // Only retain the source Data for writable formats — same rationale
        // as `read(from:url)`.
        switch metadata.format {
        case .mp4, .mov, .m4v:
            metadata.originalData = data
        case .mxf, .mkv, .webm, .avi, .mpg, .braw, .arriraw, .r3d, .nikonRaw, .xocn, .crm, .crl, .ivf:
            metadata.originalData = nil
        }
        if metadata.fileSize == nil { metadata.fileSize = Int64(data.count) }
        if metadata.formatLongName == nil { metadata.formatLongName = defaultFormatLongName(metadata.format) }
        return metadata
    }

    /// Upper bound on how much of a Matroska/WebM file we load. Matches the
    /// parser's internal `maxHeaderScan` — bytes past this never get read.
    private static let matroskaReadCap: Int = 512 * 1024 * 1024

    /// Load a container file with a format-aware strategy that avoids pulling
    /// multi-GB payloads into RAM on external volumes.
    ///
    /// The read is wrapped in `autoreleasepool` so the bridged NSData temporary
    /// that `FileHandle.readData` returns gets drained before we return.
    /// Without that, batch importers that call us in a tight loop hold every
    /// prefix buffer alive until the enclosing pool drains — turning a 512 MB
    /// per-file peak into 512 MB × files-imported.
    private static func loadContainerData(from url: URL) throws -> Data {
#if canImport(ObjectiveC)
        var result: Data = Data()
        var thrownError: Error?
        autoreleasepool {
            do {
                result = try loadContainerDataInner(from: url)
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return result
#else
        // Linux Foundation has no autoreleasepool — bridged NSData temporaries
        // don't accumulate the same way, so a direct call is fine.
        return try loadContainerDataInner(from: url)
#endif
    }

    private static func loadContainerDataInner(from url: URL) throws -> Data {
        // Peek the first 16 bytes to detect the container. Every format we
        // support can be identified within that window.
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 16)

        // Matroska/WebM: bounded prefix read capped at `matroskaReadCap`.
        // The parser never scans beyond this offset, so loading the tail is
        // pure waste — and with 10-15 GB Blu-ray rips on an external SSD
        // `.mappedIfSafe` quietly falls back to a full in-RAM read.
        if MatroskaReader.isMatroska(head) {
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            let readLen = min(Int(truncatingIfNeeded: fileSize), matroskaReadCap)
            try fh.seek(toOffset: 0)
            if readLen > 0 {
                return fh.readData(ofLength: readLen)
            }
            return Data()
        }

        // Every other container needs either the header *and* footer (MXF,
        // MP4/MOV with tail-placed moov) or a linear walk, so fall back to a
        // mapped read. Use `.alwaysMapped` rather than `.mappedIfSafe` — the
        // latter declines to map external volumes and silently loads the
        // whole file into RAM.
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    private static func defaultFormatLongName(_ format: VideoFormat) -> String {
        switch format {
        // ISOBMFF family (mov,mp4,m4a,3gp,3g2,mj2) — ffprobe reports the same
        // long name for every brand, since they share the demuxer.
        case .mp4, .mov, .m4v: return "QuickTime / MOV"
        case .mxf: return "MXF (Material eXchange Format)"
        case .mkv, .webm: return "Matroska / WebM"
        case .avi: return "AVI (Audio Video Interleave)"
        case .mpg: return "MPEG-PS / MPEG-TS"
        case .braw: return "Blackmagic RAW"
        case .arriraw: return "ARRIRAW (MXF)"
        case .r3d: return "RED RAW"
        case .nikonRaw: return "Nikon RAW"
        case .xocn: return "Sony X-OCN (MXF)"
        case .crm: return "Canon Cinema RAW Light"
        case .crl: return "Canon Cinema RAW Light Proxy"
        case .ivf: return "On2 IVF"
        }
    }

    private static func parseContainer(_ data: Data) throws -> VideoMetadata {
        if MXFReader.isMXF(data) {
            return try MXFReader.parse(data)
        }
        if MatroskaReader.isMatroska(data) {
            return try MatroskaReader.parse(data)
        }
        if AVIReader.isAVI(data) {
            return try AVIReader.parse(data)
        }
        if MPEGReader.isMPEG(data) {
            return try MPEGReader.parse(data)
        }
        if R3DReader.isR3D(data) {
            return try R3DReader.parse(data)
        }
        if IVFReader.isIVF(data) {
            return try IVFReader.parse(data)
        }
        return try MP4Parser.parse(data)
    }

    // MARK: - Writing

    /// Write updated metadata back to a new Data blob.
    ///
    /// Writing is only supported for ISOBMFF containers (MP4/MOV/M4V); all other
    /// formats throw `MetadataError.writeNotSupported`.
    public func writeToData() throws -> Data {
        guard let original = originalData else {
            throw MetadataError.writeNotSupported("No original video data available for writing")
        }
        switch format {
        case .mp4, .mov, .m4v:
            return try MP4Writer.write(self, to: original)
        case .mxf, .mkv, .webm, .avi, .mpg, .braw, .arriraw, .r3d, .nikonRaw, .xocn, .crm, .crl, .ivf:
            throw MetadataError.writeNotSupported("Writing is not supported for \(format.rawValue.uppercased()) containers")
        }
    }

    /// Write updated metadata to a file URL.
    public func write(to url: URL) throws {
        try write(to: url, options: .default)
    }

    /// Write metadata to a file URL with options (atomic, backup).
    public func write(to url: URL, options: ImageMetadata.WriteOptions) throws {
        let data = try writeToData()
        let fm = FileManager.default

        if options.createBackup && fm.fileExists(atPath: url.path) {
            let backupURL = ImageMetadata.backupURL(for: url, suffix: options.backupSuffix)
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }

        if options.atomic {
            let dir = url.deletingLastPathComponent()
            let tempURL = dir.appendingPathComponent(".swiftexif_tmp_\(UUID().uuidString)")
            do {
                try data.write(to: tempURL)
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } catch {
                try? fm.removeItem(at: tempURL)
                throw MetadataError.fileWriteError("Atomic write failed: \(error.localizedDescription)")
            }
        } else {
            try data.write(to: url)
        }
    }

    // MARK: - Stripping

    /// Strip all user metadata (title, artist, comment, GPS, XMP, C2PA, camera).
    public mutating func stripMetadata() {
        title = nil
        artist = nil
        comment = nil
        gpsLatitude = nil
        gpsLongitude = nil
        gpsAltitude = nil
        xmp = nil
        c2pa = nil
        camera = nil
    }

    /// Strip only GPS metadata.
    public mutating func stripGPS() {
        gpsLatitude = nil
        gpsLongitude = nil
        gpsAltitude = nil
    }

    /// Strip only XMP metadata.
    public mutating func stripXMP() {
        xmp = nil
    }

    // MARK: - Timecode

    /// Record a timecode value tagged with its source. Appends to `timecodes`,
    /// sets `timecode` on the first call (so the existing scalar API still
    /// works), and emits a `warnings` entry whenever a later source disagrees
    /// with one already recorded (ignoring case so `HH:MM:SS:FF` vs
    /// `HH:MM:SS;FF` drop-frame variants can still match when the frame counts
    /// line up — but we treat the full string as the canonical form, so a `;`
    /// vs `:` difference IS a mismatch and gets flagged).
    internal mutating func recordTimecode(_ value: String, source: TimecodeSource, frameRate: Double? = nil) {
        // Skip empty / "00:00:00:00" placeholder entries that some writers
        // emit when they don't actually know the clip start — they add no
        // information and spuriously trigger mismatch warnings against real
        // values.
        guard !value.isEmpty, value != "00:00:00:00", value != "00:00:00;00" else { return }

        // Drop exact duplicates (same value AND same source) so re-scanning
        // the same container can't silently grow the array.
        if timecodes.contains(where: { $0.value == value && $0.source == source }) {
            return
        }

        // Warn when this value disagrees with any previously recorded value
        // from a different source. Same-source duplicates with different
        // values (e.g. two MXF TimecodeComponents in the File package) are
        // already flagged via mxfMaterialPackage vs mxfFilePackage labelling.
        for existing in timecodes where existing.value != value {
            warnings.append(
                "timecode mismatch: \(existing.source.rawValue)=\(existing.value) vs \(source.rawValue)=\(value)"
            )
        }

        timecodes.append(Timecode(value: value, source: source, frameRate: frameRate))
        if timecode == nil { timecode = value }
    }

    /// Pull `xmpDM:startTimeCode` / `xmpDM:altTimeCode` out of the attached
    /// XMP block (if any) and record them via `recordTimecode`. Parsers
    /// should call this once XMP has been attached to `self.xmp` so the
    /// XMP values show up in `timecodes` alongside container-native
    /// timecode sources.
    internal mutating func ingestXMPTimecodes() {
        guard let xmp = xmp else { return }
        if let start = xmp.startTimecode {
            recordTimecode(start.timeValue, source: .xmpDM, frameRate: start.frameRate)
        }
        if let alt = xmp.altTimecode {
            recordTimecode(alt.timeValue, source: .xmpDMAlt, frameRate: alt.frameRate)
        }
    }

    /// Pull the Sony NRT LtcChangeTable start timecode out of `self.camera`
    /// (if present) and record it as a `.sonyNRT` entry in `timecodes`.
    /// Callers should invoke this once `camera` is attached — NRT can be
    /// embedded in MXF header metadata or auto-discovered as an XML sidecar,
    /// and both paths should surface the same provenance.
    internal mutating func ingestNRTTimecode() {
        guard let tc = camera?.startTimecode, !tc.isEmpty else { return }
        recordTimecode(tc, source: .sonyNRT, frameRate: camera?.captureFps)
    }

    /// Progressive / interlaced / unknown — suitable for a "Scan Type" UI
    /// column. Derived from `fieldOrder`, which encodes both scan type and
    /// scan order in a single value.
    public var scanType: VideoScanType? {
        switch fieldOrder {
        case .none: return nil
        case .progressive: return .progressive
        case .topFieldFirst, .bottomFieldFirst, .mixed: return .interlaced
        case .unknown: return .unknown
        }
    }

    /// "TFF" / "BFF" for interlaced streams, `nil` otherwise. Suitable for a
    /// "Scan Order" UI column alongside `scanType`.
    public var scanOrder: String? {
        switch fieldOrder {
        case .topFieldFirst: return "TFF"
        case .bottomFieldFirst: return "BFF"
        default: return nil
        }
    }
}

/// A single MPEG-TS program — one logical TV channel inside a multi-program
/// transport stream (DVB / ATSC OTA capture, satellite broadcast).
///
/// PAT lists every program with its `programNumber` and the PID of the PMT
/// that describes its elementary streams. The PMT then lists video/audio/
/// subtitle PIDs. SDT (PID 0x0011) optionally adds a service name and
/// provider label.
public struct MPEGProgram: Sendable, Equatable {
    /// PAT-assigned program number (DVB calls this "service_id").
    public var programNumber: Int
    /// PID of the PMT section that describes this program's streams.
    public var pmtPID: Int
    /// PIDs of every elementary stream (video/audio/subtitles) listed in
    /// this program's PMT.
    public var elementaryPIDs: [Int]
    /// DVB service name from SDT, if available (e.g. "BBC ONE HD").
    public var serviceName: String?
    /// DVB service provider name from SDT (e.g. "BBC", "ARD").
    public var providerName: String?

    public init(
        programNumber: Int,
        pmtPID: Int,
        elementaryPIDs: [Int] = [],
        serviceName: String? = nil,
        providerName: String? = nil
    ) {
        self.programNumber = programNumber
        self.pmtPID = pmtPID
        self.elementaryPIDs = elementaryPIDs
        self.serviceName = serviceName
        self.providerName = providerName
    }
}
