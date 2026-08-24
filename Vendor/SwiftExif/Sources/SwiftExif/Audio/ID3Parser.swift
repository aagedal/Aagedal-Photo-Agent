import Foundation

/// Parse ID3v2/v1 metadata tags from MP3 files.
public struct ID3Parser: Sendable {

    /// Parse an MP3 file and extract metadata from ID3 tags.
    public static func parse(_ data: Data) throws -> AudioMetadata {
        var metadata = AudioMetadata(format: .mp3)
        metadata.codec = "mp3"
        metadata.codecName = "MP3"

        // Try ID3v2 first
        var firstFrameOffset = 0
        if data.count >= 10 && data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 {
            try parseID3v2(data, into: &metadata)
            // ID3v2 header size is syncsafe in bytes 6..9; the MPEG audio frame
            // starts right after the tag.
            let tagSize = decodeSyncsafe(data[6], data[7], data[8], data[9])
            firstFrameOffset = min(10 + tagSize, data.count)
        }

        // Fallback/supplement with ID3v1
        if data.count >= 128 {
            parseID3v1(data, into: &metadata)
        }

        // Audio-frame derived facts: sample rate, channels, bitrate, duration.
        parseFirstAudioFrame(data, from: firstFrameOffset, into: &metadata)

        return metadata
    }

    // MARK: - MPEG audio frame header

    /// Walk forward from `offset` looking for a valid MPEG audio frame sync
    /// word (FFF…). Decode the first frame we find to extract stream-level
    /// facts. The cost is bounded — we search a small window.
    private static let frameScanWindow = 64 * 1024

    private static func parseFirstAudioFrame(_ data: Data, from offset: Int, into metadata: inout AudioMetadata) {
        let end = min(data.count - 4, offset + frameScanWindow)
        guard offset >= 0, offset < end else { return }

        var i = offset
        while i < end {
            let b0 = data[data.startIndex + i]
            let b1 = data[data.startIndex + i + 1]
            if b0 == 0xFF && (b1 & 0xE0) == 0xE0 {
                let b2 = data[data.startIndex + i + 2]
                let b3 = data[data.startIndex + i + 3]
                if let info = decodeMPEGFrameHeader(b0, b1, b2, b3) {
                    metadata.sampleRate = info.sampleRate
                    metadata.channels = info.channels
                    metadata.bitrate = info.bitrate
                    switch info.layer {
                    case 1: metadata.codecName = "MPEG Layer I"
                    case 2: metadata.codecName = "MP2"
                    case 3: metadata.codecName = "MP3"
                    default: break
                    }
                    // Approximate duration from (file_size - offset) / (bitrate/8).
                    // Accurate VBR files populate this via the Xing/Info frame,
                    // which is out of scope here.
                    if info.bitrate > 0 {
                        let audioBytes = Double(data.count - i)
                        metadata.duration = audioBytes / (Double(info.bitrate) / 8)
                    }
                    return
                }
            }
            i += 1
        }
    }

    private struct MPEGFrameInfo {
        let layer: Int       // 1, 2, 3
        let bitrate: Int     // bps
        let sampleRate: Int  // Hz
        let channels: Int
    }

    private static let bitrateTable: [[[Int]]] = [
        // [version_index][layer_index][bitrate_index] → kbps
        // version: 0=MPEG-1, 1=MPEG-2/2.5
        // layer:   0=Layer I, 1=Layer II, 2=Layer III
        // Entries below are kbps; 0 means "free" (not supported here), -1 means reserved.
        [ // MPEG-1
            [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, -1],
            [0, 32, 48, 56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320, 384, -1],
            [0, 32, 40, 48,  56,  64,  80,  96, 112, 128, 160, 192, 224, 256, 320, -1],
        ],
        [ // MPEG-2 / MPEG-2.5
            [0, 32, 48, 56,  64,  80,  96, 112, 128, 144, 160, 176, 192, 224, 256, -1],
            [0,  8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160, -1],
            [0,  8, 16, 24,  32,  40,  48,  56,  64,  80,  96, 112, 128, 144, 160, -1],
        ],
    ]

    /// MPEG audio frame header (4 bytes):
    ///   b0         sync byte (0xFF)
    ///   b1[7..5]   sync (111)
    ///   b1[4..3]   version (00=MPEG-2.5, 10=MPEG-2, 11=MPEG-1)
    ///   b1[2..1]   layer   (01=III, 10=II, 11=I)
    ///   b1[0]      protection
    ///   b2[7..4]   bitrate index
    ///   b2[3..2]   sampling frequency index
    ///   b2[1]      padding
    ///   b3[7..6]   channel mode (00=stereo,01=joint,10=dual,11=mono)
    private static func decodeMPEGFrameHeader(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> MPEGFrameInfo? {
        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        let bitrateIdx = Int((b2 >> 4) & 0x0F)
        let freqIdx = Int((b2 >> 2) & 0x03)
        let channelMode = (b3 >> 6) & 0x03

        guard versionBits != 0x01 else { return nil } // reserved
        guard layerBits != 0x00 else { return nil }   // reserved
        guard bitrateIdx > 0, bitrateIdx < 15 else { return nil }
        guard freqIdx != 3 else { return nil }

        let versionIndex = versionBits == 0x03 ? 0 : 1 // MPEG-1 vs MPEG-2/2.5
        let layer: Int
        let layerIndex: Int
        switch layerBits {
        case 0x03: layer = 1; layerIndex = 0
        case 0x02: layer = 2; layerIndex = 1
        case 0x01: layer = 3; layerIndex = 2
        default: return nil
        }

        let kbps = bitrateTable[versionIndex][layerIndex][bitrateIdx]
        guard kbps > 0 else { return nil }

        // Sample rate tables (Hz).
        let mpeg1Rates = [44100, 48000, 32000]
        let mpeg2Rates = [22050, 24000, 16000]
        let mpeg25Rates = [11025, 12000, 8000]
        let sampleRate: Int
        switch versionBits {
        case 0x03: sampleRate = mpeg1Rates[freqIdx]
        case 0x02: sampleRate = mpeg2Rates[freqIdx]
        case 0x00: sampleRate = mpeg25Rates[freqIdx]
        default: return nil
        }

        let channels = channelMode == 0x03 ? 1 : 2
        return MPEGFrameInfo(layer: layer, bitrate: kbps * 1000, sampleRate: sampleRate, channels: channels)
    }

    // MARK: - ID3v2

    private static func parseID3v2(_ data: Data, into metadata: inout AudioMetadata) throws {
        // Header: "ID3" (3) + version major (1) + version minor (1) + flags (1) + size (4)
        guard data.count >= 10 else { return }

        let versionMajor = Int(data[3])
        // let versionMinor = Int(data[4])
        // let flags = data[5]
        let tagSize = decodeSyncsafe(data[6], data[7], data[8], data[9])

        guard versionMajor >= 2 && versionMajor <= 4 else {
            throw MetadataError.invalidMP3("Unsupported ID3v2 version: \(versionMajor)")
        }

        let headerSize = 10
        let endOffset = min(headerSize + tagSize, data.count)

        var offset = headerSize

        while offset + 10 <= endOffset {
            // Frame header: ID (4) + size (4) + flags (2) for v2.3/v2.4
            let frameID: String
            let frameSize: Int

            if versionMajor >= 3 {
                guard offset + 10 <= endOffset else { break }
                guard let id = String(data: data[offset..<offset + 4], encoding: .ascii) else { break }
                frameID = id

                if versionMajor == 4 {
                    frameSize = decodeSyncsafe(data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7])
                } else {
                    frameSize = Int(data[offset + 4]) << 24 | Int(data[offset + 5]) << 16 |
                                Int(data[offset + 6]) << 8 | Int(data[offset + 7])
                }

                offset += 10  // Skip header
            } else {
                // ID3v2.2: 3-byte ID + 3-byte size
                guard offset + 6 <= endOffset else { break }
                guard let id = String(data: data[offset..<offset + 3], encoding: .ascii) else { break }
                frameID = id
                frameSize = Int(data[offset + 3]) << 16 | Int(data[offset + 4]) << 8 | Int(data[offset + 5])
                offset += 6
            }

            // Validate
            guard frameSize > 0, offset + frameSize <= endOffset else { break }

            // Null frame ID means padding
            if frameID.hasPrefix("\0") { break }

            let frameData = Data(data[offset..<offset + frameSize])
            offset += frameSize

            // Map frame IDs (v2.3/v2.4, with v2.2 aliases)
            switch frameID {
            case "TIT2", "TT2":
                metadata.title = metadata.title ?? decodeTextFrame(frameData)
            case "TPE1", "TP1":
                metadata.artist = metadata.artist ?? decodeTextFrame(frameData)
            case "TALB", "TAL":
                metadata.album = metadata.album ?? decodeTextFrame(frameData)
            case "TRCK", "TRK":
                if let text = decodeTextFrame(frameData) {
                    // May be "3/12" format
                    let parts = text.split(separator: "/")
                    metadata.trackNumber = metadata.trackNumber ?? Int(parts.first ?? "")
                }
            case "TPOS", "TPA":
                if let text = decodeTextFrame(frameData) {
                    let parts = text.split(separator: "/")
                    metadata.discNumber = metadata.discNumber ?? Int(parts.first ?? "")
                }
            case "TDRC", "TYER", "TYE":
                metadata.year = metadata.year ?? decodeTextFrame(frameData)
            case "TCON", "TCO":
                if let text = decodeTextFrame(frameData) {
                    // May contain numeric genre ID like "(13)" or "(13)Pop"
                    metadata.genre = metadata.genre ?? cleanGenre(text)
                }
            case "TPE2":
                metadata.albumArtist = metadata.albumArtist ?? decodeTextFrame(frameData)
            case "TCOM", "TCM":
                metadata.composer = metadata.composer ?? decodeTextFrame(frameData)
            case "COMM", "COM":
                if metadata.comment == nil {
                    metadata.comment = decodeCommentFrame(frameData)
                }
            case "APIC", "PIC":
                if metadata.coverArt == nil {
                    metadata.coverArt = extractAPIC(frameData)
                }
            case "TXXX", "TXX":
                if let pair = decodeUserTextFrame(frameData) {
                    metadata.userTextFrames[pair.description] = pair.value
                }
            case "WXXX", "WXX":
                if let pair = decodeUserURLFrame(frameData) {
                    metadata.userURLFrames[pair.description] = pair.url
                }
            case "WCOM", "WCM",
                 "WCOP", "WCP",
                 "WOAF", "WAF",
                 "WOAR", "WAR",
                 "WOAS", "WAS",
                 "WORS",
                 "WPAY",
                 "WPUB", "WPB":
                // Standard URL frames have no encoding byte — body is ISO-Latin-1 ASCII.
                if let url = String(data: frameData, encoding: .isoLatin1)?
                    .trimmingCharacters(in: .controlCharacters)
                    .trimmingCharacters(in: .whitespaces),
                   !url.isEmpty {
                    metadata.urlFrames[frameID] = url
                }
            case "PRIV":
                if let priv = decodePRIVFrame(frameData) {
                    metadata.privateFrames.append(priv)
                }
            case "GEOB", "GEO":
                if let obj = decodeGEOBFrame(frameData) {
                    metadata.attachedObjects.append(obj)
                }
            case "CHAP":
                if let chap = decodeCHAPFrame(frameData) {
                    metadata.chapters.append(chap)
                }
            case "CTOC":
                if let toc = decodeCTOCFrame(frameData) {
                    metadata.chapterTOCs.append(toc)
                }
            default:
                break
            }
        }
    }

    // MARK: - Extended Frame Decoders

    /// TXXX: encoding (1) + description (null-terminated) + value (rest).
    private static func decodeUserTextFrame(_ data: Data) -> (description: String, value: String)? {
        guard !data.isEmpty else { return nil }
        let encoding = data[data.startIndex]
        let body = data.dropFirst()
        guard let split = splitOnNullTerminator(body, encoding: encoding) else { return nil }
        let description = decodeString(split.head, encoding: encoding) ?? ""
        let value = decodeString(split.tail, encoding: encoding) ?? ""
        if description.isEmpty && value.isEmpty { return nil }
        return (description, value)
    }

    /// WXXX: encoding (1) + description (null-terminated, encoding-aware) + URL (ISO-Latin-1, null-terminated).
    private static func decodeUserURLFrame(_ data: Data) -> (description: String, url: String)? {
        guard !data.isEmpty else { return nil }
        let encoding = data[data.startIndex]
        let body = data.dropFirst()
        guard let split = splitOnNullTerminator(body, encoding: encoding) else { return nil }
        let description = decodeString(split.head, encoding: encoding) ?? ""
        // URL portion is always ISO-Latin-1 per spec.
        var urlBytes = Data(split.tail)
        if let nul = urlBytes.firstIndex(of: 0) { urlBytes = urlBytes.prefix(upTo: nul) }
        let url = String(data: urlBytes, encoding: .isoLatin1)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if url.isEmpty { return nil }
        return (description, url)
    }

    /// PRIV: owner identifier (Latin-1, null-terminated) + binary payload.
    private static func decodePRIVFrame(_ data: Data) -> ID3PrivateFrame? {
        guard let nul = data.firstIndex(of: 0) else { return nil }
        let ownerBytes = data[data.startIndex ..< nul]
        let owner = String(data: Data(ownerBytes), encoding: .isoLatin1) ?? ""
        let payload = Data(data[(nul + 1)...])
        return ID3PrivateFrame(owner: owner, data: payload)
    }

    /// GEOB: encoding (1) + MIME (Latin-1 null-term) + filename (encoding-aware null-term)
    /// + description (encoding-aware null-term) + binary data.
    private static func decodeGEOBFrame(_ data: Data) -> ID3AttachedObject? {
        guard data.count >= 4 else { return nil }
        let encoding = data[data.startIndex]
        var idx = data.startIndex + 1

        // MIME: Latin-1, null-terminated.
        guard let mimeNull = data[idx...].firstIndex(of: 0) else { return nil }
        let mime = String(data: Data(data[idx ..< mimeNull]), encoding: .isoLatin1) ?? ""
        idx = mimeNull + 1

        // Filename: encoding-aware null-terminated.
        let after1 = data[idx...]
        guard let split1 = splitOnNullTerminator(after1, encoding: encoding) else { return nil }
        let filename = decodeString(split1.head, encoding: encoding) ?? ""

        // Description: encoding-aware null-terminated.
        guard let split2 = splitOnNullTerminator(split1.tail, encoding: encoding) else { return nil }
        let description = decodeString(split2.head, encoding: encoding) ?? ""

        return ID3AttachedObject(
            mimeType: mime, filename: filename, description: description, data: Data(split2.tail))
    }

    /// CHAP: element ID (null-term Latin-1) + start_time (4) + end_time (4)
    /// + start_offset (4) + end_offset (4) + sub-frames.
    private static func decodeCHAPFrame(_ data: Data) -> ID3Chapter? {
        guard let nul = data.firstIndex(of: 0) else { return nil }
        let elementID = String(data: Data(data[data.startIndex ..< nul]), encoding: .isoLatin1) ?? ""
        let after = nul + 1
        guard data.endIndex - after >= 16 else { return nil }
        let startTime = readBE32(data, at: after)
        let endTime = readBE32(data, at: after + 4)
        let startOffset = readBE32(data, at: after + 8)
        let endOffset = readBE32(data, at: after + 12)

        var chapter = ID3Chapter(
            elementID: elementID,
            startTimeMs: startTime, endTimeMs: endTime,
            startOffset: startOffset, endOffset: endOffset
        )

        // Embedded sub-frames are full ID3 frames (10-byte header + body).
        let subStart = after + 16
        for sub in iterateSubFrames(data, from: subStart, end: data.endIndex) {
            switch sub.id {
            case "TIT2":
                chapter.title = chapter.title ?? decodeTextFrame(sub.body)
            case "WXXX":
                if let pair = decodeUserURLFrame(sub.body) {
                    chapter.url = chapter.url ?? pair.url
                }
            default: break
            }
        }
        return chapter
    }

    /// CTOC: element ID (null-term) + flags (1) + entry_count (1) + child IDs (each null-term) + sub-frames.
    private static func decodeCTOCFrame(_ data: Data) -> ID3ChapterTOC? {
        guard let nul = data.firstIndex(of: 0) else { return nil }
        let elementID = String(data: Data(data[data.startIndex ..< nul]), encoding: .isoLatin1) ?? ""
        var idx = nul + 1
        guard idx + 2 <= data.endIndex else { return nil }
        let flags = data[idx]
        let isTopLevel = (flags & 0x02) != 0
        let isOrdered = (flags & 0x01) != 0
        idx += 1
        let entryCount = Int(data[idx])
        idx += 1

        var children: [String] = []
        for _ in 0..<entryCount {
            guard idx < data.endIndex,
                  let n = data[idx...].firstIndex(of: 0) else { break }
            let id = String(data: Data(data[idx ..< n]), encoding: .isoLatin1) ?? ""
            children.append(id)
            idx = n + 1
        }

        var title: String?
        for sub in iterateSubFrames(data, from: idx, end: data.endIndex) where sub.id == "TIT2" {
            title = decodeTextFrame(sub.body)
            break
        }

        return ID3ChapterTOC(
            elementID: elementID,
            isTopLevel: isTopLevel, isOrdered: isOrdered,
            childElementIDs: children, title: title
        )
    }

    /// Walk embedded ID3v2.3/v2.4 frames inside a CHAP/CTOC body.
    private static func iterateSubFrames(_ data: Data, from start: Int, end: Int) -> [(id: String, body: Data)] {
        var out: [(String, Data)] = []
        var off = start
        while off + 10 <= end {
            guard let id = String(data: Data(data[off ..< off + 4]), encoding: .ascii) else { break }
            // Sub-frames inside CHAP/CTOC are commonly encoded with 32-bit big-endian
            // size (not syncsafe) per the v2.3 spec where these were introduced;
            // some v2.4 writers use syncsafe. Treat as syncsafe first, fall back to BE.
            let syncsafe = decodeSyncsafe(data[off + 4], data[off + 5], data[off + 6], data[off + 7])
            let beSize = (Int(data[off + 4]) << 24) | (Int(data[off + 5]) << 16) | (Int(data[off + 6]) << 8) | Int(data[off + 7])
            let size: Int
            if syncsafe > 0, off + 10 + syncsafe <= end {
                size = syncsafe
            } else if beSize > 0, off + 10 + beSize <= end {
                size = beSize
            } else {
                break
            }
            let body = Data(data[off + 10 ..< off + 10 + size])
            out.append((id, body))
            off += 10 + size
        }
        return out
    }

    /// Split a buffer on the encoding-aware null terminator. UTF-16 uses two
    /// zero bytes aligned on an even byte; Latin-1/UTF-8 use a single zero byte.
    /// Returns (head: bytes before the null, tail: bytes after).
    private static func splitOnNullTerminator(_ data: Data.SubSequence, encoding: UInt8) -> (head: Data.SubSequence, tail: Data.SubSequence)? {
        let useUTF16 = encoding == 1 || encoding == 2
        if useUTF16 {
            var i = data.startIndex
            while i + 1 < data.endIndex {
                if data[i] == 0 && data[i + 1] == 0 {
                    return (data[data.startIndex ..< i], data[(i + 2) ..< data.endIndex])
                }
                i += 2
            }
            return nil
        } else {
            guard let nul = data.firstIndex(of: 0) else { return nil }
            return (data[data.startIndex ..< nul], data[(nul + 1) ..< data.endIndex])
        }
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    // MARK: - ID3v1

    private static func parseID3v1(_ data: Data, into metadata: inout AudioMetadata) {
        let start = data.count - 128
        guard start >= 0 else { return }
        guard data[start] == 0x54 && data[start + 1] == 0x41 && data[start + 2] == 0x47 else { return } // "TAG"

        let readField: (Int, Int) -> String? = { offset, length in
            let fieldData = data[start + offset..<start + offset + length]
            return String(data: fieldData, encoding: .isoLatin1)?
                .trimmingCharacters(in: .controlCharacters)
                .trimmingCharacters(in: .whitespaces)
                .nilIfEmpty
        }

        metadata.title = metadata.title ?? readField(3, 30)
        metadata.artist = metadata.artist ?? readField(33, 30)
        metadata.album = metadata.album ?? readField(63, 30)
        metadata.year = metadata.year ?? readField(93, 4)
        metadata.comment = metadata.comment ?? readField(97, 28)

        // ID3v1.1: track number in byte 125 if byte 124 is 0
        if metadata.trackNumber == nil && data[start + 125] == 0 && data[start + 126] != 0 {
            metadata.trackNumber = Int(data[start + 126])
        }

        // Genre byte
        if metadata.genre == nil {
            let genreID = Int(data[start + 127])
            if genreID < id3v1Genres.count {
                metadata.genre = id3v1Genres[genreID]
            }
        }
    }

    // MARK: - Text Decoding

    /// Decode a text frame: encoding byte + text data.
    static func decodeTextFrame(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let encoding = data[data.startIndex]
        let textData = data.dropFirst()
        return decodeString(textData, encoding: encoding)
    }

    /// Decode a COMM frame: encoding (1) + language (3) + short desc (null-terminated) + text
    private static func decodeCommentFrame(_ data: Data) -> String? {
        guard data.count >= 5 else { return nil }
        let base = data.startIndex
        let encoding = data[base]
        // Skip encoding (1) + language (3 bytes).
        var offset = base + 4

        // Skip short description (null-terminated)
        if encoding == 1 || encoding == 2 {
            // UTF-16: null terminator is 2 bytes
            while offset + 1 < data.endIndex {
                if data[offset] == 0 && data[offset + 1] == 0 { offset += 2; break }
                offset += 2
            }
        } else {
            while offset < data.endIndex {
                if data[offset] == 0 { offset += 1; break }
                offset += 1
            }
        }

        guard offset < data.endIndex else { return nil }
        return decodeString(data[offset...], encoding: encoding)
    }

    /// Extract image data from APIC frame.
    private static func extractAPIC(_ data: Data) -> Data? {
        guard data.count > 4 else { return nil }
        let base = data.startIndex
        let encoding = data[base]
        var offset = base + 1

        // Skip MIME type (null-terminated ASCII)
        while offset < data.endIndex && data[offset] != 0 { offset += 1 }
        offset += 1 // skip null

        guard offset < data.endIndex else { return nil }
        // Skip picture type byte
        offset += 1

        // Skip description (null-terminated, encoding-aware)
        if encoding == 1 || encoding == 2 {
            while offset + 1 < data.endIndex {
                if data[offset] == 0 && data[offset + 1] == 0 { offset += 2; break }
                offset += 2
            }
        } else {
            while offset < data.endIndex && data[offset] != 0 { offset += 1 }
            offset += 1
        }

        guard offset < data.endIndex else { return nil }
        return Data(data[offset...])
    }

    private static func decodeString(_ data: Data.SubSequence, encoding: UInt8) -> String? {
        let rawData = Data(data)
        let result: String?
        switch encoding {
        case 0:
            result = String(data: rawData, encoding: .isoLatin1)
        case 1:
            result = String(data: rawData, encoding: .utf16)
        case 2:
            result = String(data: rawData, encoding: .utf16BigEndian)
        case 3:
            result = String(data: rawData, encoding: .utf8)
        default:
            result = String(data: rawData, encoding: .utf8)
        }
        // Trim null terminators and whitespace
        return result?.trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }

    // MARK: - Syncsafe Integer

    /// Decode a 4-byte syncsafe integer (7 bits per byte, MSB always 0).
    public static func decodeSyncsafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Int {
        (Int(b0) << 21) | (Int(b1) << 14) | (Int(b2) << 7) | Int(b3)
    }

    /// Encode an integer as 4-byte syncsafe.
    public static func encodeSyncsafe(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
         UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    // MARK: - Genre Helpers

    private static func cleanGenre(_ text: String) -> String {
        // Handle formats like "(13)", "(13)Pop", "13"
        if text.hasPrefix("("), let endIdx = text.firstIndex(of: ")") {
            let numStr = text[text.index(after: text.startIndex)..<endIdx]
            if let num = Int(numStr), num < id3v1Genres.count {
                let remainder = String(text[text.index(after: endIdx)...]).trimmingCharacters(in: .whitespaces)
                return remainder.isEmpty ? id3v1Genres[num] : remainder
            }
        }
        if let num = Int(text), num < id3v1Genres.count {
            return id3v1Genres[num]
        }
        return text
    }

    /// Standard ID3v1 genre list.
    static let id3v1Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
