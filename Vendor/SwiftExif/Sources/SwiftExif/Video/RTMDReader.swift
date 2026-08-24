import Foundation

/// Per-frame Sony RTMD attribute snapshot (one entry per rtmd sample, i.e.
/// one per video frame). All optional because individual tags may be
/// missing on a given camera body / firmware combo.
public struct RTMDFrameAttribute: Sendable, Equatable {
    public let frameIndex: Int
    public let timestampSeconds: Double
    public let iso: Int?
    public let exposureTimeSeconds: Double?
    public let fNumber: Double?
    public let focalLengthMm: Double?
    public let captureGamma: String?
    public let whiteBalance: String?
    public let serialNumber: String?
    public let frameRate: Double?
    public let gpsLatitude: Double?
    public let gpsLongitude: Double?
    public let dateTime: String?

    public init(
        frameIndex: Int,
        timestampSeconds: Double,
        iso: Int? = nil,
        exposureTimeSeconds: Double? = nil,
        fNumber: Double? = nil,
        focalLengthMm: Double? = nil,
        captureGamma: String? = nil,
        whiteBalance: String? = nil,
        serialNumber: String? = nil,
        frameRate: Double? = nil,
        gpsLatitude: Double? = nil,
        gpsLongitude: Double? = nil,
        dateTime: String? = nil
    ) {
        self.frameIndex = frameIndex
        self.timestampSeconds = timestampSeconds
        self.iso = iso
        self.exposureTimeSeconds = exposureTimeSeconds
        self.fNumber = fNumber
        self.focalLengthMm = focalLengthMm
        self.captureGamma = captureGamma
        self.whiteBalance = whiteBalance
        self.serialNumber = serialNumber
        self.frameRate = frameRate
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
        self.dateTime = dateTime
    }
}

/// One IMU triple from a Sony RTMD per-frame block. Components are raw
/// signed 16-bit counts (Sony's on-disk format); pitch/roll/yaw counts are
/// gyroscope output, accelerometer counts include gravity (so the up-axis
/// reads ~8000+ at rest).
public struct RTMDMotionSample: Sendable, Equatable {
    public let timestampSeconds: Double
    public let x: Int16
    public let y: Int16
    public let z: Int16

    public init(timestampSeconds: Double, x: Int16, y: Int16, z: Int16) {
        self.timestampSeconds = timestampSeconds
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum RTMDStream: String, Sendable, CaseIterable {
    case gyroscope
    case accelerometer
}

/// Cheap clip-level RTMD summary. Surfaced via `VideoMetadata.rtmd` in
/// regular `read` output. The full per-frame stream lives behind the
/// `rtmd-frames` CLI subcommand to keep `read` from walking thousands of
/// samples on every invocation.
public struct RTMDSummary: Sendable, Equatable {
    /// IMU samples per second derived from the first rtmd sample's
    /// accelerometer header. Sony Alpha bodies typically report 1000 Hz or
    /// 2000 Hz depending on the body and recording mode.
    public let imuSampleRateHz: Int?
    /// Decoded attribute snapshot from the first rtmd sample.
    public let firstFrame: RTMDFrameAttribute?

    public init(imuSampleRateHz: Int?, firstFrame: RTMDFrameAttribute?) {
        self.imuSampleRateHz = imuSampleRateHz
        self.firstFrame = firstFrame
    }
}

/// Reader for Sony Real-Time Metadata (`rtmd`) tracks in MP4/MOV files.
///
/// Sony stores rtmd as a flat 2-byte-tag / 2-byte-length stream after a
/// 28-byte header, with two special cases: tag `0x060e` is a 16-byte SMPTE
/// UL marker (inert), and tag `0x8300` is a transparent container the
/// walker descends into. This is ExifTool's algorithm (`Process_rtmd` in
/// `Sony.pm`) and matches Sony Alpha bodies (A1, A7S III, FX3, FX30, …).
///
/// Per-frame, each rtmd sample carries ISO, exposure, lens, GPS, plus a
/// bulk IMU block with 40 pitch/roll/yaw and 40 accelerometer triples
/// (≈2 kHz IMU at 50 fps). The IMU arrays live at tags `0xe43b` and
/// `0xe44b`, prefixed with an 8-byte (count, sample_size) descriptor that
/// we strip before decoding.
public enum RTMDReader {

    public static func readAttributes(from url: URL) throws -> [RTMDFrameAttribute] {
        // Map rather than copy — Sony XAVC/MXF files are routinely multi-GB
        // and the reader only scatter-reads per-frame RTMD payloads at offsets
        // pulled from sample tables. See `VideoMetadata.loadContainerData`
        // for the full `.alwaysMapped` rationale.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readAttributes(from: data)
    }

    public static func readAttributes(from data: Data) throws -> [RTMDFrameAttribute] {
        guard let trakData = (try? findRTMDTrack(in: data)) ?? nil else {
            throw MetadataError.invalidVideo("No Sony RTMD track found")
        }
        guard let layout = sampleLayout(trakData: trakData, fullData: data) else { return [] }
        var out: [RTMDFrameAttribute] = []
        out.reserveCapacity(layout.offsets.count)
        for i in 0..<layout.offsets.count {
            guard let range = sampleByteRange(offset: layout.offsets[i], size: layout.sizes[i], in: data)
            else { break }
            let payload = data.subdata(in: range)
            let ts = Double(layout.starts[i]) / layout.timescale
            out.append(decodeFrameAttributes(payload: payload, frameIndex: i, timestamp: ts))
        }
        return out
    }

    public static func readMotionSamples(
        from url: URL, stream: RTMDStream
    ) throws -> [RTMDMotionSample] {
        // Same mmap rationale as `readAttributes(from url:)` above.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readMotionSamples(from: data, stream: stream)
    }

    public static func readMotionSamples(
        from data: Data, stream: RTMDStream
    ) throws -> [RTMDMotionSample] {
        guard let trakData = (try? findRTMDTrack(in: data)) ?? nil else {
            throw MetadataError.invalidVideo("No Sony RTMD track found")
        }
        guard let layout = sampleLayout(trakData: trakData, fullData: data) else { return [] }
        let count = layout.offsets.count
        let imuTag: UInt16 = (stream == .gyroscope) ? 0xe43b : 0xe44b
        var out: [RTMDMotionSample] = []
        for i in 0..<count {
            guard let range = sampleByteRange(offset: layout.offsets[i], size: layout.sizes[i], in: data)
            else { break }
            let payload = data.subdata(in: range)
            let frameStart = Double(layout.starts[i]) / layout.timescale
            let frameEnd: Double
            if i + 1 < count {
                frameEnd = Double(layout.starts[i + 1]) / layout.timescale
            } else if i > 0 {
                let prev = Double(layout.starts[i - 1]) / layout.timescale
                frameEnd = frameStart + (frameStart - prev)
            } else {
                frameEnd = frameStart + (1.0 / 50.0)
            }

            guard let raw = findFlatTagValue(payload, tag: imuTag),
                  raw.count >= 8 else { continue }
            // 8-byte header is (uint32 count BE, uint32 sample_size BE);
            // skip it and decode int16BE triples from the remainder.
            let arr = raw.subdata(in: 8..<raw.count)
            let triples = decodeInt16BETriples(arr)
            guard !triples.isEmpty else { continue }
            let dt = (frameEnd - frameStart) / Double(triples.count)
            for (j, t) in triples.enumerated() {
                let ts = frameStart + Double(j) * dt
                out.append(RTMDMotionSample(timestampSeconds: ts, x: t.0, y: t.1, z: t.2))
            }
        }
        return out
    }

    /// Cheap snapshot for `VideoMetadata.read`. Reads the first rtmd
    /// sample only. Returns nil if the file has no rtmd track.
    public static func firstFrameSnapshot(from data: Data) -> RTMDFrameAttribute? {
        guard let trakData = (try? findRTMDTrack(in: data)) ?? nil,
              let layout = sampleLayout(trakData: trakData, fullData: data),
              !layout.offsets.isEmpty else { return nil }
        guard let range = sampleByteRange(offset: layout.offsets[0], size: layout.sizes[0], in: data)
        else { return nil }
        let payload = data.subdata(in: range)
        let ts = layout.starts.first.map { Double($0) / layout.timescale } ?? 0
        return decodeFrameAttributes(payload: payload, frameIndex: 0, timestamp: ts)
    }

    public static func hasRTMDTrack(in data: Data) -> Bool {
        return (try? findRTMDTrack(in: data)) ?? nil != nil
    }

    /// IMU sample rate in Hz from the first rtmd sample. Reads the 8-byte
    /// header on tag 0xe44b: `(count, sample_size)` per frame, divided by
    /// the frame interval.
    public static func estimateIMUSampleRate(in data: Data) -> Int? {
        guard let trakData = (try? findRTMDTrack(in: data)) ?? nil,
              let layout = sampleLayout(trakData: trakData, fullData: data),
              layout.starts.count >= 2 else { return nil }
        guard let range = sampleByteRange(offset: layout.offsets[0], size: layout.sizes[0], in: data)
        else { return nil }
        let payload = data.subdata(in: range)
        guard let raw = findFlatTagValue(payload, tag: 0xe44b), raw.count >= 8 else {
            return nil
        }
        let count = Int(readBigUInt32(raw, at: raw.startIndex) ?? 0)
        let dtTicks = layout.starts[1] - layout.starts[0]
        let frameDuration = Double(dtTicks) / layout.timescale
        guard count > 0, frameDuration > 0 else { return nil }
        return Int((Double(count) / frameDuration).rounded())
    }

    // MARK: - Track discovery

    private static func findRTMDTrack(in fullData: Data) throws -> Data? {
        guard let moov = try topLevelBox(named: "moov", in: fullData) else { return nil }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov)
        for trak in moovChildren where trak.type == "trak" {
            // rtmd tracks use handler type "meta" (per SMPTE RDD-18)
            guard MP4Parser.trakHandlerType(trak.data) == "meta" else { continue }
            guard let stsd = try? stsdBox(of: trak.data),
                  let codec = MP4Parser.parseFirstStsdCodec(stsd),
                  codec == "rtmd" else { continue }
            return trak.data
        }
        return nil
    }

    private static func topLevelBox(named type: String, in fullData: Data) throws -> Data? {
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: fullData)
        return boxes.first(where: { $0.type == type })?.data
    }

    private static func stsdBox(of trakData: Data) throws -> Data {
        guard let mdia = try ISOBMFFBoxReader.parseBoxes(from: trakData)
                .first(where: { $0.type == "mdia" }),
              let minf = try ISOBMFFBoxReader.parseBoxes(from: mdia.data)
                .first(where: { $0.type == "minf" }),
              let stbl = try ISOBMFFBoxReader.parseBoxes(from: minf.data)
                .first(where: { $0.type == "stbl" }),
              let stsd = try ISOBMFFBoxReader.parseBoxes(from: stbl.data)
                .first(where: { $0.type == "stsd" }) else {
            throw MetadataError.invalidVideo("rtmd trak lacks mdia/minf/stbl/stsd chain")
        }
        return stsd.data
    }

    // MARK: - stbl walking

    private struct SampleLayout {
        let timescale: Double
        let starts: [UInt64]
        let sizes: [Int]
        let offsets: [UInt64]
    }

    /// Validate a file-absolute sample window before slicing `data`.
    ///
    /// `offset` comes verbatim from a `co64`/`stco` chunk table, so a crafted
    /// file can push it past `Int.max` — where `Int(offset)` traps and crashes
    /// the parser — or, after the wrapping accumulation in `sampleFileOffsets`,
    /// anywhere in `UInt64`. Bound it in `UInt64` space first, then use
    /// subtraction so the `Int` math can't overflow either (mirrors
    /// `MP4Parser.brawFrameWindow`). Returns nil if the window escapes `data`.
    private static func sampleByteRange(
        offset: UInt64, size: Int, in data: Data
    ) -> Range<Int>? {
        guard size >= 0, offset <= UInt64(Int.max) else { return nil }
        let off = Int(offset)
        guard off <= data.count - size else { return nil }
        return off..<(off + size)
    }

    private static func sampleLayout(trakData: Data, fullData: Data) -> SampleLayout? {
        guard let mdia = try? ISOBMFFBoxReader.parseBoxes(from: trakData)
                .first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let mdhdInfo = MP4Parser.parseMDHD(mdhd.data),
              mdhdInfo.timescale > 0,
              let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data) else {
            return nil
        }
        let timescale = Double(mdhdInfo.timescale)
        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stscBox = stblChildren.first(where: { $0.type == "stsc" })
        let stcoBox = stblChildren.first(where: { $0.type == "stco" })
        let co64Box = stblChildren.first(where: { $0.type == "co64" })

        guard let starts = sttsBox.flatMap({ MP4Parser.sttsSampleStartTicks($0.data) }),
              let sizes = stszBox.flatMap({ MP4Parser.stszSampleSizes($0.data) }),
              !starts.isEmpty, !sizes.isEmpty else { return nil }
        let samplesPerChunk = stscBox.flatMap { MP4Parser.stscSamplesPerChunk($0.data) } ?? []
        let chunkOffsets: [UInt64] = {
            if let b = co64Box { return MP4Parser.co64Offsets(b.data) }
            if let b = stcoBox { return MP4Parser.stcoOffsets(b.data).map(UInt64.init) }
            return []
        }()
        guard !chunkOffsets.isEmpty else { return nil }

        let sampleCount = min(starts.count, sizes.count)
        let offsets = MP4Parser.sampleFileOffsets(
            sampleCount: sampleCount,
            sizes: sizes,
            samplesPerChunk: samplesPerChunk,
            chunkOffsets: chunkOffsets
        )
        guard offsets.count == sampleCount else { return nil }
        return SampleLayout(
            timescale: timescale,
            starts: Array(starts.prefix(sampleCount)),
            sizes: Array(sizes.prefix(sampleCount)),
            offsets: offsets
        )
    }

    // MARK: - Flat tag walker (ExifTool Process_rtmd algorithm)

    /// Walk every (tag, length, value) triple in an rtmd sample, returning
    /// the value bytes for `targetTag` or nil if absent. Stops on the first
    /// match. Tags `0x060e` (16-byte SMPTE UL) are skipped entirely. Tag
    /// `0x8300` is a transparent container — descend into it.
    private static func findFlatTagValue(_ payload: Data, tag targetTag: UInt16) -> Data? {
        guard payload.count >= 4 else { return nil }
        let headerLen = Int(readBigUInt16(payload, at: payload.startIndex) ?? 0)
        var pos = payload.startIndex + headerLen
        let end = payload.endIndex
        while pos + 4 < end {
            guard let tag = readBigUInt16(payload, at: pos) else { return nil }
            if tag == 0 { break }
            guard let lenU = readBigUInt16(payload, at: pos + 2) else { return nil }
            var length = Int(lenU)
            if tag == 0x060e {
                length = 0x10
                if pos + length > end { return nil }
                pos += length
                continue
            } else if tag == 0x8300 {
                // Transparent container — step past header (4 bytes) and
                // continue walking inside it without consuming length.
                pos += 4
                continue
            } else {
                pos += 4
                if pos + length > end { return nil }
                if tag == targetTag {
                    return payload.subdata(in: pos..<(pos + length))
                }
                pos += length
            }
        }
        return nil
    }

    /// Variant that collects every recognised attribute tag in one pass.
    /// Avoids walking the sample once per field.
    private static func decodeFrameAttributes(
        payload: Data, frameIndex: Int, timestamp: Double
    ) -> RTMDFrameAttribute {
        var iso: Int?
        var exposureTime: Double?
        var fNumber: Double?
        var focalLengthMm: Double?
        let captureGamma: String? = nil
        var whiteBalance: String?
        var serialNumber: String?
        var frameRate: Double?
        var gpsLat: Double?
        var gpsLon: Double?
        var dateTime: String?

        guard payload.count >= 4 else {
            return RTMDFrameAttribute(frameIndex: frameIndex, timestampSeconds: timestamp)
        }
        let headerLen = Int(readBigUInt16(payload, at: payload.startIndex) ?? 0)
        var pos = payload.startIndex + headerLen
        let end = payload.endIndex
        while pos + 4 < end {
            guard let tag = readBigUInt16(payload, at: pos) else { break }
            if tag == 0 { break }
            guard let lenU = readBigUInt16(payload, at: pos + 2) else { break }
            var length = Int(lenU)
            if tag == 0x060e {
                length = 0x10
                if pos + length > end { break }
                pos += length
                continue
            } else if tag == 0x8300 {
                pos += 4
                continue
            }
            pos += 4
            if pos + length > end { break }
            let valueRange = pos..<(pos + length)
            let v = payload[valueRange]

            switch tag {
            case 0x8000:
                // FNumber: int16u, ValueConv: 2 ** (8 - val/8192)
                if let raw = readBigUInt16(v, at: v.startIndex) {
                    fNumber = pow(2.0, 8.0 - Double(raw) / 8192.0)
                }
            case 0x8004:
                // FocalLength35efl candidate; some bodies emit this with a
                // useful value, others write 0xffff. Only adopt if value
                // looks plausible (1-10000 mm).
                if let raw = readBigUInt16(v, at: v.startIndex), raw > 0, raw < 10_000 {
                    focalLengthMm = Double(raw) / 10.0
                }
            case 0x8106:
                // FrameRate: rational64u (4-byte num, 4-byte denom)
                if length >= 8,
                   let num = readBigUInt32(v, at: v.startIndex),
                   let den = readBigUInt32(v, at: v.startIndex + 4),
                   den != 0 {
                    frameRate = Double(num) / Double(den)
                }
            case 0x8109:
                // ExposureTime: rational64u
                if length >= 8,
                   let num = readBigUInt32(v, at: v.startIndex),
                   let den = readBigUInt32(v, at: v.startIndex + 4),
                   den != 0 {
                    exposureTime = Double(num) / Double(den)
                }
            case 0x810b:
                if let raw = readBigUInt16(v, at: v.startIndex), iso == nil {
                    iso = Int(raw)
                }
            case 0x8114:
                serialNumber = trimmedString(Data(v))
            case 0xe301:
                // ISO (int32u) — preferred over 0x810b when present.
                if length >= 4, let raw = readBigUInt32(v, at: v.startIndex) {
                    iso = Int(raw)
                }
            case 0xe303:
                // WhiteBalance enum
                if let raw = v.first {
                    whiteBalance = wbName(for: raw)
                }
            case 0xe304:
                // DateTime, 8 bytes encoded BCD-ish: bytes are
                // century, year-low, month, day, hour, min, sec, frame
                if length == 8 {
                    dateTime = decodeRTMDDateTime(Data(v))
                }
            case 0x8502, 0x8504:
                // GPSLatitude / GPSLongitude as rational64u triple
                // (deg, min, sec) — 3 × rational64u = 24 bytes.
                if length >= 24, let deg = parseRationalDMS(Data(v)) {
                    if tag == 0x8502 { gpsLat = deg } else { gpsLon = deg }
                }
            default:
                break
            }
            pos += length
        }
        return RTMDFrameAttribute(
            frameIndex: frameIndex,
            timestampSeconds: timestamp,
            iso: iso,
            exposureTimeSeconds: exposureTime,
            fNumber: fNumber,
            focalLengthMm: focalLengthMm,
            captureGamma: captureGamma,
            whiteBalance: whiteBalance,
            serialNumber: serialNumber,
            frameRate: frameRate,
            gpsLatitude: gpsLat,
            gpsLongitude: gpsLon,
            dateTime: dateTime
        )
    }

    private static func decodeInt16BETriples(_ data: Data) -> [(Int16, Int16, Int16)] {
        var out: [(Int16, Int16, Int16)] = []
        let count = data.count / 6
        out.reserveCapacity(count)
        var i = data.startIndex
        for _ in 0..<count {
            let x = Int16(bitPattern: (UInt16(data[i]) << 8) | UInt16(data[i + 1]))
            let y = Int16(bitPattern: (UInt16(data[i + 2]) << 8) | UInt16(data[i + 3]))
            let z = Int16(bitPattern: (UInt16(data[i + 4]) << 8) | UInt16(data[i + 5]))
            out.append((x, y, z))
            i += 6
        }
        return out
    }

    // MARK: - Helpers

    private static func readBigUInt16(_ data: Data, at index: Data.Index) -> UInt16? {
        guard index >= data.startIndex, index + 2 <= data.endIndex else { return nil }
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }

    private static func readBigUInt32(_ data: Data, at index: Data.Index) -> UInt32? {
        guard index >= data.startIndex, index + 4 <= data.endIndex else { return nil }
        return (UInt32(data[index]) << 24)
             | (UInt32(data[index + 1]) << 16)
             | (UInt32(data[index + 2]) << 8)
             |  UInt32(data[index + 3])
    }

    private static func trimmedString(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\r\n"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func wbName(for raw: UInt8) -> String? {
        switch raw {
        case 1: return "Incandescent"
        case 2: return "Fluorescent"
        case 4: return "Daylight"
        case 5: return "Cloudy"
        case 6: return "Custom"
        case 255: return "Preset"
        default: return nil
        }
    }

    /// Decode RTMD DateTime tag 0xe304 — 8 bytes per Sony.pm:
    ///   `unpack("x1H4H2H2H2H2H2", $val)` → "YYYY:MM:DD HH:MM:SS"
    /// First byte skipped, then 4 hex digits = year, 2 = month, ...
    private static func decodeRTMDDateTime(_ data: Data) -> String? {
        guard data.count == 8 else { return nil }
        let bytes = Array(data)
        let yearHex = String(format: "%02X%02X", bytes[1], bytes[2])
        let monthHex = String(format: "%02X", bytes[3])
        let dayHex = String(format: "%02X", bytes[4])
        let hourHex = String(format: "%02X", bytes[5])
        let minHex = String(format: "%02X", bytes[6])
        let secHex = String(format: "%02X", bytes[7])
        return "\(yearHex):\(monthHex):\(dayHex) \(hourHex):\(minHex):\(secHex)"
    }

    /// Decode a 24-byte (deg, min, sec) rational64u triple to decimal degrees.
    private static func parseRationalDMS(_ data: Data) -> Double? {
        guard data.count >= 24 else { return nil }
        func r(_ off: Int) -> Double? {
            guard let n = readBigUInt32(data, at: data.startIndex + off),
                  let d = readBigUInt32(data, at: data.startIndex + off + 4),
                  d != 0 else { return nil }
            return Double(n) / Double(d)
        }
        guard let deg = r(0), let min = r(8), let sec = r(16) else { return nil }
        return deg + min / 60.0 + sec / 3600.0
    }
}
