import Foundation

/// Chapter-marker decoding for MP4Parser: the Nero-style `chpl` flat
/// list, the QuickTime `tref > chap` text-track shape (each chapter is a
/// sample in a referenced text/subt track), plus the small sample-table
/// helpers (stts, stsz, stsc, stco, co64, sampleFileOffsets) those paths
/// share with `RTMDReader` and `BRAWFrameReader`.
///
/// Extracted from MP4Parser.swift to keep that file scannable. No behavior
/// change — `private static` callers that the rest of MP4Parser still
/// invokes (parseChapterTracks, parseTrefChap, decodeChapterTrack) are
/// relaxed to internal so they're reachable from this extension across
/// files.
extension MP4Parser {

    // MARK: - Chapter markers

    /// Nero-style `chpl` box (written by x264 / ffmpeg / MP4Box). Only the
    /// version-1 shape is recognised — it's what every modern muxer emits and
    /// the only form documented by Nero.
    ///
    /// Layout:
    ///   FullBox header(4)            version(1) + flags(0)
    ///   reserved(1)                  0x00
    ///   count(4)                     big-endian UInt32 entry count
    ///   entries[count]:
    ///     start(8)                   big-endian UInt64, 100-nanosecond units
    ///     title_length(1)            UInt8
    ///     title(title_length)        UTF-8 bytes
    static func parseCHPL(_ data: Data) -> [VideoChapter] {
        // version(1) + flags(3) + reserved(1) + count(4) = 9 bytes minimum
        guard data.count >= 9 else { return [] }
        let s = data.startIndex
        guard data[s] == 1 else { return [] } // only version 1 is supported
        var offset = 4      // past FullBox header
        offset += 1         // reserved
        let count = Int(
            (UInt32(data[s + offset]) << 24)
            | (UInt32(data[s + offset + 1]) << 16)
            | (UInt32(data[s + offset + 2]) << 8)
            | UInt32(data[s + offset + 3])
        )
        offset += 4
        // Clamp to something defensive — real-world chapter lists are <10 000.
        guard count > 0, count <= 100_000 else { return [] }

        var out: [VideoChapter] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard offset + 9 <= data.count else { break }
            var raw: UInt64 = 0
            for j in 0..<8 {
                raw = (raw << 8) | UInt64(data[s + offset + j])
            }
            offset += 8
            let titleLen = Int(data[s + offset])
            offset += 1
            guard offset + titleLen <= data.count else { break }
            let titleBytes = data[s + offset ..< s + offset + titleLen]
            offset += titleLen
            // Nero encodes start as 100-ns ticks: 10 000 000 ticks / second.
            let start = Double(raw) / 10_000_000.0
            let title = String(data: Data(titleBytes), encoding: .utf8)
            out.append(VideoChapter(
                index: i,
                startTime: start,
                title: title?.isEmpty == true ? nil : title
            ))
        }
        return out
    }

    /// Walk the moov children for QuickTime chapter tracks. A chapter track is
    /// a trak whose handler is `text` / `subt` / `sbtl`, referenced by another
    /// trak's `tref > chap`. Each sample is a chapter title; the sample's
    /// decoding timestamp (from stts) is the chapter's start time.
    ///
    /// Apple's QuickTime File Format § "Chapter Lists" — see
    /// https://developer.apple.com/documentation/quicktime-file-format/chapter_lists
    static func parseChapterTracks(
        _ moovChildren: [ISOBMFFBox],
        fullData: Data
    ) -> [VideoChapter] {
        // Build trackID → trak index for tref lookup.
        var traksByID: [UInt32: Data] = [:]
        for trak in moovChildren where trak.type == "trak" {
            if let tid = parseTKHDTrackID(trak.data) {
                traksByID[tid] = trak.data
            }
        }

        // Collect chapter track IDs referenced from any trak. DaVinci writes
        // the `tref chap` on the video track; ffmpeg's mov muxer writes it on
        // audio + subtitle tracks instead. Scan every trak so either layout
        // surfaces the chapter list.
        var chapterTrackIDs: [UInt32] = []
        for trak in moovChildren where trak.type == "trak" {
            for tid in parseTrefChap(trak.data) where traksByID[tid] != nil {
                if !chapterTrackIDs.contains(tid) { chapterTrackIDs.append(tid) }
            }
        }

        // Decode the first chapter track only — ffprobe behaves the same way.
        // A movie with multiple chap-referenced tracks (rare) typically
        // duplicates them per language; we pick the first and surface the
        // rest through per-track `VideoStream.title` already.
        for tid in chapterTrackIDs {
            guard let trakData = traksByID[tid] else { continue }
            let handler = trakHandlerType(trakData) ?? ""
            guard handler == "text" || handler == "subt" || handler == "sbtl" else { continue }
            let chapters = decodeChapterTrack(trakData, fullData: fullData)
            if !chapters.isEmpty { return chapters }
        }
        return []
    }

    /// `trak > tref > chap` — list of track IDs whose samples provide chapter
    /// text for the referencing track.
    static func parseTrefChap(_ trakData: Data) -> [UInt32] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let tref = trakChildren.first(where: { $0.type == "tref" }),
              let trefChildren = try? ISOBMFFBoxReader.parseBoxes(from: tref.data),
              let chap = trefChildren.first(where: { $0.type == "chap" }) else { return [] }
        let payload = chap.data
        let count = payload.count / 4
        var out: [UInt32] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let s = payload.startIndex + i * 4
            let v = (UInt32(payload[s]) << 24)
                | (UInt32(payload[s + 1]) << 16)
                | (UInt32(payload[s + 2]) << 8)
                | UInt32(payload[s + 3])
            out.append(v)
        }
        return out
    }

    /// Pull timed chapter samples out of a text-track trak. Each sample starts
    /// with a 2-byte big-endian length followed by UTF-8 bytes (QuickTime text
    /// sample format); any trailing metadata atoms are ignored.
    static func decodeChapterTrack(
        _ trakData: Data,
        fullData: Data
    ) -> [VideoChapter] {
        guard let trakChildren = try? ISOBMFFBoxReader.parseBoxes(from: trakData),
              let mdia = trakChildren.first(where: { $0.type == "mdia" }),
              let mdiaChildren = try? ISOBMFFBoxReader.parseBoxes(from: mdia.data),
              let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }),
              let mdhdInfo = parseMDHD(mdhd.data), mdhdInfo.timescale > 0,
              let minf = mdiaChildren.first(where: { $0.type == "minf" }),
              let minfChildren = try? ISOBMFFBoxReader.parseBoxes(from: minf.data),
              let stbl = minfChildren.first(where: { $0.type == "stbl" }),
              let stblChildren = try? ISOBMFFBoxReader.parseBoxes(from: stbl.data)
        else { return [] }

        let timescale = Double(mdhdInfo.timescale)
        let sttsBox = stblChildren.first(where: { $0.type == "stts" })
        let stszBox = stblChildren.first(where: { $0.type == "stsz" })
        let stscBox = stblChildren.first(where: { $0.type == "stsc" })
        let stcoBox = stblChildren.first(where: { $0.type == "stco" })
        let co64Box = stblChildren.first(where: { $0.type == "co64" })

        guard let starts = sttsBox.flatMap({ sttsSampleStartTicks($0.data) }),
              !starts.isEmpty else { return [] }

        let sizes = stszBox.flatMap({ stszSampleSizes($0.data) }) ?? []
        let samplesPerChunk = stscBox.flatMap({ stscSamplesPerChunk($0.data) }) ?? []
        let chunkOffsets: [UInt64] = {
            if let b = co64Box { return co64Offsets(b.data) }
            if let b = stcoBox { return stcoOffsets(b.data).map(UInt64.init) }
            return []
        }()

        let sampleCount = min(starts.count, sizes.count)
        guard sampleCount > 0, !chunkOffsets.isEmpty else { return [] }

        // Build a list of sample file offsets.
        let sampleOffsets = sampleFileOffsets(
            sampleCount: sampleCount,
            sizes: sizes,
            samplesPerChunk: samplesPerChunk,
            chunkOffsets: chunkOffsets
        )
        guard sampleOffsets.count == sampleCount else { return [] }

        var out: [VideoChapter] = []
        for i in 0..<sampleCount {
            let fileOff = sampleOffsets[i]
            let size = sizes[i]
            // `sampleFileOffsets` accumulates with wrapping `&+`, so `fileOff`
            // can reach anywhere in UInt64. Compare with subtraction so the
            // bounds check itself can't overflow-trap on `fileOff + size`.
            guard size >= 2,
                  UInt64(size) <= UInt64(fullData.count),
                  fileOff <= UInt64(fullData.count) - UInt64(size) else { continue }
            let base = fullData.startIndex + Int(fileOff)
            let titleLen = (Int(fullData[base]) << 8) | Int(fullData[base + 1])
            guard titleLen >= 0, 2 + titleLen <= size else { continue }
            let titleBytes = fullData[base + 2 ..< base + 2 + titleLen]
            let title = stripBOM(String(data: Data(titleBytes), encoding: .utf8))
            let start = Double(starts[i]) / timescale
            let end: TimeInterval?
            if i + 1 < starts.count {
                end = Double(starts[i + 1]) / timescale
            } else {
                end = nil
            }
            out.append(VideoChapter(
                index: i,
                startTime: start,
                endTime: end,
                title: title?.isEmpty == true ? nil : title
            ))
        }
        return out
    }

    /// Strip a UTF-16 BOM from a decoded title (QuickTime sometimes encodes
    /// chapter titles as UTF-16 with a BOM inside the UTF-8 sample bytes when
    /// the TextSampleEntry's encoding hint calls for it — the BOM shows up as
    /// a leading "\u{FEFF}"). Removing it keeps test assertions clean.
    private static func stripBOM(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    /// Running-sum sample start ticks (cumulative sample_delta in stts).
    internal static func sttsSampleStartTicks(_ data: Data) -> [UInt64]? {
        guard data.count >= 8 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return nil }
        var out: [UInt64] = []
        var running: UInt64 = 0
        // Total-sample cap — stts expands sample_count per entry, so the two
        // per-loop caps below still let a crafted file produce 2^32 samples.
        // Real chapter tracks have hundreds of samples, not millions.
        let totalCap = 1 << 20
        outer: for _ in 0..<min(entryCount, 1 << 16) {
            guard let sc = try? reader.readUInt32BigEndian(),
                  let sd = try? reader.readUInt32BigEndian() else { break }
            for _ in 0..<min(sc, 1 << 16) {
                if out.count >= totalCap { break outer }
                out.append(running)
                running &+= UInt64(sd)
            }
        }
        return out
    }

    /// Per-sample sizes from stsz. Handles both uniform size and per-sample
    /// size modes.
    internal static func stszSampleSizes(_ data: Data) -> [Int]? {
        guard data.count >= 12 else { return nil }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let uniform = try? reader.readUInt32BigEndian(),
              let count = try? reader.readUInt32BigEndian() else { return nil }
        let capped = Int(min(count, 1 << 20))
        if uniform > 0 {
            return Array(repeating: Int(uniform), count: capped)
        }
        var out: [Int] = []
        out.reserveCapacity(capped)
        for _ in 0..<capped {
            guard let sz = try? reader.readUInt32BigEndian() else { break }
            out.append(Int(sz))
        }
        return out
    }

    /// stsc entries: [first_chunk, samples_per_chunk, sample_description_index].
    /// Return just the first_chunk / samples_per_chunk pairs — the description
    /// index is irrelevant for chapter text, which always uses entry 1.
    internal static func stscSamplesPerChunk(_ data: Data) -> [(firstChunk: Int, samplesPerChunk: Int)] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let entryCount = try? reader.readUInt32BigEndian() else { return [] }
        var out: [(Int, Int)] = []
        for _ in 0..<min(entryCount, 1 << 16) {
            guard let fc = try? reader.readUInt32BigEndian(),
                  let spc = try? reader.readUInt32BigEndian(),
                  (try? reader.skip(4)) != nil else { break }
            out.append((Int(fc), Int(spc)))
        }
        return out
    }

    /// All stco chunk offsets.
    internal static func stcoOffsets(_ data: Data) -> [UInt32] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return [] }
        var out: [UInt32] = []
        out.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<min(count, 1 << 20) {
            guard let off = try? reader.readUInt32BigEndian() else { break }
            out.append(off)
        }
        return out
    }

    /// All co64 chunk offsets.
    internal static func co64Offsets(_ data: Data) -> [UInt64] {
        guard data.count >= 8 else { return [] }
        var reader = BinaryReader(data: data)
        _ = try? reader.readBytes(4)
        guard let count = try? reader.readUInt32BigEndian() else { return [] }
        var out: [UInt64] = []
        out.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<min(count, 1 << 20) {
            guard let off = try? reader.readUInt64BigEndian() else { break }
            out.append(off)
        }
        return out
    }

    /// Walk stsc to resolve each sample's containing chunk + index-in-chunk,
    /// then add the chunk's file offset plus the summed sizes of preceding
    /// samples in the same chunk.
    ///
    /// When stsc is empty (single-chunk case typical of chapter tracks), every
    /// sample lives in chunk 0.
    internal static func sampleFileOffsets(
        sampleCount: Int,
        sizes: [Int],
        samplesPerChunk: [(firstChunk: Int, samplesPerChunk: Int)],
        chunkOffsets: [UInt64]
    ) -> [UInt64] {
        guard !chunkOffsets.isEmpty else { return [] }

        // Expand stsc's run-length-encoded (first_chunk, spc) pairs into a flat
        // samples-per-chunk array covering every chunk up to chunkOffsets.count.
        // stsc uses 1-based chunk indices.
        var spc = [Int](repeating: 1, count: chunkOffsets.count)
        if !samplesPerChunk.isEmpty {
            for i in 0..<samplesPerChunk.count {
                let firstChunk = max(samplesPerChunk[i].firstChunk - 1, 0)
                let nextFirst = (i + 1 < samplesPerChunk.count)
                    ? max(samplesPerChunk[i + 1].firstChunk - 1, 0)
                    : chunkOffsets.count
                let value = samplesPerChunk[i].samplesPerChunk
                for c in firstChunk..<min(nextFirst, chunkOffsets.count) {
                    spc[c] = value
                }
            }
        }

        var out: [UInt64] = []
        out.reserveCapacity(sampleCount)
        var sampleIdx = 0
        for (chunkIdx, chunkOff) in chunkOffsets.enumerated() {
            let inChunk = spc[chunkIdx]
            var runningInChunk: UInt64 = 0
            for _ in 0..<inChunk {
                guard sampleIdx < sampleCount, sampleIdx < sizes.count else { return out }
                out.append(chunkOff &+ runningInChunk)
                runningInChunk &+= UInt64(sizes[sampleIdx])
                sampleIdx += 1
            }
            if sampleIdx >= sampleCount { break }
        }
        return out
    }
}
