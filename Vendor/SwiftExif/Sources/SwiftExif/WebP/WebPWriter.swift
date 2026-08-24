import Foundation

/// Reconstructs a WebP file from parsed components with updated metadata.
public struct WebPWriter: Sendable {

    // MARK: - VP8X Feature Flags

    /// Bit flags in the VP8X extended header.
    private struct VP8XFlags {
        static let icc:       UInt8 = 1 << 5
        static let alpha:     UInt8 = 1 << 4
        static let exif:      UInt8 = 1 << 3
        static let xmp:       UInt8 = 1 << 2
        static let animation: UInt8 = 1 << 1
    }

    /// Reconstruct a WebP file with updated metadata.
    public static func write(_ file: WebPFile, exif: ExifData?, xmp: XMPData?,
                             iccProfile: ICCProfile?) throws -> Data {
        var chunks = file.chunks

        // Update or remove EXIF chunk
        updateChunk(&chunks, fourCC: "EXIF", data: exif.map { ExifWriter.writeTIFF($0) })

        // Update or remove XMP chunk (raw XML, no JPEG APP1 prefix)
        updateChunk(&chunks, fourCC: "XMP ", data: xmp.map { Data(XMPWriter.generateXML($0).utf8) })

        // Update or remove ICCP chunk
        updateChunk(&chunks, fourCC: "ICCP", data: iccProfile?.data)

        // Ensure VP8X chunk reflects current feature flags
        ensureVP8X(&chunks)

        return serialize(chunks: chunks)
    }

    // MARK: - Private Helpers

    /// Insert, update, or remove a chunk by FourCC.
    private static func updateChunk(_ chunks: inout [WebPChunk], fourCC: String, data: Data?) {
        let existingIndex = chunks.firstIndex { $0.fourCC == fourCC }

        if let data, !data.isEmpty {
            let chunk = WebPChunk(fourCC: fourCC, data: data)
            if let idx = existingIndex {
                chunks[idx] = chunk
            } else {
                // Insert metadata chunks after the image data chunks
                let insertIndex = findMetadataInsertIndex(chunks, for: fourCC)
                chunks.insert(chunk, at: insertIndex)
            }
        } else if let idx = existingIndex {
            chunks.remove(at: idx)
        }
    }

    /// Determine where to insert a metadata chunk.
    /// WebP spec ordering: VP8X, ICCP, ANIM/ANMF, ALPH, VP8/VP8L, EXIF, XMP
    private static func findMetadataInsertIndex(_ chunks: [WebPChunk], for fourCC: String) -> Int {
        switch fourCC {
        case "ICCP":
            // ICCP goes right after VP8X (or at the start if no VP8X)
            if let vp8xIdx = chunks.firstIndex(where: { $0.fourCC == "VP8X" }) {
                return vp8xIdx + 1
            }
            return 0
        case "EXIF":
            // EXIF goes after image data, before XMP
            if let xmpIdx = chunks.firstIndex(where: { $0.fourCC == "XMP " }) {
                return xmpIdx
            }
            return chunks.endIndex
        case "XMP ":
            // XMP goes at the end
            return chunks.endIndex
        default:
            return chunks.endIndex
        }
    }

    /// Ensure a VP8X chunk exists and its flags match the actual chunks present.
    /// If the file is simple (VP8/VP8L only, no metadata), VP8X may not be needed.
    private static func ensureVP8X(_ chunks: inout [WebPChunk]) {
        let hasExif = chunks.contains { $0.fourCC == "EXIF" }
        let hasXMP = chunks.contains { $0.fourCC == "XMP " }
        let hasICC = chunks.contains { $0.fourCC == "ICCP" }
        let hasAlpha = chunks.contains { $0.fourCC == "ALPH" }
            || chunks.contains { $0.fourCC == "VP8L" } // VP8L can have alpha
        let hasAnimation = chunks.contains { $0.fourCC == "ANIM" }

        let needsVP8X = hasExif || hasXMP || hasICC || hasAnimation

        if !needsVP8X {
            // Remove VP8X if no extended features remain
            chunks.removeAll { $0.fourCC == "VP8X" }
            return
        }

        // Build flags byte
        var flags: UInt8 = 0
        if hasICC { flags |= VP8XFlags.icc }
        if hasAlpha { flags |= VP8XFlags.alpha }
        if hasExif { flags |= VP8XFlags.exif }
        if hasXMP { flags |= VP8XFlags.xmp }
        if hasAnimation { flags |= VP8XFlags.animation }

        // VP8X payload: 10 bytes
        // Byte 0: flags (only bits 0-5 used)
        // Bytes 1-3: reserved (0)
        // Bytes 4-6: canvas width minus one (24-bit LE)
        // Bytes 7-9: canvas height minus one (24-bit LE)
        if let vp8xIdx = chunks.firstIndex(where: { $0.fourCC == "VP8X" }) {
            // Update flags in existing VP8X, preserve canvas size
            var data = chunks[vp8xIdx].data
            if data.count >= 10 {
                data[data.startIndex] = flags
            }
            chunks[vp8xIdx] = WebPChunk(fourCC: "VP8X", data: data)
        } else {
            // Create VP8X with canvas size from VP8/VP8L chunk
            let (width, height) = extractCanvasSize(from: chunks)
            var data = Data(count: 10)
            data[0] = flags
            // Canvas width - 1 (24-bit LE)
            let w = max(0, width - 1)
            data[4] = UInt8(w & 0xFF)
            data[5] = UInt8((w >> 8) & 0xFF)
            data[6] = UInt8((w >> 16) & 0xFF)
            // Canvas height - 1 (24-bit LE)
            let h = max(0, height - 1)
            data[7] = UInt8(h & 0xFF)
            data[8] = UInt8((h >> 8) & 0xFF)
            data[9] = UInt8((h >> 16) & 0xFF)
            chunks.insert(WebPChunk(fourCC: "VP8X", data: data), at: 0)
        }
    }

    /// Extract canvas dimensions from VP8 or VP8L bitstream header.
    private static func extractCanvasSize(from chunks: [WebPChunk]) -> (width: Int, height: Int) {
        // VP8 lossy: width/height at bytes 6-9 of the bitstream (after 3-byte frame tag + 3-byte sync code)
        if let vp8 = chunks.first(where: { $0.fourCC == "VP8 " }), vp8.data.count >= 10 {
            let d = vp8.data
            let w = Int(d[d.startIndex + 6]) | (Int(d[d.startIndex + 7]) << 8)
            let h = Int(d[d.startIndex + 8]) | (Int(d[d.startIndex + 9]) << 8)
            // Lower 14 bits are the dimension, upper 2 bits are scaling
            return (w & 0x3FFF, h & 0x3FFF)
        }

        // VP8L lossless: signature byte 0x2F, then 32-bit LE with width(14)-height(14)-alpha(1)-version(3)
        if let vp8l = chunks.first(where: { $0.fourCC == "VP8L" }), vp8l.data.count >= 5 {
            let d = vp8l.data
            if d[d.startIndex] == 0x2F {
                let bits = UInt32(d[d.startIndex + 1])
                    | (UInt32(d[d.startIndex + 2]) << 8)
                    | (UInt32(d[d.startIndex + 3]) << 16)
                    | (UInt32(d[d.startIndex + 4]) << 24)
                let w = Int(bits & 0x3FFF) + 1
                let h = Int((bits >> 14) & 0x3FFF) + 1
                return (w, h)
            }
        }

        return (1, 1) // fallback
    }

    /// Serialize chunks back into a complete RIFF/WebP byte stream.
    private static func serialize(chunks: [WebPChunk]) -> Data {
        // Calculate total payload size (all chunks)
        var payloadSize = 4 // "WEBP" signature
        for chunk in chunks {
            payloadSize += 8 // FourCC + size
            payloadSize += chunk.data.count
            if chunk.data.count & 1 != 0 {
                payloadSize += 1 // padding byte
            }
        }

        var data = Data(capacity: 8 + payloadSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(&data, UInt32(payloadSize))
        data.append(contentsOf: "WEBP".utf8)

        // Chunks
        for chunk in chunks {
            // FourCC
            data.append(contentsOf: chunk.fourCC.utf8)
            // Size (LE u32)
            appendUInt32LE(&data, UInt32(chunk.data.count))
            // Payload
            data.append(chunk.data)
            // Pad to even boundary
            if chunk.data.count & 1 != 0 {
                data.append(0)
            }
        }

        return data
    }

    private static func appendUInt32LE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
