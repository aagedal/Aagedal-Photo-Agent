import Foundation

/// Writes modified metadata back to CR3 files.
///
/// CR3 is an ISOBMFF container. Editing metadata means rebuilding the `moov`
/// box (whose `CMT1`/`CMT2`/`CMT4` TIFF blocks hold EXIF/GPS) and possibly the
/// top-level XMP `uuid` box. Both can change size — and that is the hard part:
/// CR3 stores **absolute file offsets** in two places that must be fixed up or
/// the file is corrupted (the embedded JPEG, preview, and CTMD track become
/// unreadable):
///
///   1. Each track's `co64`/`stco` chunk-offset table points at sample data in
///      `mdat`. When `mdat` moves, every entry shifts by the same amount.
///   2. The Canon `CTBO` box records the absolute offset+size of the top-level
///      boxes that follow `moov` (the XMP uuid, the preview uuid, and `mdat`).
///      Each entry must be re-pointed at the box's new location and size.
///
/// The rewrite therefore runs in two passes: build the new `moov` once to learn
/// its size (offsets don't affect byte length), compute the new top-level
/// layout, then build it again with `co64`/`stco`/`CTBO` patched to the new
/// offsets. Offset-fix-up logic mirrors ExifTool's `QuickTime.pm`/`Canon.pm`
/// CR3 handling (Phil Harvey), which SwiftExif (GPL-3) may reuse.
public struct CR3Writer: Sendable {

    /// A top-level box in the original file, with its absolute byte range.
    private struct TopBox {
        let type: String
        let start: Int        // absolute offset of the box header in the original file
        let total: Int        // full box size including header
        let uuidPrefix: Data  // first 16 bytes of payload for `uuid` boxes (else empty)
        var newTotal: Int     // size this box will have in the output
        var newStart: Int     // absolute offset this box will have in the output
    }

    /// Rebuild a CR3 file with updated Exif and XMP metadata, fixing up all
    /// absolute offset tables so the media payload stays valid.
    public static func write(
        _ file: CR3File,
        exif: ExifData?,
        xmp: XMPData?,
        originalData: Data
    ) throws -> Data {
        // 1. Walk the original top-level boxes, capturing their byte ranges.
        var topBoxes = try parseTopLevelBoxes(originalData)
        guard let moovIndex = topBoxes.firstIndex(where: { $0.type == "moov" }) else {
            // No moov — nothing to rebuild; return original unchanged.
            return originalData
        }
        let moovBox = topBoxes[moovIndex]
        let moovPayload = originalData.subdata(in: (moovBox.start + 8) ..< (moovBox.start + moovBox.total))

        // New XMP payload (16-byte uuid + XML), if we're rewriting XMP.
        let xmpReplacement: Data? = xmp.map { x in
            var payload = Data(CanonUUID.xmpUUID)
            payload.append(Data(XMPWriter.generateXML(x).utf8))
            return payload
        }
        let hasXMPBox = topBoxes.contains {
            $0.type == "uuid" && $0.uuidPrefix == CanonUUID.xmpUUID
        }

        // 2. Pass 1 — rebuild moov with identity offsets to learn its new size.
        let moovPass1 = try rebuildMoovPayload(
            moovPayload, exif: exif, shift: { $0 }, ctboRemap: { ($0, $1) }
        )

        // 3. Compute the new top-level layout (sizes, then offsets).
        for i in topBoxes.indices {
            if i == moovIndex {
                topBoxes[i].newTotal = 8 + moovPass1.count
            } else if let repl = xmpReplacement,
                      topBoxes[i].type == "uuid",
                      topBoxes[i].uuidPrefix == CanonUUID.xmpUUID {
                topBoxes[i].newTotal = 8 + repl.count
            } else {
                topBoxes[i].newTotal = topBoxes[i].total
            }
        }
        var cursor = 0
        for i in topBoxes.indices {
            topBoxes[i].newStart = cursor
            cursor += topBoxes[i].newTotal
        }

        // `shift(off)` maps an original absolute offset to its new location by
        // summing the size change of every box that starts before it.
        let snapshot = topBoxes
        let shift: (UInt64) -> UInt64 = { off in
            let o = Int(off)
            var delta = 0
            for b in snapshot where b.start < o {
                delta += b.newTotal - b.total
            }
            let result = o + delta
            return result < 0 ? 0 : UInt64(result)
        }
        // `ctboRemap` re-points a CTBO (offset, size) entry at the box's new
        // location and size. Empty entries (0,0) are reserved slots — leave them.
        let ctboRemap: (UInt64, UInt64) -> (UInt64, UInt64) = { off, size in
            if off == 0 && size == 0 { return (0, 0) }
            if let b = snapshot.first(where: { $0.start == Int(off) }) {
                return (UInt64(b.newStart), UInt64(b.newTotal))
            }
            return (shift(off), size)
        }

        // 4. Pass 2 — rebuild moov with the real offset fix-ups.
        let moovPass2 = try rebuildMoovPayload(
            moovPayload, exif: exif, shift: shift, ctboRemap: ctboRemap
        )
        // Offset values never change a box's byte length; if they did, the
        // layout we computed above would be wrong, so refuse rather than corrupt.
        guard moovPass2.count == moovPass1.count else {
            throw MetadataError.invalidCR3("CR3 moov size changed between offset passes")
        }

        // 5. Emit the file: rebuilt moov, replaced XMP, everything else verbatim.
        var writer = BinaryWriter(capacity: originalData.count)
        for box in topBoxes {
            if box.type == "moov" {
                writer.writeUInt32BigEndian(UInt32(8 + moovPass2.count))
                writer.writeString("moov", encoding: .isoLatin1)
                writer.writeBytes(moovPass2)
            } else if let repl = xmpReplacement,
                      box.type == "uuid", box.uuidPrefix == CanonUUID.xmpUUID {
                writer.writeUInt32BigEndian(UInt32(8 + repl.count))
                writer.writeString("uuid", encoding: .isoLatin1)
                writer.writeBytes(repl)
            } else {
                // Copy the original bytes verbatim (preserves extended-size
                // headers, free boxes, the preview uuid, and mdat exactly).
                writer.writeBytes(originalData.subdata(in: box.start ..< (box.start + box.total)))
            }
        }

        // If XMP is new (no prior box), append it after mdat. It isn't recorded
        // in CTBO, but co64 offsets are unaffected since it trails everything.
        if let repl = xmpReplacement, !hasXMPBox {
            writer.writeUInt32BigEndian(UInt32(8 + repl.count))
            writer.writeString("uuid", encoding: .isoLatin1)
            writer.writeBytes(repl)
        }

        return writer.data
    }

    // MARK: - Top-level walk

    private static func parseTopLevelBoxes(_ data: Data) throws -> [TopBox] {
        var boxes: [TopBox] = []
        var reader = BinaryReader(data: data)

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let total: Int
            if size32 == 1 {
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16, size64 <= UInt64(Int.max) else { break }
                total = Int(size64)
            } else if size32 == 0 {
                total = data.count - boxStart
            } else {
                guard size32 >= 8 else { break }
                total = Int(size32)
            }
            guard total >= 8, boxStart + total <= data.count else { break }

            // Capture the 16-byte uuid prefix so we can identify XMP/preview boxes.
            var prefix = Data()
            if type == "uuid" {
                let headerSize = size32 == 1 ? 16 : 8
                let payloadStart = boxStart + headerSize
                if payloadStart + 16 <= data.count {
                    prefix = data.subdata(in: payloadStart ..< payloadStart + 16)
                }
            }

            boxes.append(TopBox(type: type, start: boxStart, total: total,
                                uuidPrefix: prefix, newTotal: total, newStart: boxStart))
            try reader.seek(to: boxStart + total)
        }
        return boxes
    }

    // MARK: - moov rebuild

    /// Rebuild the `moov` payload: replace CMT1/2/4 from `exif`, shift every
    /// `co64`/`stco` chunk offset, and remap `CTBO` entries.
    private static func rebuildMoovPayload(
        _ moovData: Data,
        exif: ExifData?,
        shift: (UInt64) -> UInt64,
        ctboRemap: (UInt64, UInt64) -> (UInt64, UInt64)
    ) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: moovData)
        var out: [ISOBMFFBox] = []

        for child in children {
            switch child.type {
            case "trak":
                out.append(try rewriteContainer(child, shift: shift))
            case "uuid" where child.data.count >= 16 && child.data.prefix(16) == CanonUUID.canonMetadata:
                let payload = try rebuildCanonMetadata(
                    Data(child.data.dropFirst(16)), exif: exif, ctboRemap: ctboRemap
                )
                var uuidPayload = Data(CanonUUID.canonMetadata)
                uuidPayload.append(payload)
                out.append(ISOBMFFBox(type: "uuid", data: uuidPayload, usesLargeSize: child.usesLargeSize))
            default:
                out.append(child)
            }
        }
        return ISOBMFFBoxWriter.serialize(boxes: out)
    }

    /// Boxes we descend into looking for `co64`/`stco` chunk-offset tables.
    private static let chunkOffsetContainers: Set<String> = ["trak", "mdia", "minf", "stbl", "edts"]

    /// Recursively rewrite a container box, shifting any `co64`/`stco` it holds.
    private static func rewriteContainer(_ box: ISOBMFFBox, shift: (UInt64) -> UInt64) throws -> ISOBMFFBox {
        let children = try ISOBMFFBoxReader.parseBoxes(from: box.data)
        var out: [ISOBMFFBox] = []
        for child in children {
            if chunkOffsetContainers.contains(child.type) {
                out.append(try rewriteContainer(child, shift: shift))
            } else if child.type == "co64" {
                out.append(shiftCo64(child, shift: shift))
            } else if child.type == "stco" {
                out.append(shiftStco(child, shift: shift))
            } else {
                out.append(child)
            }
        }
        return ISOBMFFBox(type: box.type, data: ISOBMFFBoxWriter.serialize(boxes: out), usesLargeSize: box.usesLargeSize)
    }

    /// Shift a 64-bit chunk-offset table. Layout: version+flags(4), count(4),
    /// then `count` × UInt64 offsets.
    private static func shiftCo64(_ box: ISOBMFFBox, shift: (UInt64) -> UInt64) -> ISOBMFFBox {
        var reader = BinaryReader(data: box.data)
        var w = BinaryWriter(capacity: box.data.count)
        guard let versionFlags = try? reader.readBytes(4),
              let count = try? reader.readUInt32BigEndian() else { return box }
        w.writeBytes(versionFlags)
        w.writeUInt32BigEndian(count)
        for _ in 0..<count {
            guard let off = try? reader.readUInt64BigEndian() else { return box }
            w.writeUInt64BigEndian(shift(off))
        }
        return ISOBMFFBox(type: "co64", data: w.data, usesLargeSize: box.usesLargeSize)
    }

    /// Shift a 32-bit chunk-offset table. Layout: version+flags(4), count(4),
    /// then `count` × UInt32 offsets.
    private static func shiftStco(_ box: ISOBMFFBox, shift: (UInt64) -> UInt64) -> ISOBMFFBox {
        var reader = BinaryReader(data: box.data)
        var w = BinaryWriter(capacity: box.data.count)
        guard let versionFlags = try? reader.readBytes(4),
              let count = try? reader.readUInt32BigEndian() else { return box }
        w.writeBytes(versionFlags)
        w.writeUInt32BigEndian(count)
        for _ in 0..<count {
            guard let off = try? reader.readUInt32BigEndian() else { return box }
            let shifted = shift(UInt64(off))
            // A 32-bit table can't hold an offset past 4 GiB; if the shift would
            // overflow, leave it (caller's file is already beyond stco's range).
            w.writeUInt32BigEndian(shifted <= UInt64(UInt32.max) ? UInt32(shifted) : off)
        }
        return ISOBMFFBox(type: "stco", data: w.data, usesLargeSize: box.usesLargeSize)
    }

    // MARK: - Canon metadata uuid rebuild

    /// Rebuild the Canon metadata container: replace CMT1/CMT2/CMT4 from `exif`,
    /// remap `CTBO`, and preserve everything else (CNCV, CCTP, CMT3, THMB, free).
    private static func rebuildCanonMetadata(
        _ data: Data,
        exif: ExifData?,
        ctboRemap: (UInt64, UInt64) -> (UInt64, UInt64)
    ) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: data)
        var out: [ISOBMFFBox] = []
        var wroteGPS = false

        for child in children {
            switch child.type {
            case "CMT1":
                if let ifd0 = exif?.ifd0 {
                    let tiff = ExifWriter.writeTIFF(ExifData.withIFD(ifd0, byteOrder: exif!.byteOrder))
                    out.append(ISOBMFFBox(type: "CMT1", data: tiff))
                } else {
                    out.append(child)
                }
            case "CMT2":
                if let exifIFD = exif?.exifIFD {
                    let tiff = ExifWriter.writeTIFF(ExifData.withIFD(exifIFD, byteOrder: exif!.byteOrder))
                    out.append(ISOBMFFBox(type: "CMT2", data: tiff))
                } else {
                    out.append(child)
                }
            case "CMT4":
                wroteGPS = true
                if let gpsIFD = exif?.gpsIFD {
                    let tiff = ExifWriter.writeTIFF(ExifData.withIFD(gpsIFD, byteOrder: exif!.byteOrder))
                    out.append(ISOBMFFBox(type: "CMT4", data: tiff))
                } else {
                    out.append(child)
                }
            case "CTBO":
                out.append(remapCTBO(child, remap: ctboRemap))
            default:
                // CMT3 (MakerNotes), CNCV, CCTP, THMB, free, etc. — preserved verbatim.
                out.append(child)
            }
        }

        if !wroteGPS, let gpsIFD = exif?.gpsIFD {
            let tiff = ExifWriter.writeTIFF(ExifData.withIFD(gpsIFD, byteOrder: exif!.byteOrder))
            out.append(ISOBMFFBox(type: "CMT4", data: tiff))
        }

        return ISOBMFFBoxWriter.serialize(boxes: out)
    }

    /// Remap a `CTBO` table. Layout: count(4), then `count` × (index(4),
    /// offset(8), size(8)). Byte length is unchanged (entry count is fixed).
    private static func remapCTBO(_ box: ISOBMFFBox, remap: (UInt64, UInt64) -> (UInt64, UInt64)) -> ISOBMFFBox {
        var reader = BinaryReader(data: box.data)
        var w = BinaryWriter(capacity: box.data.count)
        guard let count = try? reader.readUInt32BigEndian() else { return box }
        w.writeUInt32BigEndian(count)
        for _ in 0..<count {
            guard let index = try? reader.readUInt32BigEndian(),
                  let offset = try? reader.readUInt64BigEndian(),
                  let size = try? reader.readUInt64BigEndian() else { return box }
            let (newOffset, newSize) = remap(offset, size)
            w.writeUInt32BigEndian(index)
            w.writeUInt64BigEndian(newOffset)
            w.writeUInt64BigEndian(newSize)
        }
        return ISOBMFFBox(type: "CTBO", data: w.data, usesLargeSize: box.usesLargeSize)
    }
}

// MARK: - ExifData Helper

extension ExifData {
    /// Create a minimal ExifData with a single IFD as ifd0 for writing to a CMT box.
    static func withIFD(_ ifd: IFD, byteOrder: ByteOrder) -> ExifData {
        var data = ExifData(byteOrder: byteOrder)
        data.ifd0 = ifd
        return data
    }
}
