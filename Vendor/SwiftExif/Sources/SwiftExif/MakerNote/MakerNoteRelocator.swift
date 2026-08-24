import Foundation

/// Fixes up a MakerNote's internal value offsets when the whole MakerNote block
/// is relocated to a new file offset during a write.
///
/// MakerNotes store internal pointers under one of two conventions (modeled on
/// ExifTool's `MakerNotes.pm::FixBase` / `WriteExif.pl::RebuildMakerNotes`):
///
/// - **Relative / entry-based** — pointers are relative to the MakerNote (or an
///   embedded TIFF header) or to each IFD entry. They move *with* the block, so
///   a verbatim copy stays valid. No fix-up, no warning.
/// - **Absolute** — pointers are byte offsets from the TIFF header start. When
///   the block moves by `delta`, every out-of-line value-offset field must be
///   patched `+= delta` (the value bytes moved by the same `delta`, staying
///   inside the block, so the correct new pointer is uniformly `oldPtr + delta`).
///
/// The convention is determined from the camera Make via a conservative
/// per-manufacturer table. Anything we cannot classify or safely patch is
/// returned unchanged with `isSafe == false`, so the caller copies the note
/// verbatim and surfaces the existing non-fatal warning — never emitting a
/// more-corrupt note than a plain verbatim copy would.
struct MakerNoteRelocator: Sendable {

    struct Result {
        /// Bytes to write: patched (absolute case) or the original input.
        let bytes: Data
        /// Whether internal offsets were rewritten.
        let didFixUp: Bool
        /// Whether the relocated note's internal offsets are known-good. When
        /// false, the caller should surface the relocated-MakerNote warning.
        let isSafe: Bool
    }

    /// Offset convention of a MakerNote's internal pointers.
    private enum Convention {
        /// Pointers relative to the moving block — verbatim copy is correct.
        case relativeSafe
        /// Pointers absolute from the TIFF start — patch each by `delta`.
        case absolute
        /// Could not classify — verbatim copy + warn.
        case unknownFallback
    }

    /// Relocate a MakerNote whose block moves by `delta` bytes.
    /// - Parameters:
    ///   - data: the verbatim MakerNote value bytes (the 0x927C entry value).
    ///   - make: the IFD0 Make string, for manufacturer identification.
    ///   - endian: the parent TIFF byte order.
    ///   - delta: `newTiffRelativeOffset - oldTiffRelativeOffset` for the block.
    static func relocate(data: Data, make: String?, endian: ByteOrder, delta: Int) -> Result {
        // No move → nothing to fix and nothing to warn about.
        if delta == 0 { return Result(bytes: data, didFixUp: false, isSafe: true) }

        switch convention(make: make) {
        case .relativeSafe:
            return Result(bytes: data, didFixUp: false, isSafe: true)
        case .unknownFallback:
            return Result(bytes: data, didFixUp: false, isSafe: false)
        case .absolute:
            if let fixed = fixAbsolute(data: data, make: make, endian: endian, delta: delta) {
                return Result(bytes: fixed, didFixUp: true, isSafe: true)
            }
            // Parse/bounds failure → verbatim + warn.
            return Result(bytes: data, didFixUp: false, isSafe: false)
        }
    }

    // MARK: - Classification

    private static func convention(make: String?) -> Convention {
        switch MakerNoteReader.identifyManufacturer(make: make) {
        // Bare IFD at offset 0 (and Pentax "AOC") using TIFF-absolute offsets.
        // Modern Sony ("Sony5") notes also store TIFF-absolute value pointers, so
        // a verbatim copy after a move leaves them dangling — they need fix-up.
        case .canon, .dji, .samsung, .pentax, .sony:
            return .absolute
        // Header- or embedded-TIFF-anchored offsets that move with the block.
        case .nikon, .fujifilm, .panasonic, .olympus, .apple:
            return .relativeSafe
        // Be conservative for the rest (Leica/Sigma mix conventions per model).
        case .leica, .sigma, .unknown:
            return .unknownFallback
        }
    }

    // MARK: - Absolute fix-up

    /// Where the internal IFD lives within an absolute-offset MakerNote, plus
    /// the note's own byte order and any trailing footer to leave out of the walk.
    private struct Layout {
        let ifdOffset: Int
        let endian: ByteOrder
        /// Trailing bytes (e.g. a Canon TIFF footer) excluded from the IFD walk.
        let footerLength: Int
    }

    private static func locate(data: Data, make: String?, parentEndian: ByteOrder) -> Layout? {
        let manufacturer = MakerNoteReader.identifyManufacturer(make: make)
        switch manufacturer {
        case .canon, .dji, .samsung:
            // Bare IFD at offset 0 in the parent byte order. Canon may carry an
            // 8-byte TIFF footer ("II*\0"/"MM\0*" + original-offset LONG).
            let footer = canonFooterLength(data: data, endian: parentEndian)
            return Layout(ifdOffset: 0, endian: parentEndian, footerLength: footer)
        case .pentax:
            // JPEG-style "AOC\0" + 2-byte BOM, then the IFD at offset 6.
            guard data.count >= 8, data.prefix(4) == Data([0x41, 0x4F, 0x43, 0x00]) else { return nil }
            let s = data.startIndex
            let bom0 = data[s + 4], bom1 = data[s + 5]
            let e: ByteOrder
            if bom0 == 0x4D && bom1 == 0x4D { e = .bigEndian }
            else if bom0 == 0x49 && bom1 == 0x49 { e = .littleEndian }
            else { return nil }
            return Layout(ifdOffset: 6, endian: e, footerLength: 0)
        case .sony:
            // Sony5 (modern Alpha/RX/FX): a bare IFD at offset 0 in the parent
            // byte order, no footer, TIFF-absolute value pointers. The older
            // "SONY DSC"/"SONY CAM"-prefixed notes use an offset base we can't
            // confirm without sample coverage, so bail to verbatim+warn for them
            // rather than risk patching the wrong fields.
            if data.count > 12,
               data.prefix(9) == Data("SONY DSC ".utf8) || data.prefix(9) == Data("SONY CAM ".utf8) {
                return nil
            }
            return Layout(ifdOffset: 0, endian: parentEndian, footerLength: 0)
        default:
            return nil
        }
    }

    /// Length of a Canon-style TIFF footer if present at the end of `data`
    /// (8 bytes: TIFF magic matching `endian` + a 4-byte original-offset LONG),
    /// else 0.
    private static func canonFooterLength(data: Data, endian: ByteOrder) -> Int {
        guard data.count >= 8 else { return 0 }
        let s = data.startIndex
        let f = s + data.count - 8
        let magic = endian == .bigEndian ? [0x4D, 0x4D, 0x00, 0x2A] : [0x49, 0x49, 0x2A, 0x00]
        for i in 0..<4 where data[f + i] != UInt8(magic[i]) { return 0 }
        return 8
    }

    /// Patch every out-of-line value-offset field (and a footer/next-IFD offset)
    /// by `delta`. Returns nil on any bounds/parse failure so the caller falls
    /// back to a verbatim copy.
    private static func fixAbsolute(data: Data, make: String?, endian parentEndian: ByteOrder, delta: Int) -> Data? {
        guard let layout = locate(data: data, make: make, parentEndian: parentEndian) else { return nil }
        let endian = layout.endian
        let ifdEnd = data.count - layout.footerLength
        guard ifdEnd >= layout.ifdOffset + 2 else { return nil }

        var writer = BinaryWriter(capacity: data.count)
        writer.writeBytes(data)
        var reader = BinaryReader(data: data)

        guard (try? reader.seek(to: layout.ifdOffset)) != nil,
              let count = try? reader.readUInt16(endian: endian) else { return nil }

        let entriesEnd = layout.ifdOffset + 2 + Int(count) * 12
        // Directory + 4-byte next-IFD pointer must fit inside the IFD region.
        guard entriesEnd + 4 <= ifdEnd else { return nil }

        for i in 0..<Int(count) {
            let entryPos = layout.ifdOffset + 2 + i * 12
            guard (try? reader.seek(to: entryPos + 2)) != nil,
                  let typeRaw = try? reader.readUInt16(endian: endian),
                  let valueCount = try? reader.readUInt32(endian: endian) else { return nil }
            // Unknown type: skip the entry (its value isn't an offset we resolve).
            guard let type = TIFFDataType(rawValue: typeRaw) else { continue }

            let (valueSize, overflow) = Int(valueCount).multipliedReportingOverflow(by: type.unitSize)
            guard !overflow, valueSize >= 0 else { return nil }
            guard valueSize > 4 else { continue } // inline value, no offset to patch

            let valueFieldPos = entryPos + 8
            guard (try? reader.seek(to: valueFieldPos)) != nil,
                  let oldPtr = try? reader.readUInt32(endian: endian) else { return nil }
            guard let newPtr = patched(oldPtr, by: delta) else { return nil }
            try? writer.patchUInt32(newPtr, at: valueFieldPos, endian: endian)
        }

        // Next-IFD pointer: a non-zero absolute offset must shift too. A non-zero
        // value also implies a chained MakerNote IFD we don't walk recursively —
        // bail to verbatim rather than emit a half-fixed note.
        guard (try? reader.seek(to: entriesEnd)) != nil,
              let nextIFD = try? reader.readUInt32(endian: endian) else { return nil }
        if nextIFD != 0 { return nil }

        // Canon TIFF footer: holds the MakerNote's original start offset. Shift
        // it so footer-aware readers (e.g. exiftool) compute a zero correction
        // rather than double-applying the move.
        if layout.footerLength == 8 {
            let footerOffPos = data.count - 4
            guard (try? reader.seek(to: footerOffPos)) != nil,
                  let oldFooter = try? reader.readUInt32(endian: endian) else { return nil }
            if oldFooter != 0, let newFooter = patched(oldFooter, by: delta) {
                try? writer.patchUInt32(newFooter, at: footerOffPos, endian: endian)
            }
        }

        return writer.data
    }

    /// Apply `delta` to a 32-bit offset, returning nil if the result is out of
    /// the representable unsigned range.
    private static func patched(_ value: UInt32, by delta: Int) -> UInt32? {
        let result = Int(value) + delta
        guard result >= 0, result <= Int(UInt32.max) else { return nil }
        return UInt32(result)
    }
}
