import Foundation

/// Decodes Apple AIFF / AIFF-C files into AudioMetadata.
///
/// AIFF uses the same chunk-list shape as WAV but with big-endian integers,
/// a `FORM` form id, and an `AIFF` (uncompressed) or `AIFC` (compressed)
/// form type. Recognized chunks:
///
/// - `COMM` — common chunk: channels, sample frame count, sample size, the
///   80-bit IEEE 754 extended sample rate, plus (AIFC only) the 4-byte
///   compression type and Pascal-string compression name.
/// - `NAME`, `AUTH`, `(c) `, `ANNO` — single-string metadata chunks.
/// - `COMT` — multi-comment chunk; each entry has a (Mac OS-style) timestamp,
///   marker id, and Pascal text. We concatenate the texts into `comment`.
public struct AIFFParser: Sendable {

    public static func parse(_ data: Data) throws -> AudioMetadata {
        guard data.count >= 12 else {
            throw MetadataError.invalidAIFF("AIFF file too small")
        }
        let s = data.startIndex
        guard data[s] == 0x46, data[s + 1] == 0x4F, data[s + 2] == 0x52, data[s + 3] == 0x4D else {
            throw MetadataError.invalidAIFF("Not a FORM container")
        }
        let formType = String(data: data[(s + 8)..<(s + 12)], encoding: .ascii)
        guard formType == "AIFF" || formType == "AIFC" else {
            throw MetadataError.invalidAIFF("Not an AIFF/AIFC FORM")
        }

        var meta = AudioMetadata(format: .aiff)
        meta.codec = "PCM"
        meta.codecName = formType == "AIFC" ? "AIFF-C / PCM" : "AIFF / PCM"

        var commentChunks: [String] = []

        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data[(s + offset)..<(s + offset + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32BE(data, at: s + offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }

            let payload = Data(data[(s + payloadStart)..<(s + payloadEnd)])
            switch chunkID {
            case "COMM":
                applyCommChunk(payload, isAIFC: formType == "AIFC", into: &meta)
            case "NAME":
                if let v = readASCII(payload) { meta.title = v }
            case "AUTH":
                if let v = readASCII(payload) { meta.artist = v }
            case "(c) ":
                if let v = readASCII(payload), meta.comment == nil { meta.comment = "© " + v }
            case "ANNO":
                if let v = readASCII(payload) { commentChunks.append(v) }
            case "COMT":
                commentChunks.append(contentsOf: parseCOMTChunk(payload))
            case "ID3 ", "id3 ":
                break  // Surface later if/when we wire AIFF ID3 reading.
            default:
                break  // SSND, MARK, INST, MIDI, AESD, APPL, etc. — ignored.
            }

            // Chunks are word-aligned: an odd-sized payload pads with a zero.
            offset = payloadEnd + (size & 1)
        }

        if !commentChunks.isEmpty {
            // Preserve the per-chunk separation; consumers can split on \n if
            // they care, but emitting one joined block keeps the surface flat.
            meta.comment = commentChunks.joined(separator: "\n")
        }

        return meta
    }

    // MARK: - COMM (Common Chunk)

    private static func applyCommChunk(_ data: Data, isAIFC: Bool, into meta: inout AudioMetadata) {
        guard data.count >= 18 else { return }
        let s = data.startIndex
        let channels = readUInt16BE(data, at: s + 0)
        // sampleFrames at +2 (UInt32) — duration in frames; we derive seconds
        // once we know the sample rate.
        let sampleFrames = readUInt32BE(data, at: s + 2)
        let sampleSize = readUInt16BE(data, at: s + 6)
        let sampleRate = readExtendedFloat80(data, at: s + 8)

        meta.channels = Int(channels)
        meta.bitDepth = Int(sampleSize)
        if let rate = sampleRate, rate > 0, rate.isFinite {
            // `rate` comes from an attacker-controlled 80-bit float; a value above
            // `Int.max` would trap on `Int(rate)`. Guard the range before each
            // narrowing conversion.
            if rate < Double(Int.max) {
                meta.sampleRate = Int(rate.rounded())
            }
            if sampleFrames > 0 {
                meta.duration = Double(sampleFrames) / rate
            }
            if sampleSize > 0 && channels > 0 {
                // Multiply in Double (which saturates to +inf instead of trapping
                // like Int overflow would) and narrow only when the result fits.
                let bitrate = rate * Double(channels) * Double(sampleSize)
                if bitrate.isFinite, bitrate < Double(Int.max) {
                    meta.bitrate = Int(bitrate)
                }
            }
        }

        // AIFC adds a 4-byte compression type + Pascal-string compression name
        // after the standard 18-byte COMM payload.
        if isAIFC, data.count >= 22 {
            let compType = String(data: data[(s + 18)..<(s + 22)], encoding: .ascii) ?? ""
            let label = aifcCompressionLabel(compType)
            meta.codec = label
            meta.codecName = "AIFF-C / \(label)"
            // Pascal-string compression name follows; ignored for now (the
            // 4-byte tag is the canonical identifier).
        }

        meta.channelLayout = channelLayoutLabel(Int(channels))
    }

    /// Decode an AIFF 80-bit IEEE 754 extended-precision float to Double.
    /// Returns nil for NaN / infinity. AIFF stores sample rate (e.g. 48000.0)
    /// in this format because IEEE 754 single-precision can't represent every
    /// integer value above 2^24 exactly.
    private static func readExtendedFloat80(_ data: Data, at offset: Int) -> Double? {
        guard offset + 10 <= data.endIndex else { return nil }
        let exponentSign = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        let mantissa: UInt64 =
            (UInt64(data[offset + 2]) << 56) |
            (UInt64(data[offset + 3]) << 48) |
            (UInt64(data[offset + 4]) << 40) |
            (UInt64(data[offset + 5]) << 32) |
            (UInt64(data[offset + 6]) << 24) |
            (UInt64(data[offset + 7]) << 16) |
            (UInt64(data[offset + 8]) << 8) |
            UInt64(data[offset + 9])

        let sign: Double = (exponentSign & 0x8000) != 0 ? -1.0 : 1.0
        let exponent = Int(exponentSign & 0x7FFF)
        if exponent == 0 && mantissa == 0 { return 0 }
        if exponent == 0x7FFF { return nil }  // Inf / NaN
        let unbiasedExponent = exponent - 16383 - 63
        // A large (but non-0x7FFF) exponent overflows `pow` to +inf; reject any
        // non-finite result so the caller never narrows it to Int and traps.
        let result = sign * Double(mantissa) * pow(2.0, Double(unbiasedExponent))
        return result.isFinite ? result : nil
    }

    private static func aifcCompressionLabel(_ tag: String) -> String {
        switch tag {
        case "NONE", "twos": return "PCM (big-endian)"
        case "sowt", "lpcm": return "PCM (little-endian)"
        case "fl32", "FL32": return "PCM (float 32-bit)"
        case "fl64", "FL64": return "PCM (float 64-bit)"
        case "alaw", "ALAW": return "A-Law"
        case "ulaw", "ULAW": return "μ-Law"
        case "ima4":         return "IMA ADPCM"
        case "MAC3":         return "MACE 3:1"
        case "MAC6":         return "MACE 6:1"
        default:             return tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func channelLayoutLabel(_ channels: Int) -> String? {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }

    // MARK: - COMT (multi-comment)

    private static func parseCOMTChunk(_ data: Data) -> [String] {
        guard data.count >= 2 else { return [] }
        let s = data.startIndex
        let count = readUInt16BE(data, at: s)
        var entries: [String] = []
        var offset = 2
        for _ in 0..<count {
            // Each comment entry: timestamp(4) + markerID(2) + count(2) + text(count, padded).
            guard offset + 8 <= data.count else { break }
            let textLen = Int(readUInt16BE(data, at: s + offset + 6))
            let textStart = offset + 8
            let textEnd = textStart + textLen
            guard textEnd <= data.count else { break }
            if let str = String(data: data[(s + textStart)..<(s + textEnd)], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                entries.append(str)
            }
            // Pad to even length.
            let padded = textLen + (textLen & 1)
            offset = textStart + padded
        }
        return entries
    }

    // MARK: - Reading helpers

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readASCII(_ data: Data) -> String? {
        let trimmed = data.prefix { $0 != 0 }
        let s = String(data: Data(trimmed), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }
}
