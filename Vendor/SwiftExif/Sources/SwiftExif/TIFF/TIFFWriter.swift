import Foundation

/// Reconstructs a TIFF file from parsed components with updated metadata.
///
/// The writer rebuilds the IFD chain from scratch and **relocates every block
/// an IFD entry points at** — strip/tile pixel data, the old-style JPEG
/// thumbnail, and every child IFD — copying the bytes into the output and
/// rewriting the offsets. This keeps the raster (and any compressed payload)
/// valid; a TIFF round-tripped through SwiftExif decodes identically.
///
/// Child-IFD relocation is generic. Exif (0x8769) and GPS (0x8825) come from the
/// assigned `exif` model so user edits apply; every other pointer — the
/// Interoperability IFD (0xA005) nested inside Exif, the SubIFDs array (0x014A)
/// that carries a DNG's full-resolution raw image, and any pointer nested inside
/// a child — is parsed from the source bytes and relocated recursively, with the
/// child's own strips/tiles and nested pointers carried along. Recursion is
/// bounded (`maxIFDDepth`) and every source offset is bounds-checked, so
/// malformed input drops the offending pointer rather than crashing or emitting
/// a dangling offset.
///
/// **MakerNote (0x927C) relocation.** A relocated MakerNote has its internal
/// offsets fixed up per manufacturer (`MakerNoteRelocator`). Notes whose
/// pointers are relative to the MakerNote/embedded-TIFF start (Nikon, Fujifilm,
/// Sony, Panasonic, Olympus, Apple) move with the block and are copied verbatim;
/// notes with TIFF-absolute pointers (Canon, DJI, Samsung, Pentax) have every
/// out-of-line value-offset field shifted by the relocation delta (and a Canon
/// TIFF footer patched to match). Anything we cannot classify or safely patch
/// (unknown manufacturer, parse failure, a chained MakerNote IFD) is copied
/// verbatim and surfaces a non-fatal warning via the `warnings` out-parameter
/// (reachable through `ImageMetadata.writeToDataWithWarnings()`), so the output
/// is never more corrupt than a plain verbatim copy.
public struct TIFFWriter: Sendable {

    // Offset-bearing tags whose values are file offsets that must be rewritten.
    private static let stripOffsets: UInt16 = 0x0111
    private static let stripByteCounts: UInt16 = 0x0117
    private static let tileOffsets: UInt16 = 0x0144
    private static let tileByteCounts: UInt16 = 0x0145
    private static let jpegInterchangeFormat: UInt16 = 0x0201        // old-style JPEG thumbnail
    private static let jpegInterchangeFormatLength: UInt16 = 0x0202

    /// Pointer tags whose value is the offset of a child IFD. A pointer is only
    /// written when we have the child IFD to relocate; otherwise it is dropped
    /// so the output never carries a dangling offset.
    private static let exifPointer: UInt16 = 0x8769
    private static let gpsPointer: UInt16 = 0x8825
    /// SubIFDs (0x014A) is special: its value is an *array* of child-IFD offsets
    /// (DNG stores the full-resolution raw image in one of these), not a single
    /// offset like the other pointers.
    private static let subIFDsPointer: UInt16 = 0x014A
    private static let pointerTags: Set<UInt16> = [
        0x8769, 0x8825, 0xA005, 0x014A, // Exif, GPS, Interoperability, SubIFDs
    ]

    /// Bound on child-IFD relocation recursion, guarding against cyclic or
    /// adversarial offset chains. Mirrors the posture used elsewhere (e.g.
    /// `GPMFReader.maxRecursionDepth`, `JUMBFParser.maxDepth`).
    private static let maxIFDDepth = 32

    /// Metadata tag IDs that we manage (replaced during write).
    private static let metadataTagIDs: Set<UInt16> = [
        ExifTag.xmpTag,          // 0x02BC — XMP
        ExifTag.iccProfile,      // 0x8773 — ICC color profile
        ExifTag.iptcNAA,         // 0x83BB — raw IPTC-NAA
        ExifTag.photoshopIRB,    // 0x8649 — Photoshop IRB (IPTC container)
        ExifTag.exifIFDPointer,  // 0x8769 — Exif sub-IFD pointer
        ExifTag.gpsIFDPointer,   // 0x8825 — GPS sub-IFD pointer
    ]

    /// IFD0 tags that describe the *pixel data itself* (layout, strips, tiles,
    /// resolution, colour). They are always taken from the destination file and
    /// never copied out of an assigned `exif`, whose IFD0 may come from a
    /// differently-sized source image — copying e.g. StripOffsets would point
    /// at the wrong bytes and corrupt the raster. Descriptive IFD0 tags
    /// (Make, Model, Software, DateTime, Artist, …) are copied from `exif`.
    private static let structuralIFD0Tags: Set<UInt16> = [
        0x00FE, 0x00FF,                                  // NewSubfileType, SubfileType
        0x0100, 0x0101, 0x0102, 0x0103, 0x0106, 0x0107,  // dimensions / compression / photometric
        0x0108, 0x0109, 0x010A,                          // cell sizes, fill order
        0x0111, 0x0115, 0x0116, 0x0117,                  // strip offsets / samples / rows / counts
        0x011A, 0x011B, 0x011C,                          // x/y resolution, planar config
        0x0122, 0x0123, 0x0128,                          // gray response, resolution unit
        0x0112,                                          // orientation (tied to the dest pixels)
        0x013D, 0x0140,                                  // predictor, color map
        0x0142, 0x0143, 0x0144, 0x0145,                  // tile width / length / offsets / counts
        0x014A, 0x0153, 0x0154, 0x0155,                  // sub-IFDs, sample format, min/max
        0x0201, 0x0202,                                  // JPEG thumbnail offset/length
    ]

    /// Reconstruct a TIFF file with updated metadata, preserving the raster.
    public static func write(_ tiffFile: TIFFFile, exif: ExifData?, iptc: IPTCData?, xmp: XMPData?, iccProfile: ICCProfile? = nil) throws -> Data {
        var warnings: [String] = []
        return try write(tiffFile, exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile, warnings: &warnings)
    }

    /// Reconstruct a TIFF file with updated metadata, preserving the raster, and
    /// collect non-fatal write warnings (e.g. a relocated MakerNote whose
    /// internal offsets may no longer resolve — see the type doc comment).
    public static func write(_ tiffFile: TIFFFile, exif: ExifData?, iptc: IPTCData?, xmp: XMPData?,
                             iccProfile: ICCProfile? = nil, warnings: inout [String]) throws -> Data {
        let endian = tiffFile.header.byteOrder
        let raw = tiffFile.rawData
        var writer = BinaryWriter(capacity: raw.count + 8192)

        // TIFF header — IFD0 immediately follows at offset 8.
        TIFFHeader(byteOrder: endian).write(to: &writer)

        // Build the top-level IFD entry lists: IFD0 gets the metadata merge,
        // later IFDs (e.g. the IFD1 thumbnail) pass through structurally.
        var topIFDs: [[IFDEntry]]
        if tiffFile.ifds.isEmpty {
            topIFDs = [try buildIFD0Entries(existing: [], exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile)]
        } else {
            topIFDs = tiffFile.ifds.map { $0.entries }
            topIFDs[0] = try buildIFD0Entries(existing: tiffFile.ifds[0].entries, exif: exif, iptc: iptc, xmp: xmp, iccProfile: iccProfile)
        }

        // Sub-IFDs to relocate under IFD0 come from the assigned exif model.
        var ifd0SubIFDs: [UInt16: [IFDEntry]] = [:]
        if let exifIFD = exif?.exifIFD { ifd0SubIFDs[exifPointer] = exifIFD.entries }
        if let gpsIFD = exif?.gpsIFD { ifd0SubIFDs[gpsPointer] = gpsIFD.entries }

        // Camera Make (from the IFD0 being written) drives per-manufacturer
        // MakerNote offset fix-up when the Exif sub-IFD is relocated below.
        let make = topIFDs[0].first { $0.tag == ExifTag.make }?.stringValue(endian: endian)

        var prevNextField: Int? = nil
        for (index, entries) in topIFDs.enumerated() {
            if writer.count % 2 != 0 { writer.writeUInt8(0) } // word-align each IFD
            let ifdStart = writer.count
            if let p = prevNextField {
                try writer.patchUInt32(UInt32(ifdStart), at: p, endian: endian)
            }
            let subIFDs = index == 0 ? ifd0SubIFDs : [:]
            prevNextField = try writeIFD(&writer, entries: entries, endian: endian, raw: raw, subIFDs: subIFDs, make: make, warnings: &warnings)
        }
        // The final IFD's next-offset field was written as 0 — leave it.

        return writer.data
    }

    // MARK: - IFD0 metadata merge

    private static func buildIFD0Entries(
        existing: [IFDEntry],
        exif: ExifData?,
        iptc: IPTCData?,
        xmp: XMPData?,
        iccProfile: ICCProfile?
    ) throws -> [IFDEntry] {
        // Keep existing non-metadata entries (this retains structural and raster
        // tags such as StripOffsets/StripByteCounts).
        var entries = existing.filter { !metadataTagIDs.contains($0.tag) }

        // Merge descriptive IFD0 tags (Make, Model, Software, DateTime, …) from
        // the assigned exif, overriding the destination's same-tag entries.
        // Structural/raster tags and sub-IFD pointers are excluded — structural
        // layout stays with the destination, and Exif/GPS sub-IFDs are written
        // separately from `exif.exifIFD` / `exif.gpsIFD`.
        if let ifd0 = exif?.ifd0 {
            let descriptive = ifd0.entries.filter {
                !structuralIFD0Tags.contains($0.tag) && !metadataTagIDs.contains($0.tag) && !pointerTags.contains($0.tag)
            }
            let overrideTags = Set(descriptive.map { $0.tag })
            entries.removeAll { overrideTags.contains($0.tag) }
            entries.append(contentsOf: descriptive)
        }

        if let xmp = xmp {
            let xmlData = Data(XMPWriter.generateXML(xmp).utf8)
            entries.append(IFDEntry(tag: ExifTag.xmpTag, type: .undefined, count: UInt32(xmlData.count), valueData: xmlData))
        }

        if let iptc = iptc, !iptc.datasets.isEmpty {
            let iptcBinary = try IPTCWriter.write(iptc)
            let irbData = PhotoshopIRB.write(blocks: [IRBBlock(resourceID: PhotoshopIRB.iptcResourceID, data: iptcBinary)])
            entries.append(IFDEntry(tag: ExifTag.photoshopIRB, type: .undefined, count: UInt32(irbData.count), valueData: irbData))
        }

        if let icc = iccProfile {
            entries.append(IFDEntry(tag: ExifTag.iccProfile, type: .undefined, count: UInt32(icc.data.count), valueData: icc.data))
        }

        return entries.sorted { $0.tag < $1.tag }
    }

    // MARK: - IFD serialization (with block relocation)

    /// Write one IFD plus all data it points at (strip/tile/JPEG rasters and the
    /// Exif/GPS sub-IFDs), rewriting every offset. Returns the file position of
    /// this IFD's 4-byte next-IFD-offset field (initialized to 0) so the caller
    /// can chain it.
    private static func writeIFD(_ writer: inout BinaryWriter, entries rawEntries: [IFDEntry], endian: ByteOrder,
                                 raw: Data, subIFDs: [UInt16: [IFDEntry]], make: String?, warnings: inout [String], depth: Int = 0) throws -> Int {
        // Resolve every pointer entry to the child IFD(s) we will relocate.
        // Model-supplied children (Exif/GPS) win; every other pointer — Interop,
        // any nested pointer, and the per-offset children of a 0x014A array — is
        // parsed from the source bytes. Pointers we cannot resolve (offset out of
        // bounds, malformed IFD, or recursion bounded) are dropped so the output
        // never carries a dangling offset.
        let canRecurse = depth < maxIFDDepth
        var singleChildren: [UInt16: [IFDEntry]] = [:]  // single-offset pointers → child entries
        var subIFDChildren: [[IFDEntry]] = []           // 0x014A array → child entries, in order
        for e in rawEntries where pointerTags.contains(e.tag) {
            if e.tag == subIFDsPointer {
                guard canRecurse else { continue }
                for off in parseOffsets(e, endian: endian) {
                    if let child = parseChildIFD(raw, offset: Int(off), endian: endian) {
                        subIFDChildren.append(child)
                    }
                }
            } else if let model = subIFDs[e.tag] {
                singleChildren[e.tag] = model
            } else if canRecurse, let off = parseOffsets(e, endian: endian).first,
                      let child = parseChildIFD(raw, offset: Int(off), endian: endian) {
                singleChildren[e.tag] = child
            }
        }
        // Model children whose pointer entry was stripped upstream (Exif/GPS are
        // removed in `buildIFD0Entries` and re-injected here).
        for (tag, child) in subIFDs where singleChildren[tag] == nil {
            singleChildren[tag] = child
        }

        // Keep only pointer entries whose child we resolved; inject a placeholder
        // pointer for resolved model children not already present in the source.
        var entries = rawEntries.filter { e in
            guard pointerTags.contains(e.tag) else { return true }
            return e.tag == subIFDsPointer ? !subIFDChildren.isEmpty : singleChildren[e.tag] != nil
        }
        for tag in singleChildren.keys where !entries.contains(where: { $0.tag == tag }) {
            entries.append(IFDEntry(tag: tag, type: .long, count: 1, valueData: Data([0, 0, 0, 0])))
        }
        entries.sort { $0.tag < $1.tag }

        // Directory type per entry: offset arrays (strip/tile rasters and the
        // 0x014A SubIFDs array) are written as LONG so a relocated offset always
        // fits even if the source used SHORT.
        func isOffsetArray(_ tag: UInt16) -> Bool {
            tag == stripOffsets || tag == tileOffsets || tag == subIFDsPointer
        }
        func dirType(_ e: IFDEntry) -> TIFFDataType {
            isOffsetArray(e.tag) ? .long : e.type
        }
        func dirCount(_ e: IFDEntry) -> UInt32 {
            if e.tag == subIFDsPointer { return UInt32(subIFDChildren.count) }
            return isOffsetArray(e.tag) ? UInt32(parseOffsets(e, endian: endian).count) : e.count
        }

        // --- Directory pass: write entries; inline small values, leave a
        // placeholder for everything that needs out-of-line data. ---
        writer.writeUInt16(UInt16(entries.count), endian: endian)
        var slotPositions: [Int] = []
        for e in entries {
            let type = dirType(e)
            let count = dirCount(e)
            writer.writeUInt16(e.tag, endian: endian)
            writer.writeUInt16(type.rawValue, endian: endian)
            writer.writeUInt32(count, endian: endian)
            let managed = pointerTags.contains(e.tag) || e.tag == stripOffsets || e.tag == tileOffsets || e.tag == jpegInterchangeFormat
            let valueSize = Int(count) * type.unitSize
            slotPositions.append(writer.count)
            if !managed && valueSize <= 4 {
                var padded = e.valueData.prefix(4)
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(Data(padded))
            } else {
                writer.writeUInt32(0, endian: endian) // placeholder; filled below
            }
        }
        let nextOffsetPos = writer.count
        writer.writeUInt32(0, endian: endian) // next-IFD offset (chained by caller)

        // --- Data pass: append out-of-line data and patch the slots. ---
        for (idx, e) in entries.enumerated() {
            let pos = slotPositions[idx]

            if e.tag == stripOffsets || e.tag == tileOffsets {
                let byteCountTag = e.tag == stripOffsets ? stripByteCounts : tileByteCounts
                let lengths = entries.first { $0.tag == byteCountTag }.map { parseOffsets($0, endian: endian) } ?? []
                let srcOffsets = parseOffsets(e, endian: endian)
                var newOffsets: [UInt64] = []
                for (k, srcOff) in srcOffsets.enumerated() {
                    let len = k < lengths.count ? Int(lengths[k]) : 0
                    align(&writer)
                    newOffsets.append(UInt64(writer.count))
                    writer.writeBytes(copyBlock(raw, offset: Int(srcOff), length: len))
                }
                writeOffsetArray(&writer, newOffsets, into: pos, endian: endian)

            } else if e.tag == jpegInterchangeFormat {
                let len = entries.first { $0.tag == jpegInterchangeFormatLength }
                    .flatMap { parseOffsets($0, endian: endian).first }.map(Int.init) ?? 0
                let srcOff = parseOffsets(e, endian: endian).first.map(Int.init) ?? 0
                align(&writer)
                let newOff = writer.count
                writer.writeBytes(copyBlock(raw, offset: srcOff, length: len))
                try writer.patchUInt32(UInt32(newOff), at: pos, endian: endian)

            } else if e.tag == subIFDsPointer {
                // Relocate each child IFD (with its own raster and nested
                // pointers) and rewrite 0x014A as the new LONG offset array.
                var newOffsets: [UInt64] = []
                for child in subIFDChildren {
                    align(&writer)
                    newOffsets.append(UInt64(writer.count))
                    _ = try writeIFD(&writer, entries: child, endian: endian, raw: raw, subIFDs: [:], make: make, warnings: &warnings, depth: depth + 1)
                }
                writeOffsetArray(&writer, newOffsets, into: pos, endian: endian)

            } else if pointerTags.contains(e.tag), let childEntries = singleChildren[e.tag] {
                align(&writer)
                let childPos = writer.count
                // Recurse with no model children: nested pointers (e.g. Interop
                // inside Exif) are relocated from `raw` by the resolver above.
                _ = try writeIFD(&writer, entries: childEntries, endian: endian, raw: raw, subIFDs: [:], make: make, warnings: &warnings, depth: depth + 1)
                try writer.patchUInt32(UInt32(childPos), at: pos, endian: endian)

            } else if e.tag == ExifTag.makerNote, Int(e.count) * e.type.unitSize > 4 {
                // Relocate the MakerNote, fixing up absolute internal offsets
                // for manufacturers we recognize. `delta` is TIFF-relative: the
                // destination header sits at buffer 0, so the new offset is the
                // write position. Without a source offset we cannot compute it.
                align(&writer)
                let off = writer.count
                if let src = e.sourceOffset {
                    let r = MakerNoteRelocator.relocate(data: e.valueData, make: make, endian: endian, delta: off - src)
                    writer.writeBytes(r.bytes)
                    if !r.isSafe { appendMakerNoteWarning(&warnings) }
                } else {
                    writer.writeBytes(e.valueData)
                    appendMakerNoteWarning(&warnings)
                }
                try writer.patchUInt32(UInt32(off), at: pos, endian: endian)

            } else if Int(e.count) * e.type.unitSize > 4 {
                align(&writer)
                let off = writer.count
                writer.writeBytes(e.valueData)
                try writer.patchUInt32(UInt32(off), at: pos, endian: endian)
            }
            // else: inline value already written in the directory pass.
        }

        return nextOffsetPos
    }

    // MARK: - Helpers

    /// Parse an entry's value as an array of unsigned integers (SHORT or LONG).
    private static func parseOffsets(_ entry: IFDEntry, endian: ByteOrder) -> [UInt64] {
        var reader = BinaryReader(data: entry.valueData)
        var values: [UInt64] = []
        for _ in 0..<entry.count {
            switch entry.type {
            case .short:
                guard let v = try? reader.readUInt16(endian: endian) else { return values }
                values.append(UInt64(v))
            case .long:
                guard let v = try? reader.readUInt32(endian: endian) else { return values }
                values.append(UInt64(v))
            default:
                return values
            }
        }
        return values
    }

    /// Parse a child IFD from the source bytes for relocation. Offsets are
    /// absolute from the TIFF start (0 for a standalone TIFF). Returns nil when
    /// the offset is out of bounds or the IFD is malformed, so the caller drops
    /// the pointer rather than emitting a dangling offset.
    private static func parseChildIFD(_ raw: Data, offset: Int, endian: ByteOrder) -> [IFDEntry]? {
        guard offset >= 0, offset < raw.count else { return nil }
        guard let (ifd, _) = try? IFDParser.parseIFD(data: raw, tiffStart: 0, offset: offset, endian: endian) else {
            return nil
        }
        return ifd.entries
    }

    /// Copy `length` bytes at `offset` from the source file, clamped to bounds.
    private static func copyBlock(_ raw: Data, offset: Int, length: Int) -> Data {
        guard offset >= 0, length > 0, offset < raw.count else { return Data() }
        let end = min(offset + length, raw.count)
        return raw.subdata(in: (raw.startIndex + offset) ..< (raw.startIndex + end))
    }

    /// Write a relocated offset array (LONG) into a directory slot: inline when
    /// a single value fits, otherwise appended out-of-line and referenced.
    private static func writeOffsetArray(_ writer: inout BinaryWriter, _ offsets: [UInt64], into pos: Int, endian: ByteOrder) {
        if offsets.count <= 1 {
            try? writer.patchUInt32(UInt32(offsets.first ?? 0), at: pos, endian: endian)
        } else {
            align(&writer)
            let arrayOffset = writer.count
            for v in offsets { writer.writeUInt32(UInt32(truncatingIfNeeded: v), endian: endian) }
            try? writer.patchUInt32(UInt32(arrayOffset), at: pos, endian: endian)
        }
    }

    private static func align(_ writer: inout BinaryWriter) {
        if writer.count % 2 != 0 { writer.writeUInt8(0) }
    }

    /// Append the (deduplicated) warning for a MakerNote that was relocated but
    /// could not have its internal offsets safely fixed up.
    static func appendMakerNoteWarning(_ warnings: inout [String]) {
        let note = "MakerNote (0x927C) was relocated but its manufacturer-specific internal offsets could not be fixed up, so they may no longer resolve."
        if !warnings.contains(note) { warnings.append(note) }
    }
}
