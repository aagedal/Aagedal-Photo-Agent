import Foundation

/// Reads metadata from Canon Cinema RAW Light files (.CRM master and .CRL
/// proxy). Both share the same on-disk structure: an ISOBMFF container with
/// `ftyp` brand `crx ` and a Canon-metadata UUID inside `moov` (identical to
/// the CR3 still-image format), plus a dedicated `CTMD` trak whose `mdat`
/// samples carry per-frame timed metadata (timestamp, focal length, exposure,
/// Canon white-balance coefficients).
///
/// The CR3 image pipeline already understands the in-`moov` Canon metadata
/// UUID; this reader reuses [`CanonUUIDExtractor`](../Canon/CanonUUIDBoxes.swift)
/// for that and adds the CTMD walker on top.
public struct CRMReader: Sendable {

    // MARK: - Public types

    /// One entry per CTMD sample (typically one per video frame).
    public struct CTMDFrame: Sendable, Equatable {
        public var sampleIndex: Int
        /// Wall-clock timestamp from CTMD record type 0x0001.
        public var timestamp: Date?
        /// Focal length in millimetres (record type 0x0004).
        public var focalLengthMm: Double?
        /// Aperture as a linear F-number (record type 0x0005).
        public var fNumber: Double?
        /// Shutter speed in seconds (record type 0x0005).
        public var exposureTimeS: Double?
        /// ISO sensitivity (record type 0x0005).
        public var iso: Int?
        /// CanonColorData R/G1/G2/B multipliers from the embedded TIFF block
        /// in record types 0x0007/0x0008/0x0009. Always 4 elements when set.
        public var whiteBalanceCoefficients: [Double]?

        public init(sampleIndex: Int = 0,
                    timestamp: Date? = nil,
                    focalLengthMm: Double? = nil,
                    fNumber: Double? = nil,
                    exposureTimeS: Double? = nil,
                    iso: Int? = nil,
                    whiteBalanceCoefficients: [Double]? = nil) {
            self.sampleIndex = sampleIndex
            self.timestamp = timestamp
            self.focalLengthMm = focalLengthMm
            self.fNumber = fNumber
            self.exposureTimeS = exposureTimeS
            self.iso = iso
            self.whiteBalanceCoefficients = whiteBalanceCoefficients
        }
    }

    public struct CRMResult: Sendable {
        public var exif: ExifData?
        public var xmp: XMPData?
        public var thumbnail: Data?
        public var preview: Data?
        /// Raw CNCV string — `"CanonCRM0001/02.10.00/00.00.00"` etc. Useful
        /// for distinguishing CRM master clips from anything else that might
        /// share the `crx ` ftyp brand.
        public var cncv: String?
        public var ctmdTimeline: [CTMDFrame]
    }

    // MARK: - Detection

    /// Fast probe — true when `data` is an ISOBMFF clip whose `ftyp` brand is
    /// `crx ` AND whose `moov` contains a Canon metadata UUID whose CNCV
    /// payload begins with `"CanonCRM"`. CR3 still images share the brand and
    /// UUID but report `"CanonCR3..."`, so this filter rejects them.
    public static func isCanonCinemaRAW(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        // ftyp at offset 4 with major brand `crx ` (4 bytes from offset 8)
        let majorBrand = data[(data.startIndex + 8)..<(data.startIndex + 12)]
        guard String(data: Data(majorBrand), encoding: .ascii) == "crx " else { return false }

        guard let topBoxes = try? ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(data),
              let moov = topBoxes.first(where: { $0.type == "moov" }),
              let moovChildren = try? ISOBMFFBoxReader.parseBoxes(from: moov.data) else {
            return false
        }

        for child in moovChildren where child.type == "uuid" && child.data.count >= 16 {
            let uuid = child.data.prefix(16)
            guard uuid == CanonUUID.canonMetadata else { continue }
            let payload = Data(child.data.dropFirst(16))
            guard let result = try? CanonUUIDExtractor.parseCanonMetadata(payload),
                  let cncv = result.cncv else { return false }
            return cncv.hasPrefix("CanonCRM")
        }
        return false
    }

    // MARK: - Read

    /// Decode every metadata channel a CRM/CRL file carries.
    public static func read(_ data: Data) throws -> CRMResult {
        let topBoxes = try ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(data)

        var exif: ExifData?
        var thumbnail: Data?
        var preview: Data?
        var cncv: String?
        var xmp: XMPData?
        var timeline: [CTMDFrame] = []

        if let moov = topBoxes.first(where: { $0.type == "moov" }) {
            let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moov.data)

            for child in moovChildren {
                switch child.type {
                case "uuid":
                    guard child.data.count >= 16 else { continue }
                    let uuid = child.data.prefix(16)
                    let payload = Data(child.data.dropFirst(16))
                    if uuid == CanonUUID.canonMetadata {
                        let r = try CanonUUIDExtractor.parseCanonMetadata(payload)
                        exif = r.exif
                        thumbnail = r.thumbnail
                        cncv = r.cncv
                    } else if uuid == CanonUUID.canonPreview {
                        preview = try CanonUUIDExtractor.parsePreview(payload)
                    }
                case "trak":
                    if let frames = decodeCTMDTrak(child.data, fileData: data) {
                        timeline = frames
                    }
                default:
                    break
                }
            }
        }

        // Top-level XMP uuid box
        for box in topBoxes where box.type == "uuid" && box.data.count >= 16 {
            let uuid = box.data.prefix(16)
            if uuid == CanonUUID.xmpUUID {
                let xmpData = Data(box.data.dropFirst(16))
                xmp = try? XMPReader.readFromXML(xmpData)
            }
        }

        return CRMResult(
            exif: exif,
            xmp: xmp,
            thumbnail: thumbnail,
            preview: preview,
            cncv: cncv,
            ctmdTimeline: timeline
        )
    }

    // MARK: - Merge

    /// Apply a `CRMResult` to a `VideoMetadata` in-place. Populates camera
    /// identity from CMT1-4 IFDs, overrides single-valued exposure / lens
    /// fields with first-frame CTMD values when available, and attaches the
    /// full per-frame timeline plus thumbnail / preview JPEGs.
    public static func merge(_ result: CRMResult, into metadata: inout VideoMetadata) {
        // Per-frame timeline + embedded JPEGs
        metadata.cameraTimeline = result.ctmdTimeline
        if metadata.embeddedThumbnailJPEG == nil { metadata.embeddedThumbnailJPEG = result.thumbnail }
        if metadata.embeddedPreviewJPEG == nil { metadata.embeddedPreviewJPEG = result.preview }
        if metadata.xmp == nil { metadata.xmp = result.xmp }

        // CMT1-4 → CameraMetadata
        var camera = metadata.camera ?? CameraMetadata()
        if let exif = result.exif {
            if camera.deviceManufacturer == nil, let make = exif.make { camera.deviceManufacturer = make }
            if camera.deviceModelName == nil, let model = exif.model { camera.deviceModelName = model }
            if camera.deviceSerialNumber == nil,
               let serial = makerNoteString(exif: exif, tag: 0x000C) {
                camera.deviceSerialNumber = serial
            }
            if camera.lensModelName == nil,
               let lens = makerNoteString(exif: exif, tag: 0x0095) {
                camera.lensModelName = lens
            }
            // Single-valued exposure fallbacks from CMT2 ExifIFD
            if camera.isoSensitivity == nil, let iso = exif.isoSpeed {
                camera.isoSensitivity = Int(iso)
            }
            if camera.irisFNumber == nil, let f = exif.fNumber, f.denominator > 0 {
                camera.irisFNumber = Double(f.numerator) / Double(f.denominator)
            }
            if camera.shutterTimeMs == nil, let t = exif.exposureTime, t.denominator > 0 {
                camera.shutterTimeMs = (Double(t.numerator) / Double(t.denominator)) * 1000.0
            }
            if camera.lensZoomActualFocalLengthMm == nil, let fl = exif.focalLength, fl.denominator > 0 {
                camera.lensZoomActualFocalLengthMm = Double(fl.numerator) / Double(fl.denominator)
            }
            if camera.creationDate == nil, let dt = exif.dateTime,
               let parsed = parseExifDateTime(dt) {
                camera.creationDate = parsed
            }
        }

        // CTMD first-frame overrides — these are per-frame samples and the
        // first one is more authoritative than CMT2 since it includes
        // hundredths-of-a-second precision and reflects the actual
        // exposure used at frame 0 (CMT2 can lag if the user dialed in an
        // override after the cam wrote IFD0).
        if let first = result.ctmdTimeline.first {
            if let ts = first.timestamp { camera.creationDate = ts }
            if let f = first.fNumber { camera.irisFNumber = f }
            if let t = first.exposureTimeS { camera.shutterTimeMs = t * 1000.0 }
            if let iso = first.iso { camera.isoSensitivity = iso }
            if let fl = first.focalLengthMm { camera.lensZoomActualFocalLengthMm = fl }
            if let wb = first.whiteBalanceCoefficients, camera.whiteBalanceCoefficients == nil {
                camera.whiteBalanceCoefficients = wb
            }
        }

        if !camera.isEmpty {
            metadata.camera = camera
        }
    }

    // MARK: - CTMD trak walking

    /// If `trakData` describes a `meta`-handler trak whose first sample entry
    /// has FourCC `"CTMD"`, decode every sample into a `CTMDFrame`. Returns
    /// `nil` for any other trak.
    private static func decodeCTMDTrak(_ trakData: Data, fileData: Data) -> [CTMDFrame]? {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
              hdlr.data.count >= 12 else { return nil }

        let handlerType = String(
            data: hdlr.data[hdlr.data.startIndex + 8 ..< hdlr.data.startIndex + 12],
            encoding: .ascii
        ) ?? ""
        guard handlerType == "meta" else { return nil }

        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data) else { return nil }

        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }),
              MP4Parser.parseFirstStsdCodec(stsd.data) == "CTMD" else { return nil }

        guard let stsz = stblChildren.first(where: { $0.type == "stsz" }),
              let stsc = stblChildren.first(where: { $0.type == "stsc" }),
              let sampleSizes = parseSTSZ(stsz.data) else { return nil }

        let chunkOffsets: [UInt64]
        if let co64 = stblChildren.first(where: { $0.type == "co64" }),
           let offsets = parseCO64(co64.data) {
            chunkOffsets = offsets
        } else if let stco = stblChildren.first(where: { $0.type == "stco" }),
                  let offsets = parseSTCO(stco.data) {
            chunkOffsets = offsets.map { UInt64($0) }
        } else {
            return nil
        }

        guard let stscEntries = parseSTSC(stsc.data), !stscEntries.isEmpty else { return nil }

        // Walk samples: for each chunk, the applicable stsc entry tells how
        // many samples are in it. The entry that "applies" to chunk N is the
        // entry with the largest first_chunk ≤ N+1.
        var frames: [CTMDFrame] = []
        var sampleIndex = 0
        for (chunkIdx, chunkBaseOffset) in chunkOffsets.enumerated() {
            let chunkNum1Based = UInt32(chunkIdx + 1)
            guard let entry = stscEntries.last(where: { $0.firstChunk <= chunkNum1Based }) else { continue }
            var sampleOffsetInChunk: UInt64 = 0
            for _ in 0..<Int(entry.samplesPerChunk) {
                guard sampleIndex < sampleSizes.count else { break }
                let sampleSize = sampleSizes[sampleIndex]
                // A crafted co64 chunk offset near UInt64.max plus the running
                // in-chunk offset would trap on the addition; stop walking this
                // chunk instead. sliceFile rejects any out-of-range result too.
                let (absoluteOffset, ovf) = chunkBaseOffset.addingReportingOverflow(sampleOffsetInChunk)
                if ovf { break }
                if let sample = sliceFile(fileData, offset: absoluteOffset, length: UInt64(sampleSize)) {
                    var frame = CTMDFrame(sampleIndex: sampleIndex)
                    decodeCTMDSample(sample, into: &frame)
                    frames.append(frame)
                }
                sampleIndex += 1
                let (nextInChunk, ovf2) = sampleOffsetInChunk.addingReportingOverflow(UInt64(sampleSize))
                if ovf2 { break }
                sampleOffsetInChunk = nextInChunk
            }
        }
        return frames
    }

    /// Decode every CTMD record in a single sample, populating `frame` with
    /// the values it carries (last-write-wins per record type — CTMD samples
    /// almost always carry one record per type).
    private static func decodeCTMDSample(_ sample: Data, into frame: inout CTMDFrame) {
        // Re-base on a fresh Data so local offsets are 0-based, regardless of
        // whether `sample` came in as a sliced sub-Data (chunked reads from
        // the original mmap'd file always do).
        let buf = Data(sample)
        var offset = 0
        while offset + 12 <= buf.count {
            let recordSize = readUInt32LE(buf, at: offset)
            guard recordSize >= 12, offset + Int(recordSize) <= buf.count else { return }
            let recordType = readUInt16LE(buf, at: offset + 4)
            let payloadStart = offset + 12
            let payloadEnd = offset + Int(recordSize)
            let payload = buf[payloadStart..<payloadEnd]

            switch recordType {
            case 0x0001:
                frame.timestamp = decodeTimestampPayload(Data(payload))
            case 0x0004:
                if let fl = decodeFocalPayload(Data(payload)) { frame.focalLengthMm = fl }
            case 0x0005:
                let exp = decodeExposurePayload(Data(payload))
                if let f = exp.fNumber { frame.fNumber = f }
                if let t = exp.exposureTimeS { frame.exposureTimeS = t }
                if let i = exp.iso { frame.iso = i }
            case 0x0007, 0x0008, 0x0009:
                if frame.whiteBalanceCoefficients == nil,
                   let coeffs = decodeWhiteBalanceFromTIFF(Data(payload)) {
                    frame.whiteBalanceCoefficients = coeffs
                }
            default:
                break
            }
            offset += Int(recordSize)
        }
    }

    // MARK: - CTMD record decoders

    /// Type 0x0001 timestamp payload (verified against EOS C70):
    ///   u16 unknown, u16 year, u8 month, u8 day, u8 hour, u8 minute,
    ///   u8 second, u8 hundredths-or-0xFF, u16 unknown
    /// All fields little-endian. We treat the wall-clock time as UTC since
    /// neither CMT1's DateTime nor CTMD encodes a time-zone offset; consumers
    /// can shift it later if they know the operator's timezone.
    /// Cameras that don't carry sub-second precision write `0xFF` in the
    /// hundredths byte — treat as 0.
    private static func decodeTimestampPayload(_ payload: Data) -> Date? {
        guard payload.count >= 12 else { return nil }
        let year = Int(readUInt16LE(payload, at: 2))
        let month = Int(payload[payload.startIndex + 4])
        let day = Int(payload[payload.startIndex + 5])
        let hour = Int(payload[payload.startIndex + 6])
        let minute = Int(payload[payload.startIndex + 7])
        let second = Int(payload[payload.startIndex + 8])
        let rawHundredths = Int(payload[payload.startIndex + 9])
        let hundredths = (0...99).contains(rawHundredths) ? rawHundredths : 0
        guard year >= 1970, year < 2100, (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = hundredths * 10_000_000
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)
    }

    /// Type 0x0004 focal length (verified against EOS C70):
    /// u16 num, u16 den — actual focal length in mm. The next 4 bytes hold a
    /// second rational (35mm-equivalent on cropped sensors); we surface only
    /// the actual focal length here since `lensZoomActualFocalLengthMm` is
    /// what consumers expect.
    private static func decodeFocalPayload(_ payload: Data) -> Double? {
        guard payload.count >= 4 else { return nil }
        let num = readUInt16LE(payload, at: 0)
        let den = readUInt16LE(payload, at: 2)
        guard den > 0 else { return nil }
        return Double(num) / Double(den)
    }

    /// Type 0x0005 exposure (verified against EOS C70):
    ///   u16 fNum, u16 fDen, u16 expNum, u16 expDen, u32 isoFlagsAndValue
    /// The "ISO" field's high bit appears to be a flag (Auto-ISO?); the
    /// low 24 bits hold the actual ISO speed rating (e.g. 800 = 0x000320).
    /// Returns the three decoded sub-values; nil for any zero-denominator
    /// rational. Total payload runs ≥ 28 bytes including a trailing block
    /// of unidentified data we currently ignore.
    private static func decodeExposurePayload(_ payload: Data) -> (fNumber: Double?, exposureTimeS: Double?, iso: Int?) {
        guard payload.count >= 12 else { return (nil, nil, nil) }
        let fNum = readUInt16LE(payload, at: 0)
        let fDen = readUInt16LE(payload, at: 2)
        let expNum = readUInt16LE(payload, at: 4)
        let expDen = readUInt16LE(payload, at: 6)
        let isoRaw = readUInt32LE(payload, at: 8)
        let iso = Int(isoRaw & 0x00FF_FFFF) // strip the high-bit flag

        let f: Double? = fDen > 0 ? Double(fNum) / Double(fDen) : nil
        let t: Double? = expDen > 0 ? Double(expNum) / Double(expDen) : nil
        return (f, t, iso > 0 ? iso : nil)
    }

    /// Types 0x0007/0x0008/0x0009 carry an embedded TIFF block. Look for tag
    /// 0x4001 (CanonColorData) and pull the first four shorts as RGGB
    /// multipliers. Best-effort: if the block isn't a parseable TIFF we
    /// return `nil` rather than throw.
    private static func decodeWhiteBalanceFromTIFF(_ payload: Data) -> [Double]? {
        guard let parsed = try? ExifReader.readFromTIFF(data: Data(payload)),
              let entry = parsed.ifd0?.entry(for: 0x4001) else { return nil }
        // CanonColorData: array of int16. The first four are R, G1, G2, B.
        let values = entry.uint16Values(endian: parsed.byteOrder)
        guard values.count >= 4 else { return nil }
        return values.prefix(4).map { Double($0) }
    }

    // MARK: - Sample-table parsers

    /// Upper bound on a sample/entry count we will materialize from a sample
    /// table, guarding against a fabricated `count` driving an OOM allocation.
    /// 2^24 ≈ 16.8 M samples covers any realistic CTMD track (one metadata
    /// sample per video frame — over 70 hours at 60 fps) while capping the
    /// worst-case array at ~64 MB.
    private static let maxSampleTableEntries: UInt32 = 1 << 24

    /// `stsz`: FullBox(4) + sample_size(4) + sample_count(4) + (per-sample u32 sizes when sample_size==0).
    /// Returns one entry per sample.
    private static func parseSTSZ(_ data: Data) -> [UInt32]? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4) // version+flags
        guard let sampleSize = try? reader.readUInt32BigEndian(),
              let count = try? reader.readUInt32BigEndian() else { return nil }
        if sampleSize > 0 {
            // `count` is attacker-controlled and, with sample_size > 0, has no
            // per-sample payload to bound it against — a fabricated 0xFFFFFFFF
            // would materialize a ~17 GB array and abort. Cap it; the sample
            // walk is bounded by the chunk/stsc tables downstream anyway.
            return Array(repeating: sampleSize, count: Int(min(count, maxSampleTableEntries)))
        }
        var sizes: [UInt32] = []
        // Each entry is 4 bytes; never reserve more than the payload can hold.
        sizes.reserveCapacity(min(Int(count), reader.remainingCount / 4))
        for _ in 0..<Int(count) {
            guard let s = try? reader.readUInt32BigEndian() else { break }
            sizes.append(s)
        }
        return sizes
    }

    private struct STSCEntry {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
        let sampleDescriptionIndex: UInt32
    }

    /// `stsc`: FullBox(4) + entry_count(4) + entries × (first_chunk:u32, samples_per_chunk:u32, sample_description_index:u32).
    private static func parseSTSC(_ data: Data) -> [STSCEntry]? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var entries: [STSCEntry] = []
        // Each entry is 12 bytes; never reserve more than the payload can hold.
        entries.reserveCapacity(min(Int(entryCount), reader.remainingCount / 12))
        for _ in 0..<Int(entryCount) {
            guard let fc = try? reader.readUInt32BigEndian(),
                  let spc = try? reader.readUInt32BigEndian(),
                  let sdi = try? reader.readUInt32BigEndian() else { break }
            entries.append(STSCEntry(firstChunk: fc, samplesPerChunk: spc, sampleDescriptionIndex: sdi))
        }
        return entries
    }

    /// `stco`: full chunk-offset table.
    private static func parseSTCO(_ data: Data) -> [UInt32]? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return nil }
        var offsets: [UInt32] = []
        // Each entry is 4 bytes; never reserve more than the payload can hold.
        offsets.reserveCapacity(min(Int(count), reader.remainingCount / 4))
        for _ in 0..<Int(count) {
            guard let off = try? reader.readUInt32BigEndian() else { break }
            offsets.append(off)
        }
        return offsets
    }

    /// `co64`: full chunk-offset table (64-bit).
    private static func parseCO64(_ data: Data) -> [UInt64]? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return nil }
        var offsets: [UInt64] = []
        // Each entry is 8 bytes; never reserve more than the payload can hold.
        offsets.reserveCapacity(min(Int(count), reader.remainingCount / 8))
        for _ in 0..<Int(count) {
            guard let off = try? reader.readUInt64BigEndian() else { break }
            offsets.append(off)
        }
        return offsets
    }

    // MARK: - Helpers

    private static func sliceFile(_ data: Data, offset: UInt64, length: UInt64) -> Data? {
        // Overflow-safe bounds check: `offset + length` would trap (UInt64
        // addition overflows) on a crafted file declaring both near UInt64.max.
        // Validate via subtraction against the file size, which cannot overflow.
        let fileCount = UInt64(data.count)
        guard length > 0,
              offset <= fileCount,
              length <= fileCount - offset,
              offset <= UInt64(Int.max),
              length <= UInt64(Int.max) else { return nil }
        let start = data.startIndex + Int(offset)
        let end = start + Int(length)
        return data[start..<end]
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func makerNoteString(exif: ExifData, tag: UInt16) -> String? {
        guard let entry = exif.makerNoteIFD?.entry(for: tag) else { return nil }
        return entry.stringValue(endian: exif.byteOrder)
    }

    /// Parse Exif-style `"yyyy:MM:dd HH:mm:ss"` into a `Date` (assumed UTC —
    /// CMT1 carries no timezone offset).
    private static func parseExifDateTime(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: s)
    }
}
