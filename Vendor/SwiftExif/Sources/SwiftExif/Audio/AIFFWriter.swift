import Foundation

/// Write metadata to AIFF / AIFF-C files by rebuilding the chunk list.
/// Preserves COMM, SSND, and any chunk we don't know about; replaces NAME,
/// AUTH, (c) , and ANNO with values from `AudioMetadata`. The audio data
/// (`SSND`) is byte-stable.
public struct AIFFWriter: Sendable {

    public static func write(_ metadata: AudioMetadata, to originalData: Data) throws -> Data {
        guard originalData.count >= 12 else {
            throw MetadataError.invalidAIFF("AIFF file too small")
        }
        let s = originalData.startIndex
        guard
            originalData[s] == 0x46, originalData[s + 1] == 0x4F,
            originalData[s + 2] == 0x52, originalData[s + 3] == 0x4D
        else {
            throw MetadataError.invalidAIFF("Not a FORM container")
        }
        let formType = String(
            data: originalData[(s + 8)..<(s + 12)],
            encoding: .ascii
        ) ?? ""
        guard formType == "AIFF" || formType == "AIFC" else {
            throw MetadataError.invalidAIFF("Not an AIFF/AIFC FORM")
        }

        var preserved: [(id: String, payload: Data)] = []

        var offset = 12
        while offset + 8 <= originalData.count {
            let chunkID = String(
                data: originalData[(s + offset)..<(s + offset + 4)],
                encoding: .ascii
            ) ?? ""
            let size = Int(readUInt32BE(originalData, at: s + offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= originalData.count else { break }
            let payload = Data(originalData[(s + payloadStart)..<(s + payloadEnd)])

            switch chunkID {
            case "NAME", "AUTH", "(c) ", "ANNO":
                // Drop existing — rewritten from AudioMetadata below.
                break
            case "COMT":
                // COMT has timestamps + marker IDs we don't model on
                // AudioMetadata, so preserve the original bytes verbatim.
                preserved.append((chunkID, payload))
            default:
                preserved.append((chunkID, payload))
            }
            offset = payloadEnd + (size & 1)
        }

        // Append fresh single-string metadata chunks. Only emit a chunk when
        // the corresponding field is set so we don't write empty NAME/etc.
        if let v = metadata.title {
            preserved.append(("NAME", asciiPayload(v)))
        }
        if let v = metadata.artist {
            preserved.append(("AUTH", asciiPayload(v)))
        }
        if let raw = metadata.comment, let copyrightText = stripCopyrightPrefix(raw) {
            // `parse` writes "© <value>" into `comment` for the (c) chunk.
            preserved.append(("(c) ", asciiPayload(copyrightText)))
        } else if let v = metadata.comment {
            preserved.append(("ANNO", asciiPayload(v)))
        }

        // Reassemble.
        var body = Data()
        body.append(contentsOf: formType.utf8)  // AIFF or AIFC
        for (id, payload) in preserved {
            body.append(asciiID(id))
            body.append(uint32BE(UInt32(payload.count)))
            body.append(payload)
            if (payload.count & 1) == 1 {
                body.append(0)
            }
        }

        var out = Data()
        out.append(contentsOf: [0x46, 0x4F, 0x52, 0x4D])  // FORM
        out.append(uint32BE(UInt32(body.count)))
        out.append(body.dropFirst(0))
        // (We already wrote the form type as the first 4 bytes of `body`.)
        return out
    }

    // MARK: - Helpers

    /// AIFF parser surfaces the (c) chunk as `"© <text>"` so a single
    /// `comment` field can carry both annotations and copyright. Round-trip
    /// that prefix here so writing back produces a (c) chunk again.
    private static func stripCopyrightPrefix(_ s: String) -> String? {
        if s.hasPrefix("© ") {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func asciiPayload(_ value: String) -> Data {
        // AIFF text chunks are not NUL-terminated; the chunk size is the
        // authoritative length.
        Data(value.utf8)
    }

    private static func asciiID(_ id: String) -> Data {
        var out = Data(id.utf8)
        if out.count < 4 { out.append(Data(repeating: 0x20, count: 4 - out.count)) }
        else if out.count > 4 { out = out.prefix(4) }
        return out
    }

    private static func uint32BE(_ v: UInt32) -> Data {
        Data([
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8(v & 0xFF),
        ])
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
