import Foundation

/// Provenance of a timecode value. Different containers embed timecode in
/// multiple independent places; each surface keeps its own entry so callers
/// can spot disagreements rather than seeing a single merged value.
public enum TimecodeSource: String, Sendable, Equatable {
    /// QuickTime/ISOBMFF `tmcd` timecode track (mdat frame counter via `tref > tmcd`).
    case tmcdTrack
    /// QuickTime `moov > udta > ©TIM` / `@TIM` / `tmcd` user-data atom — written
    /// by Sony, Panasonic and other broadcast camcorders.
    case quicktimeUdta
    /// XMP `xmpDM:startTimecode` (frame + format).
    case xmpDM
    /// XMP `xmpDM:altTimecode` (alternate / secondary timecode reel).
    case xmpDMAlt
    /// MXF MaterialPackage TimecodeComponent (the "program" timecode ffprobe
    /// surfaces as `format.tags.timecode`).
    case mxfMaterialPackage
    /// MXF FilePackage/SourcePackage TimecodeComponent (the "source" timecode
    /// the camera stamped on the essence).
    case mxfFilePackage
    /// Sony NonRealTimeMeta XML (`<LtcChangeTable>` / Duration@frameCount base).
    case sonyNRT
    /// RED R3D TLV record carried in the `RED2` clip-header atom — the camera
    /// stamps both a record timecode (start of capture) and a playback /
    /// edge-code timecode in the slate.
    case redR3D
}

/// A single decoded timecode value with its source. Shape is `HH:MM:SS:FF`
/// (non-drop-frame) or `HH:MM:SS;FF` (drop-frame), matching ffprobe.
public struct Timecode: Sendable, Equatable {
    public var value: String
    public var source: TimecodeSource
    /// Frame-rate companion (e.g. 23.976, 25, 29.97) when the source carries
    /// one alongside the value — xmpDM's `timeFormat` field is the common
    /// case. `nil` when the frame rate has to be inferred from the stream.
    public var frameRate: Double?

    public init(value: String, source: TimecodeSource, frameRate: Double? = nil) {
        self.value = value
        self.source = source
        self.frameRate = frameRate
    }
}

/// Scan/field order for video essence. Encodes both *scan type* (progressive
/// vs interlaced) and *scan order* (which field is first) in one value — split
/// into distinct properties via `VideoStream.scanType` / `VideoStream.scanOrder`
/// when a UI wants separate columns (e.g. MediaInfo-style).
public enum VideoFieldOrder: String, Sendable, Equatable {
    case progressive
    case topFieldFirst = "top-field-first"
    case bottomFieldFirst = "bottom-field-first"
    case mixed
    case unknown
}

/// High-level scan type suitable for a "Scan Type" UI column. Derived from
/// `VideoFieldOrder` so consumers don't have to enumerate every field-order
/// case themselves.
public enum VideoScanType: String, Sendable, Equatable {
    case progressive
    case interlaced
    case unknown
}

/// Parsed color-space metadata for a video track.
/// Values use the numeric codes defined in ITU-T H.273 / ISO/IEC 23091-2.
public struct VideoColorInfo: Sendable, Equatable {
    /// Color primaries (H.273 Table 2). Common: 1=BT.709, 9=BT.2020, 6/7=BT.601.
    public var primaries: Int?
    /// Transfer characteristics (H.273 Table 3). Common: 1=BT.709, 16=PQ (SMPTE ST 2084), 18=HLG.
    public var transfer: Int?
    /// Matrix coefficients (H.273 Table 4). Common: 1=BT.709, 9=BT.2020-NCL, 6/7=BT.601.
    public var matrix: Int?
    /// `true` = full (0-255), `false` = limited (16-235).
    public var fullRange: Bool?

    public init(primaries: Int? = nil, transfer: Int? = nil, matrix: Int? = nil, fullRange: Bool? = nil) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
    }

    /// True when every field is nil.
    public var isEmpty: Bool {
        primaries == nil && transfer == nil && matrix == nil && fullRange == nil
    }

    /// Human-readable label for the color space — e.g. "bt709", "bt2020-pq", "bt2020-hlg".
    public var label: String? {
        guard let matrix else { return nil }
        let base: String
        switch matrix {
        case 1: base = "bt709"
        case 6, 7: base = "bt601"
        case 9: base = "bt2020"
        default: base = "mc\(matrix)"
        }
        switch transfer {
        case 16: return "\(base)-pq"
        case 18: return "\(base)-hlg"
        default: return base
        }
    }
}

/// A video track (stream) inside a container.
public struct VideoStream: Sendable, Equatable {
    public var index: Int
    public var codec: String?
    public var codecName: String?
    /// Codec profile name (e.g. "Main", "Main 10", "High", "Main 4:4:4 12",
    /// "Constrained Baseline"). Populated where the codec's decoder-config
    /// record carries an unambiguous profile_idc (HEVC, AV1, AVC).
    public var profile: String?
    public var width: Int?
    public var height: Int?
    /// Final rendered display dimensions, after pixel-aspect correction (`pasp`)
    /// *and* rotation (the `tkhd` matrix on MP4/MOV). Matches `ffprobe`'s
    /// `display_aspect_ratio` view. For an iPhone-recorded 3840×2160 portrait
    /// clip this is 2160×3840 with `rotation = -90`. Consumers should use
    /// these for UI/window sizing — do NOT also apply `rotation` to them.
    public var displayWidth: Int?
    public var displayHeight: Int?
    /// Pixel aspect ratio as (horizontal, vertical). Intrinsic to the encoded
    /// pixel grid — independent of any `rotation` applied at display time.
    public var pixelAspectRatio: (Int, Int)?
    public var bitDepth: Int?
    /// Stream bitrate in bits per second (if advertised by the container).
    public var bitRate: Int?
    /// Single frame-rate figure (kept for backwards compatibility — equals
    /// `avgFrameRate` when available, else `rFrameRate`).
    public var frameRate: Double?
    /// Average frame rate across the stream (ffprobe `avg_frame_rate`).
    public var avgFrameRate: Double?
    /// "Real" frame rate — the base cadence the decoder ticks at, typically
    /// equal to the inverse of DefaultDuration / sample delta (ffprobe
    /// `r_frame_rate`).
    public var rFrameRate: Double?
    public var duration: TimeInterval?
    public var fieldOrder: VideoFieldOrder?
    public var colorInfo: VideoColorInfo?
    /// Chroma subsampling notation (e.g. "4:2:0", "4:2:2", "4:4:4", "4:0:0").
    public var chromaSubsampling: String?
    /// Chroma sample location (e.g. "left", "center", "topleft", "top",
    /// "bottomleft", "bottom"). Matches ffprobe `chroma_location`.
    public var chromaLocation: String?
    /// ffprobe-style pixel format string (e.g. "yuv420p", "yuv420p10le",
    /// "yuvj420p", "yuv444p12le"). Derived from codec + bit depth + chroma
    /// subsampling + color range when the container doesn't name one directly.
    public var pixelFormat: String?
    /// Number of video frames (from container metadata).
    public var frameCount: Int?
    /// True when the track is a cover-art / attached-picture track rather
    /// than a timed video track (ffprobe `DISPOSITION:attached_pic`).
    public var isAttachedPic: Bool?
    /// Default-track flag (ffprobe `DISPOSITION:default`). When the container
    /// is Matroska and the element is absent, defaults to `true` per spec.
    public var isDefault: Bool?
    /// Forced-display flag (ffprobe `DISPOSITION:forced`).
    public var isForced: Bool?
    /// Per-stream timecode (HH:MM:SS:FF) where available.
    public var timecode: String?
    /// Optional human-readable track title / label set by the muxer.
    public var title: String?
    /// Display rotation in degrees, derived from the MP4/MOV `tkhd` 3x3
    /// transformation matrix. Matches ffprobe's `side_data_list[].rotation`
    /// (negative = clockwise). `-90` is the typical iPhone-portrait value.
    /// Nil when the matrix is identity or the container has no display matrix.
    public var rotation: Int?
    /// HDR side-data: SMPTE ST 2086 mastering display color volume,
    /// CTA-861.3 content light level, Dolby Vision configuration. Populated
    /// from `mdcv`, `clli`, and `dvcC`/`dvvC` boxes inside the visual sample
    /// entry. Nil for SDR streams.
    public var hdr: HDRMetadata?
    /// True when the stream carries embedded CTA-708 / CEA-608 closed
    /// captions (detected from H.264/HEVC SEI A/53 user-data wrappers, or
    /// from MP4 `\u{a9}cca` / Matroska CodecPrivate hints).
    public var hasClosedCaptions: Bool?
    /// True when the stream signals an alpha (transparency) channel via the
    /// HEVC `alpha_channel_info` SEI message.
    public var hasAlphaChannel: Bool?

    public init(index: Int) {
        self.index = index
    }

    /// Progressive vs interlaced, suitable for a MediaInfo-style "Scan Type"
    /// UI column. Derived from `fieldOrder`. Note: MBAFF / PAFF distinctions
    /// require bitstream parsing and aren't exposed here — both collapse to
    /// `.interlaced` (matching the container-descriptor view).
    public var scanType: VideoScanType? {
        switch fieldOrder {
        case .none: return nil
        case .progressive: return .progressive
        case .topFieldFirst, .bottomFieldFirst, .mixed: return .interlaced
        case .unknown: return .unknown
        }
    }

    /// Field-first order for a "Scan Order" UI column — "TFF" or "BFF".
    /// `nil` for progressive content or when the order could not be determined.
    public var scanOrder: String? {
        switch fieldOrder {
        case .topFieldFirst: return "TFF"
        case .bottomFieldFirst: return "BFF"
        default: return nil
        }
    }

    public static func == (lhs: VideoStream, rhs: VideoStream) -> Bool {
        lhs.index == rhs.index
            && lhs.codec == rhs.codec
            && lhs.codecName == rhs.codecName
            && lhs.profile == rhs.profile
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.displayWidth == rhs.displayWidth
            && lhs.displayHeight == rhs.displayHeight
            && lhs.pixelAspectRatio?.0 == rhs.pixelAspectRatio?.0
            && lhs.pixelAspectRatio?.1 == rhs.pixelAspectRatio?.1
            && lhs.bitDepth == rhs.bitDepth
            && lhs.bitRate == rhs.bitRate
            && lhs.frameRate == rhs.frameRate
            && lhs.avgFrameRate == rhs.avgFrameRate
            && lhs.rFrameRate == rhs.rFrameRate
            && lhs.duration == rhs.duration
            && lhs.fieldOrder == rhs.fieldOrder
            && lhs.colorInfo == rhs.colorInfo
            && lhs.chromaSubsampling == rhs.chromaSubsampling
            && lhs.chromaLocation == rhs.chromaLocation
            && lhs.pixelFormat == rhs.pixelFormat
            && lhs.frameCount == rhs.frameCount
            && lhs.isAttachedPic == rhs.isAttachedPic
            && lhs.isDefault == rhs.isDefault
            && lhs.isForced == rhs.isForced
            && lhs.timecode == rhs.timecode
            && lhs.title == rhs.title
            && lhs.rotation == rhs.rotation
            && lhs.hdr == rhs.hdr
            && lhs.hasClosedCaptions == rhs.hasClosedCaptions
            && lhs.hasAlphaChannel == rhs.hasAlphaChannel
    }
}

/// HDR side-data attached to a video stream.
///
/// Carries any combination of SMPTE ST 2086 mastering display color volume,
/// CTA-861.3 content light level, ITU-T H.273 content colour volume,
/// ambient viewing environment, and Dolby Vision configuration records found
/// in container-level boxes (`mdcv`, `clli`, `dvcC`/`dvvC`) or in-bitstream
/// SEI messages (HEVC payload types 137 / 144 / 147 / 148). Each field is
/// optional because containers / encoders can declare any subset.
public struct HDRMetadata: Sendable, Equatable {
    public var masteringDisplay: HDRMasteringDisplay?
    public var contentLightLevel: HDRContentLightLevel?
    public var contentColourVolume: HDRContentColourVolume?
    public var ambientViewingEnvironment: HDRAmbientViewingEnvironment?
    public var dolbyVision: HDRDolbyVisionConfig?

    public init(
        masteringDisplay: HDRMasteringDisplay? = nil,
        contentLightLevel: HDRContentLightLevel? = nil,
        contentColourVolume: HDRContentColourVolume? = nil,
        ambientViewingEnvironment: HDRAmbientViewingEnvironment? = nil,
        dolbyVision: HDRDolbyVisionConfig? = nil
    ) {
        self.masteringDisplay = masteringDisplay
        self.contentLightLevel = contentLightLevel
        self.contentColourVolume = contentColourVolume
        self.ambientViewingEnvironment = ambientViewingEnvironment
        self.dolbyVision = dolbyVision
    }

    /// True when at least one HDR signal is present.
    public var isPresent: Bool {
        masteringDisplay != nil
            || contentLightLevel != nil
            || contentColourVolume != nil
            || ambientViewingEnvironment != nil
            || dolbyVision != nil
    }
}

/// SMPTE ST 2086 mastering-display primaries and luminance bounds. Coordinates
/// are CIE 1931 xy chromaticities; luminance is in cd/m^2 (nits).
public struct HDRMasteringDisplay: Sendable, Equatable {
    public var redX: Double
    public var redY: Double
    public var greenX: Double
    public var greenY: Double
    public var blueX: Double
    public var blueY: Double
    public var whitePointX: Double
    public var whitePointY: Double
    public var maxLuminance: Double
    public var minLuminance: Double

    public init(
        redX: Double, redY: Double,
        greenX: Double, greenY: Double,
        blueX: Double, blueY: Double,
        whitePointX: Double, whitePointY: Double,
        maxLuminance: Double, minLuminance: Double
    ) {
        self.redX = redX; self.redY = redY
        self.greenX = greenX; self.greenY = greenY
        self.blueX = blueX; self.blueY = blueY
        self.whitePointX = whitePointX; self.whitePointY = whitePointY
        self.maxLuminance = maxLuminance; self.minLuminance = minLuminance
    }
}

/// CTA-861.3 content light level — peak frame brightness (MaxCLL) and peak
/// frame-average brightness (MaxFALL), both in cd/m^2.
public struct HDRContentLightLevel: Sendable, Equatable {
    public var maxCLL: Int
    public var maxFALL: Int

    public init(maxCLL: Int, maxFALL: Int) {
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }
}

/// ITU-T H.273 / H.265 D.2.41 — content colour volume (`cclv` box in ISOBMFF,
/// SEI payload type 147 in HEVC). Describes the actual chromaticity and
/// luminance bounds the content reaches, distinct from the *display* the
/// content was mastered on. Any subset of the three flag groups can be
/// signalled (primaries / min-luminance / max-luminance / avg-luminance);
/// fields that weren't signalled stay nil rather than defaulting to zero so
/// callers can tell "not advertised" from "advertised as zero."
public struct HDRContentColourVolume: Sendable, Equatable {
    /// CIE 1931 xy chromaticities for the content's R / G / B primaries.
    public var redX: Double?
    public var redY: Double?
    public var greenX: Double?
    public var greenY: Double?
    public var blueX: Double?
    public var blueY: Double?
    /// cd/m². Minimum luminance the content reaches.
    public var minLuminance: Double?
    /// cd/m². Maximum luminance the content reaches.
    public var maxLuminance: Double?
    /// cd/m². Average luminance across the entire content.
    public var avgLuminance: Double?

    public init(
        redX: Double? = nil, redY: Double? = nil,
        greenX: Double? = nil, greenY: Double? = nil,
        blueX: Double? = nil, blueY: Double? = nil,
        minLuminance: Double? = nil,
        maxLuminance: Double? = nil,
        avgLuminance: Double? = nil
    ) {
        self.redX = redX; self.redY = redY
        self.greenX = greenX; self.greenY = greenY
        self.blueX = blueX; self.blueY = blueY
        self.minLuminance = minLuminance
        self.maxLuminance = maxLuminance
        self.avgLuminance = avgLuminance
    }
}

/// ITU-T H.273 / H.265 D.2.44 — ambient viewing environment (SEI payload
/// type 148). Encoder-provided hint about the room the content was intended
/// to be viewed in: a target illuminance plus the white-point chromaticity
/// of the ambient light. Useful for HDR tone-mapping decisions.
public struct HDRAmbientViewingEnvironment: Sendable, Equatable {
    /// Target ambient illuminance in lux.
    public var ambientIlluminance: Double
    /// CIE 1931 xy chromaticity of the ambient light.
    public var ambientLightX: Double
    public var ambientLightY: Double

    public init(ambientIlluminance: Double, ambientLightX: Double, ambientLightY: Double) {
        self.ambientIlluminance = ambientIlluminance
        self.ambientLightX = ambientLightX
        self.ambientLightY = ambientLightY
    }
}

/// DOVIDecoderConfigurationRecord (Dolby Vision spec, ETSI TS 103 572).
/// Carried in `dvcC` (legacy / single-layer) and `dvvC` (cross-layer) boxes
/// inside the HEVC / AVC / AV1 visual sample entry on iPhone, recent Apple
/// silicon Macs, and Dolby-mastered broadcast streams.
public struct HDRDolbyVisionConfig: Sendable, Equatable {
    public var versionMajor: Int
    public var versionMinor: Int
    public var profile: Int
    public var level: Int
    public var rpuPresent: Bool
    public var elPresent: Bool
    public var blPresent: Bool
    /// Backward-compatibility identifier. 0 = Dolby Vision only,
    /// 1 = HDR10, 2 = SDR, 4 = HLG, 6 = Dolby Vision DV+. Other values
    /// reserved.
    public var blSignalCompatibilityID: Int

    public init(
        versionMajor: Int, versionMinor: Int,
        profile: Int, level: Int,
        rpuPresent: Bool, elPresent: Bool, blPresent: Bool,
        blSignalCompatibilityID: Int
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.elPresent = elPresent
        self.blPresent = blPresent
        self.blSignalCompatibilityID = blSignalCompatibilityID
    }
}

/// A chapter marker inside a container (MP4/MOV `chpl` or QuickTime text-track
/// chapters; Matroska `Chapters` master element).
///
/// Times are expressed in seconds from the start of the presentation. `endTime`
/// is optional — Matroska allows open-ended chapters (end implied by the next
/// chapter's start), and Nero `chpl` boxes never record an end time.
public struct VideoChapter: Sendable, Equatable {
    /// Stable identifier where the container provides one (Matroska
    /// `ChapterUID`). Nil for MP4 chapter tracks, which have no persistent id.
    public var id: UInt64?
    /// Index in the chapter list, numbered from 0. Matches ffprobe's
    /// `chapters[].id` when the container lacks an explicit UID.
    public var index: Int
    /// Start time in seconds, measured from the start of the presentation.
    public var startTime: TimeInterval
    /// End time in seconds. Nil when the container doesn't record one.
    public var endTime: TimeInterval?
    /// Human-readable chapter title (the first `ChapString` or `chpl` entry
    /// title). May be nil when the container omits a label.
    public var title: String?
    /// BCP-47 or ISO 639-2/T language tag for the title when the container
    /// records one (Matroska `ChapLanguage` / `ChapLanguageBCP47`). Nil for MP4.
    public var language: String?

    public init(
        index: Int,
        id: UInt64? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        title: String? = nil,
        language: String? = nil
    ) {
        self.index = index
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.language = language
    }

    /// Chapter length in seconds, derived from `endTime - startTime`. Nil when
    /// the source doesn't record an end time (Nero `chpl` — consumer can fall
    /// back to `nextChapter.startTime - startTime`, with the clip duration as
    /// the backstop for the final chapter).
    public var duration: TimeInterval? {
        endTime.map { $0 - startTime }
    }
}

/// A subtitle / timed-text / closed-caption track inside a container.
public struct SubtitleStream: Sendable, Equatable {
    public var index: Int
    /// Short codec identifier as stored in the container (e.g. "tx3g", "wvtt",
    /// "stpp", "c608", "c708", "S_TEXT/UTF8", "S_TEXT/ASS", "S_HDMV/PGS",
    /// "S_VOBSUB", "dvb_subtitle", "dvb_teletext").
    public var codec: String?
    /// Human-readable codec label ("WebVTT", "TTML", "3GPP Timed Text",
    /// "SubRip", "ASS", "PGS", "VobSub", "DVB Subtitles", …).
    public var codecName: String?
    /// ISO 639-2/T language code (e.g. "eng", "nor", "swe"), when declared.
    public var language: String?
    /// Optional human-readable track title / label.
    public var title: String?
    /// Default-track flag if the container signals one.
    public var isDefault: Bool?
    /// Forced-display flag (e.g. foreign-audio burn-in tracks).
    public var isForced: Bool?
    /// Hearing-impaired flag (SDH).
    public var isHearingImpaired: Bool?
    public var duration: TimeInterval?

    public init(index: Int) {
        self.index = index
    }
}

/// A non-AV "data" track — anything ffprobe reports with `codec_type=data`.
/// QuickTime timecode (`tmcd`), Apple metadata (`mdta`/`meta`), GoPro GPMF
/// (`gpmd`), embedded thumbnails (`pict`), and chapter-text tracks all land
/// here. We expose them as streams so per-track listings line up 1:1 with
/// ffprobe's stream count.
public struct DataStream: Sendable, Equatable {
    public var index: Int
    /// MP4/MOV `hdlr` type (e.g. "tmcd", "meta", "mdta", "gpmd", "pict",
    /// "text"). Carries the source of the track for callers that want to
    /// distinguish a timecode track from a generic metadata track.
    public var handlerType: String
    /// FourCC from the first sample entry in `stsd`, when present.
    public var codec: String?
    /// Human-readable codec label ("Timecode", "Apple Metadata", "GoPro GPMF").
    public var codecName: String?
    public var language: String?
    public var title: String?
    public var isDefault: Bool?
    public var duration: TimeInterval?

    public init(index: Int, handlerType: String) {
        self.index = index
        self.handlerType = handlerType
    }
}

/// Discriminated locator for a per-track stream in `VideoMetadata.streamOrder`.
/// The associated value is the index into the matching typed array.
public enum StreamKind: Sendable, Equatable {
    case video(Int)
    case audio(Int)
    case subtitle(Int)
    case data(Int)
}

/// An audio track (stream) inside a container.
public struct AudioStream: Sendable, Equatable {
    public var index: Int
    public var codec: String?
    public var codecName: String?
    /// Codec profile (e.g. "LC", "HE-AAC", "HE-AACv2", "Main", "LTP").
    public var profile: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var channelLayout: String?
    public var bitDepth: Int?
    public var bitRate: Int?
    public var duration: TimeInterval?
    public var language: String?
    /// Default-track flag if the container signals one.
    public var isDefault: Bool?
    /// Optional human-readable track title / label set by the muxer.
    public var title: String?
    /// SMPTE ST 377-4 MCA Tag Symbol attached to this track via an
    /// AudioChannelLabelSubDescriptor (e.g. "chL", "chR", "chM1"). Only MXF
    /// files with bmxtools-style audio labelling populate this.
    public var mcaChannelLabel: String?
    /// SMPTE ST 377-4 MCA Tag Name (e.g. "Left", "Right", "Mono One").
    public var mcaChannelName: String?
    /// Soundfield-group symbol the channel belongs to (e.g. "sgST", "sgM").
    public var mcaSoundfieldGroup: String?
    /// Group-of-soundfield-groups symbol the channel rolls up to (e.g.
    /// "ggMPg", "ggDcm", "ggME"). When the channel sits in more than one
    /// group, the first one in declaration order wins; the full graph is
    /// available in `VideoMetadata.mcaAudioLabeling`.
    public var mcaGroupOfSoundfieldGroups: String?

    public init(index: Int) {
        self.index = index
    }
}
