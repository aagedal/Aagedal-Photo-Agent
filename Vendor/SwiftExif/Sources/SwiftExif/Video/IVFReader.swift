import Foundation

/// Reader for IVF (On2 IVF) — a deliberately minimal container that wraps a
/// single raw video elementary stream (VP8, VP9, AV1, or the experimental AV2).
/// There is no audio, no timecode, and no per-track structure: just a 32-byte
/// file header naming the codec / dimensions / time base, followed by a flat
/// list of length-prefixed frames.
///
/// File header (32 bytes, little-endian):
/// ```
///   0  signature   "DKIF"
///   4  version      uint16  (0)
///   6  headerLength uint16  (32)
///   8  fourCC       4 bytes (codec: "VP80" / "VP90" / "AV01" / "AV02")
///  12  width        uint16
///  14  height       uint16
///  16  timeBaseRate uint32  (denominator — frames per timeBaseScale seconds)
///  20  timeBaseScale uint32 (numerator)
///  24  frameCount   uint32  (often 0 — encoders frequently leave it unset)
///  28  reserved     uint32
/// ```
///
/// Each frame is preceded by a 12-byte header — `uint32` frame size plus a
/// `uint64` presentation timestamp in time-base units — then the codec payload.
///
/// We never decode the payload. The frame rate, dimensions, and codec all come
/// from the container header; the frame count and duration come from walking the
/// frame table (the header's `frameCount` is unreliable). In particular the AV2
/// (FourCC `AV02`) bitstream syntax is still experimental and unstable, so we
/// deliberately do not attempt to read its sequence header for bit depth /
/// chroma / profile — doing so would risk reporting wrong metadata as the format
/// evolves.
public struct IVFReader: Sendable {

    /// Detect an IVF container by its `DKIF` signature.
    public static func isIVF(_ data: Data) -> Bool {
        guard data.count >= 32 else { return false }
        let s = data.startIndex
        // "DKIF"
        return data[s] == 0x44 && data[s + 1] == 0x4B && data[s + 2] == 0x49 && data[s + 3] == 0x46
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isIVF(data) else {
            throw MetadataError.invalidVideo("Not an IVF (DKIF) file")
        }
        var metadata = VideoMetadata(format: .ivf)
        metadata.fileSize = Int64(data.count)
        guard data.count >= 32 else { return metadata }

        // `headerLength` is nominally 32 but we honour the field (clamped to a
        // sane minimum) so a future revision that grows the header still parses.
        let headerLength = max(32, Int(readUInt16LE(data, at: 6)))
        let fourCC = fourCC(data, at: 8)
        let width = Int(readUInt16LE(data, at: 12))
        let height = Int(readUInt16LE(data, at: 14))
        let timeBaseRate = readUInt32LE(data, at: 16)   // denominator
        let timeBaseScale = readUInt32LE(data, at: 20)  // numerator
        let declaredFrameCount = readUInt32LE(data, at: 24)

        var stream = VideoStream(index: 0)
        stream.codec = codecID(fourCC)
        stream.codecName = codecLongName(fourCC)
        if width > 0 { stream.width = width }
        if height > 0 { stream.height = height }

        // Frame rate = rate / scale. The standard IVF time base is 1/fps
        // (scale = 1, rate = fps) or scaled (scale = 1000, rate = fps*1000),
        // both of which yield the frame rate directly. A microsecond time base
        // (rate = 1_000_000) would instead make this absurdly large, so only
        // accept a result in a plausible range and otherwise leave it nil —
        // the duration below is still recovered from the frame timestamps.
        var fps: Double?
        if timeBaseScale > 0 && timeBaseRate > 0 {
            let candidate = Double(timeBaseRate) / Double(timeBaseScale)
            if candidate > 0 && candidate <= 1000 { fps = candidate }
        }
        stream.frameRate = fps
        stream.avgFrameRate = fps
        stream.rFrameRate = fps

        // Walk the frame table. The header `frameCount` is frequently 0 or
        // stale, so count frames ourselves. A file that is truncated or still
        // being encoded ends in a frame header whose payload runs past EOF — we
        // stop at that point and flag it rather than reading out of bounds.
        var offset = headerLength
        var walkedFrameCount = 0
        var totalPayloadBytes = 0
        var lastTimestamp: UInt64?
        var truncated = false
        while offset + 12 <= data.count {
            let frameSize = Int(readUInt32LE(data, at: offset))
            let timestamp = readUInt64LE(data, at: offset + 4)
            let payloadStart = offset + 12
            let payloadEnd = payloadStart + frameSize
            if payloadEnd > data.count {
                // Incomplete trailing frame (truncated or mid-encode).
                truncated = true
                break
            }
            walkedFrameCount += 1
            totalPayloadBytes += frameSize
            lastTimestamp = timestamp
            offset = payloadEnd
        }

        if walkedFrameCount > 0 {
            stream.frameCount = walkedFrameCount
        } else if declaredFrameCount > 0 {
            stream.frameCount = Int(declaredFrameCount)
        }

        // Duration: prefer the last decoded timestamp plus one frame interval —
        // timestamps are in time-base units of (scale / rate) seconds, which is
        // correct regardless of whether the time base is 1/fps or microseconds.
        // Fall back to frame-count / fps when there are no usable timestamps.
        if let ts = lastTimestamp, timeBaseRate > 0 {
            metadata.duration = Double(ts + 1) * Double(timeBaseScale) / Double(timeBaseRate)
        } else if let fps, fps > 0, let n = stream.frameCount {
            metadata.duration = Double(n) / fps
        }

        // Overall bit rate from the bitstream payload over the clip duration.
        if let duration = metadata.duration, duration > 0, totalPayloadBytes > 0 {
            metadata.bitRate = Int(Double(totalPayloadBytes) * 8.0 / duration)
        }

        // IVF carries a single video elementary stream, so the clip-level
        // duration and bit rate are also the stream's.
        stream.duration = metadata.duration
        stream.bitRate = metadata.bitRate

        metadata.videoStreams = [stream]
        metadata.streamOrder = [.video(0)]

        // Surface the single video track to the top-level convenience fields.
        metadata.videoWidth = stream.width
        metadata.videoHeight = stream.height
        metadata.videoCodec = stream.codec
        metadata.frameRate = stream.frameRate

        if truncated {
            metadata.warnings.append(
                "IVF stream ends in an incomplete frame (file truncated or still encoding); "
                + "metadata covers \(walkedFrameCount) complete frame(s)")
        }
        if declaredFrameCount > 0, walkedFrameCount > 0, Int(declaredFrameCount) != walkedFrameCount {
            metadata.warnings.append(
                "IVF header frame count (\(declaredFrameCount)) disagrees with the "
                + "\(walkedFrameCount) frame(s) actually present; using the walked count")
        }

        return metadata
    }

    // MARK: - Codec naming

    /// ffprobe-style short codec id for the IVF FourCC.
    private static func codecID(_ fourCC: String) -> String {
        switch fourCC.uppercased() {
        case "VP80": return "vp8"
        case "VP90": return "vp9"
        case "AV01": return "av1"
        case "AV02": return "av2"
        default:
            return fourCC.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).lowercased()
        }
    }

    /// Human-readable codec name, or nil for an unrecognised FourCC.
    private static func codecLongName(_ fourCC: String) -> String? {
        switch fourCC.uppercased() {
        case "VP80": return "VP8"
        case "VP90": return "VP9"
        case "AV01": return "AV1"
        case "AV02": return "AV2"
        default: return nil
        }
    }

    // MARK: - Byte helpers (little-endian)

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        let s = data.startIndex + offset
        guard s + 4 <= data.endIndex else { return "" }
        return String(data: data[s ..< s + 4], encoding: .ascii) ?? ""
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let s = data.startIndex + offset
        guard s + 2 <= data.endIndex else { return 0 }
        return UInt16(data[s]) | (UInt16(data[s + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        guard s + 4 <= data.endIndex else { return 0 }
        return UInt32(data[s])
            | (UInt32(data[s + 1]) << 8)
            | (UInt32(data[s + 2]) << 16)
            | (UInt32(data[s + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let s = data.startIndex + offset
        guard s + 8 <= data.endIndex else { return 0 }
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(data[s + i]) << (8 * i)
        }
        return value
    }
}
