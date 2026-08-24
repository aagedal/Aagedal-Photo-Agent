import Foundation

/// Decodes RIFF WAVE / Broadcast WAVE files into AudioMetadata.
///
/// Recognized chunks:
/// - `fmt ` — required, decodes sample rate / channels / bit depth / codec.
/// - `bext` — Broadcast Wave (EBU Tech 3285 r2): scene, originator,
///   start-of-day sample reference, BS.1770 loudness, coding history.
/// - `iXML` — XML metadata used by Sound Devices, Aaton, and most modern
///   field recorders (project, scene, take, circled flag, sound roll, etc.).
///   The full XML is preserved on `bwf.iXML` for downstream consumers.
/// - `LIST` (`INFO` form) — INAM / IART / ICOP / ICMT / ICRD / IPRD / ISFT.
/// - `id3 ` — embedded ID3v2 tag (rare but legal in WAV).
///
/// Other chunks (`data`, `fact`, `cue `, `plst`, `JUNK`, …) are skipped.
public struct WAVParser: Sendable {

    /// WAV format-tag values. WAV uses these in the `fmt ` chunk's first
    /// uint16 to declare the codec; everything not in this list is treated
    /// as "unknown" and the codec field is left nil.
    private static let formatTagNames: [UInt16: String] = [
        0x0001: "PCM",
        0x0002: "ADPCM",
        0x0003: "PCM (float)",
        0x0006: "A-Law",
        0x0007: "μ-Law",
        0x0011: "IMA ADPCM",
        0x0050: "MPEG",
        0x0055: "MP3",
        0x2000: "AC-3",
        0x2001: "DTS",
        0xFFFE: "Extensible",
    ]

    public static func parse(_ data: Data) throws -> AudioMetadata {
        guard data.count >= 12 else {
            throw MetadataError.invalidWAV("WAV file too small")
        }
        let s = data.startIndex
        // RIFF header + 4-byte file size + WAVE form id.
        guard data[s] == 0x52, data[s + 1] == 0x49, data[s + 2] == 0x46, data[s + 3] == 0x46,
              data[s + 8] == 0x57, data[s + 9] == 0x41, data[s + 10] == 0x56, data[s + 11] == 0x45
        else {
            throw MetadataError.invalidWAV("Not a RIFF WAVE")
        }

        var meta = AudioMetadata(format: .wav)
        meta.codec = "PCM"            // safe default; overwritten by `fmt ` below

        // Walk RIFF chunks starting after the 12-byte form header.
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(
                data: data[(s + offset)..<(s + offset + 4)],
                encoding: .ascii
            ) ?? ""
            let size = Int(readUInt32LE(data, at: s + offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }

            let payload = Data(data[(s + payloadStart)..<(s + payloadEnd)])

            switch chunkID {
            case "fmt ":
                applyFmtChunk(payload, into: &meta)
            case "bext":
                meta.bwf = parseBextChunk(payload)
            case "iXML":
                if meta.bwf == nil { meta.bwf = BWFMetadata() }
                meta.bwf?.iXML = String(data: payload, encoding: .utf8)
                    ?? String(data: payload, encoding: .ascii)
            case "LIST":
                applyListChunk(payload, into: &meta)
            case "id3 ", "ID3 ":
                // Embedded ID3v2 tag — skip for now; the full ID3 surface
                // already exists for MP3 and would deserve its own wiring.
                break
            case "data", "fact", "cue ", "plst", "JUNK", "PAD ", "axml":
                break  // intentionally ignored
            default:
                break
            }

            // Chunks are word-aligned: an odd-sized payload pads with a zero.
            offset = payloadEnd + (size & 1)
        }

        return meta
    }

    // MARK: - fmt

    private static func applyFmtChunk(_ data: Data, into meta: inout AudioMetadata) {
        guard data.count >= 16 else { return }
        let s = data.startIndex
        let formatTag = readUInt16LE(data, at: s)
        let channels = readUInt16LE(data, at: s + 2)
        let sampleRate = readUInt32LE(data, at: s + 4)
        let avgBytesPerSec = readUInt32LE(data, at: s + 8)
        // blockAlign at +12 (UInt16) — not exposed.
        let bitsPerSample = readUInt16LE(data, at: s + 14)

        meta.channels = Int(channels)
        meta.sampleRate = Int(sampleRate)
        meta.bitDepth = Int(bitsPerSample)
        meta.bitrate = Int(avgBytesPerSec) * 8

        if let name = formatTagNames[formatTag] {
            meta.codec = name
            meta.codecName = "WAVE / \(name)"
        }
        if formatTag == 0xFFFE && data.count >= 40 {
            // WAVEFORMATEXTENSIBLE — first 16 bytes of the SubFormat GUID
            // are the actual format tag. Skip cb_size(2) + valid_bits(2) +
            // channel_mask(4) = 8 bytes after the 16-byte fmt header.
            let subFormatTag = readUInt16LE(data, at: s + 24)
            if let name = formatTagNames[subFormatTag] {
                meta.codec = name
                meta.codecName = "WAVE Extensible / \(name)"
            }
        }
        meta.channelLayout = channelLayoutLabel(Int(channels))
    }

    private static func channelLayoutLabel(_ channels: Int) -> String? {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 3: return "2.1"
        case 4: return "quad"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }

    // MARK: - bext

    private static func parseBextChunk(_ data: Data) -> BWFMetadata {
        var bwf = BWFMetadata()
        let s = data.startIndex

        bwf.description = readASCIIField(data, offset: s + 0, length: 256)
        bwf.originator = readASCIIField(data, offset: s + 256, length: 32)
        bwf.originatorReference = readASCIIField(data, offset: s + 288, length: 32)
        bwf.originationDate = readASCIIField(data, offset: s + 320, length: 10)
        bwf.originationTime = readASCIIField(data, offset: s + 330, length: 8)

        if data.count >= 346 {
            let low = UInt64(readUInt32LE(data, at: s + 338))
            let high = UInt64(readUInt32LE(data, at: s + 342))
            bwf.timeReference = (high << 32) | low
        }
        if data.count >= 348 {
            bwf.version = readUInt16LE(data, at: s + 346)
        }

        // UMID — 64 bytes from offset 348, present when version >= 1.
        if let v = bwf.version, v >= 1, data.count >= 412 {
            bwf.umid = Data(data[(s + 348)..<(s + 412)])
        }

        // Loudness fields from offset 412, present when version >= 2.
        if let v = bwf.version, v >= 2, data.count >= 422 {
            bwf.loudnessValue       = Double(Int16(bitPattern: readUInt16LE(data, at: s + 412))) / 100.0
            bwf.loudnessRange       = Double(Int16(bitPattern: readUInt16LE(data, at: s + 414))) / 100.0
            bwf.maxTruePeakLevel    = Double(Int16(bitPattern: readUInt16LE(data, at: s + 416))) / 100.0
            bwf.maxMomentaryLoudness = Double(Int16(bitPattern: readUInt16LE(data, at: s + 418))) / 100.0
            bwf.maxShortTermLoudness = Double(Int16(bitPattern: readUInt16LE(data, at: s + 420))) / 100.0
        }

        // CodingHistory — variable-length string starting at offset 602.
        if data.count > 602 {
            let raw = Data(data[(s + 602)..<data.endIndex])
            let trimmed = raw.prefix { $0 != 0 }
            if let str = String(data: Data(trimmed), encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                bwf.codingHistory = str
            }
        }
        return bwf
    }

    // MARK: - LIST INFO

    private static func applyListChunk(_ data: Data, into meta: inout AudioMetadata) {
        guard data.count >= 4 else { return }
        let s = data.startIndex
        let listType = String(data: data[s..<(s + 4)], encoding: .ascii)
        guard listType == "INFO" else { return }

        var offset = 4
        while offset + 8 <= data.count {
            let id = String(data: data[(s + offset)..<(s + offset + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32LE(data, at: s + offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }

            let raw = data[(s + payloadStart)..<(s + payloadEnd)]
            let value = String(data: Data(raw.prefix { $0 != 0 }), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let value = value, !value.isEmpty {
                switch id {
                case "INAM": meta.title = value
                case "IART": meta.artist = value
                case "ICOP": if meta.comment == nil { meta.comment = "© " + value }
                case "ICMT": meta.comment = value
                case "ICRD": meta.year = value
                case "IGNR": meta.genre = value
                case "IPRD": meta.album = value
                case "IPRT", "ITRK": meta.trackNumber = Int(value)
                default: break
                }
            }
            offset = payloadEnd + (size & 1)
        }
    }

    // MARK: - Reading helpers

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readASCIIField(_ data: Data, offset: Int, length: Int) -> String? {
        guard offset + length <= data.endIndex else { return nil }
        let slice = data[offset..<(offset + length)]
        let trimmed = slice.prefix { $0 != 0 }
        let s = String(data: Data(trimmed), encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
