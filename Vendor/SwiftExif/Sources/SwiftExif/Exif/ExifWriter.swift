import Foundation

/// Serialize ExifData back to APP1 segment payload.
public struct ExifWriter: Sendable {

    /// Serialize ExifData to APP1 segment payload (including "Exif\0\0" prefix).
    public static func write(_ exifData: ExifData) -> Data {
        var warnings: [String] = []
        return write(exifData, warnings: &warnings)
    }

    /// Serialize ExifData to APP1 segment payload (including "Exif\0\0" prefix),
    /// collecting non-fatal write warnings (e.g. a relocated MakerNote whose
    /// internal offsets could not be fixed up).
    public static func write(_ exifData: ExifData, warnings: inout [String]) -> Data {
        var writer = BinaryWriter(capacity: 4096)

        // Exif identifier
        writer.writeBytes([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

        // Append raw TIFF data
        writer.writeBytes(writeTIFF(exifData, warnings: &warnings))

        return writer.data
    }

    /// Serialize ExifData to an APP1 segment payload (including "Exif\0\0" prefix)
    /// that fits within `maxPayload` bytes — JPEG's hard per-segment ceiling.
    ///
    /// EXIF copied wholesale from a camera RAW can carry oversized proprietary
    /// blobs that blow past the 64 KB limit — e.g. a Sony A1 (ILCE-1) embeds a
    /// ~1.5 MB C2PA / Content Credentials manifest (JUMBF) in IFD0 tag 0xCD41,
    /// and other bodies stash embedded RAW previews or SR2 private data. JPEG's
    /// Exif APP1 simply cannot hold these (ExifTool refuses to exceed the limit
    /// too), so rather than abort the whole metadata write, drop the largest
    /// droppable values and re-serialize until the payload fits, recording each
    /// drop as a non-fatal warning.
    ///
    /// Drop priority: IFD1 thumbnail → large proprietary external-value tags
    /// (largest first) → MakerNote (dropped last; it carries real lens/body
    /// telemetry worth keeping). Standard tags (Make/Model/exposure/lens) are
    /// tiny and are never selected before the big blobs are gone.
    ///
    /// Note: copying a source C2PA manifest into a re-encoded derivative is
    /// semantically invalid anyway — its content-binding hash covers the
    /// original pixels — so dropping it here is correct, not a lossy compromise.
    public static func write(_ exifData: ExifData, maxPayload: Int, warnings: inout [String]) -> Data {
        var scratch: [String] = []
        var data = write(exifData, warnings: &scratch)
        if data.count <= maxPayload {
            warnings.append(contentsOf: scratch)
            return data
        }

        var trimmed = exifData
        var dropped: [String] = []

        func reserialize() {
            scratch = []
            data = write(trimmed, warnings: &scratch)
        }

        // 1. Thumbnail IFD (IFD1) — never essential on a re-encoded derivative.
        if data.count > maxPayload, trimmed.ifd1 != nil {
            trimmed.ifd1 = nil
            dropped.append("thumbnail (IFD1)")
            reserialize()
        }

        // 2. Largest external-value tags, MakerNote dropped last.
        while data.count > maxPayload, let target = largestDroppableTag(in: trimmed) {
            trimmed = dropTag(target, from: trimmed)
            dropped.append(target.label)
            reserialize()
        }

        if !dropped.isEmpty {
            warnings.append(
                "Exif APP1 payload exceeded JPEG's \(maxPayload)-byte segment limit; "
                + "dropped \(dropped.joined(separator: ", ")) to fit."
            )
        }
        if data.count > maxPayload {
            warnings.append(
                "Exif APP1 payload still exceeds the \(maxPayload)-byte JPEG segment limit "
                + "(\(data.count) bytes) after dropping all droppable tags."
            )
        }
        warnings.append(contentsOf: scratch)
        return data
    }

    /// Identifies a single external-value tag to drop when shrinking an
    /// over-length Exif APP1 payload.
    private struct DropTarget {
        enum Location { case ifd0, exifIFD }
        let location: Location
        let tag: UInt16
        let size: Int
        let label: String
    }

    /// The largest droppable external-value (> 4 byte) tag in IFD0 or the Exif
    /// sub-IFD, preferring proprietary blobs over the MakerNote (which is only
    /// surrendered once nothing else is left to drop). Sub-IFD pointers are
    /// excluded — the writer recomputes those.
    private static func largestDroppableTag(in exif: ExifData) -> DropTarget? {
        var best: DropTarget?
        func consider(_ ifd: IFD?, _ location: DropTarget.Location) {
            guard let ifd = ifd else { return }
            for entry in ifd.entries where entry.totalValueSize > 4 {
                switch entry.tag {
                case ExifTag.makerNote, ExifTag.exifIFDPointer, ExifTag.gpsIFDPointer:
                    continue
                default:
                    break
                }
                if best == nil || entry.totalValueSize > best!.size {
                    best = DropTarget(location: location, tag: entry.tag,
                                      size: entry.totalValueSize,
                                      label: tagLabel(entry.tag, size: entry.totalValueSize))
                }
            }
        }
        consider(exif.ifd0, .ifd0)
        consider(exif.exifIFD, .exifIFD)
        if let best = best { return best }

        // No proprietary blob left — surrender the MakerNote as a last resort.
        if let makerNote = exif.exifIFD?.entry(for: ExifTag.makerNote) {
            return DropTarget(location: .exifIFD, tag: ExifTag.makerNote,
                              size: makerNote.totalValueSize,
                              label: "MakerNote (\(makerNote.totalValueSize) bytes)")
        }
        return nil
    }

    private static func dropTag(_ target: DropTarget, from exif: ExifData) -> ExifData {
        var exif = exif
        switch target.location {
        case .ifd0:
            if let ifd0 = exif.ifd0 { exif.ifd0 = ifd0.removingEntry(for: target.tag) }
        case .exifIFD:
            if let exifIFD = exif.exifIFD { exif.exifIFD = exifIFD.removingEntry(for: target.tag) }
            // Also clear the parsed MakerNote so a dirty copy isn't re-injected.
            if target.tag == ExifTag.makerNote { exif.makerNote = nil }
        }
        return exif
    }

    private static func tagLabel(_ tag: UInt16, size: Int) -> String {
        let name: String
        switch tag {
        case 0xCD41: name = "C2PA/JUMBF manifest"
        default: name = String(format: "tag 0x%04X", tag)
        }
        return "\(name) (\(size) bytes)"
    }

    /// Serialize ExifData to raw TIFF bytes (no "Exif\0\0" prefix).
    /// Used by PNG (eXIf chunk), JPEG XL (Exif box), AVIF (Exif property box), and TIFF files.
    public static func writeTIFF(_ exifData: ExifData) -> Data {
        var warnings: [String] = []
        return writeTIFF(exifData, warnings: &warnings)
    }

    /// Serialize ExifData to raw TIFF bytes, collecting non-fatal write warnings.
    public static func writeTIFF(_ exifData: ExifData, warnings: inout [String]) -> Data {
        let endian = exifData.byteOrder
        let make = exifData.make
        var writer = BinaryWriter(capacity: 4096)

        let tiffStart = writer.count

        // TIFF header (will patch IFD offset)
        let header = TIFFHeader(byteOrder: endian)
        header.write(to: &writer)

        // Collect all IFDs and their data
        var ifd0Entries = exifData.ifd0?.entries ?? []
        var exifIFDEntries = exifData.exifIFD?.entries ?? []
        let gpsIFDEntries = exifData.gpsIFD?.entries ?? []

        // If MakerNote is dirty, regenerate its binary and update the Exif IFD entry.
        // A regenerated note is rebuilt by MakerNoteWriter, so it bypasses
        // relocation fix-up below.
        var makerNoteWasRebuilt = false
        if let makerNote = exifData.makerNote, makerNote.isDirty {
            let newMakerNoteData = MakerNoteWriter.write(makerNote, byteOrder: endian)
            exifIFDEntries = exifIFDEntries.map { entry in
                if entry.tag == ExifTag.makerNote {
                    return IFDEntry(tag: ExifTag.makerNote, type: .undefined,
                                    count: UInt32(newMakerNoteData.count), valueData: newMakerNoteData)
                }
                return entry
            }
            makerNoteWasRebuilt = true
        }

        // Remove existing sub-IFD pointers (we'll recalculate)
        ifd0Entries.removeAll { $0.tag == ExifTag.exifIFDPointer || $0.tag == ExifTag.gpsIFDPointer }

        // Phase 1: Calculate sizes to determine offsets

        // IFD0 size
        let hasExifIFD = !exifIFDEntries.isEmpty
        let hasGPSIFD = !gpsIFDEntries.isEmpty

        var totalIFD0Entries = ifd0Entries.count
        if hasExifIFD { totalIFD0Entries += 1 }
        if hasGPSIFD { totalIFD0Entries += 1 }

        let ifd0Size = 2 + totalIFD0Entries * 12 + 4 // count + entries + next offset

        // IFD0 data starts after IFD0 directory
        let ifd0DataStart = 8 + ifd0Size // 8 = TIFF header size

        // Calculate IFD0 external data size
        var ifd0ExternalSize = 0
        for entry in ifd0Entries {
            if entry.totalValueSize > 4 {
                ifd0ExternalSize += entry.totalValueSize
                // Align to word boundary
                if ifd0ExternalSize % 2 != 0 { ifd0ExternalSize += 1 }
            }
        }

        // Exif IFD offset (after IFD0 + IFD0 data)
        let exifIFDOffset = ifd0DataStart + ifd0ExternalSize

        // Exif IFD size
        let exifIFDSize = hasExifIFD ? (2 + exifIFDEntries.count * 12 + 4) : 0

        // Exif IFD external data
        var exifExternalSize = 0
        if hasExifIFD {
            for entry in exifIFDEntries {
                if entry.totalValueSize > 4 {
                    exifExternalSize += entry.totalValueSize
                    if exifExternalSize % 2 != 0 { exifExternalSize += 1 }
                }
            }
        }

        // GPS IFD offset
        let gpsIFDOffset = exifIFDOffset + exifIFDSize + exifExternalSize

        // GPS IFD size (used for offset calculation above)
        _ = hasGPSIFD ? (2 + gpsIFDEntries.count * 12 + 4) : 0

        var gpsExternalSize = 0
        if hasGPSIFD {
            for entry in gpsIFDEntries {
                if entry.totalValueSize > 4 {
                    gpsExternalSize += entry.totalValueSize
                    if gpsExternalSize % 2 != 0 { gpsExternalSize += 1 }
                }
            }
        }

        // Phase 2: Write IFD0
        // Add sub-IFD pointer entries
        var allIFD0Entries = ifd0Entries
        if hasExifIFD {
            var exifOffsetData = BinaryWriter(capacity: 4)
            exifOffsetData.writeUInt32(UInt32(exifIFDOffset), endian: endian)
            allIFD0Entries.append(IFDEntry(tag: ExifTag.exifIFDPointer, type: .long, count: 1, valueData: exifOffsetData.data))
        }
        if hasGPSIFD {
            var gpsOffsetData = BinaryWriter(capacity: 4)
            gpsOffsetData.writeUInt32(UInt32(gpsIFDOffset), endian: endian)
            allIFD0Entries.append(IFDEntry(tag: ExifTag.gpsIFDPointer, type: .long, count: 1, valueData: gpsOffsetData.data))
        }

        // Sort by tag ID (TIFF spec requires this)
        allIFD0Entries.sort { $0.tag < $1.tag }

        writeIFD(&writer, entries: allIFD0Entries, endian: endian, dataOffset: ifd0DataStart, nextIFDOffset: 0, tiffStart: tiffStart, make: make, relocateMakerNote: false, warnings: &warnings)

        // Write Exif IFD
        if hasExifIFD {
            let exifDataStart = exifIFDOffset + 2 + exifIFDEntries.count * 12 + 4
            let sortedExifEntries = exifIFDEntries.sorted { $0.tag < $1.tag }
            writeIFD(&writer, entries: sortedExifEntries, endian: endian, dataOffset: exifDataStart, nextIFDOffset: 0, tiffStart: tiffStart, make: make, relocateMakerNote: !makerNoteWasRebuilt, warnings: &warnings)
        }

        // Write GPS IFD
        if hasGPSIFD {
            let gpsDataStart = gpsIFDOffset + 2 + gpsIFDEntries.count * 12 + 4
            let sortedGPSEntries = gpsIFDEntries.sorted { $0.tag < $1.tag }
            writeIFD(&writer, entries: sortedGPSEntries, endian: endian, dataOffset: gpsDataStart, nextIFDOffset: 0, tiffStart: tiffStart, make: make, relocateMakerNote: false, warnings: &warnings)
        }

        return writer.data
    }

    // MARK: - Private

    static func writeIFD(_ writer: inout BinaryWriter, entries: [IFDEntry], endian: ByteOrder, dataOffset: Int, nextIFDOffset: UInt32, tiffStart: Int,
                         make: String? = nil, relocateMakerNote: Bool = false, warnings: inout [String]) {
        writer.writeUInt16(UInt16(entries.count), endian: endian)

        // Track where external data will go
        var currentDataOffset = dataOffset

        // First pass: write directory entries
        for entry in entries {
            writer.writeUInt16(entry.tag, endian: endian)
            writer.writeUInt16(entry.type.rawValue, endian: endian)
            writer.writeUInt32(entry.count, endian: endian)

            if entry.totalValueSize <= 4 {
                // Inline value (pad to 4 bytes)
                var padded = entry.valueData
                while padded.count < 4 { padded.append(0x00) }
                writer.writeBytes(padded.prefix(4))
            } else {
                // Write offset
                writer.writeUInt32(UInt32(currentDataOffset), endian: endian)
                currentDataOffset += entry.totalValueSize
                if currentDataOffset % 2 != 0 { currentDataOffset += 1 }
            }
        }

        // Next IFD offset
        writer.writeUInt32(nextIFDOffset, endian: endian)

        // Second pass: write external data
        for entry in entries {
            if entry.totalValueSize > 4 {
                if relocateMakerNote, entry.tag == ExifTag.makerNote {
                    // The block lands at this position; `delta` is TIFF-relative.
                    let newOffset = writer.count - tiffStart
                    if let src = entry.sourceOffset {
                        let r = MakerNoteRelocator.relocate(data: entry.valueData, make: make, endian: endian, delta: newOffset - src)
                        writer.writeBytes(r.bytes)
                        if !r.isSafe { TIFFWriter.appendMakerNoteWarning(&warnings) }
                    } else {
                        writer.writeBytes(entry.valueData)
                        TIFFWriter.appendMakerNoteWarning(&warnings)
                    }
                } else {
                    writer.writeBytes(entry.valueData)
                }
                if entry.valueData.count % 2 != 0 {
                    writer.writeUInt8(0x00)
                }
            }
        }
    }
}
