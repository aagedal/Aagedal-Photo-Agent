import Foundation

/// Audio `stsd` SampleEntry parsing for MP4Parser: the QuickTime V0/V1/V2
/// sound description, channel layouts (`chan`), and the MP4 Elementary
/// Stream Descriptor (`esds`) average bit-rate / AAC profile fields.
///
/// Extracted from MP4Parser.swift to keep that file scannable. No behavior
/// change — `private static` helpers that were file-local in the source
/// are now `static` so they're reachable from this extension across files.
extension MP4Parser {

    // MARK: - Audio sample entry

    /// QuickTime / ISO audio sample entry. The layout branches on a Version
    /// field in the QuickTime-specific header: Version 0 is the common case
    /// (plain PCM or compressed audio), Version 1 adds sound-description
    /// extensions used by variable-bitrate formats, and Version 2 is the
    /// full QuickTime "Sound Description V2" used by high-bit-depth LPCM.
    static func parseAudioSampleEntry(_ stsdData: Data, into stream: inout AudioStream) {
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

        // Skip reserved(6) + data_reference_index(2).
        guard (try? reader.skip(8)) != nil else { return }

        // QuickTime audio sample entries all start with a Version field; ISO
        // files leave this as 0. The layout *after* Version differs per version.
        guard let soundVersion = try? reader.readUInt16BigEndian() else { return }
        _ = try? reader.readUInt16BigEndian() // revision_level
        _ = try? reader.readUInt32BigEndian() // vendor

        var channels = 0
        var sampleRate = 0
        var bitDepth = 0

        if soundVersion == 0 || soundVersion == 1 {
            // V0 layout (also the ISO layout):
            //   channelcount(2) + samplesize(2) + pre_defined(2) + reserved(2)
            //   + samplerate (32-bit fixed-point, Hz << 16)
            let ch = (try? reader.readUInt16BigEndian()) ?? 0
            let ss = (try? reader.readUInt16BigEndian()) ?? 0
            _ = try? reader.readUInt16BigEndian() // pre_defined/compression_id
            _ = try? reader.readUInt16BigEndian() // packet_size
            let sampleRateFP = (try? reader.readUInt32BigEndian()) ?? 0
            channels = Int(ch)
            bitDepth = Int(ss)
            sampleRate = Int(sampleRateFP >> 16)

            // V1 appends 16 bytes of compressed-sound extensions; skip them
            // so we land at the start of any child boxes.
            if soundVersion == 1 {
                _ = try? reader.skip(16)
            }
        } else if soundVersion == 2 {
            // V2 Sound Description (QuickTime File Format Reference). After
            // version/revision/vendor the layout is 16 bytes of constants
            // (repurposing V0's 16–27 slots with magic values) plus the
            // V2-specific fields:
            //   always_3(2) + always_16(2) + always_-2(2) + reserved(2)
            //   + always_65536(4) + sizeOfStructOnly(4)
            //   + audioSampleRate(Float64)
            //   + numAudioChannels(4) + always_0x7F000000(4)
            //   + constBitsPerChannel(4) + formatSpecificFlags(4)
            //   + constBytesPerAudioPacket(4) + constLPCMFramesPerAudioPacket(4)
            _ = try? reader.readUInt16BigEndian() // always_3
            _ = try? reader.readUInt16BigEndian() // always_16
            _ = try? reader.readUInt16BigEndian() // always_-2 (Int16, read as bits)
            _ = try? reader.readUInt16BigEndian() // reserved
            _ = try? reader.readUInt32BigEndian() // always_65536
            _ = try? reader.readUInt32BigEndian() // sizeOfStructOnly

            let sr64 = (try? reader.readUInt64BigEndian()) ?? 0
            let channels32 = (try? reader.readUInt32BigEndian()) ?? 0
            _ = try? reader.readUInt32BigEndian() // always_0x7F000000
            let bitsPerChannel = (try? reader.readUInt32BigEndian()) ?? 0
            _ = try? reader.readUInt32BigEndian() // formatSpecificFlags
            _ = try? reader.readUInt32BigEndian() // constBytesPerAudioPacket
            _ = try? reader.readUInt32BigEndian() // constLPCMFramesPerAudioPacket

            let srDouble = Double(bitPattern: sr64)
            if srDouble.isFinite, srDouble > 0, srDouble < Double(Int.max) {
                sampleRate = Int(srDouble)
            }
            channels = Int(channels32)
            bitDepth = Int(bitsPerChannel)
        } else {
            // Unknown version — bail out before we read bogus fields.
            return
        }

        if channels > 0 { stream.channels = channels }
        if sampleRate > 0 { stream.sampleRate = sampleRate }
        if bitDepth > 0 { stream.bitDepth = bitDepth }

        // Now scan child boxes for `chan` (channel layout), `esds`/`dOps` (codec
        // config), and `btrt` (bit rate).
        let entryEnd = entryStart + Int(entrySize32)
        guard reader.offset < entryEnd, entryEnd <= stsdData.count else { return }
        let childrenData = Data(
            stsdData[(stsdData.startIndex + reader.offset) ..< (stsdData.startIndex + entryEnd)]
        )
        if let kids = try? ISOBMFFBoxReader.parseBoxes(from: childrenData) {
            for kid in kids {
                switch kid.type {
                case "chan":
                    if let layout = parseCHAN(kid.data) {
                        stream.channelLayout = layout
                    }
                case "btrt":
                    if let br = parseBTRT(kid.data) {
                        stream.bitRate = br
                    }
                case "esds":
                    // MPEG-4 Elementary Stream Descriptor: average bit rate
                    // (DecoderConfigDescriptor) + AOT-derived profile name
                    // (DecoderSpecificInfo).
                    if let br = parseESDSAvgBitRate(kid.data) {
                        stream.bitRate = br
                    }
                    if stream.codec == "mp4a", stream.profile == nil,
                       let profile = parseESDSAACProfile(kid.data) {
                        stream.profile = profile
                    }
                default:
                    break
                }
            }
        }

        // If we still have no channel layout but `channels` is a standard
        // value, synthesize a sensible label (matches ffprobe's default).
        if stream.channelLayout == nil, let ch = stream.channels {
            stream.channelLayout = defaultChannelLayout(forChannels: ch)
        }

        // AAC profile fallback: when esds didn't surface DecoderSpecificInfo,
        // default to "LC" (the overwhelming majority of mp4a streams). ffprobe
        // does the equivalent: when avcodec can't decode the AOT it shows the
        // codec as plain `aac` with no profile, but every iPhone / Android
        // recorder we care about emits LC.
        if stream.codec == "mp4a", stream.profile == nil {
            stream.profile = "LC"
        }
    }

    /// QuickTime `chan` (ChannelLayoutBox) — FullBox(version, flags) then:
    ///   channelLayoutTag(4) + channelBitmap(4) + numberChannelDescriptions(4) + [descriptor…]
    /// Rather than maintaining a 240-entry layout tag table, we translate the
    /// most common layouts camera and editing workflows produce.
    static func parseCHAN(_ data: Data) -> String? {
        guard data.count >= 16 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // FullBox header
        guard let tag = try? reader.readUInt32BigEndian() else { return nil }
        _ = try? reader.readUInt32BigEndian() // channelBitmap (when tag == UseChannelBitmap)
        _ = try? reader.readUInt32BigEndian() // numberChannelDescriptions

        // CoreAudio channel layout tags — the top 16 bits identify the family;
        // the low 16 bits store a channel count for kAudioChannelLayoutTag_Mono/Stereo/… .
        switch tag {
        case 0x64_0001: return "mono"          // Mono
        case 0x65_0002: return "stereo"        // Stereo
        case 0x66_0002: return "stereo-headphones"
        case 0x67_0004: return "4.0"           // Quadraphonic
        case 0x6C_0005: return "5.0"           // MPEG 5.0 B
        case 0x81_0006: return "5.1"           // MPEG 5.1 D
        case 0xAF_0008: return "7.1"           // AAC 7.1
        default:
            // Families that embed the channel count in the low 16 bits.
            let family = tag >> 16
            let count = Int(tag & 0xFFFF)
            if family == 0x0064, count == 1 { return "mono" }
            if family == 0x0065, count == 2 { return "stereo" }
            if count > 0 { return defaultChannelLayout(forChannels: count) }
            return nil
        }
    }

    /// Parse the MP4 Elementary Stream Descriptor for an audio track's
    /// average bit rate. Layout: [ES_Descriptor tag(1) + length(varint)]
    /// ES_ID(2) + flags(1) + [stream_dependence/URL/OCR data] +
    /// DecoderConfigDescriptor tag(1) + length(varint) + objectTypeIndication(1) +
    /// streamType+upStream+reserved(1) + bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4).
    /// Here we do the minimum: locate 0x04 (DecoderConfigDescriptor) and read
    /// fields at the known offsets.
    static func parseESDSAvgBitRate(_ data: Data) -> Int? {
        // Skip FullBox header.
        guard data.count > 4 else { return nil }
        let payload = data.suffix(from: data.startIndex + 4)
        // Find the DecoderConfigDescriptor (tag 0x04) which holds the bitrates.
        for i in payload.startIndex..<payload.endIndex {
            if payload[i] == 0x04, i + 1 < payload.endIndex {
                // Next bytes are a variable-length size (1–4 bytes, each with MSB
                // flag). Skip it.
                var off = i + 1
                var seen = 0
                while off < payload.endIndex && seen < 4 {
                    let b = payload[off]
                    off += 1; seen += 1
                    if (b & 0x80) == 0 { break }
                }
                // DecoderConfigDescriptor body: objType(1) + stream+flags(1) +
                // bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4).
                guard off + 13 <= payload.endIndex else { return nil }
                let mb = UInt32(payload[off + 5]) << 24
                    | UInt32(payload[off + 6]) << 16
                    | UInt32(payload[off + 7]) << 8
                    | UInt32(payload[off + 8])
                let ab = UInt32(payload[off + 9]) << 24
                    | UInt32(payload[off + 10]) << 16
                    | UInt32(payload[off + 11]) << 8
                    | UInt32(payload[off + 12])
                if ab > 0 { return Int(ab) }
                if mb > 0 { return Int(mb) }
                return nil
            }
        }
        return nil
    }

    /// Pull the MPEG-4 audio object type out of an `esds` box and map it to the
    /// short profile labels ffprobe reports (`LC`, `HE-AAC`, `HE-AACv2`, `LD`).
    /// Layout: ES_Descriptor (tag 0x03) → DecoderConfigDescriptor (0x04) →
    /// DecoderSpecificInfo (0x05) whose first 5 bits are the audio object type.
    static func parseESDSAACProfile(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let payload = data.suffix(from: data.startIndex + 4)
        // Locate the DecoderSpecificInfo descriptor (tag 0x05) directly — its
        // payload begins with the AudioObjectType packed in the high 5 bits.
        var i = payload.startIndex
        while i < payload.endIndex {
            if payload[i] == 0x05, i + 1 < payload.endIndex {
                var off = i + 1
                var size = 0
                var seen = 0
                while off < payload.endIndex, seen < 4 {
                    let b = payload[off]
                    size = (size << 7) | Int(b & 0x7F)
                    off += 1; seen += 1
                    if (b & 0x80) == 0 { break }
                }
                guard size >= 1, off < payload.endIndex else { return nil }
                let aot = Int(payload[off] >> 3) & 0x1F
                switch aot {
                case 1: return "Main"
                case 2: return "LC"
                case 3: return "SSR"
                case 4: return "LTP"
                case 5: return "HE-AAC"
                case 6: return "Scalable"
                case 7: return "TwinVQ"
                case 17: return "ER LC"
                case 19: return "ER LTP"
                case 23: return "LD"
                case 29: return "HE-AACv2"
                case 39: return "ELD"
                default: return nil
                }
            }
            i += 1
        }
        return nil
    }

    /// ffprobe-style default channel layout for a given count. We use these
    /// names for consistency with the rest of the AV ecosystem.
    static func defaultChannelLayout(forChannels n: Int) -> String? {
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
}
