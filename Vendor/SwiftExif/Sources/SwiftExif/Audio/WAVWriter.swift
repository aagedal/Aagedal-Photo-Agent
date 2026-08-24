import Foundation

/// Write metadata to RIFF WAVE / Broadcast WAVE files by rebuilding the
/// chunk list. Preserves `fmt `, `data`, and any other unrecognized chunks
/// untouched; replaces the LIST/INFO block (and, when present, the `bext`
/// description/originator/origination fields) with the values supplied on
/// the AudioMetadata.
///
/// The audio frames in `data` are byte-stable: this writer does not
/// recompress, retime, or otherwise touch sample data.
public struct WAVWriter: Sendable {

    public static func write(_ metadata: AudioMetadata, to originalData: Data) throws -> Data {
        guard originalData.count >= 12 else {
            throw MetadataError.invalidWAV("WAV file too small")
        }
        let s = originalData.startIndex
        guard
            originalData[s] == 0x52, originalData[s + 1] == 0x49,
            originalData[s + 2] == 0x46, originalData[s + 3] == 0x46,
            originalData[s + 8] == 0x57, originalData[s + 9] == 0x41,
            originalData[s + 10] == 0x56, originalData[s + 11] == 0x45
        else {
            throw MetadataError.invalidWAV("Not a RIFF WAVE")
        }

        // Walk every existing chunk so we can rebuild in original order,
        // skipping the metadata chunks we're about to rewrite.
        var preservedChunks: [(id: String, payload: Data)] = []
        var existingBext: Data?

        var offset = 12
        while offset + 8 <= originalData.count {
            let chunkID = String(
                data: originalData[(s + offset)..<(s + offset + 4)],
                encoding: .ascii
            ) ?? ""
            let size = Int(readUInt32LE(originalData, at: s + offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= originalData.count else { break }
            let payload = Data(originalData[(s + payloadStart)..<(s + payloadEnd)])

            switch chunkID {
            case "LIST":
                // Drop the existing LIST/INFO (and any other LIST forms);
                // the new metadata is rewritten from the AudioMetadata fields.
                if isInfoList(payload) {
                    break
                } else {
                    preservedChunks.append((chunkID, payload))
                }
            case "bext":
                existingBext = payload
            default:
                preservedChunks.append((chunkID, payload))
            }
            offset = payloadEnd + (size & 1)
        }

        // Build the replacement LIST/INFO chunk from the supplied metadata.
        if let listInfo = makeListInfoPayload(metadata) {
            preservedChunks.append(("LIST", listInfo))
        }
        // bext gets carried over with description/originator updated when the
        // caller has them on `metadata.bwf`. Anything we don't know about in
        // the original payload is preserved byte-for-byte.
        if let bextPayload = makeUpdatedBextChunk(existing: existingBext, metadata: metadata) {
            preservedChunks.append(("bext", bextPayload))
        }

        // Reassemble: RIFF header (4) + size (4) + WAVE form id (4) + chunks.
        var body = Data()
        for (id, payload) in preservedChunks {
            body.append(asciiID(id))
            body.append(uint32LE(UInt32(payload.count)))
            body.append(payload)
            if (payload.count & 1) == 1 {
                body.append(0)  // word-align odd-sized chunks
            }
        }

        var out = Data()
        out.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // RIFF
        out.append(uint32LE(UInt32(4 + body.count)))      // size of WAVE+chunks
        out.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // WAVE
        out.append(body)
        return out
    }

    // MARK: - LIST/INFO replacement

    private static func isInfoList(_ payload: Data) -> Bool {
        guard payload.count >= 4 else { return false }
        return String(data: payload.prefix(4), encoding: .ascii) == "INFO"
    }

    /// Build a fresh LIST/INFO payload from AudioMetadata. Returns nil when
    /// the metadata has no fields that would produce any INFO entries — keeps
    /// us from emitting an empty `LIST INFO` chunk.
    private static func makeListInfoPayload(_ metadata: AudioMetadata) -> Data? {
        var entries: [(id: String, value: String)] = []
        if let v = metadata.title { entries.append(("INAM", v)) }
        if let v = metadata.artist { entries.append(("IART", v)) }
        if let v = metadata.album { entries.append(("IPRD", v)) }
        if let v = metadata.year { entries.append(("ICRD", v)) }
        if let v = metadata.genre { entries.append(("IGNR", v)) }
        if let v = metadata.comment { entries.append(("ICMT", v)) }
        if let v = metadata.trackNumber { entries.append(("ITRK", String(v))) }
        guard !entries.isEmpty else { return nil }

        var payload = Data()
        payload.append(asciiID("INFO"))
        for entry in entries {
            // Each INFO sub-chunk: 4-byte id + 4-byte LE size + value (NUL-terminated).
            var valueData = Data(entry.value.utf8)
            valueData.append(0)  // INFO entries are conventionally NUL-terminated
            payload.append(asciiID(entry.id))
            payload.append(uint32LE(UInt32(valueData.count)))
            payload.append(valueData)
            if (valueData.count & 1) == 1 {
                payload.append(0)  // word-align
            }
        }
        return payload
    }

    // MARK: - bext update

    /// Rewrite the bext description/originator/origination fields when the
    /// caller has those on `metadata.bwf`. Other bext bytes (UMID, loudness,
    /// CodingHistory) are preserved as-is. Returns nil when there is no bext
    /// to begin with and no BWFMetadata supplied — i.e. nothing to write.
    private static func makeUpdatedBextChunk(existing: Data?, metadata: AudioMetadata) -> Data? {
        guard existing != nil || metadata.bwf != nil else { return nil }
        var payload = existing ?? Data(repeating: 0, count: 602)
        // The bext spec mandates at least 602 bytes of fixed fields; pad if
        // the original was somehow truncated, so writes don't shorten it.
        if payload.count < 602 {
            payload.append(Data(repeating: 0, count: 602 - payload.count))
        }
        if let bwf = metadata.bwf {
            if let v = bwf.description {
                writeASCIIField(into: &payload, offset: 0, length: 256, value: v)
            }
            if let v = bwf.originator {
                writeASCIIField(into: &payload, offset: 256, length: 32, value: v)
            }
            if let v = bwf.originatorReference {
                writeASCIIField(into: &payload, offset: 288, length: 32, value: v)
            }
            if let v = bwf.originationDate {
                writeASCIIField(into: &payload, offset: 320, length: 10, value: v)
            }
            if let v = bwf.originationTime {
                writeASCIIField(into: &payload, offset: 330, length: 8, value: v)
            }
        }
        return payload
    }

    // MARK: - Encoding helpers

    private static func asciiID(_ id: String) -> Data {
        var out = Data(id.utf8)
        if out.count < 4 { out.append(Data(repeating: 0x20, count: 4 - out.count)) }
        else if out.count > 4 { out = out.prefix(4) }
        return out
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// NUL-pad or right-truncate `value` to fit a fixed-length ASCII field.
    private static func writeASCIIField(into payload: inout Data, offset: Int, length: Int, value: String) {
        let bytes = Array(value.utf8.prefix(length))
        let end = offset + length
        guard end <= payload.count else { return }
        for i in 0..<length {
            payload[payload.startIndex + offset + i] = i < bytes.count ? bytes[i] : 0
        }
    }
}
