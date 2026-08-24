import Foundation

/// Bitstream helpers and codec-specific parsers used by `MPEGReader`.
///
/// MPEG-TS streams carry codec parameters (resolution, frame rate, sample
/// rate) inside the elementary stream itself — there's no container-level
/// `tkhd` or descriptor to lift them from. Reaching feature parity with
/// ffprobe requires decoding the H.264/H.265 SPS, AAC ADTS, AC-3 sync
/// frames and AAC LATM `AudioSpecificConfig` directly.
///
/// Helpers live in their own file to keep `MPEGReader.swift` focused on
/// the container walk; nothing outside MPEGReader uses them today (the
/// MP4 parser stays byte-level), so they're file-internal.
enum MPEGBitstream {

    // MARK: - Bit reader

    /// Big-endian bit reader over a `Data` slice. Bits are consumed
    /// MSB-first within each byte, matching every bitstream syntax used
    /// here (H.264 / H.265 / AAC / AC-3).
    struct BitReader {
        let data: Data
        private(set) var bitOffset: Int = 0

        init(_ data: Data) { self.data = data }

        var bitsRemaining: Int { data.count * 8 - bitOffset }

        /// Read up to 64 bits as an unsigned integer. Reading past the
        /// end clamps and returns 0 — callers check `bitsRemaining` when
        /// they need to bail cleanly.
        mutating func read(_ n: Int) -> UInt64 {
            guard n > 0, n <= 64 else { return 0 }
            var value: UInt64 = 0
            var remaining = n
            while remaining > 0 {
                let byteIndex = data.startIndex + (bitOffset >> 3)
                if byteIndex >= data.endIndex {
                    bitOffset += remaining
                    return value << remaining
                }
                let bitInByte = bitOffset & 7
                let available = 8 - bitInByte
                let take = min(remaining, available)
                let byte = data[byteIndex]
                let shift = available - take
                let mask: UInt8 = (take == 8) ? 0xFF : UInt8((1 << take) - 1)
                let bits = (byte >> shift) & mask
                value = (value << take) | UInt64(bits)
                bitOffset += take
                remaining -= take
            }
            return value
        }

        mutating func readBool() -> Bool { read(1) == 1 }

        /// Skip `n` bits.
        mutating func skip(_ n: Int) { bitOffset += n }

        /// Unsigned Exp-Golomb (H.264/H.265 `ue(v)`). Returns 0 when the
        /// bitstream is truncated.
        mutating func readUE() -> UInt32 {
            var leadingZeros = 0
            while bitsRemaining > 0, read(1) == 0, leadingZeros < 32 {
                leadingZeros += 1
            }
            if leadingZeros == 0 { return 0 }
            let suffix = read(leadingZeros)
            return UInt32(truncatingIfNeeded: ((1 << leadingZeros) - 1) + Int(suffix))
        }

        /// Signed Exp-Golomb (H.264/H.265 `se(v)`).
        mutating func readSE() -> Int32 {
            let ue = readUE()
            if ue == 0 { return 0 }
            // Widen to UInt64 before `+ 1`: a malformed bitstream can make
            // readUE() return 0xFFFFFFFF, and `ue + 1` in UInt32 would trap.
            let magnitude = Int64((UInt64(ue) + 1) >> 1)
            let signed = (ue & 1) == 1 ? magnitude : -magnitude
            return Int32(truncatingIfNeeded: signed)
        }
    }

    // MARK: - NAL extraction

    /// Walk `data` looking for Annex-B start codes (`00 00 01` or
    /// `00 00 00 01`) and return the byte ranges of each NAL unit's
    /// RBSP payload. Each returned `Range` excludes the start code so
    /// callers can read the NAL header byte directly at `range.lowerBound`.
    static func annexBNALRanges(_ data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        let count = data.count
        guard count >= 4 else { return ranges }
        var i = 0
        var unitStart: Int? = nil
        while i + 2 < count {
            // Detect 00 00 01 or 00 00 00 01.
            if data[data.startIndex + i] == 0 && data[data.startIndex + i + 1] == 0 {
                let startLen: Int
                if i + 3 < count, data[data.startIndex + i + 2] == 0,
                   data[data.startIndex + i + 3] == 1 {
                    startLen = 4
                } else if data[data.startIndex + i + 2] == 1 {
                    startLen = 3
                } else {
                    i += 1
                    continue
                }
                if let prev = unitStart {
                    ranges.append(prev..<i)
                }
                unitStart = i + startLen
                i += startLen
                continue
            }
            i += 1
        }
        if let prev = unitStart, prev < count {
            ranges.append(prev..<count)
        }
        return ranges
    }

    /// Strip H.264/H.265 emulation-prevention bytes (`00 00 03` → `00 00`).
    /// Returns a fresh `Data` because callers feed it to a `BitReader` that
    /// expects contiguous storage.
    static func stripEmulationPrevention(_ src: Data) -> Data {
        var out = Data()
        out.reserveCapacity(src.count)
        var i = 0
        let n = src.count
        while i < n {
            if i + 2 < n,
               src[src.startIndex + i] == 0,
               src[src.startIndex + i + 1] == 0,
               src[src.startIndex + i + 2] == 3 {
                out.append(0)
                out.append(0)
                i += 3
                continue
            }
            out.append(src[src.startIndex + i])
            i += 1
        }
        return out
    }

    /// Walk the parameter-set NAL arrays inside an HEVCDecoderConfigurationRecord
    /// (ISOBMFF `hvcC` box / Matroska `V_MPEGH/ISO/HEVC` `CodecPrivate`). Starting
    /// at byte 22 — `numOfArrays` — each array is { type byte, num NALUs (u16 BE),
    /// (NALU length u16 BE + NALU bytes) × N }. The NAL_unit_type lives in the low
    /// 6 bits of the array's type byte. Returns the first SPS RBSP (NAL type 33,
    /// header stripped, emulation-prevention bytes removed) and every prefix /
    /// suffix SEI RBSP (NAL types 39 / 40, same treatment) — the same format the
    /// MPEG-TS pipeline already feeds to `parseHEVCSPS` and `parseSEIMessages`.
    /// Out-of-bounds reads or malformed sizes terminate the walk silently.
    static func extractHEVCConfigurationBitstreams(
        _ data: Data
    ) -> (sps: Data?, seiRBSPs: [Data]) {
        // Fixed header before the NAL arrays is 23 bytes (configurationVersion …
        // numOfArrays). Anything shorter cannot describe a single array.
        guard data.count > 22 else { return (nil, []) }
        let base = data.startIndex
        let numArrays = Int(data[base + 22])
        var offset = 23
        var sps: Data?
        var seis: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= data.count else { break }
            let nalType = Int(data[base + offset] & 0x3F)
            let numNalus = (Int(data[base + offset + 1]) << 8) | Int(data[base + offset + 2])
            offset += 3

            for _ in 0..<numNalus {
                guard offset + 2 <= data.count else { return (sps, seis) }
                let len = (Int(data[base + offset]) << 8) | Int(data[base + offset + 1])
                offset += 2
                guard offset + len <= data.count, len >= 2 else { return (sps, seis) }
                // The first 2 bytes of every HEVC NALU are the NAL header; the
                // RBSP-with-emulation-prevention payload follows. Both consumers
                // here (parseHEVCSPS / parseSEIMessages) take RBSPs that start
                // *after* the NAL header.
                let payloadStart = offset + 2
                let payloadEnd = offset + len
                let raw = data.subdata(in: base + payloadStart ..< base + payloadEnd)
                let rbsp = stripEmulationPrevention(raw)
                switch nalType {
                case 33 where sps == nil: sps = rbsp     // SPS (first one wins)
                case 39, 40:              seis.append(rbsp) // prefix / suffix SEI
                default: break
                }
                offset += len
            }
        }
        return (sps, seis)
    }

    // MARK: - H.264 SPS

    struct H264SPSFields {
        var profile: String?
        var level: String?
        var width: Int?
        var height: Int?
        var chromaSubsampling: String?
        var bitDepth: Int?
        var sampleAspect: (Int, Int)?
        var displayAspect: (Int, Int)?
        var frameRate: Double?
        var color: VideoColorInfo?
        var chromaLocation: String?
        var fieldOrder: VideoFieldOrder?
    }

    /// Decode the subset of an H.264 SPS RBSP needed for ffprobe-parity
    /// metadata. `rbsp` must already have emulation-prevention bytes
    /// stripped and start at the byte after the 1-byte NAL header.
    static func parseH264SPS(_ rbsp: Data) -> H264SPSFields? {
        guard rbsp.count >= 4 else { return nil }
        var f = H264SPSFields()

        let profileIDC = Int(rbsp[rbsp.startIndex])
        let constraintFlags = rbsp[rbsp.startIndex + 1]
        let levelIDC = Int(rbsp[rbsp.startIndex + 2])
        f.profile = h264ProfileName(profileIDC: profileIDC, constraintFlags: constraintFlags)
        f.level = h264LevelName(levelIDC: levelIDC)

        var br = BitReader(rbsp.subdata(in: (rbsp.startIndex + 3)..<rbsp.endIndex))
        _ = br.readUE() // seq_parameter_set_id

        var chromaFormatIDC: UInt32 = 1
        // 64-bit so the `+ 8` can't overflow when a malformed stream makes
        // readUE() return a near-UInt32.max value.
        var bitDepthLuma = 8
        let highFamily: Set<Int> = [44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244]
        if highFamily.contains(profileIDC) {
            chromaFormatIDC = br.readUE()
            if chromaFormatIDC == 3 { _ = br.readBool() } // separate_colour_plane_flag
            bitDepthLuma = Int(br.readUE()) + 8
            _ = br.readUE()  // bit_depth_chroma_minus8
            _ = br.readBool()    // qpprime_y_zero_transform_bypass_flag
            let seqScalingPresent = br.readBool()
            if seqScalingPresent {
                let scalingListCount = chromaFormatIDC == 3 ? 12 : 8
                for i in 0..<scalingListCount {
                    if br.readBool() {
                        skipH264ScalingList(&br, size: i < 6 ? 16 : 64)
                    }
                }
            }
        }
        f.chromaSubsampling = h264ChromaName(chromaFormatIDC: chromaFormatIDC)
        f.bitDepth = bitDepthLuma

        _ = br.readUE() // log2_max_frame_num_minus4
        let picOrderCntType = br.readUE()
        if picOrderCntType == 0 {
            _ = br.readUE() // log2_max_pic_order_cnt_lsb_minus4
        } else if picOrderCntType == 1 {
            _ = br.readBool() // delta_pic_order_always_zero_flag
            _ = br.readSE()   // offset_for_non_ref_pic
            _ = br.readSE()   // offset_for_top_to_bottom_field
            let numRef = br.readUE()
            for _ in 0..<min(numRef, 256) { _ = br.readSE() }
        }
        _ = br.readUE() // num_ref_frames
        _ = br.readBool() // gaps_in_frame_num_value_allowed_flag

        // 64-bit Int throughout: readUE() can return up to 0xFFFFFFFF on a
        // malformed stream, so `+ 1` and `* 16` must not overflow/trap.
        let picWidthInMBs = Int(br.readUE()) + 1
        let picHeightInMapUnits = Int(br.readUE()) + 1
        let frameMBsOnly = br.readBool()
        if !frameMBsOnly { _ = br.readBool() } // mb_adaptive_frame_field_flag
        _ = br.readBool() // direct_8x8_inference_flag

        var width = picWidthInMBs * 16
        var height = picHeightInMapUnits * 16 * (frameMBsOnly ? 1 : 2)

        let frameCroppingFlag = br.readBool()
        if frameCroppingFlag {
            let cropL = br.readUE()
            let cropR = br.readUE()
            let cropT = br.readUE()
            let cropB = br.readUE()
            let (subW, subH) = h264ChromaSubFactors(chromaFormatIDC: chromaFormatIDC)
            let cropUnitX = subW
            let cropUnitY = subH * (frameMBsOnly ? 1 : 2)
            width -= (Int(cropL) + Int(cropR)) * cropUnitX
            height -= (Int(cropT) + Int(cropB)) * cropUnitY
        }
        f.width = max(0, width)
        f.height = max(0, height)
        f.fieldOrder = frameMBsOnly ? .progressive : nil

        let vuiPresent = br.readBool()
        if vuiPresent {
            // aspect_ratio_info_present_flag
            if br.readBool() {
                let idc = br.read(8)
                if idc == 255 {
                    let sarW = Int(br.read(16))
                    let sarH = Int(br.read(16))
                    if sarW > 0, sarH > 0 { f.sampleAspect = (sarW, sarH) }
                } else if let sar = h264SARTable(idc: Int(idc)) {
                    f.sampleAspect = sar
                }
            }
            if let sar = f.sampleAspect, let w = f.width, let h = f.height,
               sar.0 > 0, sar.1 > 0, w > 0, h > 0 {
                let dispW = w * sar.0
                let dispH = h * sar.1
                let g = gcd(dispW, dispH)
                if g > 0 { f.displayAspect = (dispW / g, dispH / g) }
            }
            // overscan_info_present_flag
            if br.readBool() { _ = br.readBool() }
            // video_signal_type_present_flag
            if br.readBool() {
                _ = br.read(3) // video_format
                let fullRange = br.readBool()
                var color = VideoColorInfo()
                color.fullRange = fullRange
                if br.readBool() { // colour_description_present_flag
                    color.primaries = Int(br.read(8))
                    color.transfer = Int(br.read(8))
                    color.matrix = Int(br.read(8))
                }
                if !color.isEmpty { f.color = color }
            }
            // chroma_loc_info_present_flag
            if br.readBool() {
                let topField = br.readUE()
                _ = br.readUE() // bottom_field
                f.chromaLocation = h264ChromaLocationName(Int(topField))
            }
            // timing_info_present_flag
            if br.readBool() {
                let numUnitsInTick = br.read(32)
                let timeScale = br.read(32)
                let fixed = br.readBool()
                _ = fixed
                if numUnitsInTick > 0, timeScale > 0 {
                    f.frameRate = Double(timeScale) / (2.0 * Double(numUnitsInTick))
                }
            }
        }
        return f
    }

    private static func skipH264ScalingList(_ br: inout BitReader, size: Int) {
        var lastScale = 8
        var nextScale = 8
        for _ in 0..<size {
            if nextScale != 0 {
                let delta = br.readSE()
                nextScale = (lastScale + Int(delta) + 256) % 256
            }
            lastScale = nextScale == 0 ? lastScale : nextScale
        }
    }

    private static func h264ProfileName(profileIDC: Int, constraintFlags: UInt8) -> String? {
        let cs1 = (constraintFlags & 0x40) != 0
        let cs3 = (constraintFlags & 0x10) != 0
        switch profileIDC {
        case 44:  return "CAVLC 4:4:4 Intra"
        case 66:  return cs1 ? "Constrained Baseline" : "Baseline"
        case 77:  return "Main"
        case 83:  return "Scalable Baseline"
        case 86:  return "Scalable High"
        case 88:  return "Extended"
        case 100: return cs3 ? "High Progressive" : "High"
        case 110: return cs3 ? "High 10 Intra" : "High 10"
        case 118: return "Multiview High"
        case 122: return cs3 ? "High 4:2:2 Intra" : "High 4:2:2"
        case 128: return "Stereo High"
        case 134: return "MFC High"
        case 135: return "MFC Depth High"
        case 138, 139: return "Multiview Depth High"
        case 244: return cs3 ? "High 4:4:4 Intra" : "High 4:4:4 Predictive"
        default:  return nil
        }
    }

    private static func h264LevelName(levelIDC: Int) -> String? {
        switch levelIDC {
        case 9: return "1b"
        case 10, 11, 12, 13:
            return "1.\(levelIDC - 10)"
        case 20, 21, 22:
            return "2.\(levelIDC - 20)"
        case 30, 31, 32:
            return "3.\(levelIDC - 30)"
        case 40, 41, 42:
            return "4.\(levelIDC - 40)"
        case 50, 51, 52:
            return "5.\(levelIDC - 50)"
        case 60, 61, 62:
            return "6.\(levelIDC - 60)"
        default:
            return nil
        }
    }

    private static func h264ChromaName(chromaFormatIDC: UInt32) -> String? {
        switch chromaFormatIDC {
        case 0: return "monochrome"
        case 1: return "4:2:0"
        case 2: return "4:2:2"
        case 3: return "4:4:4"
        default: return nil
        }
    }

    private static func h264ChromaSubFactors(chromaFormatIDC: UInt32) -> (Int, Int) {
        switch chromaFormatIDC {
        case 1: return (2, 2) // 4:2:0
        case 2: return (2, 1) // 4:2:2
        case 3: return (1, 1) // 4:4:4
        default: return (1, 1)
        }
    }

    /// H.264 Annex E.2.1 (Table E-1): `aspect_ratio_idc` to (sar_width, sar_height).
    private static func h264SARTable(idc: Int) -> (Int, Int)? {
        switch idc {
        case 1:  return (1, 1)
        case 2:  return (12, 11)
        case 3:  return (10, 11)
        case 4:  return (16, 11)
        case 5:  return (40, 33)
        case 6:  return (24, 11)
        case 7:  return (20, 11)
        case 8:  return (32, 11)
        case 9:  return (80, 33)
        case 10: return (18, 11)
        case 11: return (15, 11)
        case 12: return (64, 33)
        case 13: return (160, 99)
        case 14: return (4, 3)
        case 15: return (3, 2)
        case 16: return (2, 1)
        default: return nil
        }
    }

    private static func h264ChromaLocationName(_ topField: Int) -> String? {
        switch topField {
        case 0: return "left"
        case 1: return "center"
        case 2: return "topleft"
        case 3: return "top"
        case 4: return "bottomleft"
        case 5: return "bottom"
        default: return nil
        }
    }

    // MARK: - HEVC SPS

    struct HEVCSPSFields {
        var profile: String?
        var level: String?
        var width: Int?
        var height: Int?
        var chromaSubsampling: String?
        var bitDepth: Int?
        var color: VideoColorInfo?
        var chromaLocation: String?
        var sampleAspect: (Int, Int)?
        var displayAspect: (Int, Int)?
        var frameRate: Double?
    }

    /// Decode an HEVC SPS NAL (NAL type 33). `rbsp` must have
    /// emulation-prevention bytes stripped and start at the byte after
    /// the 2-byte NAL header.
    static func parseHEVCSPS(_ rbsp: Data) -> HEVCSPSFields? {
        guard rbsp.count >= 4 else { return nil }
        var f = HEVCSPSFields()
        var br = BitReader(rbsp)
        _ = br.read(4)                                  // sps_video_parameter_set_id
        let maxSubLayersMinus1 = Int(br.read(3))
        _ = br.readBool()                               // sps_temporal_id_nesting_flag

        // profile_tier_level(maxSubLayersMinus1)
        if let ptl = parseHEVCProfileTierLevel(&br, maxSubLayersMinus1: maxSubLayersMinus1) {
            f.profile = ptl.profile
            f.level = ptl.level
        }

        _ = br.readUE() // sps_seq_parameter_set_id
        let chromaFormatIDC = br.readUE()
        if chromaFormatIDC == 3 { _ = br.readBool() } // separate_colour_plane_flag
        f.chromaSubsampling = h264ChromaName(chromaFormatIDC: chromaFormatIDC)
        let picWidth = br.readUE()
        let picHeight = br.readUE()
        var width = Int(picWidth)
        var height = Int(picHeight)
        if br.readBool() { // conformance_window_flag
            let cropL = br.readUE()
            let cropR = br.readUE()
            let cropT = br.readUE()
            let cropB = br.readUE()
            let (subW, subH) = h264ChromaSubFactors(chromaFormatIDC: chromaFormatIDC)
            // Int additions: `cropL + cropR` in UInt32 would trap on a
            // malformed stream where both decode near UInt32.max.
            width -= (Int(cropL) + Int(cropR)) * subW
            height -= (Int(cropT) + Int(cropB)) * subH
        }
        f.width = max(0, width)
        f.height = max(0, height)

        let bitDepthLuma = Int(br.readUE()) + 8
        _ = br.readUE() // bit_depth_chroma
        f.bitDepth = bitDepthLuma

        let log2MaxPicOrderCntLsbMinus4 = br.readUE()

        let subLayerOrderingPresent = br.readBool()
        let firstLayer = subLayerOrderingPresent ? 0 : maxSubLayersMinus1
        for _ in firstLayer...maxSubLayersMinus1 {
            _ = br.readUE() // sps_max_dec_pic_buffering_minus1
            _ = br.readUE() // sps_max_num_reorder_pics
            _ = br.readUE() // sps_max_latency_increase_plus1
        }

        _ = br.readUE() // log2_min_luma_coding_block_size_minus3
        _ = br.readUE() // log2_diff_max_min_luma_coding_block_size
        _ = br.readUE() // log2_min_luma_transform_block_size_minus2
        _ = br.readUE() // log2_diff_max_min_luma_transform_block_size
        _ = br.readUE() // max_transform_hierarchy_depth_inter
        _ = br.readUE() // max_transform_hierarchy_depth_intra

        if br.readBool() { // scaling_list_enabled_flag
            if br.readBool() { // sps_scaling_list_data_present_flag
                skipHEVCScalingListData(&br)
            }
        }
        _ = br.readBool() // amp_enabled_flag
        _ = br.readBool() // sample_adaptive_offset_enabled_flag

        if br.readBool() { // pcm_enabled_flag
            _ = br.read(4) // pcm_sample_bit_depth_luma
            _ = br.read(4) // pcm_sample_bit_depth_chroma
            _ = br.readUE() // log2_min_pcm_luma_coding_block_size_minus3
            _ = br.readUE() // log2_diff_max_min_pcm_luma_coding_block_size
            _ = br.readBool() // pcm_loop_filter_disabled_flag
        }

        // short_term_ref_pic_sets(). To reach the VUI block we have to step
        // past every set in the SPS array — each one is either a direct
        // (num_negative_pics + num_positive_pics) encoding or an inter-RPS
        // prediction referencing the previous set (Blu-ray HEVC encoders use
        // the latter for the tail of the list). Inter-RPS prediction needs
        // NumDeltaPocs[stRpsIdx - 1] to know how many `used_by_curr_pic_flag`
        // / `use_delta_flag` pairs to consume, so we track each set's
        // negative/positive delta-poc count as we go.
        let numShortTermRefPicSets = br.readUE()
        var numDeltaPocs: [Int] = []
        numDeltaPocs.reserveCapacity(Int(min(numShortTermRefPicSets, 64)))
        for i in 0..<min(numShortTermRefPicSets, 64) {
            let interPredFlag = i > 0 ? br.readBool() : false
            if interPredFlag {
                // In SPS context stRpsIdx is always < num_short_term_ref_pic_sets,
                // so delta_idx_minus1 is never coded — RefRpsIdx = i - 1.
                _ = br.readBool()                    // delta_rps_sign
                _ = br.readUE()                      // abs_delta_rps_minus1
                let refDelta = numDeltaPocs.last ?? 0
                var newCount = 0
                for _ in 0...refDelta {              // j = 0 … NumDeltaPocs[RefRpsIdx]
                    let used = br.readBool()         // used_by_curr_pic_flag[j]
                    var useDelta = used              // inferred to 1 when used == 1
                    if !used {
                        useDelta = br.readBool()     // use_delta_flag[j]
                    }
                    if used || useDelta { newCount += 1 }
                }
                // Spec equations 7-71..7-78 also fold in the delta_rps entry,
                // which adds at most one more pic, and a sign-based filter
                // can drop entries that flip side. For the purpose of reading
                // the NEXT inter-RPS set's bit count, treating `newCount` as
                // NumDeltaPocs is the right upper bound — any subsequent
                // chained inter-RPS set reads at most this many flag pairs.
                numDeltaPocs.append(newCount)
            } else {
                let numNeg = br.readUE()
                let numPos = br.readUE()
                let total = Int(numNeg + numPos)
                for _ in 0..<min(total, 64) {
                    _ = br.readUE()                  // delta_poc_s0_minus1 / s1_minus1
                    _ = br.readBool()                // used_by_curr_pic_flag
                }
                numDeltaPocs.append(total)
            }
        }
        if br.readBool() {                           // long_term_ref_pics_present_flag
            let numLong = br.readUE()
            // lt_ref_pic_poc_lsb_sps is `log2_max_pic_order_cnt_lsb_minus4 + 4`
            // bits wide — the previous hardcoded `read(4)` desynced any SPS
            // with log2_max > 0 (typical Blu-ray values are 4 → 8-bit POC LSB).
            let ltPocBits = Int(log2MaxPicOrderCntLsbMinus4) + 4
            for _ in 0..<min(numLong, 32) {
                _ = br.read(ltPocBits)               // lt_ref_pic_poc_lsb_sps[i]
                _ = br.readBool()                    // used_by_curr_pic_lt_sps_flag[i]
            }
        }
        _ = br.readBool() // sps_temporal_mvp_enabled_flag
        _ = br.readBool() // strong_intra_smoothing_enabled_flag

        if br.readBool() { // vui_parameters_present_flag
            if br.readBool() { // aspect_ratio_info_present_flag
                let idc = br.read(8)
                if idc == 255 {
                    let sarW = Int(br.read(16))
                    let sarH = Int(br.read(16))
                    if sarW > 0, sarH > 0 { f.sampleAspect = (sarW, sarH) }
                } else if let sar = h264SARTable(idc: Int(idc)) {
                    f.sampleAspect = sar
                }
            }
            if let sar = f.sampleAspect, let w = f.width, let h = f.height,
               sar.0 > 0, sar.1 > 0, w > 0, h > 0 {
                let dispW = w * sar.0
                let dispH = h * sar.1
                let g = gcd(dispW, dispH)
                if g > 0 { f.displayAspect = (dispW / g, dispH / g) }
            }
            if br.readBool() { _ = br.readBool() } // overscan_info
            if br.readBool() { // video_signal_type_present
                _ = br.read(3) // video_format
                let fullRange = br.readBool()
                var color = VideoColorInfo()
                color.fullRange = fullRange
                if br.readBool() { // colour_description_present
                    color.primaries = Int(br.read(8))
                    color.transfer = Int(br.read(8))
                    color.matrix = Int(br.read(8))
                }
                if !color.isEmpty { f.color = color }
            }
            if br.readBool() { // chroma_loc_info
                let topField = br.readUE()
                _ = br.readUE()
                f.chromaLocation = h264ChromaLocationName(Int(topField))
            }
            _ = br.readBool() // neutral_chroma_indication
            _ = br.readBool() // field_seq_flag
            _ = br.readBool() // frame_field_info_present_flag
            if br.readBool() { // default_display_window
                _ = br.readUE(); _ = br.readUE(); _ = br.readUE(); _ = br.readUE()
            }
            if br.readBool() { // vui_timing_info_present_flag
                let numUnitsInTick = br.read(32)
                let timeScale = br.read(32)
                if numUnitsInTick > 0, timeScale > 0 {
                    // HEVC's tick is field-rate-equivalent; ffprobe reports
                    // time_scale / num_units_in_tick (no /2 like H.264).
                    f.frameRate = Double(timeScale) / Double(numUnitsInTick)
                }
            }
        }
        return f
    }

    private static func parseHEVCProfileTierLevel(
        _ br: inout BitReader,
        maxSubLayersMinus1: Int
    ) -> (profile: String?, level: String?)? {
        guard br.bitsRemaining >= 88 + 8 * maxSubLayersMinus1 else { return nil }
        _ = br.read(2) // general_profile_space
        let tierFlag = br.readBool()
        let profileIDC = Int(br.read(5))
        var profileCompat: UInt32 = 0
        for _ in 0..<32 { profileCompat = (profileCompat << 1) | UInt32(br.read(1)) }
        _ = br.read(4)  // progressive_source_flag … non_packed_constraint_flag
        _ = br.read(43) // remaining general_constraint_indicator_flags
        _ = br.read(1)  // inbld / reserved
        let levelIDC = Int(br.read(8))

        var subLayerProfilePresent = [Bool](repeating: false, count: maxSubLayersMinus1)
        var subLayerLevelPresent = [Bool](repeating: false, count: maxSubLayersMinus1)
        for i in 0..<maxSubLayersMinus1 {
            subLayerProfilePresent[i] = br.readBool()
            subLayerLevelPresent[i] = br.readBool()
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 { _ = br.read(2) } // reserved_zero_2bits
        }
        for i in 0..<maxSubLayersMinus1 {
            if subLayerProfilePresent[i] {
                _ = br.read(2)  // sub_layer_profile_space
                _ = br.read(1)  // sub_layer_tier_flag
                _ = br.read(5)  // sub_layer_profile_idc
                _ = br.read(32) // sub_layer_profile_compatibility_flag
                _ = br.read(48) // constraint flags
            }
            if subLayerLevelPresent[i] {
                _ = br.read(8) // sub_layer_level_idc
            }
        }
        return (
            hevcProfileName(profileIDC: profileIDC, profileCompat: profileCompat, tier: tierFlag),
            hevcLevelName(levelIDC: levelIDC)
        )
    }

    private static func skipHEVCScalingListData(_ br: inout BitReader) {
        // Spec 7.3.4 scaling_list_data():
        //   for (sizeId = 0; sizeId < 4; sizeId++)
        //     for (matrixId = 0; matrixId < 6; matrixId += (sizeId == 3) ? 3 : 1)
        //
        // The upper bound is always 6; the *step* of 3 for sizeId=3 makes the
        // inner loop visit matrixId ∈ {0, 3} (Intra-Y and Inter-Y, the only two
        // 32×32 matrices defined). Earlier code used `matrixCount = 2` for
        // sizeId=3 which dropped matrix [3][3] entirely — desyncing the bit
        // cursor by roughly 450 bits for any SPS that signals coefficients for
        // the 32×32 Inter-Y matrix (Blu-ray HEVC remuxes routinely do).
        for sizeId in 0..<4 {
            var matrixId = 0
            while matrixId < 6 {
                if !br.readBool() {                       // scaling_list_pred_mode_flag
                    _ = br.readUE()                       // scaling_list_pred_matrix_id_delta
                } else {
                    var coefNum = min(64, 1 << (4 + (sizeId << 1)))
                    if sizeId > 1 { _ = br.readSE() }     // scaling_list_dc_coef_minus8
                    while coefNum > 0 {
                        _ = br.readSE()                   // scaling_list_delta_coef
                        coefNum -= 1
                    }
                }
                matrixId += (sizeId == 3) ? 3 : 1
            }
        }
    }

    private static func hevcProfileName(profileIDC: Int, profileCompat: UInt32, tier: Bool) -> String? {
        // profile_compatibility_flag[i] bits run MSB-first in the stream;
        // bit at position (31 - i) corresponds to flag[i].
        func compat(_ i: Int) -> Bool { (profileCompat >> (31 - i)) & 1 == 1 }
        let base: String?
        switch profileIDC {
        case 1: base = "Main"
        case 2: base = "Main 10"
        case 3: base = "Main Still Picture"
        case 4: base = "Format Range Extensions"
        case 5: base = "High Throughput"
        case 6: base = "Multiview Main"
        case 7: base = "Scalable Main"
        case 8: base = "3D Main"
        case 9: base = "Screen Content Coding"
        default:
            if compat(2) { base = "Main 10" }
            else if compat(1) { base = "Main" }
            else if compat(3) { base = "Main Still Picture" }
            else { base = nil }
        }
        guard let base else { return nil }
        return tier ? "\(base) High Tier" : base
    }

    private static func hevcLevelName(levelIDC: Int) -> String? {
        // levelIDC is encoded as level × 30 (e.g. 4.0 → 120, 5.1 → 153).
        guard levelIDC > 0 else { return nil }
        let value = Double(levelIDC) / 30.0
        let major = Int(value)
        let minorTimes10 = Int(value * 10) - major * 10
        return minorTimes10 == 0 ? "\(major)" : "\(major).\(minorTimes10)"
    }

    // MARK: - AAC ADTS

    struct ADTSFields {
        var profile: String?
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
    }

    /// Standard AAC sample-rate table (sampling_frequency_index → Hz).
    static let aacSampleRateTable: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350, 0, 0, 0,
    ]

    /// Find the first ADTS fixed header (`syncword == 0xFFF`) inside a
    /// PES payload and decode it.
    static func parseAACADTS(_ data: Data) -> ADTSFields? {
        let n = data.count
        guard n >= 4 else { return nil }
        var i = 0
        while i + 4 <= n {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            if b0 == 0xFF, (b1 & 0xF6) == 0xF0 {
                let b2 = data[data.startIndex + i + 2]
                let b3 = data[data.startIndex + i + 3]
                let aotMinus1 = Int((b2 >> 6) & 0x03)
                let sfi = Int((b2 >> 2) & 0x0F)
                let chConfig = Int(((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03))
                guard sfi < aacSampleRateTable.count, aacSampleRateTable[sfi] > 0 else {
                    i += 1
                    continue
                }
                var f = ADTSFields()
                f.profile = aacProfileName(aot: aotMinus1 + 1)
                f.sampleRate = aacSampleRateTable[sfi]
                if chConfig > 0 {
                    f.channels = aacChannelCount(chConfig)
                    f.channelLayout = aacChannelLayout(chConfig)
                }
                return f
            }
            i += 1
        }
        return nil
    }

    /// Decode an AAC `AudioSpecificConfig` (used by LATM/LOAS). `data`
    /// is the bitstream-aligned config as carried in `StreamMuxConfig`.
    static func parseAudioSpecificConfig(_ data: Data) -> ADTSFields? {
        guard !data.isEmpty else { return nil }
        var br = BitReader(data)
        var aot = Int(br.read(5))
        if aot == 31 { aot = 32 + Int(br.read(6)) }
        let sfi = Int(br.read(4))
        var sampleRate: Int? = nil
        if sfi == 15 {
            let sr = Int(br.read(24))
            if sr > 0 { sampleRate = sr }
        } else if sfi < aacSampleRateTable.count, aacSampleRateTable[sfi] > 0 {
            sampleRate = aacSampleRateTable[sfi]
        }
        let chConfig = Int(br.read(4))
        // Handle SBR/PS extensions (HE-AAC v1/v2): bumped sample rate is
        // stored as `extension_sampling_frequency_index` after the AOT.
        if aot == 5 || aot == 29 {
            let extSfi = Int(br.read(4))
            if extSfi == 15 { _ = br.read(24) }
            else if extSfi < aacSampleRateTable.count, aacSampleRateTable[extSfi] > 0 {
                // Match ffprobe: report base sample rate from AOT-5.
                sampleRate = aacSampleRateTable[extSfi]
            }
            aot = Int(br.read(5))
            if aot == 31 { aot = 32 + Int(br.read(6)) }
        }
        var f = ADTSFields()
        f.profile = aacProfileName(aot: aot)
        f.sampleRate = sampleRate
        if chConfig > 0 {
            f.channels = aacChannelCount(chConfig)
            f.channelLayout = aacChannelLayout(chConfig)
        }
        return f
    }

    private static func aacProfileName(aot: Int) -> String? {
        switch aot {
        case 1: return "Main"
        case 2: return "LC"
        case 3: return "SSR"
        case 4: return "LTP"
        case 5: return "HE-AAC"
        case 22: return "BSAC"
        case 23: return "LD"
        case 29: return "HE-AACv2"
        case 39: return "ELD"
        default: return nil
        }
    }

    private static func aacChannelCount(_ chConfig: Int) -> Int? {
        switch chConfig {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 5
        case 6: return 6
        case 7: return 8
        default: return nil
        }
    }

    private static func aacChannelLayout(_ chConfig: Int) -> String? {
        switch chConfig {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "3.0"
        case 4: return "4.0"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "7.1"
        default: return nil
        }
    }

    // MARK: - AAC LATM/LOAS

    /// Parse the first LATM `AudioSpecificConfig` found inside a PES
    /// payload. Sync is the 11-bit `audio_mux_element` start
    /// `0x2B7` followed by `audioMuxLengthBytes` length field.
    static func parseAACLATM(_ data: Data) -> ADTSFields? {
        let n = data.count
        guard n >= 4 else { return nil }
        var i = 0
        while i + 3 < n {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            // 11-bit syncword 0x2B7 — top 11 bits of [b0 b1].
            if b0 == 0x56, (b1 & 0xE0) == 0xE0 {
                let payloadStart = i + 3
                guard payloadStart < n else { return nil }
                let payload = data.subdata(in: (data.startIndex + payloadStart)..<data.endIndex)
                if let cfg = decodeLATMConfig(payload) { return cfg }
            }
            i += 1
        }
        return nil
    }

    private static func decodeLATMConfig(_ payload: Data) -> ADTSFields? {
        guard !payload.isEmpty else { return nil }
        var br = BitReader(payload)
        if br.readBool() { return nil } // useSameStreamMux=1: config absent in this frame
        // StreamMuxConfig: audioMuxVersion u(1), allStreamsSameTimeFraming u(1)
        let audioMuxVersion = br.readBool()
        if audioMuxVersion {
            // audioMuxVersionA u(1) etc. skipped for parity with most encoders
            return nil
        }
        _ = br.readBool() // allStreamsSameTimeFraming
        let numSubFrames = Int(br.read(6))
        let numProgram = Int(br.read(4))
        let numLayer = Int(br.read(3))
        _ = numSubFrames; _ = numProgram; _ = numLayer
        // AudioSpecificConfig follows directly.
        // Build a byte-aligned ASC by re-reading bits into a Data.
        var ascBits: [UInt8] = []
        var bitsCollected = 0
        var current: UInt8 = 0
        // Read at most 8 bytes — that's plenty for plain ASC.
        let maxBits = min(8 * 8, br.bitsRemaining)
        while bitsCollected < maxBits {
            current = (current << 1) | UInt8(br.read(1))
            bitsCollected += 1
            if bitsCollected % 8 == 0 {
                ascBits.append(current)
                current = 0
            }
        }
        if bitsCollected % 8 != 0 {
            current <<= UInt8(8 - bitsCollected % 8)
            ascBits.append(current)
        }
        return parseAudioSpecificConfig(Data(ascBits))
    }

    // MARK: - AC-3 / E-AC-3

    struct AC3Fields {
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
        var bitRate: Int?
    }

    /// AC-3 sync = 0x0B77. Decode the bsi up to acmod / lfeon for sample
    /// rate, channels, and bit rate.
    static func parseAC3(_ data: Data) -> AC3Fields? {
        let n = data.count
        guard n >= 7 else { return nil }
        var i = 0
        while i + 7 <= n {
            if data[data.startIndex + i] == 0x0B,
               data[data.startIndex + i + 1] == 0x77 {
                var br = BitReader(data.subdata(in: (data.startIndex + i + 2)..<data.endIndex))
                _ = br.read(16) // crc1
                let fscod = Int(br.read(2))
                let frmsizecod = Int(br.read(6))
                let bsid = Int(br.read(5))
                _ = br.read(3) // bsmod
                let acmod = Int(br.read(3))
                if (acmod & 1) != 0, acmod != 1 { _ = br.read(2) } // cmixlev
                if (acmod & 4) != 0 { _ = br.read(2) }             // surmixlev
                if acmod == 2 { _ = br.read(2) }                   // dsurmod
                let lfeon = br.readBool()
                if bsid > 10 {
                    // Out of range for plain AC-3 — could be E-AC-3
                    // misdetected. Skip.
                    return nil
                }
                var f = AC3Fields()
                f.sampleRate = ac3SampleRate(fscod: fscod)
                f.channels = ac3ChannelCount(acmod: acmod, lfe: lfeon)
                f.channelLayout = ac3ChannelLayout(acmod: acmod, lfe: lfeon)
                f.bitRate = ac3BitRate(frmsizecod: frmsizecod)
                return f
            }
            i += 1
        }
        return nil
    }

    /// E-AC-3 sync = 0x0B77 with `bsid` between 11 and 16.
    static func parseEAC3(_ data: Data) -> AC3Fields? {
        let n = data.count
        guard n >= 6 else { return nil }
        var i = 0
        while i + 6 <= n {
            if data[data.startIndex + i] == 0x0B,
               data[data.startIndex + i + 1] == 0x77 {
                var br = BitReader(data.subdata(in: (data.startIndex + i + 2)..<data.endIndex))
                _ = br.read(2) // strmtyp
                _ = br.read(3) // substreamid
                _ = br.read(11) // frmsiz
                let fscod = Int(br.read(2))
                let fscod2 = Int(br.read(2))
                _ = br.read(2) // numblkscod
                let acmod = Int(br.read(3))
                let lfeon = br.readBool()
                let bsid = Int(br.read(5))
                guard bsid >= 11, bsid <= 16 else { return nil }
                var f = AC3Fields()
                f.sampleRate = fscod == 3
                    ? eac3HalfRate(fscod2: fscod2)
                    : ac3SampleRate(fscod: fscod)
                f.channels = ac3ChannelCount(acmod: acmod, lfe: lfeon)
                f.channelLayout = ac3ChannelLayout(acmod: acmod, lfe: lfeon)
                return f
            }
            i += 1
        }
        return nil
    }

    private static func ac3SampleRate(fscod: Int) -> Int? {
        switch fscod {
        case 0: return 48000
        case 1: return 44100
        case 2: return 32000
        default: return nil
        }
    }

    private static func eac3HalfRate(fscod2: Int) -> Int? {
        switch fscod2 {
        case 0: return 24000
        case 1: return 22050
        case 2: return 16000
        default: return nil
        }
    }

    private static func ac3ChannelCount(acmod: Int, lfe: Bool) -> Int? {
        let main: Int
        switch acmod {
        case 0: main = 2 // 1+1 (Ch1, Ch2 dual mono)
        case 1: main = 1
        case 2: main = 2
        case 3: main = 3
        case 4: main = 3
        case 5: main = 4
        case 6: main = 4
        case 7: main = 5
        default: return nil
        }
        return main + (lfe ? 1 : 0)
    }

    private static func ac3ChannelLayout(acmod: Int, lfe: Bool) -> String? {
        let base: String
        switch acmod {
        case 0: base = "1+1"
        case 1: base = "mono"
        case 2: base = "stereo"
        case 3: base = "3.0"
        case 4: base = "2.1"
        case 5: base = "3.1"
        case 6: base = "2.2"
        case 7: base = "5.0"
        default: return nil
        }
        if !lfe { return base }
        // Append LFE for layouts that take one.
        switch acmod {
        case 1: return "1.1"
        case 2: return "2.1"
        case 3: return "3.1"
        case 4: return "3.1"
        case 5: return "4.1"
        case 6: return "4.1"
        case 7: return "5.1"
        default: return base
        }
    }

    private static func ac3BitRate(frmsizecod: Int) -> Int? {
        // Lower 5 bits index the bit-rate table; the 6th bit selects the
        // frame size variant at non-48k sample rates and doesn't change
        // the bit rate. ATSC A/52 Table 5.18.
        let table: [Int] = [
            32_000, 40_000, 48_000, 56_000, 64_000, 80_000, 96_000, 112_000,
            128_000, 160_000, 192_000, 224_000, 256_000, 320_000, 384_000, 448_000,
            512_000, 576_000, 640_000,
        ]
        let idx = frmsizecod >> 1
        guard idx < table.count else { return nil }
        return table[idx]
    }

    // MARK: - Helpers

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    // MARK: - SEI

    /// Per-stream SEI metadata extracted from H.264/H.265 SEI NAL units.
    /// SEI is the in-band variant of MP4's `mdcv`/`clli`/`dvcC` boxes —
    /// MPEG-TS, MKV and bare H.264/HEVC streams carry HDR + caption + timecode
    /// info here because they have no container slot for it.
    struct SEIData {
        /// SMPTE ST 2086 mastering display color volume (SEI payload type 137).
        var masteringDisplay: HDRMasteringDisplay?
        /// CTA-861.3 content light level (SEI payload type 144).
        var contentLightLevel: HDRContentLightLevel?
        /// H.265 D.2.41 content colour volume (SEI payload type 147).
        var contentColourVolume: HDRContentColourVolume?
        /// H.265 D.2.44 ambient viewing environment (SEI payload type 148).
        var ambientViewingEnvironment: HDRAmbientViewingEnvironment?
        /// True if the stream carries CTA-708 / CEA-608 closed captions in
        /// SEI user_data_registered_itu_t_t35 (payload type 4) with the
        /// ATSC A/53 wrapper (provider 0x0031, user_identifier 'GA94', cc_data type 0x03).
        var hasClosedCaptions: Bool = false
        /// Total bytes of cc_data observed (across all SEI messages in the input).
        var closedCaptionByteCount: Int = 0
        /// HEVC SEI time_code (payload type 136) decoded as "HH:MM:SS:FF".
        var timecode: String?
        /// HEVC alpha_channel_info SEI (payload type 165) — true if alpha is signalled.
        var hasAlphaChannel: Bool = false
    }

    /// Walk an array of SEI NAL RBSPs (emulation-prevention already stripped)
    /// and decode all known payloads. `forHEVC == true` for H.265 streams,
    /// `false` for H.264. SEI message structure is identical between codecs.
    static func parseSEIMessages(_ rbsps: [Data], forHEVC: Bool) -> SEIData {
        var sei = SEIData()
        for rbsp in rbsps {
            parseOneSEINALU(rbsp, forHEVC: forHEVC, into: &sei)
        }
        return sei
    }

    /// Parse a single SEI NAL's RBSP. Multiple SEI messages may share one NAL.
    private static func parseOneSEINALU(_ rbsp: Data, forHEVC: Bool, into sei: inout SEIData) {
        var i = rbsp.startIndex
        let end = rbsp.endIndex
        while i < end {
            // payload_type — 0xFF bytes accumulate, the next byte is the
            // final increment. Same encoding for payload_size.
            var payloadType = 0
            while i < end, rbsp[i] == 0xFF {
                payloadType += 255
                i += 1
            }
            guard i < end else { return }
            payloadType += Int(rbsp[i])
            i += 1

            var payloadSize = 0
            while i < end, rbsp[i] == 0xFF {
                payloadSize += 255
                i += 1
            }
            guard i < end else { return }
            payloadSize += Int(rbsp[i])
            i += 1

            guard i + payloadSize <= end else { return }
            let payload = rbsp.subdata(in: i ..< i + payloadSize)
            i += payloadSize

            decodeSEIPayload(type: payloadType, payload: payload, forHEVC: forHEVC, into: &sei)

            // SEI messages end with rbsp_trailing_bits — typically 0x80. Stop
            // when we hit it cleanly to avoid mis-parsing trailing zero bytes.
            if i < end, rbsp[i] == 0x80 { return }
        }
    }

    private static func decodeSEIPayload(type: Int, payload: Data, forHEVC: Bool, into sei: inout SEIData) {
        switch type {
        case 4:
            // user_data_registered_itu_t_t35 — A/53 closed captions.
            decodeITUTT35(payload, into: &sei)
        case 137:
            // mastering_display_colour_volume.
            sei.masteringDisplay = decodeMDCVPayload(payload) ?? sei.masteringDisplay
        case 144:
            // content_light_level_info.
            sei.contentLightLevel = decodeCLLIPayload(payload) ?? sei.contentLightLevel
        case 147:
            // content_colour_volume (H.265 D.2.41).
            sei.contentColourVolume = decodeCCVPayload(payload) ?? sei.contentColourVolume
        case 148:
            // ambient_viewing_environment (H.265 D.2.44).
            sei.ambientViewingEnvironment = decodeAVEPayload(payload) ?? sei.ambientViewingEnvironment
        case 136 where forHEVC:
            // time_code (HEVC only).
            if let tc = decodeTimeCodePayload(payload) {
                sei.timecode = tc
            }
        case 165 where forHEVC:
            // alpha_channel_info (HEVC RExt).
            sei.hasAlphaChannel = true
        default:
            break
        }
    }

    /// SEI payload type 4 — A/53 closed captions are wrapped in an
    /// itu_t_t35 envelope with country=0xB5 (US), provider=0x0031,
    /// user_identifier='GA94'.
    private static func decodeITUTT35(_ payload: Data, into sei: inout SEIData) {
        guard payload.count >= 9 else { return }
        var p = payload.startIndex
        guard payload[p] == 0xB5 else { return }
        p += 1
        // Skip optional itu_t_t35_country_code_extension_byte.
        if payload[p - 1] == 0xFF {
            guard p < payload.endIndex else { return }
            p += 1
        }
        guard p + 2 <= payload.endIndex else { return }
        let provider = (UInt16(payload[p]) << 8) | UInt16(payload[p + 1])
        p += 2
        guard provider == 0x0031 else { return }
        // user_identifier (4 bytes) — 'GA94' for ATSC A/53.
        guard p + 4 <= payload.endIndex else { return }
        let userID = (UInt32(payload[p]) << 24)
            | (UInt32(payload[p + 1]) << 16)
            | (UInt32(payload[p + 2]) << 8)
            | UInt32(payload[p + 3])
        p += 4
        guard userID == 0x47413934 else { return }
        // user_data_type_code 0x03 = cc_data.
        guard p < payload.endIndex else { return }
        let typeCode = payload[p]
        p += 1
        guard typeCode == 0x03 else { return }
        sei.hasClosedCaptions = true
        sei.closedCaptionByteCount += max(0, payload.endIndex - p)
    }

    /// SEI payload type 137 — mastering_display_colour_volume.
    /// Layout (24 bytes): display_primaries_x[c], y[c] for c=0..2 (G, B, R order
    /// per H.264 D.2.27 / H.265 D.2.27), white_point_x, white_point_y (uint16),
    /// max/min_display_mastering_luminance (uint32, 0.0001 nit units).
    private static func decodeMDCVPayload(_ payload: Data) -> HDRMasteringDisplay? {
        guard payload.count >= 24 else { return nil }
        var reader = BinaryReader(data: payload)
        guard let gx = try? reader.readUInt16BigEndian(),
              let gy = try? reader.readUInt16BigEndian(),
              let bx = try? reader.readUInt16BigEndian(),
              let by = try? reader.readUInt16BigEndian(),
              let rx = try? reader.readUInt16BigEndian(),
              let ry = try? reader.readUInt16BigEndian(),
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

    /// SEI payload type 144 — content_light_level_info (uint16 maxCLL, maxFALL).
    private static func decodeCLLIPayload(_ payload: Data) -> HDRContentLightLevel? {
        guard payload.count >= 4 else { return nil }
        var reader = BinaryReader(data: payload)
        guard let maxCLL = try? reader.readUInt16BigEndian(),
              let maxFALL = try? reader.readUInt16BigEndian() else { return nil }
        return HDRContentLightLevel(maxCLL: Int(maxCLL), maxFALL: Int(maxFALL))
    }

    /// SEI payload type 147 — content_colour_volume (H.265 D.2.41). Layout:
    ///   bit 0:    ccv_cancel_flag
    ///   bits 1..2: persistence_flag, primaries_present_flag
    ///   bits 3..5: min/max/avg luminance_present_flag
    ///   bits 6..7: reserved
    ///   (byte-aligned)
    ///   if primaries_present: 3 × (i32 ccv_primaries_x, i32 ccv_primaries_y) in
    ///     0.00002 CIE 1931 xy units, G/B/R order matching mdcv (H.265 D.2.27).
    ///   if min_lum_present: u32 ccv_min_luminance_value in 0.0001 cd/m²
    ///   if max_lum_present: u32 ccv_max_luminance_value in 0.0001 cd/m²
    ///   if avg_lum_present: u32 ccv_avg_luminance_value in 0.0001 cd/m²
    ///
    /// ccv_cancel_flag = 1 tells decoders to drop any prior CCV — we treat it
    /// as a no-op (nil) so an upstream value isn't overwritten.
    private static func decodeCCVPayload(_ payload: Data) -> HDRContentColourVolume? {
        guard payload.count >= 1 else { return nil }
        let flags = payload[payload.startIndex]
        let cancel = (flags & 0x80) != 0
        if cancel { return nil }
        let primariesPresent = (flags & 0x20) != 0
        let minLumPresent    = (flags & 0x10) != 0
        let maxLumPresent    = (flags & 0x08) != 0
        let avgLumPresent    = (flags & 0x04) != 0

        // Sub-data after the 1 byte of flags is byte-aligned per spec.
        let body = payload.subdata(in: payload.startIndex + 1 ..< payload.endIndex)
        var reader = BinaryReader(data: body)
        let chromaScale = 0.00002
        let lumaScale = 0.0001

        var ccv = HDRContentColourVolume()
        if primariesPresent {
            // G, B, R order per mdcv convention. ccv_primaries_* is i32 in the
            // spec — reinterpret the u32 bit pattern via Int32(bitPattern:).
            guard let gx = try? reader.readUInt32BigEndian(),
                  let gy = try? reader.readUInt32BigEndian(),
                  let bx = try? reader.readUInt32BigEndian(),
                  let by = try? reader.readUInt32BigEndian(),
                  let rx = try? reader.readUInt32BigEndian(),
                  let ry = try? reader.readUInt32BigEndian() else { return nil }
            ccv.greenX = Double(Int32(bitPattern: gx)) * chromaScale
            ccv.greenY = Double(Int32(bitPattern: gy)) * chromaScale
            ccv.blueX  = Double(Int32(bitPattern: bx)) * chromaScale
            ccv.blueY  = Double(Int32(bitPattern: by)) * chromaScale
            ccv.redX   = Double(Int32(bitPattern: rx)) * chromaScale
            ccv.redY   = Double(Int32(bitPattern: ry)) * chromaScale
        }
        if minLumPresent {
            guard let v = try? reader.readUInt32BigEndian() else { return nil }
            ccv.minLuminance = Double(v) * lumaScale
        }
        if maxLumPresent {
            guard let v = try? reader.readUInt32BigEndian() else { return nil }
            ccv.maxLuminance = Double(v) * lumaScale
        }
        if avgLumPresent {
            guard let v = try? reader.readUInt32BigEndian() else { return nil }
            ccv.avgLuminance = Double(v) * lumaScale
        }
        return ccv
    }

    /// SEI payload type 148 — ambient_viewing_environment (H.265 D.2.44). Layout
    /// (8 bytes): ambient_illuminance u32 (0.0001 lux), ambient_light_x u16,
    /// ambient_light_y u16 (both 0.00002 CIE 1931 xy units).
    private static func decodeAVEPayload(_ payload: Data) -> HDRAmbientViewingEnvironment? {
        guard payload.count >= 8 else { return nil }
        var reader = BinaryReader(data: payload)
        guard let illum = try? reader.readUInt32BigEndian(),
              let ax = try? reader.readUInt16BigEndian(),
              let ay = try? reader.readUInt16BigEndian() else { return nil }
        return HDRAmbientViewingEnvironment(
            ambientIlluminance: Double(illum) * 0.0001,
            ambientLightX: Double(ax) * 0.00002,
            ambientLightY: Double(ay) * 0.00002
        )
    }

    /// SEI payload type 136 (HEVC) — time_code. Decode the first clock timestamp
    /// to "HH:MM:SS:FF" form. The full SEI permits up to 3 timestamps; we surface
    /// only the first (matches ffprobe's `side_data_list[].timecode`).
    private static func decodeTimeCodePayload(_ payload: Data) -> String? {
        var br = BitReader(payload)
        guard br.bitsRemaining >= 2 else { return nil }
        let numClockTS = Int(br.read(2))
        guard numClockTS > 0 else { return nil }
        for _ in 0..<numClockTS {
            guard br.bitsRemaining >= 1 else { return nil }
            let clockTimestampFlag = br.readBool()
            guard clockTimestampFlag else { continue }
            guard br.bitsRemaining >= 17 else { return nil }
            _ = br.readBool() // units_field_based_flag
            _ = br.read(5)    // counting_type
            let fullTimestampFlag = br.readBool()
            _ = br.readBool() // discontinuity_flag
            _ = br.readBool() // cnt_dropped_flag
            let nFrames = Int(br.read(9))
            var seconds = 0, minutes = 0, hours = 0
            if fullTimestampFlag {
                seconds = Int(br.read(6))
                minutes = Int(br.read(6))
                hours = Int(br.read(5))
            } else {
                if br.readBool() {
                    seconds = Int(br.read(6))
                    if br.readBool() {
                        minutes = Int(br.read(6))
                        if br.readBool() {
                            hours = Int(br.read(5))
                        }
                    }
                }
            }
            return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, nFrames)
        }
        return nil
    }
}
