import Foundation

/// Reader for AVI (Audio Video Interleave) RIFF containers.
///
/// AVI is a classic RIFF format whose top-level structure is:
///     RIFF <size> 'AVI '
///         LIST 'hdrl'
///             'avih'   — AVIMainHeader
///             LIST 'strl'
///                 'strh'   — AVIStreamHeader
///                 'strf'   — BITMAPINFOHEADER or WAVEFORMATEX
///             ...
///         LIST 'movi'
///         'idx1' …
/// All fields are little-endian.
///
/// Large AVI files (>4 GB) store per-stream frame counts in an OpenDML
/// `dmlh`/`indx` header — we read `dmlh` when present to recover the true
/// frame count.
public struct AVIReader: Sendable {

    public static func isAVI(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let s = data.startIndex
        guard data[s] == 0x52 && data[s + 1] == 0x49 && data[s + 2] == 0x46 && data[s + 3] == 0x46 else { return false }
        // Subtype at offset 8: "AVI "
        return data[s + 8] == 0x41 && data[s + 9] == 0x56 && data[s + 10] == 0x49 && data[s + 11] == 0x20
    }

    public static func parse(_ data: Data) throws -> VideoMetadata {
        guard isAVI(data) else {
            throw MetadataError.invalidVideo("Not a RIFF AVI file")
        }
        var metadata = VideoMetadata(format: .avi)
        guard data.count >= 12 else { return metadata }

        // Skip the RIFF header (12 bytes) and scan the top-level chunks.
        let riffEnd = min(data.count, readRIFFSize(data) + 8)
        var offset = 12
        while offset + 8 <= riffEnd {
            let id = fourCC(data, at: offset)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= data.count else { break }

            if id == "LIST" && payloadEnd - payloadStart >= 4 {
                let listType = fourCC(data, at: payloadStart)
                switch listType {
                case "hdrl":
                    parseHeaderList(data, from: payloadStart + 4, end: payloadEnd, into: &metadata)
                case "INFO":
                    parseINFOList(data, from: payloadStart + 4, end: payloadEnd, into: &metadata)
                default:
                    break
                }
            }

            // Chunks are padded to even bytes.
            offset = payloadEnd + (size & 1)
        }

        // Post-process: surface the first video/audio track to top-level fields.
        if let v = metadata.videoStreams.first {
            if metadata.videoWidth == nil { metadata.videoWidth = v.width }
            if metadata.videoHeight == nil { metadata.videoHeight = v.height }
            if metadata.videoCodec == nil { metadata.videoCodec = v.codec }
            if metadata.frameRate == nil { metadata.frameRate = v.frameRate }
            if metadata.bitDepth == nil { metadata.bitDepth = v.bitDepth }
            if metadata.fieldOrder == nil { metadata.fieldOrder = v.fieldOrder }
        }
        if let a = metadata.audioStreams.first {
            if metadata.audioCodec == nil { metadata.audioCodec = a.codec }
            if metadata.audioSampleRate == nil { metadata.audioSampleRate = a.sampleRate }
            if metadata.audioChannels == nil { metadata.audioChannels = a.channels }
        }

        for i in 0..<metadata.videoStreams.count {
            if metadata.videoStreams[i].pixelFormat == nil {
                metadata.videoStreams[i].pixelFormat = PixelFormatDerivation.derive(
                    chromaSubsampling: metadata.videoStreams[i].chromaSubsampling,
                    bitDepth: metadata.videoStreams[i].bitDepth,
                    fullRange: metadata.videoStreams[i].colorInfo?.fullRange,
                    codec: metadata.videoStreams[i].codec
                )
            }
            if metadata.videoStreams[i].avgFrameRate == nil,
               let fps = metadata.videoStreams[i].frameRate {
                metadata.videoStreams[i].avgFrameRate = fps
                if metadata.videoStreams[i].rFrameRate == nil {
                    metadata.videoStreams[i].rFrameRate = fps
                }
            }
        }

        return metadata
    }

    // MARK: - hdrl / strl walker

    private static func parseHeaderList(_ data: Data, from start: Int, end: Int, into metadata: inout VideoMetadata) {
        var offset = start
        while offset + 8 <= end {
            let id = fourCC(data, at: offset)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }

            switch id {
            case "avih":
                parseAVIH(data, from: payloadStart, size: size, into: &metadata)
            case "LIST" where payloadEnd - payloadStart >= 4:
                let listType = fourCC(data, at: payloadStart)
                if listType == "strl" {
                    parseStrl(data, from: payloadStart + 4, end: payloadEnd, into: &metadata)
                } else if listType == "odml" {
                    parseOdml(data, from: payloadStart + 4, end: payloadEnd, into: &metadata)
                }
            default:
                break
            }

            offset = payloadEnd + (size & 1)
        }
    }

    /// AVIMainHeader (56 bytes, little-endian):
    ///   dwMicroSecPerFrame      uint32
    ///   dwMaxBytesPerSec        uint32
    ///   dwPaddingGranularity    uint32
    ///   dwFlags                 uint32
    ///   dwTotalFrames           uint32   (unreliable >4GB — overwritten by dmlh)
    ///   dwInitialFrames         uint32
    ///   dwStreams               uint32
    ///   dwSuggestedBufferSize   uint32
    ///   dwWidth                 uint32
    ///   dwHeight                uint32
    ///   dwReserved[4]
    private static func parseAVIH(_ data: Data, from start: Int, size: Int, into metadata: inout VideoMetadata) {
        guard size >= 40, start + 40 <= data.count else { return }
        let microSecPerFrame = readUInt32LE(data, at: start)
        let dwFlags = readUInt32LE(data, at: start + 12)
        let totalFrames = readUInt32LE(data, at: start + 16)
        let width = readUInt32LE(data, at: start + 32)
        let height = readUInt32LE(data, at: start + 36)

        if microSecPerFrame > 0 {
            metadata.frameRate = 1_000_000.0 / Double(microSecPerFrame)
            if totalFrames > 0 {
                metadata.duration = Double(totalFrames) * Double(microSecPerFrame) / 1_000_000.0
            }
        }
        if width > 0 { metadata.videoWidth = Int(width) }
        if height > 0 { metadata.videoHeight = Int(height) }

        // AVIF_ISINTERLEAVED is bit 8; there's no explicit scan-type flag in avih,
        // but many interlaced-source muxers set dwFlags bit 0x20 (unofficial). We
        // prefer the per-stream `dwCaps` inside strh.
        _ = dwFlags
    }

    /// strl: one per stream. Contains strh (stream header) and strf (format).
    private static func parseStrl(_ data: Data, from start: Int, end: Int, into metadata: inout VideoMetadata) {
        var fccType: String = ""
        var fccHandler: String = ""
        var dwScale: UInt32 = 0
        var dwRate: UInt32 = 0
        var dwLength: UInt32 = 0
        var strfStart: Int = -1
        var strfSize: Int = 0

        var offset = start
        while offset + 8 <= end {
            let id = fourCC(data, at: offset)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }

            switch id {
            case "strh":
                // AVIStreamHeader:
                //   fccType(4) + fccHandler(4) + dwFlags(4) + wPriority(2) + wLanguage(2) +
                //   dwInitialFrames(4) + dwScale(4) + dwRate(4) + dwStart(4) + dwLength(4) + …
                if size >= 36 {
                    fccType = fourCC(data, at: payloadStart)
                    fccHandler = fourCC(data, at: payloadStart + 4)
                    dwScale = readUInt32LE(data, at: payloadStart + 20)
                    dwRate = readUInt32LE(data, at: payloadStart + 24)
                    dwLength = readUInt32LE(data, at: payloadStart + 32)
                }
            case "strf":
                strfStart = payloadStart
                strfSize = size
            default:
                break
            }

            offset = payloadEnd + (size & 1)
        }

        guard strfStart >= 0 else { return }

        if fccType == "vids" {
            var stream = VideoStream(index: metadata.videoStreams.count)
            stream.codec = fccHandler.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            stream.codecName = codecLongNameAVI(fccHandler)

            // BITMAPINFOHEADER:
            //   biSize(4) + biWidth(4) + biHeight(4) + biPlanes(2) + biBitCount(2) +
            //   biCompression(4) + biSizeImage(4) + biXPelsPerMeter(4) + biYPelsPerMeter(4) +
            //   biClrUsed(4) + biClrImportant(4)
            if strfSize >= 40 {
                let width = readInt32LE(data, at: strfStart + 4)
                let height = readInt32LE(data, at: strfStart + 8)
                let bitCount = Int(readUInt16LE(data, at: strfStart + 14))
                let compression = fourCC(data, at: strfStart + 16)

                stream.width = Int(abs(width))
                stream.height = Int(abs(height))
                if bitCount > 0 { stream.bitDepth = bitCount / max(1, 3) }

                // biCompression is the "real" FourCC (strh.fccHandler can be 0 for
                // uncompressed streams). Prefer it when not all-zero.
                let compTrim = compression.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                if !compTrim.isEmpty, compTrim != "RGB" {
                    stream.codec = compTrim
                    stream.codecName = codecLongNameAVI(compTrim) ?? compTrim
                }

                // Bit depth: for packed RGB streams biBitCount is total bits per pixel;
                // for YUV we can't infer per-component depth without the FourCC map.
                if compTrim.isEmpty || compTrim == "RGB" {
                    stream.bitDepth = bitCount
                }
            }

            if dwScale > 0, dwRate > 0 {
                stream.frameRate = Double(dwRate) / Double(dwScale)
                if dwLength > 0 {
                    stream.duration = Double(dwLength) * Double(dwScale) / Double(dwRate)
                    stream.frameCount = Int(dwLength)
                }
            }

            if stream.chromaSubsampling == nil, let codec = stream.codec {
                stream.chromaSubsampling = chromaGuess(forCodec: codec)
            }

            metadata.videoStreams.append(stream)

            if metadata.duration == nil, let d = stream.duration { metadata.duration = d }
        } else if fccType == "auds" {
            var stream = AudioStream(index: metadata.audioStreams.count)

            // WAVEFORMATEX:
            //   wFormatTag(2) + nChannels(2) + nSamplesPerSec(4) + nAvgBytesPerSec(4) +
            //   nBlockAlign(2) + wBitsPerSample(2) + cbSize(2) …
            if strfSize >= 16 {
                let formatTag = Int(readUInt16LE(data, at: strfStart))
                let channels = Int(readUInt16LE(data, at: strfStart + 2))
                let sampleRate = Int(readUInt32LE(data, at: strfStart + 4))
                let avgBytesPerSec = Int(readUInt32LE(data, at: strfStart + 8))
                let bitsPerSample = Int(readUInt16LE(data, at: strfStart + 14))
                stream.channels = channels
                stream.sampleRate = sampleRate
                stream.bitDepth = bitsPerSample
                if avgBytesPerSec > 0 {
                    stream.bitRate = avgBytesPerSec * 8
                }
                stream.codec = String(format: "0x%04X", formatTag)
                stream.codecName = audioFormatTagName(UInt16(formatTag))
            }

            if dwScale > 0, dwRate > 0, dwLength > 0 {
                stream.duration = Double(dwLength) * Double(dwScale) / Double(dwRate)
            }

            if stream.channelLayout == nil, let ch = stream.channels {
                stream.channelLayout = defaultChannelLayout(forChannels: ch)
            }
            metadata.audioStreams.append(stream)
        } else if fccType == "txts" {
            // Text / subtitle stream. Codec comes from strh.fccHandler — common
            // values are "DXSB" (XSUB bitmap subtitles) and "UTF8" (plain text).
            var stream = SubtitleStream(index: metadata.subtitleStreams.count)
            let handler = fccHandler.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            if !handler.isEmpty {
                stream.codec = handler
                stream.codecName = subtitleCodecNameAVI(handler)
            }
            if dwScale > 0, dwRate > 0, dwLength > 0 {
                stream.duration = Double(dwLength) * Double(dwScale) / Double(dwRate)
            }
            metadata.subtitleStreams.append(stream)
        }
    }

    private static func chromaGuess(forCodec codec: String) -> String? {
        switch codec.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) {
        case "H264", "X264", "AVC1", "AVC",
             "HEVC", "HVC1", "HEV1", "H265", "X265",
             "XVID", "DIVX", "DX50", "MP4V",
             "MJPG",
             "VP80", "VP90", "AV01":
            return "4:2:0"
        case "DVSD", "DVHD", "DV25":
            return "4:1:1"
        case "DV50":
            return "4:2:2"
        default:
            return nil
        }
    }

    private static func defaultChannelLayout(forChannels n: Int) -> String? {
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

    private static func parseOdml(_ data: Data, from start: Int, end: Int, into metadata: inout VideoMetadata) {
        var offset = start
        while offset + 8 <= end {
            let id = fourCC(data, at: offset)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }

            if id == "dmlh", size >= 4 {
                // dmlh.dwTotalFrames — the only reliable frame count for >4 GB files.
                let totalFrames = readUInt32LE(data, at: payloadStart)
                if totalFrames > 0, let fps = metadata.frameRate, fps > 0 {
                    metadata.duration = Double(totalFrames) / fps
                }
            }

            offset = payloadEnd + (size & 1)
        }
    }

    private static func parseINFOList(_ data: Data, from start: Int, end: Int, into metadata: inout VideoMetadata) {
        var offset = start
        while offset + 8 <= end {
            let id = fourCC(data, at: offset)
            let size = Int(readUInt32LE(data, at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }

            let value = readASCIIPayload(data, from: payloadStart, size: size)
            switch id {
            case "INAM": if metadata.title == nil { metadata.title = value }
            case "IART": if metadata.artist == nil { metadata.artist = value }
            case "ICMT": if metadata.comment == nil { metadata.comment = value }
            default: break
            }

            offset = payloadEnd + (size & 1)
        }
    }

    // MARK: - RIFF primitives

    private static func readRIFFSize(_ data: Data) -> Int {
        guard data.count >= 8 else { return 0 }
        return Int(readUInt32LE(data, at: 4))
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return String(data: Data(bytes), encoding: .ascii) ?? ""
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let s = data.startIndex
        return UInt16(data[s + offset]) | (UInt16(data[s + offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let s = data.startIndex
        return UInt32(data[s + offset])
            | (UInt32(data[s + offset + 1]) << 8)
            | (UInt32(data[s + offset + 2]) << 16)
            | (UInt32(data[s + offset + 3]) << 24)
    }

    private static func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32LE(data, at: offset))
    }

    private static func readASCIIPayload(_ data: Data, from offset: Int, size: Int) -> String? {
        guard offset + size <= data.count, size > 0 else { return nil }
        let slice = data[data.startIndex + offset ..< data.startIndex + offset + size]
        let trimmed = slice.prefix(while: { $0 != 0 })
        return String(data: Data(trimmed), encoding: .utf8)
            ?? String(data: Data(trimmed), encoding: .isoLatin1)
    }

    // MARK: - Codec naming

    private static func codecLongNameAVI(_ fourCC: String) -> String? {
        let clean = fourCC.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).uppercased()
        switch clean {
        case "H264", "X264", "AVC1", "AVC": return "H.264 / AVC"
        case "HEVC", "HVC1", "HEV1", "H265", "X265": return "H.265 / HEVC"
        case "XVID", "DIVX", "DX50", "MP4V": return "MPEG-4 ASP"
        case "MJPG": return "Motion JPEG"
        case "DVSD", "DVHD", "DV25", "DV50": return "DV"
        case "VP80": return "VP8"
        case "VP90": return "VP9"
        case "AV01": return "AV1"
        case "": return "Uncompressed"
        default: return nil
        }
    }

    private static func subtitleCodecNameAVI(_ fourCC: String) -> String? {
        let clean = fourCC.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).uppercased()
        switch clean {
        case "DXSB": return "DivX Subtitles (XSUB)"
        case "UTF8": return "Plain UTF-8 Text"
        default: return nil
        }
    }

    private static func audioFormatTagName(_ tag: UInt16) -> String? {
        switch tag {
        case 0x0001: return "PCM (signed 16-bit)"
        case 0x0003: return "PCM (IEEE float)"
        case 0x0050: return "MPEG-1 Layer II"
        case 0x0055: return "MPEG-1 Layer III (MP3)"
        case 0x0092: return "Dolby Digital (AC-3)"
        case 0x00FF, 0x1600, 0x1601: return "AAC"
        case 0x2000: return "AC-3"
        case 0x2001: return "DTS"
        default: return nil
        }
    }
}
