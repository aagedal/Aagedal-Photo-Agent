import Foundation

/// Reader for Ogg-container audio files (RFC 3533): Ogg Vorbis (.ogg) and
/// Ogg Opus (.opus).
///
/// Ogg framing: the stream is a sequence of pages. Each page header is
///   "OggS" (4) + version (1) + header_type (1) + granule_position (8) +
///   bitstream_serial (4) + page_sequence (4) + crc (4) + page_segments (1) +
///   segment_table[page_segments]
/// The concatenation of segment_table sums to the page payload length.
/// Logical packets can span multiple pages; we reconstruct the first two
/// packets of a logical stream — the identification header and the comment
/// header — which carry everything we surface as audio metadata.
public struct OggReader: Sendable {

    /// True when the file begins with the Ogg capture pattern.
    public static func isOgg(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x4F && data[s + 1] == 0x67 && data[s + 2] == 0x67 && data[s + 3] == 0x53
    }

    /// Determine whether the first Ogg stream carries Opus, Vorbis or neither.
    /// Inspects the first packet's identification signature.
    public static func detectOggCodec(_ data: Data) -> AudioFormat? {
        guard isOgg(data),
              let firstPage = readFirstPage(data),
              let sig = firstPage.payload.prefix(8).isEmpty ? nil : firstPage.payload
        else { return nil }

        if sig.count >= 8, matchesASCII(sig, "OpusHead") {
            return .opus
        }
        // Vorbis identification packet: 0x01 "vorbis"
        if sig.count >= 7, sig[sig.startIndex] == 0x01,
           matchesASCII(sig.dropFirst(), "vorbis") {
            return .oggVorbis
        }
        return nil
    }

    /// Parse Ogg audio data into an `AudioMetadata`. The caller supplies the
    /// pre-detected format so we avoid re-sniffing.
    public static func parse(_ data: Data, format: AudioFormat) throws -> AudioMetadata {
        guard isOgg(data) else {
            throw MetadataError.unsupportedFormat
        }

        // Collect logical packets for the *first* bitstream by reassembling
        // segments across pages. Almost every real-world file has a single
        // bitstream; chained/multiplexed files would need per-serial tracking
        // which we don't need for audio metadata.
        let (packets, lastGranule) = collectFirstBitstreamPackets(data, maxPackets: 3)

        var metadata = AudioMetadata(format: format)

        switch format {
        case .opus:
            var preSkip: Double = 0
            if packets.count >= 1 {
                preSkip = parseOpusHeader(packets[0], into: &metadata) ?? 0
            }
            if packets.count >= 2 {
                parseOpusTags(packets[1], into: &metadata)
            }
            // Opus decodes at 48 kHz regardless of input sample rate; duration
            // is (last_granule − preskip) / 48 000.
            if lastGranule > 0 {
                let samples = Double(lastGranule) - preSkip
                metadata.duration = max(0, samples) / 48000.0
            }
            metadata.codec = "opus"
            metadata.codecName = "Opus"

        case .oggVorbis:
            if packets.count >= 1 {
                parseVorbisIDHeader(packets[0], into: &metadata)
            }
            if packets.count >= 2 {
                parseVorbisComment(packets[1], into: &metadata)
            }
            if lastGranule > 0, let rate = metadata.sampleRate, rate > 0 {
                metadata.duration = Double(lastGranule) / Double(rate)
            }
            metadata.codec = "vorbis"
            metadata.codecName = "Vorbis"

        default:
            throw MetadataError.unsupportedFormat
        }

        return metadata
    }

    // MARK: - Ogg framing

    private struct OggPage {
        var serial: UInt32
        var sequence: UInt32
        var granule: Int64
        var headerType: UInt8
        var segmentTable: [UInt8]
        var payload: Data
        var nextOffset: Int
    }

    private static func readPage(_ data: Data, at offset: Int) -> OggPage? {
        guard offset + 27 <= data.count else { return nil }
        let s = data.startIndex + offset
        guard data[s] == 0x4F && data[s + 1] == 0x67 && data[s + 2] == 0x67 && data[s + 3] == 0x53 else {
            return nil
        }

        let headerType = data[s + 5]

        // granule_position is a little-endian signed 64 — values of
        // 0xFFFF_FFFF_FFFF_FFFF mean "no granule" for the page.
        var granule: Int64 = 0
        for i in 0..<8 {
            granule |= Int64(data[s + 6 + i]) << (8 * i)
        }

        let serial = readUInt32LE(data, at: offset + 14)
        let sequence = readUInt32LE(data, at: offset + 18)

        let pageSegments = Int(data[s + 26])
        guard offset + 27 + pageSegments <= data.count else { return nil }

        var segmentTable = [UInt8](repeating: 0, count: pageSegments)
        var payloadSize = 0
        for i in 0..<pageSegments {
            let v = data[s + 27 + i]
            segmentTable[i] = v
            payloadSize += Int(v)
        }

        let payloadStart = offset + 27 + pageSegments
        guard payloadStart + payloadSize <= data.count else { return nil }
        let payload = data[data.startIndex + payloadStart ..< data.startIndex + payloadStart + payloadSize]
        return OggPage(
            serial: serial,
            sequence: sequence,
            granule: granule,
            headerType: headerType,
            segmentTable: segmentTable,
            payload: Data(payload),
            nextOffset: payloadStart + payloadSize
        )
    }

    private static func readFirstPage(_ data: Data) -> OggPage? {
        readPage(data, at: 0)
    }

    /// Reconstruct the first `maxPackets` logical packets of the first
    /// bitstream and find the last granule position seen for that stream.
    ///
    /// Logical packet boundaries: a packet ends when a segment is shorter than
    /// 255 bytes (or when the page's segment table runs out with a full-255
    /// terminator, in which case the packet continues to the next page).
    private static func collectFirstBitstreamPackets(_ data: Data, maxPackets: Int)
        -> (packets: [Data], lastGranule: Int64)
    {
        var packets: [Data] = []
        var current = Data()
        var bitstreamSerial: UInt32?
        var lastGranule: Int64 = 0
        var offset = 0

        // Walk forward to assemble packets. Stop early once we have enough.
        while offset < data.count, packets.count < maxPackets {
            guard let page = readPage(data, at: offset) else { break }
            if bitstreamSerial == nil {
                bitstreamSerial = page.serial
            }
            if page.serial != bitstreamSerial {
                offset = page.nextOffset
                continue
            }

            var segStart = 0
            for (i, segLen) in page.segmentTable.enumerated() {
                let n = Int(segLen)
                let slice = page.payload[page.payload.startIndex + segStart ..< page.payload.startIndex + segStart + n]
                current.append(Data(slice))
                segStart += n

                let isLastSegment = (i == page.segmentTable.count - 1)
                if segLen < 255 {
                    packets.append(current)
                    current = Data()
                    if packets.count >= maxPackets { break }
                } else if isLastSegment {
                    // Packet continues on next page — keep accumulating.
                }
            }

            offset = page.nextOffset
        }

        // Scan the tail of the file for the last granule of our bitstream.
        // This is cheap with memory-mapped Data: we only read a few final
        // pages. We walk backwards until we hit our serial.
        lastGranule = findLastGranule(data, serial: bitstreamSerial) ?? 0

        return (packets, lastGranule)
    }

    /// Scan backwards from the end of the file for the last page belonging to
    /// `serial` and return its granule. We search the last 64 KB — enough for
    /// even very short trailing pages.
    private static let tailScanWindow = 64 * 1024

    private static func findLastGranule(_ data: Data, serial: UInt32?) -> Int64? {
        guard let serial else { return nil }
        let tailStart = max(0, data.count - tailScanWindow)
        let tail = data.suffix(from: data.startIndex + tailStart)
        let needle = Data("OggS".utf8)
        var found: Int64?

        var searchFrom = tail.startIndex
        while searchFrom < tail.endIndex {
            guard let range = tail.range(of: needle, in: searchFrom..<tail.endIndex) else { break }
            let absOffset = range.lowerBound - data.startIndex
            if let page = readPage(data, at: absOffset), page.serial == serial {
                // The last page for this stream always carries a real granule
                // (unlike mid-stream spanning pages which may be -1).
                if page.granule >= 0 {
                    found = page.granule
                }
            }
            searchFrom = tail.index(after: range.lowerBound)
        }
        return found
    }

    // MARK: - Opus parsing

    /// OpusHead layout (RFC 7845, §5.1):
    ///   magic "OpusHead" (8)
    ///   version (1) — top bit reserved, low nibble must be 1
    ///   channelCount (1)
    ///   preSkip (2, little-endian)
    ///   inputSampleRate (4, little-endian, 0 = "unknown")
    ///   outputGain (2)
    ///   channelMappingFamily (1)
    ///   [channel mapping table if family != 0]
    ///
    /// Returns the preskip value (48 kHz samples) so the caller can subtract
    /// it from the stream's last granule when computing duration.
    private static func parseOpusHeader(_ packet: Data, into m: inout AudioMetadata) -> Double? {
        guard packet.count >= 19, matchesASCII(packet.prefix(8), "OpusHead") else { return nil }
        let s = packet.startIndex
        let channels = Int(packet[s + 9])
        let preSkip = Int(packet[s + 10]) | (Int(packet[s + 11]) << 8)
        let inputRate = readUInt32LE(packet, at: 12)
        let family = packet[s + 18]

        m.channels = channels
        // Opus always decodes to 48 kHz; `inputRate` is informational only.
        // Report inputRate when advertised so it matches the upstream source.
        m.sampleRate = inputRate > 0 ? Int(inputRate) : 48000

        // Synthesize a channel layout for family 0 (mono / stereo) and family
        // 1 (Vorbis-order surround layouts). We don't decode the full mapping
        // table because audio metadata consumers just want a readable name.
        m.channelLayout = opusChannelLayout(family: family, channels: channels)
        return Double(preSkip)
    }

    /// OpusTags layout: magic "OpusTags" (8) + Vorbis-style comment block.
    private static func parseOpusTags(_ packet: Data, into m: inout AudioMetadata) {
        guard packet.count >= 8, matchesASCII(packet.prefix(8), "OpusTags") else { return }
        let commentBlock = packet.dropFirst(8)
        if let parsed = try? VorbisComment.parse(Data(commentBlock)) {
            applyVorbisComments(parsed, into: &m)
        }
    }

    private static func opusChannelLayout(family: UInt8, channels: Int) -> String? {
        // Family 0: mono/stereo. Family 1: Vorbis surround (1–8 channels).
        // Other families (2+) are experimental; we fall back to a count label.
        guard family == 0 || family == 1 else {
            return channels > 0 ? "\(channels) channels" : nil
        }
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "3.0"
        case 4: return "quad"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return channels > 0 ? "\(channels) channels" : nil
        }
    }

    // MARK: - Vorbis parsing

    /// Vorbis identification header (RFC 3534 + Vorbis I spec §4.2.2):
    ///   packet_type (1) = 0x01
    ///   "vorbis" (6)
    ///   vorbis_version (4)
    ///   audio_channels (1)
    ///   audio_sample_rate (4)
    ///   bitrate_maximum (4, signed)
    ///   bitrate_nominal (4, signed)
    ///   bitrate_minimum (4, signed)
    ///   blocksize_0 (4 bits) + blocksize_1 (4 bits)
    ///   framing_flag (1 bit)
    private static func parseVorbisIDHeader(_ packet: Data, into m: inout AudioMetadata) {
        guard packet.count >= 30,
              packet[packet.startIndex] == 0x01,
              matchesASCII(packet.dropFirst().prefix(6), "vorbis") else { return }
        // packet_type(1) + magic(6) + version(4) = 11 bytes skip
        let channels = Int(packet[packet.startIndex + 11])
        let sampleRate = Int(readUInt32LE(packet, at: 12))
        let bitrateMaxRaw = Int32(bitPattern: readUInt32LE(packet, at: 16))
        let bitrateNominal = Int32(bitPattern: readUInt32LE(packet, at: 20))
        let bitrateMin = Int32(bitPattern: readUInt32LE(packet, at: 24))

        m.channels = channels
        m.sampleRate = sampleRate

        // Vorbis is VBR by design. Prefer nominal; fall back to a midpoint
        // between min and max when nominal is missing.
        if bitrateNominal > 0 {
            m.bitrate = Int(bitrateNominal)
        } else if bitrateMin > 0, bitrateMaxRaw > 0 {
            m.bitrate = Int(bitrateMin + bitrateMaxRaw) / 2
        }

        m.channelLayout = vorbisChannelLayout(channels: channels)
    }

    /// Vorbis comment header: packet_type(1)=0x03 + "vorbis"(6) + comment block + framing bit.
    private static func parseVorbisComment(_ packet: Data, into m: inout AudioMetadata) {
        guard packet.count > 7,
              packet[packet.startIndex] == 0x03,
              matchesASCII(packet.dropFirst().prefix(6), "vorbis") else { return }
        let commentBlock = packet.dropFirst(7)
        // Drop the trailing framing bit (1 byte = 0x01) if present.
        var block = Data(commentBlock)
        if block.last == 0x01 { block = block.dropLast() }
        if let parsed = try? VorbisComment.parse(block) {
            applyVorbisComments(parsed, into: &m)
        }
    }

    private static func vorbisChannelLayout(channels: Int) -> String? {
        // Vorbis I specifies channel order for 1–8 channels.
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "3.0"
        case 4: return "quad"
        case 5: return "5.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return channels > 0 ? "\(channels) channels" : nil
        }
    }

    // MARK: - Vorbis comments → AudioMetadata

    private static func applyVorbisComments(_ vc: VorbisComment, into m: inout AudioMetadata) {
        m.title = m.title ?? vc.value(for: "TITLE")
        m.artist = m.artist ?? vc.value(for: "ARTIST")
        m.album = m.album ?? vc.value(for: "ALBUM")
        m.year = m.year ?? vc.value(for: "DATE")
        m.genre = m.genre ?? vc.value(for: "GENRE")
        m.comment = m.comment ?? (vc.value(for: "COMMENT") ?? vc.value(for: "DESCRIPTION"))
        m.albumArtist = m.albumArtist ?? vc.value(for: "ALBUMARTIST")
        m.composer = m.composer ?? vc.value(for: "COMPOSER")
        if m.trackNumber == nil, let t = vc.value(for: "TRACKNUMBER") { m.trackNumber = Int(t) }
        if m.discNumber == nil, let d = vc.value(for: "DISCNUMBER") { m.discNumber = Int(d) }
    }

    // MARK: - Helpers

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex
        return UInt32(data[s + offset])
            | UInt32(data[s + offset + 1]) << 8
            | UInt32(data[s + offset + 2]) << 16
            | UInt32(data[s + offset + 3]) << 24
    }

    private static func matchesASCII<S: DataProtocol>(_ slice: S, _ ascii: String) -> Bool {
        let expected = Array(ascii.utf8)
        guard slice.count >= expected.count else { return false }
        var it = slice.makeIterator()
        for b in expected {
            guard let got = it.next(), got == b else { return false }
        }
        return true
    }
}

