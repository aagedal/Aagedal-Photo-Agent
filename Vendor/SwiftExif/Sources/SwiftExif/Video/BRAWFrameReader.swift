import Foundation

/// Per-frame BRAW metadata extracted from the `bmdf` header that opens
/// every video chunk in mdat. All value fields are optional because
/// individual atoms can be absent on a given camera body / firmware
/// combo (most commonly: lens strings empty when no electronic lens is
/// attached).
public struct BRAWFrameAttribute: Sendable, Equatable {
    public let frameIndex: Int
    public let timestampSeconds: Double

    /// "180°" — UTF-8, exact on-disk content. Numeric column in CSV.
    public let shutterAngle: String?
    /// "f2.7"
    public let aperture: String?
    /// "135mm"
    public let focalLength: String?
    /// "2430mm"
    public let focusDistance: String?
    public let iso: Int?
    public let whiteBalanceKelvin: Int?
    public let whiteBalanceTint: Int?

    public init(
        frameIndex: Int,
        timestampSeconds: Double,
        shutterAngle: String? = nil,
        aperture: String? = nil,
        focalLength: String? = nil,
        focusDistance: String? = nil,
        iso: Int? = nil,
        whiteBalanceKelvin: Int? = nil,
        whiteBalanceTint: Int? = nil
    ) {
        self.frameIndex = frameIndex
        self.timestampSeconds = timestampSeconds
        self.shutterAngle = shutterAngle
        self.aperture = aperture
        self.focalLength = focalLength
        self.focusDistance = focusDistance
        self.iso = iso
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.whiteBalanceTint = whiteBalanceTint
    }
}

/// One IMU sample from a BRAW `mebx` motion-data track. Vec3 components
/// are big-endian-container, little-endian-payload float32s — gyroscope
/// values are in rad/s, accelerometer values are in m/s² (with gravity
/// observable on whichever axis is up at record-start).
public struct BRAWMotionSample: Sendable, Equatable {
    public let timestampSeconds: Double
    public let x: Float
    public let y: Float
    public let z: Float

    public init(timestampSeconds: Double, x: Float, y: Float, z: Float) {
        self.timestampSeconds = timestampSeconds
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Selects which `mebx` timed-metadata track to read.
public enum BRAWMotionStream: String, Sendable, CaseIterable {
    case gyroscope
    case accelerometer

    /// 4-byte ASCII key id BMD writes in front of every sample's vec3
    /// payload. Used to gate the per-sample decode against a stream
    /// mismatch (silent corruption is worse than a partial read).
    fileprivate var sampleKeyID: String {
        switch self {
        case .gyroscope: return "mogy"
        case .accelerometer: return "moac"
        }
    }

    /// Substring the `mebx → keys → keyd` declaration must contain
    /// for this stream. We don't fully parse the keys table — a
    /// substring scan is sufficient and matches `detectBRAWMotionTracks`.
    fileprivate var keysNamespace: String {
        switch self {
        case .gyroscope: return "com.blackmagicdesign.motiondata.gyroscope"
        case .accelerometer: return "com.blackmagicdesign.motiondata.accelerometer"
        }
    }
}

/// Reverse-engineered per-frame readers for Blackmagic RAW. Wraps the
/// stbl walkers in `MP4Parser` to expose two time-series streams the
/// aggregate `VideoMetadata.read` only samples once.
///
/// - `readAttributes` walks every video chunk, decoding the `bmdf` header
///   (shutter angle, aperture, focal length, focus distance, ISO, WB
///   Kelvin / tint) per frame.
/// - `readMotionSamples` walks the gyroscope or accelerometer `mebx`
///   track, decoding its 20-byte samples (`size + key_id + 3× float32 LE`)
///   into vec3 values with timestamps.
///
/// Neither attaches to `VideoMetadata` — these are dedicated time-series
/// outputs that would balloon the aggregate model. `swift-exif braw-frames`
/// is the CSV consumer.
public enum BRAWFrameReader {

    /// Read every frame's `bmdf` interpretation header. Returns one entry
    /// per video sample in the BRAW track, with cumulative `stts`-derived
    /// timestamps in seconds. Throws `.invalidVideo` when the file isn't
    /// BRAW (no `br*` video sample entry) or the trak lacks the sample
    /// tables we need to walk.
    public static func readAttributes(from url: URL) throws -> [BRAWFrameAttribute] {
        // Map rather than copy — BRAW files are routinely 10s of GB and the
        // reader only scatter-reads small per-frame `bmdf` payloads. Matches
        // the `VideoMetadata.loadContainerData` rationale (`.alwaysMapped`
        // because external volumes silently defeat `.mappedIfSafe`).
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readAttributes(from: data)
    }

    public static func readAttributes(from data: Data) throws -> [BRAWFrameAttribute] {
        guard let trakData = try findBRAWVideoTrack(in: data) else {
            throw MetadataError.invalidVideo("No Blackmagic RAW video track found")
        }
        return try walkBRAWVideoFrames(trakData: trakData, fullData: data)
    }

    /// Read every IMU sample from a BRAW `mebx` motion-data track.
    /// `stream` selects gyroscope (rad/s) vs accelerometer (m/s²).
    /// Returns an empty array when the requested stream is absent.
    public static func readMotionSamples(
        from url: URL, stream: BRAWMotionStream
    ) throws -> [BRAWMotionSample] {
        // Same mmap rationale as `readAttributes(from url:)` above.
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try readMotionSamples(from: data, stream: stream)
    }

    public static func readMotionSamples(
        from data: Data, stream: BRAWMotionStream
    ) throws -> [BRAWMotionSample] {
        guard let trakData = try findMebxTrack(in: data, matching: stream.keysNamespace) else {
            return []
        }
        return walkMebxSamples(
            trakData: trakData,
            fullData: data,
            expectedKeyID: stream.sampleKeyID
        )
    }

    // MARK: - Track discovery

    /// Find the first BRAW video track (handler `vide`, codec FourCC
    /// starting with `br`). Returns its raw `trak` data.
    private static func findBRAWVideoTrack(in fullData: Data) throws -> Data? {
        guard let moov = try topLevelBox(named: "moov", in: fullData) else { return nil }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov)
        for trak in moovChildren where trak.type == "trak" {
            guard MP4Parser.trakHandlerType(trak.data) == "vide" else { continue }
            guard let stsd = try? stsdBox(of: trak.data),
                  let codec = MP4Parser.parseFirstStsdCodec(stsd),
                  codec.hasPrefix("br") else { continue }
            return trak.data
        }
        return nil
    }

    /// Find an `mebx` track whose `keys → keyd` declaration includes the
    /// given namespace substring (e.g. "com.blackmagicdesign.motiondata.gyroscope").
    private static func findMebxTrack(
        in fullData: Data, matching namespaceSubstring: String
    ) throws -> Data? {
        guard let moov = try topLevelBox(named: "moov", in: fullData) else { return nil }
        let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov)
        let needle = Data(namespaceSubstring.utf8)
        for trak in moovChildren where trak.type == "trak" {
            guard let stsd = try? stsdBox(of: trak.data) else { continue }
            // The mebx key declarations live as children of the first
            // sample entry. Walking the box hierarchy is overkill —
            // detectBRAWMotionTracks already established that the
            // namespace string sits inline in the stsd payload as ASCII,
            // so a substring scan is reliable and cheap.
            if stsd.range(of: Data("mebx".utf8)) != nil,
               stsd.range(of: needle) != nil {
                return trak.data
            }
        }
        return nil
    }

    /// Walk the file's top-level boxes (incremental, no full-tree parse)
    /// and return the payload of the first box whose type matches.
    private static func topLevelBox(named type: String, in fullData: Data) throws -> Data? {
        let boxes = try ISOBMFFBoxReader.parseBoxes(from: fullData)
        return boxes.first(where: { $0.type == type })?.data
    }

    /// Drill `trak → mdia → minf → stbl → stsd` and return its payload.
    private static func stsdBox(of trakData: Data) throws -> Data {
        guard let mdia = try ISOBMFFBoxReader.parseBoxes(from: trakData)
                .first(where: { $0.type == "mdia" }),
              let minf = try ISOBMFFBoxReader.parseBoxes(from: mdia.data)
                .first(where: { $0.type == "minf" }),
              let stbl = try ISOBMFFBoxReader.parseBoxes(from: minf.data)
                .first(where: { $0.type == "stbl" }),
              let stsd = try ISOBMFFBoxReader.parseBoxes(from: stbl.data)
                .first(where: { $0.type == "stsd" }) else {
            throw MetadataError.invalidVideo("trak lacks mdia/minf/stbl/stsd chain")
        }
        return stsd.data
    }

    // MARK: - Per-frame bmdf walker

    private static func walkBRAWVideoFrames(
        trakData: Data, fullData: Data
    ) throws -> [BRAWFrameAttribute] {
        guard let mdia = try ISOBMFFBoxReader.parseBoxes(from: trakData)
                .first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let mdhdInfo = MP4Parser.parseMDHD(mdhd.data),
              mdhdInfo.timescale > 0,
              let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data) else {
            throw MetadataError.invalidVideo("BRAW trak lacks the sample tables we need")
        }

        let timescale = Double(mdhdInfo.timescale)
        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stcoBox = stblChildren.first(where: { $0.type == "stco" })
        let co64Box = stblChildren.first(where: { $0.type == "co64" })

        guard let starts = sttsBox.flatMap({ MP4Parser.sttsSampleStartTicks($0.data) }),
              !starts.isEmpty else {
            throw MetadataError.invalidVideo("BRAW trak missing stts entries")
        }
        let chunkOffsets: [UInt64] = {
            if let b = co64Box { return MP4Parser.co64Offsets(b.data) }
            if let b = stcoBox { return MP4Parser.stcoOffsets(b.data).map(UInt64.init) }
            return []
        }()
        guard !chunkOffsets.isEmpty else {
            throw MetadataError.invalidVideo("BRAW trak missing stco/co64")
        }

        // BRAW writes one sample per chunk, so chunk count == sample count.
        // (stsc may be present with a single (1, 1, 1) entry; we don't need
        // it for this layout.)
        let sampleCount = min(starts.count, chunkOffsets.count)

        var out: [BRAWFrameAttribute] = []
        out.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let offset = chunkOffsets[i]
            guard let window = MP4Parser.brawFrameWindow(at: offset, in: fullData) else { continue }
            let timestamp = Double(starts[i]) / timescale
            let payload = MP4Parser.decodeBRAWFrameHeader(window)
            // Even when payload is nil we still emit a row — the timestamp
            // grid stays continuous. The CSV columns will simply be empty.
            out.append(BRAWFrameAttribute(
                frameIndex: i,
                timestampSeconds: timestamp,
                shutterAngle: payload?.shutterAngle,
                aperture: payload?.aperture,
                focalLength: payload?.focalLength,
                focusDistance: payload?.focusDistance,
                iso: payload?.iso,
                whiteBalanceKelvin: payload?.whiteBalanceKelvin,
                whiteBalanceTint: payload?.whiteBalanceTint
            ))
        }
        return out
    }

    // MARK: - Mebx motion-sample walker

    private static func walkMebxSamples(
        trakData: Data, fullData: Data, expectedKeyID: String
    ) -> [BRAWMotionSample] {
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
            return []
        }

        let timescale = Double(mdhdInfo.timescale)
        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stscBox = stblChildren.first(where: { $0.type == "stsc" })
        let stcoBox = stblChildren.first(where: { $0.type == "stco" })
        let co64Box = stblChildren.first(where: { $0.type == "co64" })

        guard let starts = sttsBox.flatMap({ MP4Parser.sttsSampleStartTicks($0.data) }),
              let sizes = stszBox.flatMap({ MP4Parser.stszSampleSizes($0.data) }),
              !starts.isEmpty, !sizes.isEmpty else { return [] }
        let samplesPerChunk = stscBox.flatMap { MP4Parser.stscSamplesPerChunk($0.data) } ?? []
        let chunkOffsets: [UInt64] = {
            if let b = co64Box { return MP4Parser.co64Offsets(b.data) }
            if let b = stcoBox { return MP4Parser.stcoOffsets(b.data).map(UInt64.init) }
            return []
        }()
        guard !chunkOffsets.isEmpty else { return [] }

        let sampleCount = min(starts.count, sizes.count)
        let sampleOffsets = MP4Parser.sampleFileOffsets(
            sampleCount: sampleCount,
            sizes: sizes,
            samplesPerChunk: samplesPerChunk,
            chunkOffsets: chunkOffsets
        )
        guard sampleOffsets.count == sampleCount else { return [] }

        let expectedKeyBytes = Array(expectedKeyID.utf8)
        var out: [BRAWMotionSample] = []
        out.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            // `sampleOffsets[i]` is a raw 64-bit value from a `co64` box, so a
            // crafted file can set it past Int.max where `Int(...)` traps. Bound
            // it in UInt64 space first (mirrors MP4Parser.brawFrameWindow).
            guard sampleOffsets[i] <= UInt64(Int.max) else { break }
            let off = Int(sampleOffsets[i])
            let size = sizes[i]
            // Each sample is `[uint32 BE size=20][4-byte key id][3× float32 LE]`.
            // Anything else means we're misaligned — bail rather than emit
            // garbage. (A clean partial read is more useful than a corrupt
            // full read for time-series analysis.)
            // Subtraction, not `off + 20`: off can reach Int.max and overflow.
            guard size >= 20,
                  off >= 0, off <= fullData.count - 20 else { break }
            let base = fullData.startIndex + off
            // Validate sample key id.
            let keyStart = base + 4
            guard fullData[keyStart] == expectedKeyBytes[0],
                  fullData[keyStart + 1] == expectedKeyBytes[1],
                  fullData[keyStart + 2] == expectedKeyBytes[2],
                  fullData[keyStart + 3] == expectedKeyBytes[3] else { break }
            // Decode the 12-byte vec3 payload as 3× float32 little-endian.
            // (The container is big-endian; this is a BMD-specific quirk.)
            let payloadBase = base + 8
            let x = readFloat32LE(fullData, at: payloadBase)
            let y = readFloat32LE(fullData, at: payloadBase + 4)
            let z = readFloat32LE(fullData, at: payloadBase + 8)
            let timestamp = Double(starts[i]) / timescale
            out.append(BRAWMotionSample(
                timestampSeconds: timestamp, x: x, y: y, z: z
            ))
        }
        return out
    }

    /// Decode a 4-byte little-endian float32 from `data` at the given
    /// absolute index. Caller guarantees `index + 4 <= data.endIndex`.
    private static func readFloat32LE(_ data: Data, at index: Data.Index) -> Float {
        let bits = UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
        return Float(bitPattern: bits)
    }
}
