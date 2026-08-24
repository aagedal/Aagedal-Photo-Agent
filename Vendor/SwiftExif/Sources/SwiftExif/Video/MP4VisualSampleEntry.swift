import Foundation

/// Visual `stsd` SampleEntry parsing for MP4Parser: dimensions, depth,
/// codec-config records (avcC / hvcC / av1C / vvcC / dvcC / dvvC),
/// HDR side-data (mdcv / clli), and FourCC-derived ProRes/APV defaults.
///
/// Extracted from MP4Parser.swift to keep that file scannable. No behavior
/// change — `private static` helpers that were file-local in the source
/// are now `static` so they're reachable from this extension across files.
extension MP4Parser {

    // MARK: - Visual sample entry

    /// stsd contains one or more SampleEntry boxes. For video, the entry is a
    /// VisualSampleEntry whose fixed header is 78 bytes (after the 8-byte box
    /// header) and is followed by optional child boxes (avcC, hvcC, colr, fiel,
    /// pasp, btrt …).
    static func parseVisualSampleEntry(_ stsdData: Data, into stream: inout VideoStream) {
        guard stsdData.count >= 16 else { return }
        var reader = BinaryReader(data: stsdData)
        _ = try? reader.readBytes(4) // FullBox header
        _ = try? reader.readUInt32BigEndian() // entry_count

        guard reader.remainingCount >= 8 else { return }
        let entryStart = reader.offset
        guard let entrySize32 = try? reader.readUInt32BigEndian(),
              let codecBytes = try? reader.readBytes(4),
              let codec = String(data: codecBytes, encoding: .ascii) else { return }

        stream.codec = codec
        stream.codecName = codecLongName(codec) ?? codec

        // Fixed VisualSampleEntry header: 78 bytes after the 8-byte box header.
        // Offsets within the entry payload:
        //   0..5   reserved
        //   6..7   data_reference_index
        //   8..23  pre_defined(16)
        //   24..27 horizresolution + 28..31 vertresolution  (both fixed-point 16.16)
        //   32..35 reserved
        //   36..37 frame_count
        //   38..69 compressor_name (Pascal string in 32 bytes)
        //   70..71 depth
        //   72..73 pre_defined (−1)
        // We still need the width/height, which live at offsets 24..27 in reality.
        // The ISO spec actually places them at offsets 24..27 — that's what we'll read.

        let payloadBase = entryStart + 8 // past size + type
        // width @ +24, height @ +26  (relative to the VisualSampleEntry start)
        if stsdData.count >= payloadBase + 32 {
            if (try? reader.seek(to: payloadBase + 24)) != nil,
               let w = try? reader.readUInt16BigEndian(),
               let h = try? reader.readUInt16BigEndian() {
                if w > 0 { stream.width = Int(w) }
                if h > 0 { stream.height = Int(h) }
            }
        }

        // depth at +74 within the VisualSampleEntry payload (see ISO/IEC 14496-12).
        // Most codecs advertise 0x18 (24 = packed RGB 8-bit) here; higher-bit-depth
        // values are rare and unreliable — the codec-specific config box (hvcC,
        // av1C, prores atom …) is the real source of truth, parsed below.
        if stsdData.count >= payloadBase + 76 {
            if (try? reader.seek(to: payloadBase + 74)) != nil,
               let depth = try? reader.readUInt16BigEndian() {
                if depth > 0, depth != 0x18, depth % 3 == 0, depth <= 96 {
                    stream.bitDepth = Int(depth / 3)
                }
            }
        }

        // The sample entry payload extends to entryStart + entrySize32; children
        // start 8 bytes after the fixed VisualSampleEntry header at payloadBase + 78.
        let entryEnd = entryStart + Int(entrySize32)
        let childrenStart = payloadBase + 78
        guard childrenStart < entryEnd, entryEnd <= stsdData.count else { return }

        let childrenData = Data(
            stsdData[(stsdData.startIndex + childrenStart) ..< (stsdData.startIndex + entryEnd)]
        )
        if let kids = try? ISOBMFFBoxReader.parseBoxes(from: childrenData) {
            for kid in kids {
                applyVisualChildBox(kid, into: &stream)
            }
        }

        // Sample entries whose FourCC uniquely identifies the codec variant
        // (ProRes, APV, ProRes RAW) can skip frame-header parsing entirely —
        // fill in profile/chroma/bit_depth from the FourCC.
        applyFourCCDefaults(codec, into: &stream)
    }

    static func applyVisualChildBox(_ box: ISOBMFFBox, into stream: inout VideoStream) {
        switch box.type {
        case "colr":
            if let info = parseColrBox(box.data) {
                stream.colorInfo = info
            }
        case "mdcv":
            if let md = parseMDCVBox(box.data) {
                if stream.hdr == nil { stream.hdr = HDRMetadata() }
                stream.hdr?.masteringDisplay = md
            }
        case "clli":
            if let cll = parseCLLIBox(box.data) {
                if stream.hdr == nil { stream.hdr = HDRMetadata() }
                stream.hdr?.contentLightLevel = cll
            }
        case "dvcC", "dvvC":
            if let dv = parseDVCConfig(box.data) {
                if stream.hdr == nil { stream.hdr = HDRMetadata() }
                stream.hdr?.dolbyVision = dv
            }
        case "fiel":
            if let fo = parseFielBox(box.data) {
                stream.fieldOrder = fo
            }
        case "pasp":
            if let par = parsePaspBox(box.data) {
                stream.pixelAspectRatio = par
                if let w = stream.width, let h = stream.height,
                   par.0 > 0, par.1 > 0 {
                    let codedDW = w * par.0 / par.1
                    let codedDH = h
                    // displayWidth/Height contract: always post-rotation rendered
                    // dims (matches ffprobe). MP4TrackParser sets `stream.rotation`
                    // from the tkhd matrix *before* dispatching here, so it's
                    // available; ±90 quarter-turns swap width and height.
                    let isQuarterTurn = abs(stream.rotation ?? 0) == 90
                    stream.displayWidth  = isQuarterTurn ? codedDH : codedDW
                    stream.displayHeight = isQuarterTurn ? codedDW : codedDH
                }
            }
        case "hvcC":
            parseHVCC(box.data, into: &stream)
        case "av1C":
            parseAV1C(box.data, into: &stream)
        case "avcC":
            // AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.2.4.1.1):
            //   byte 0 : configurationVersion (1)
            //   byte 1 : AVCProfileIndication  (profile_idc from SPS)
            //   byte 2 : profile_compatibility
            //   byte 3 : AVCLevelIndication
            // Chroma/bit_depth live in the SPS (variable-length decode beyond
            // scope); every AVC profile shipped by Apple/Adobe/NVENC defaults
            // to 4:2:0 8-bit, so surface that.
            if box.data.count >= 2 {
                let profileIDC = box.data[box.data.startIndex + 1]
                stream.profile = avcProfileName(profileIDC)
            }
            if stream.bitDepth == nil { stream.bitDepth = 8 }
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }
        case "btrt":
            if let br = parseBTRT(box.data) {
                stream.bitRate = br
            }
        case "vvcC":
            parseVVCC(box.data, into: &stream)
        default:
            break
        }
    }

    /// VvcDecoderConfigurationRecord (ISO/IEC 14496-15 §11.3) — the fields we
    /// need live in the first few bytes:
    ///   byte 0 : LengthSizeMinusOne(2) | ptl_present_flag(1) | reserved(5)
    ///   bytes 1–2 : ols_idx(9) / num_sublayers(3) / constant_frame_rate(2) /
    ///                chroma_format_idc(2)
    ///   byte 3 : bit_depth_minus8 (3 bits in the high nibble)
    /// We only peek at the chroma and bit depth — profile lives in an optional
    /// PTL record and varies too much across VVC drafts to map reliably here.
    static func parseVVCC(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 4 else { return }
        let s = data.startIndex
        let ptlPresent = (data[s] >> 5) & 0x01
        guard ptlPresent == 1, data.count >= 5 else {
            // Without PTL the chroma/bit_depth fields aren't guaranteed — bail
            // out after setting defensible defaults (every shipping VVC clip we
            // care about is 10-bit 4:2:0 Main 10 Intra or Main 10).
            if stream.chromaSubsampling == nil { stream.chromaSubsampling = "4:2:0" }
            if stream.bitDepth == nil { stream.bitDepth = 10 }
            return
        }
        // ptl_present_flag = 1: next 2 bytes are ols_idx(9)+sublayers(3)+cfr(2)+
        // chroma_format_idc(2). Bit_depth_minus_8 is in the high 3 bits of the
        // byte that follows.
        let byte2 = data[s + 2]
        let chromaIDC = Int(byte2 & 0x03)
        let bitDepthMinus8 = Int((data[s + 3] >> 5) & 0x07)
        if stream.chromaSubsampling == nil {
            switch chromaIDC {
            case 0: stream.chromaSubsampling = "4:0:0"
            case 1: stream.chromaSubsampling = "4:2:0"
            case 2: stream.chromaSubsampling = "4:2:2"
            case 3: stream.chromaSubsampling = "4:4:4"
            default: break
            }
        }
        if stream.bitDepth == nil, bitDepthMinus8 >= 0, bitDepthMinus8 <= 8 {
            stream.bitDepth = bitDepthMinus8 + 8
        }
    }

    /// Deterministic pix_fmt / profile / bit_depth for codecs whose sample
    /// entry FourCC uniquely identifies the subcodec — notably ProRes, APV
    /// and ProRes RAW. ffprobe reads the same fields from the frame header,
    /// but every FourCC here maps 1:1 so surfacing them from the container
    /// side matches ffprobe's output without any bitstream parsing.
    static func applyFourCCDefaults(_ codec: String, into stream: inout VideoStream) {
        switch codec {
        // Apple ProRes (SMPTE RP 2019)
        case "apco": // 422 Proxy
            stream.profile = stream.profile ?? "Proxy"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apcs": // 422 LT
            stream.profile = stream.profile ?? "LT"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apcn": // 422 Standard
            stream.profile = stream.profile ?? "Standard"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "apch": // 422 HQ
            stream.profile = stream.profile ?? "HQ"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        case "ap4h": // 4444 — always carries alpha, 12-bit YUV
            stream.profile = stream.profile ?? "4444"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:4:4"
            stream.bitDepth = stream.bitDepth ?? 12
            stream.pixelFormat = stream.pixelFormat ?? "yuva444p12le"
        case "ap4x": // 4444 XQ
            stream.profile = stream.profile ?? "4444XQ"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:4:4"
            stream.bitDepth = stream.bitDepth ?? 12
            stream.pixelFormat = stream.pixelFormat ?? "yuva444p12le"
        // Apple ProRes RAW
        case "aprn":
            stream.profile = stream.profile ?? "RAW"
            stream.bitDepth = stream.bitDepth ?? 12
        case "aprh":
            stream.profile = stream.profile ?? "RAW HQ"
            stream.bitDepth = stream.bitDepth ?? 12
        // APV (Advanced Professional Video, SMPTE ST 2130) — the sample entry
        // FourCC `apv1` always carries 10-bit 4:2:2 Main profile (profile_idc
        // 33). Newer 4:4:4 / 12-bit variants will need a real APVC box.
        case "apv1":
            stream.profile = stream.profile ?? "33"
            stream.chromaSubsampling = stream.chromaSubsampling ?? "4:2:2"
            stream.bitDepth = stream.bitDepth ?? 10
        default:
            break
        }
    }

    /// `btrt` (BitRateBox): buffer_size_db(4) + max_bitrate(4) + avg_bitrate(4).
    /// We prefer avg_bitrate; fall back to max_bitrate when avg is 0.
    static func parseBTRT(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readUInt32BigEndian() // buffer_size_db
        let maxBR = (try? reader.readUInt32BigEndian()) ?? 0
        let avgBR = (try? reader.readUInt32BigEndian()) ?? 0
        if avgBR > 0 { return Int(avgBR) }
        if maxBR > 0 { return Int(maxBR) }
        return nil
    }

    /// `colr` box: type FullBox variant. First 4 bytes are the color_type.
    ///   - "nclx": 2+2+2+1 bytes: primaries, transfer, matrix, flag (bit 7 = full_range).
    ///   - "nclc": 2+2+2 bytes: primaries, transfer, matrix (no range flag).
    ///   - "prof"/"rICC": ICC profile payload — we skip it.
    static func parseColrBox(_ data: Data) -> VideoColorInfo? {
        guard data.count >= 4 else { return nil }
        let colorType = String(data: data.prefix(4), encoding: .ascii) ?? ""
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)

        switch colorType {
        case "nclx":
            guard data.count >= 11,
                  let p = try? reader.readUInt16BigEndian(),
                  let t = try? reader.readUInt16BigEndian(),
                  let m = try? reader.readUInt16BigEndian(),
                  let flag = try? reader.readUInt8() else { return nil }
            return VideoColorInfo(
                primaries: Int(p),
                transfer: Int(t),
                matrix: Int(m),
                fullRange: (flag & 0x80) != 0
            )
        case "nclc":
            guard data.count >= 10,
                  let p = try? reader.readUInt16BigEndian(),
                  let t = try? reader.readUInt16BigEndian(),
                  let m = try? reader.readUInt16BigEndian() else { return nil }
            return VideoColorInfo(primaries: Int(p), transfer: Int(t), matrix: Int(m), fullRange: nil)
        default:
            return nil
        }
    }

    /// `fiel` box: 1 byte field_count (1 = progressive, 2 = interlaced),
    /// 1 byte field_ordering (0/1 = TFF, 6 = BFF for MP4; 9/14 for QuickTime).
    static func parseFielBox(_ data: Data) -> VideoFieldOrder? {
        guard data.count >= 1 else { return nil }
        let fieldCount = data[data.startIndex]
        if fieldCount == 1 { return .progressive }
        guard fieldCount == 2, data.count >= 2 else { return .mixed }
        switch data[data.startIndex + 1] {
        case 0, 1, 9: return .topFieldFirst
        case 6, 14: return .bottomFieldFirst
        default: return .unknown
        }
    }

    /// `pasp` box: 4 bytes hSpacing + 4 bytes vSpacing.
    static func parsePaspBox(_ data: Data) -> (Int, Int)? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        guard let h = try? reader.readUInt32BigEndian(),
              let v = try? reader.readUInt32BigEndian(),
              h > 0, v > 0 else { return nil }
        return (Int(h), Int(v))
    }

    /// `mdcv` box (SMPTE ST 2086 Mastering Display Color Volume), 24 bytes.
    /// All values big-endian. Display primaries and white point are stored as
    /// uint16 values in 0.00002 chromaticity units (so 50000 = 1.0 on the CIE
    /// 1931 xy plane). Luminance values are uint32 in 0.0001 cd/m^2 units.
    static func parseMDCVBox(_ data: Data) -> HDRMasteringDisplay? {
        guard data.count >= 24 else { return nil }
        var reader = BinaryReader(data: data)
        guard let rx = try? reader.readUInt16BigEndian(),
              let ry = try? reader.readUInt16BigEndian(),
              let gx = try? reader.readUInt16BigEndian(),
              let gy = try? reader.readUInt16BigEndian(),
              let bx = try? reader.readUInt16BigEndian(),
              let by = try? reader.readUInt16BigEndian(),
              let wx = try? reader.readUInt16BigEndian(),
              let wy = try? reader.readUInt16BigEndian(),
              let maxL = try? reader.readUInt32BigEndian(),
              let minL = try? reader.readUInt32BigEndian() else { return nil }

        let chromaScale = 0.00002
        let lumaScale = 0.0001
        return HDRMasteringDisplay(
            redX: Double(rx) * chromaScale,
            redY: Double(ry) * chromaScale,
            greenX: Double(gx) * chromaScale,
            greenY: Double(gy) * chromaScale,
            blueX: Double(bx) * chromaScale,
            blueY: Double(by) * chromaScale,
            whitePointX: Double(wx) * chromaScale,
            whitePointY: Double(wy) * chromaScale,
            maxLuminance: Double(maxL) * lumaScale,
            minLuminance: Double(minL) * lumaScale
        )
    }

    /// `clli` box (CTA-861.3 Content Light Level Information), 4 bytes.
    /// Both values big-endian uint16, in cd/m^2.
    static func parseCLLIBox(_ data: Data) -> HDRContentLightLevel? {
        guard data.count >= 4 else { return nil }
        var reader = BinaryReader(data: data)
        guard let maxCLL = try? reader.readUInt16BigEndian(),
              let maxFALL = try? reader.readUInt16BigEndian() else { return nil }
        return HDRContentLightLevel(maxCLL: Int(maxCLL), maxFALL: Int(maxFALL))
    }

    /// `dvcC` / `dvvC` box — DOVIDecoderConfigurationRecord (Dolby Vision spec).
    /// Layout (24 bytes total, but the layout-bearing portion is just the
    /// first 6 bytes — the rest is reserved):
    ///   byte 0       dv_version_major
    ///   byte 1       dv_version_minor
    ///   bytes 2..5   dv_profile (7) + dv_level (6) + rpu (1) + el (1) +
    ///                 bl (1) + dv_bl_signal_compatibility_id (4) +
    ///                 reserved (12) — read as one big-endian UInt32.
    ///   bytes 6..23  reserved (must be zero)
    static func parseDVCConfig(_ data: Data) -> HDRDolbyVisionConfig? {
        guard data.count >= 6 else { return nil }
        let s = data.startIndex
        let versionMajor = Int(data[s])
        let versionMinor = Int(data[s + 1])
        let word = (UInt32(data[s + 2]) << 24)
            | (UInt32(data[s + 3]) << 16)
            | (UInt32(data[s + 4]) << 8)
            | UInt32(data[s + 5])
        let profile = Int((word >> 25) & 0x7F)
        let level = Int((word >> 19) & 0x3F)
        let rpuPresent = ((word >> 18) & 1) == 1
        let elPresent = ((word >> 17) & 1) == 1
        let blPresent = ((word >> 16) & 1) == 1
        let blCompat = Int((word >> 12) & 0x0F)
        return HDRDolbyVisionConfig(
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            profile: profile,
            level: level,
            rpuPresent: rpuPresent,
            elPresent: elPresent,
            blPresent: blPresent,
            blSignalCompatibilityID: blCompat
        )
    }

    /// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15, §8.3.3.1.2). The box is
    /// *not* a FullBox — the payload starts at configurationVersion.
    /// Byte offsets in the record:
    ///   0       configurationVersion
    ///   1       profile_space(2) + tier_flag(1) + profile_idc(5)
    ///   2..5    general_profile_compatibility_flags
    ///   6..11   general_constraint_indicator_flags
    ///   12      general_level_idc
    ///   13..14  reserved + min_spatial_segmentation_idc
    ///   15      reserved + parallelismType
    ///   16      reserved + chroma_format_idc   ← 0=4:0:0, 1=4:2:0, 2=4:2:2, 3=4:4:4
    ///   17      reserved + bit_depth_luma_minus8
    ///   18      reserved + bit_depth_chroma_minus8
    static func parseHVCC(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 23 else { return }
        let s = data.startIndex
        // Byte 1 low 5 bits are profile_idc (0-31). 2=Main10, 1=Main, 3=Main
        // Still Picture, 4=Range Extensions (with chroma_format_idc deciding
        // "Main 4:2:2 10", "Main 4:4:4 12" etc.).
        let profileIDC = Int(data[s + 1] & 0x1F)
        let chromaFormatIDC = Int(data[s + 16] & 0x03)
        let bitDepthLuma = Int(data[s + 17] & 0x07) + 8
        stream.chromaSubsampling = chromaSubsamplingLabel(forIDC: chromaFormatIDC)
        stream.bitDepth = bitDepthLuma
        stream.profile = hevcProfileName(
            profileIDC: profileIDC,
            chromaFormatIDC: chromaFormatIDC,
            bitDepth: bitDepthLuma
        )
        applyHEVCBitstreamFromConfigRecord(data, into: &stream)
    }

    /// Walk the NAL arrays inside an HEVCDecoderConfigurationRecord and harvest
    /// what container-level boxes don't always advertise: SPS-VUI color
    /// signalling (primaries / transfer / matrix / range) plus prefix-SEI HDR
    /// static metadata (mastering display volume 137, content light level 144).
    /// Real-world Blu-ray HDR10 muxes — particularly MakeMKV output — rely on
    /// these instead of the parallel `Colour` / `mdcv` / `clli` container
    /// elements, so without this step the HDR metadata is silently lost on
    /// MKV (and any MP4 that doesn't also carry `mdcv` / `clli`).
    static func applyHEVCBitstreamFromConfigRecord(
        _ data: Data,
        into stream: inout VideoStream
    ) {
        let (spsRBSP, seiRBSPs) = MPEGBitstream.extractHEVCConfigurationBitstreams(data)

        if let sps = spsRBSP, let fields = MPEGBitstream.parseHEVCSPS(sps) {
            if let color = fields.color {
                // Only fill gaps — container-level `colr` boxes (when present)
                // remain the source of truth because they reflect post-encode
                // overrides muxers occasionally apply.
                var merged = stream.colorInfo ?? VideoColorInfo()
                if merged.primaries == nil { merged.primaries = color.primaries }
                if merged.transfer == nil  { merged.transfer  = color.transfer }
                if merged.matrix == nil    { merged.matrix    = color.matrix }
                if merged.fullRange == nil { merged.fullRange = color.fullRange }
                stream.colorInfo = merged
            }
            if stream.chromaLocation == nil, let cl = fields.chromaLocation {
                stream.chromaLocation = cl
            }
        }

        if !seiRBSPs.isEmpty {
            let sei = MPEGBitstream.parseSEIMessages(seiRBSPs, forHEVC: true)
            if sei.masteringDisplay != nil
                || sei.contentLightLevel != nil
                || sei.contentColourVolume != nil
                || sei.ambientViewingEnvironment != nil {
                if stream.hdr == nil { stream.hdr = HDRMetadata() }
                if let md = sei.masteringDisplay, stream.hdr?.masteringDisplay == nil {
                    stream.hdr?.masteringDisplay = md
                }
                if let cll = sei.contentLightLevel, stream.hdr?.contentLightLevel == nil {
                    stream.hdr?.contentLightLevel = cll
                }
                if let ccv = sei.contentColourVolume, stream.hdr?.contentColourVolume == nil {
                    stream.hdr?.contentColourVolume = ccv
                }
                if let ave = sei.ambientViewingEnvironment, stream.hdr?.ambientViewingEnvironment == nil {
                    stream.hdr?.ambientViewingEnvironment = ave
                }
            }
        }
    }

    /// Map H.264 / AVC profile_idc (ISO/IEC 14496-10 Annex A.2) to the
    /// ffprobe-compatible label. Covers the common profiles encoders actually
    /// ship — rarer ones (Multiview, Stereo High) fall through to nil.
    static func avcProfileName(_ profileIDC: UInt8) -> String? {
        switch profileIDC {
        case 66: return "Constrained Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High 10"
        case 122: return "High 4:2:2"
        case 244: return "High 4:4:4 Predictive"
        case 44: return "CAVLC 4:4:4 Intra"
        case 83: return "Scalable Baseline"
        case 86: return "Scalable High"
        case 118: return "Multiview High"
        case 128: return "Stereo High"
        default: return nil
        }
    }

    /// Map HEVC profile_idc → ffprobe-style profile string. Range-Extensions
    /// profile names depend on chroma_format_idc and bit depth, so they're
    /// composed here rather than via a flat table.
    static func hevcProfileName(profileIDC: Int, chromaFormatIDC: Int, bitDepth: Int) -> String? {
        switch profileIDC {
        case 1: return "Main"
        case 2: return "Main 10"
        case 3: return "Main Still Picture"
        case 4:
            let chromaLabel: String
            switch chromaFormatIDC {
            case 0: return "Monochrome \(bitDepth)"
            case 1: chromaLabel = "4:2:0"
            case 2: chromaLabel = "4:2:2"
            case 3: chromaLabel = "4:4:4"
            default: return "Range Extensions"
            }
            return "Main \(chromaLabel) \(bitDepth)"
        default:
            return nil
        }
    }

    /// AV1CodecConfigurationRecord (AV1 in ISOBMFF spec, §2.3.3).
    /// Byte 2 bit layout (MSB first):
    ///   bit7 seq_tier_0
    ///   bit6 high_bitdepth
    ///   bit5 twelve_bit
    ///   bit4 monochrome
    ///   bit3 chroma_subsampling_x
    ///   bit2 chroma_subsampling_y
    ///   bits 0-1 chroma_sample_position
    static func parseAV1C(_ data: Data, into stream: inout VideoStream) {
        guard data.count >= 3 else { return }
        let byte1 = data[data.startIndex + 1]
        let byte2 = data[data.startIndex + 2]
        // Byte 1: marker(1) + version(7), but AV1 actually uses top 3 bits as
        // seq_profile (0=Main, 1=High, 2=Professional). Seven bits would waste
        // 4 bits; ffmpeg reads byte[1] & 0xE0 >> 5.
        let seqProfile = Int((byte1 & 0xE0) >> 5)
        let highBitDepth = (byte2 >> 6) & 0x01
        let twelveBit = (byte2 >> 5) & 0x01
        let monochrome = (byte2 >> 4) & 0x01
        let ssx = (byte2 >> 3) & 0x01
        let ssy = (byte2 >> 2) & 0x01

        stream.bitDepth = twelveBit == 1 ? 12 : (highBitDepth == 1 ? 10 : 8)
        if monochrome == 1 {
            stream.chromaSubsampling = "4:0:0"
        } else if ssx == 1 && ssy == 1 {
            stream.chromaSubsampling = "4:2:0"
        } else if ssx == 1 && ssy == 0 {
            stream.chromaSubsampling = "4:2:2"
        } else if ssx == 0 && ssy == 0 {
            stream.chromaSubsampling = "4:4:4"
        }
        switch seqProfile {
        case 0: stream.profile = "Main"
        case 1: stream.profile = "High"
        case 2: stream.profile = "Professional"
        default: break
        }
    }

    static func chromaSubsamplingLabel(forIDC idc: Int) -> String? {
        switch idc {
        case 0: return "4:0:0"
        case 1: return "4:2:0"
        case 2: return "4:2:2"
        case 3: return "4:4:4"
        default: return nil
        }
    }

    // MARK: - Codec name lookup

    /// Long-form codec label for a sample-entry FourCC. Used by both the
    /// visual and audio sample-entry paths to populate `codecName`.
    static func codecLongName(_ fourCC: String) -> String? {
        switch fourCC {
        case "avc1", "avc3": return "H.264 / AVC"
        case "hvc1", "hev1": return "H.265 / HEVC"
        case "hev2", "dvh1", "dvhe": return "HEVC (Dolby Vision)"
        case "vvc1", "vvi1": return "H.266 / VVC"
        case "av01": return "AV1"
        case "vp08": return "VP8"
        case "vp09": return "VP9"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "Apple ProRes"
        case "aprh", "aprn": return "Apple ProRes RAW"
        case "mp4v": return "MPEG-4 Visual"
        case "s263": return "H.263"
        case "dvh1\0": return "Dolby Vision HEVC"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "ac-3": return "Dolby Digital (AC-3)"
        case "ec-3": return "Dolby Digital Plus (E-AC-3)"
        case "Opus": return "Opus"
        case "twos", "sowt": return "PCM (signed, big/little endian)"
        case "lpcm": return "Linear PCM"
        case "fl32", "fl64": return "PCM (floating point)"
        case "in24", "in32": return "PCM (signed 24/32-bit)"
        case "samr": return "AMR"
        case "mlpa": return "MLP"
        default: return nil
        }
    }
}
