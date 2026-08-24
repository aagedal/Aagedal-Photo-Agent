import Foundation

/// Parser for GoPro's GPMF — Generic Polymorphic Metadata Format.
///
/// GPMF is a self-describing KLV (Key-Length-Value) binary format that
/// GoPro Hero / MAX / Karma cameras embed as a `gpmd` track inside MP4 /
/// MOV files. Each sample carries frame-rate GPS, accelerometer, gyroscope,
/// magnetometer, scene-classifier, and face-detection telemetry.
///
/// Format spec: https://github.com/gopro/gpmf-parser/blob/main/docs/README.md
///
/// Each KLV entry is at minimum 8 bytes:
///   bytes 0..3   : FourCC key (ASCII)
///   byte  4      : type (one of `gpmfType`)
///   byte  5      : sample size in bytes
///   bytes 6..7   : sample count (big-endian uint16)
///   bytes 8..    : payload, padded out to a 4-byte boundary
///
/// A container key has type == 0; its payload is itself a sequence of KLV
/// entries describing nested telemetry streams (DEVC → STRM → ACCL/GYRO/...).
public struct GPMFReader: Sendable {

    /// One decoded KLV entry. Containers carry no value bytes — their
    /// children are parsed recursively into `children`.
    public struct Entry: Sendable, Equatable {
        public let fourCC: String
        public let type: GPMFType
        public let sampleSize: Int
        public let sampleCount: Int
        /// Raw payload bytes (not present for containers).
        public let payload: Data
        /// Nested entries (only present when `type == .container`).
        public let children: [Entry]
    }

    /// GPMF type codes. See README.md "Type" table in the spec.
    public enum GPMFType: Sendable, Equatable {
        case container          // 0x00
        case int8u              // 'B'
        case int8s              // 'b'
        case int16u             // 'S'
        case int16s             // 's'
        case int32u             // 'L'
        case int32s             // 'l'
        case int64u             // 'J'
        case int64s             // 'j'
        case float32            // 'f'
        case float64            // 'd'
        case fourCC             // 'F'
        case asciiString        // 'c'
        case utcDate            // 'U'   16-byte ASCII "yymmddhhmmss.sss"
        case q1516              // 'q'   15.16 fixed-point
        case q3132              // 'Q'   31.32 fixed-point
        case complexType        // '?'   compound described by a sibling 'TYPE' entry
        case other(UInt8)

        init(_ raw: UInt8) {
            switch raw {
            case 0x00: self = .container
            case 0x42: self = .int8u
            case 0x62: self = .int8s
            case 0x53: self = .int16u
            case 0x73: self = .int16s
            case 0x4C: self = .int32u
            case 0x6C: self = .int32s
            case 0x4A: self = .int64u
            case 0x6A: self = .int64s
            case 0x66: self = .float32
            case 0x64: self = .float64
            case 0x46: self = .fourCC
            case 0x63: self = .asciiString
            case 0x55: self = .utcDate
            case 0x71: self = .q1516
            case 0x51: self = .q3132
            case 0x3F: self = .complexType
            default: self = .other(raw)
            }
        }
    }

    /// High-level extracted GoPro telemetry. Populated where the relevant
    /// stream is present in the source GPMF blob.
    public struct Telemetry: Sendable, Equatable {
        public var deviceName: String?
        public var firmwareVersion: String?
        public var cameraSerialNumber: String?
        public var mediaUniqueID: String?
        /// GPS5/GPS9 sample count (rows of lat,lon,alt,speed,speed3D).
        public var gpsSampleCount: Int = 0
        /// First GPS sample (lat, lon, alt) in degrees / metres.
        public var firstGPS: (lat: Double, lon: Double, alt: Double)?
        /// Last GPS sample.
        public var lastGPS: (lat: Double, lon: Double, alt: Double)?
        public var hasAccelerometer: Bool = false
        public var hasGyroscope: Bool = false
        public var hasMagnetometer: Bool = false
        public var hasGravity: Bool = false
        public var hasFaceDetection: Bool = false
        public var hasSceneClassifier: Bool = false

        public static func == (lhs: Telemetry, rhs: Telemetry) -> Bool {
            lhs.deviceName == rhs.deviceName
                && lhs.firmwareVersion == rhs.firmwareVersion
                && lhs.cameraSerialNumber == rhs.cameraSerialNumber
                && lhs.mediaUniqueID == rhs.mediaUniqueID
                && lhs.gpsSampleCount == rhs.gpsSampleCount
                && lhs.firstGPS?.lat == rhs.firstGPS?.lat
                && lhs.firstGPS?.lon == rhs.firstGPS?.lon
                && lhs.firstGPS?.alt == rhs.firstGPS?.alt
                && lhs.lastGPS?.lat == rhs.lastGPS?.lat
                && lhs.lastGPS?.lon == rhs.lastGPS?.lon
                && lhs.lastGPS?.alt == rhs.lastGPS?.alt
                && lhs.hasAccelerometer == rhs.hasAccelerometer
                && lhs.hasGyroscope == rhs.hasGyroscope
                && lhs.hasMagnetometer == rhs.hasMagnetometer
                && lhs.hasGravity == rhs.hasGravity
                && lhs.hasFaceDetection == rhs.hasFaceDetection
                && lhs.hasSceneClassifier == rhs.hasSceneClassifier
        }

        public init() {}
    }

    /// Hard cap on container nesting depth. Real GoPro telemetry tops out at
    /// `DEVC → STRM → leaf` (depth 2–3); 32 leaves plenty of headroom while
    /// keeping a crafted blob from blowing the thread stack via unbounded
    /// recursion. Mirrors `XMPReader.maxFrameDepth`.
    static let maxRecursionDepth = 32

    /// Parse a raw GPMF buffer (typically the concatenated payload of every
    /// `gpmd`-track sample) into a tree of entries.
    public static func parse(_ data: Data) -> [Entry] {
        // `parseEntries` treats `range`/`off` as offsets *relative to*
        // `data.startIndex` — it converts to absolute indices via `data[s + off]`
        // and clamps recursion with `data.count`. Seed it with `0 ..< count`, not
        // the absolute `startIndex ..< endIndex`: a sliced `Data` argument (non-zero
        // `startIndex`, e.g. `parse(buf[100...])`) would otherwise double-count
        // `startIndex` and index past `endIndex` → out-of-bounds trap.
        parseEntries(in: data, range: 0 ..< data.count)
    }

    /// High-level convenience: walk the GPMF tree and pull common telemetry.
    public static func telemetry(from data: Data) -> Telemetry {
        var t = Telemetry()
        var scaleStack: [[Double]] = []
        let entries = parse(data)
        walk(entries, scaleStack: &scaleStack, telemetry: &t)
        return t
    }

    // MARK: - Recursive walker

    private static func parseEntries(in data: Data, range: Range<Int>, depth: Int = 0) -> [Entry] {
        var out: [Entry] = []
        var off = range.lowerBound
        while off + 8 <= range.upperBound {
            let s = data.startIndex
            // FourCC + type + sample size + sample count
            let fcc = data[s + off ..< s + off + 4]
            guard let cc = String(data: Data(fcc), encoding: .ascii) else { return out }
            let typeRaw = data[s + off + 4]
            let sampleSize = Int(data[s + off + 5])
            let sampleCount = (Int(data[s + off + 6]) << 8) | Int(data[s + off + 7])
            let type = GPMFType(typeRaw)

            let payloadBytes = sampleSize * sampleCount
            // Payload is padded out to a 4-byte boundary in the container.
            let paddedPayload = ((payloadBytes + 3) / 4) * 4
            let payloadStart = off + 8
            let payloadEnd = min(payloadStart + paddedPayload, range.upperBound)
            guard payloadEnd >= payloadStart else { break }

            let payload = Data(data[s + payloadStart ..< s + min(payloadStart + payloadBytes, payloadEnd)])

            var children: [Entry] = []
            // Stop descending once `maxRecursionDepth` levels deep — a crafted
            // GPMF can chain containers ad infinitum (8 bytes per level), which
            // would otherwise blow the thread stack. Same graceful-degradation
            // posture as the range clamp below: keep the entry, drop children.
            if case .container = type, depth < GPMFReader.maxRecursionDepth {
                // Clamp recursive range to the actual buffer: an attacker-controlled
                // sampleSize × sampleCount can declare a payload that extends past
                // the buffer, and the inner loop's `off + 8 <= range.upperBound`
                // check would otherwise let reads run off the end of `data`.
                let childEnd = min(payloadStart + payloadBytes, payloadEnd, data.count)
                children = parseEntries(in: data,
                                         range: payloadStart ..< childEnd,
                                         depth: depth + 1)
            }

            out.append(Entry(
                fourCC: cc, type: type,
                sampleSize: sampleSize, sampleCount: sampleCount,
                payload: payload, children: children))

            off = payloadEnd
        }
        return out
    }

    /// Walk a GPMF subtree harvesting telemetry summaries.
    /// `scaleStack` carries the active SCAL multipliers for the enclosing STRM.
    private static func walk(_ entries: [Entry], scaleStack: inout [[Double]], telemetry: inout Telemetry) {
        var localScale: [Double]? = nil
        for entry in entries {
            switch entry.fourCC {
            case "DVNM":
                telemetry.deviceName = telemetry.deviceName ?? decodeASCII(entry)
            case "FMWR":
                telemetry.firmwareVersion = telemetry.firmwareVersion ?? decodeASCII(entry)
            case "CASN":
                telemetry.cameraSerialNumber = telemetry.cameraSerialNumber ?? decodeASCII(entry)
            case "MUID":
                if telemetry.mediaUniqueID == nil {
                    telemetry.mediaUniqueID = entry.payload.map { String(format: "%02x", $0) }.joined()
                }
            case "SCAL":
                var values = decodeIntegers(entry).map { Double($0) }
                if values.isEmpty { values = decodeFloats(entry) }
                if !values.isEmpty {
                    localScale = values
                    scaleStack.append(values)
                }
            case "GPS5", "GPS9":
                applyGPS5(entry, scale: scaleStack.last, into: &telemetry)
            case "ACCL":
                telemetry.hasAccelerometer = true
            case "GYRO":
                telemetry.hasGyroscope = true
            case "MAGN":
                telemetry.hasMagnetometer = true
            case "GRAV":
                telemetry.hasGravity = true
            case "FACE":
                telemetry.hasFaceDetection = true
            case "SCEN":
                telemetry.hasSceneClassifier = true
            default:
                break
            }
            if !entry.children.isEmpty {
                let depthBeforeChildren = scaleStack.count
                walk(entry.children, scaleStack: &scaleStack, telemetry: &telemetry)
                while scaleStack.count > depthBeforeChildren { scaleStack.removeLast() }
            }
        }
        if localScale != nil, scaleStack.last == localScale {
            scaleStack.removeLast()
        }
    }

    // MARK: - Payload decoders

    /// GPS5: 5 × int32 per sample (lat, lon, alt, 2D speed, 3D speed).
    /// SCAL provides per-component divisors (e.g. 10_000_000 for lat/lon, 1000 for alt).
    /// GPS9 extends with two additional uint32 fields (DOP, fix). We treat them the same.
    private static func applyGPS5(_ entry: Entry, scale: [Double]?, into telemetry: inout Telemetry) {
        guard entry.sampleSize > 0, entry.sampleCount > 0 else { return }
        let perSampleInts = entry.sampleSize / 4
        guard perSampleInts >= 3 else { return }
        let bytesNeeded = entry.sampleSize * entry.sampleCount
        guard entry.payload.count >= bytesNeeded else { return }
        let s = scale ?? []
        let scLat = s.count > 0 ? s[0] : 10_000_000
        let scLon = s.count > 1 ? s[1] : 10_000_000
        let scAlt = s.count > 2 ? s[2] : 1_000
        var samples: [(lat: Double, lon: Double, alt: Double)] = []
        samples.reserveCapacity(entry.sampleCount)
        for i in 0..<entry.sampleCount {
            let base = i * entry.sampleSize
            let lat = readInt32BE(entry.payload, at: base)
            let lon = readInt32BE(entry.payload, at: base + 4)
            let alt = readInt32BE(entry.payload, at: base + 8)
            samples.append((
                lat: Double(lat) / scLat,
                lon: Double(lon) / scLon,
                alt: Double(alt) / scAlt
            ))
        }
        telemetry.gpsSampleCount += samples.count
        if telemetry.firstGPS == nil { telemetry.firstGPS = samples.first }
        if let last = samples.last { telemetry.lastGPS = last }
    }

    private static func decodeASCII(_ entry: Entry) -> String? {
        guard !entry.payload.isEmpty else { return nil }
        let bytesNeeded = min(entry.sampleSize * entry.sampleCount, entry.payload.count)
        let trimmed = entry.payload.prefix(bytesNeeded)
        return String(data: Data(trimmed), encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func decodeIntegers(_ entry: Entry) -> [Int] {
        var out: [Int] = []
        let totalSamples = entry.sampleCount * (entry.sampleSize / max(1, byteWidth(entry.type)))
        let width = byteWidth(entry.type)
        guard width > 0, totalSamples > 0 else { return [] }
        for i in 0..<totalSamples {
            let off = i * width
            guard off + width <= entry.payload.count else { break }
            switch entry.type {
            case .int16u: out.append(Int(readUInt16BE(entry.payload, at: off)))
            case .int16s: out.append(Int(readInt16BE(entry.payload, at: off)))
            case .int32u: out.append(Int(UInt32(readUInt32BE(entry.payload, at: off))))
            case .int32s: out.append(Int(readInt32BE(entry.payload, at: off)))
            case .int8u:  out.append(Int(entry.payload[entry.payload.startIndex + off]))
            case .int8s:  out.append(Int(Int8(bitPattern: entry.payload[entry.payload.startIndex + off])))
            default: return []
            }
        }
        return out
    }

    private static func decodeFloats(_ entry: Entry) -> [Double] {
        guard entry.type == .float32 || entry.type == .float64 else { return [] }
        let width = entry.type == .float32 ? 4 : 8
        let totalSamples = entry.sampleCount * (entry.sampleSize / width)
        guard totalSamples > 0 else { return [] }
        var out: [Double] = []
        for i in 0..<totalSamples {
            let off = i * width
            guard off + width <= entry.payload.count else { break }
            if width == 4 {
                let bits = readUInt32BE(entry.payload, at: off)
                out.append(Double(Float(bitPattern: UInt32(bits))))
            } else {
                let bits = readUInt64BE(entry.payload, at: off)
                out.append(Double(bitPattern: bits))
            }
        }
        return out
    }

    private static func byteWidth(_ type: GPMFType) -> Int {
        switch type {
        case .int8u, .int8s, .asciiString: return 1
        case .int16u, .int16s: return 2
        case .int32u, .int32s, .float32, .fourCC: return 4
        case .int64u, .int64s, .float64, .q3132: return 8
        case .q1516: return 4
        default: return 0
        }
    }

    // MARK: - BE readers

    private static func readUInt16BE(_ data: Data, at offset: Int) -> UInt16 {
        let s = data.startIndex + offset
        return (UInt16(data[s]) << 8) | UInt16(data[s + 1])
    }

    private static func readInt16BE(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16BE(data, at: offset))
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return (UInt32(data[s]) << 24)
            | (UInt32(data[s + 1]) << 16)
            | (UInt32(data[s + 2]) << 8)
            | UInt32(data[s + 3])
    }

    private static func readInt32BE(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(data, at: offset))
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let s = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[s + i]) }
        return v
    }
}
