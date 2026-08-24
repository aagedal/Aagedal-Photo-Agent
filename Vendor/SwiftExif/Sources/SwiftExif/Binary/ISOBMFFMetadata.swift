import Foundation

/// Shared metadata extraction and writing logic for ISOBMFF-based formats (AVIF, HEIF, CR3).
/// Operates on the `meta → iprp → ipco` box hierarchy common to all these formats.
public struct ISOBMFFMetadata: Sendable {

    // MARK: - Reading

    /// Extract Exif data from ISOBMFF boxes.
    /// Tries ipco properties first, then iloc item-based extraction using `fileData`.
    public static func extractExif(from boxes: [ISOBMFFBox], fileData: Data? = nil) throws -> ExifData? {
        // Search for Exif box in top-level and nested boxes
        if let exifBox = findBox(type: "Exif", in: boxes) {
            return try parseExifBox(exifBox)
        }

        // Check inside meta → iprp → ipco container hierarchy
        if let metaBox = boxes.first(where: { $0.type == "meta" }) {
            if let exif = try extractExifFromMeta(metaBox) {
                return exif
            }

            // Fall back to iloc item-based extraction (real HEIF files)
            if let fileData {
                if let exif = try extractExifViaItem(metaBox: metaBox, fileData: fileData) {
                    return exif
                }
            }
        }

        return nil
    }

    /// Extract XMP data from ISOBMFF boxes.
    /// Tries ipco properties first, then iloc item-based extraction using `fileData`.
    public static func extractXMP(from boxes: [ISOBMFFBox], fileData: Data? = nil) throws -> XMPData? {
        if let metaBox = boxes.first(where: { $0.type == "meta" }) {
            if let xmp = try extractXMPFromMeta(metaBox) {
                return xmp
            }

            // Fall back to iloc item-based extraction
            if let fileData {
                if let xmp = try extractXMPViaItem(metaBox: metaBox, fileData: fileData) {
                    return xmp
                }
            }
        }
        return nil
    }

    /// Extract ICC profile from a `colr` box (type `"prof"` or `"rICC"`) in
    /// the ipco hierarchy of an ISOBMFF file. Navigates `meta → iprp → ipco`
    /// explicitly because the meta box has a 4-byte FullBox header that the
    /// generic recursive search would mis-parse.
    public static func extractICCProfile(from boxes: [ISOBMFFBox]) -> ICCProfile? {
        // Navigate meta → iprp → ipco for image-property colr boxes.
        if let metaBox = boxes.first(where: { $0.type == "meta" }),
           let metaChildren = try? parseMetaChildren(metaBox.data),
           let iprpBox = metaChildren.first(where: { $0.type == "iprp" }),
           let iprpChildren = try? ISOBMFFBoxReader.parseBoxes(from: iprpBox.data),
           let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }),
           let properties = try? ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data) {
            for prop in properties where prop.type == "colr" {
                if let icc = parseColrBox(prop) { return icc }
            }
        }
        // Fallback for formats that put colr at the top level.
        if let colrBox = boxes.first(where: { $0.type == "colr" }),
           let icc = parseColrBox(colrBox) {
            return icc
        }
        return nil
    }

    /// Extract HDR static metadata (SMPTE ST 2086 mastering display volume +
    /// CTA-861.3 content light level) from `mdcv` and `clli` boxes inside the
    /// HEIF / AVIF `meta → iprp → ipco` property hierarchy. Modern iPhone Pro
    /// HDR HEIC stills and AOM's HDR AVIF reference encoder both write these
    /// alongside the `colr` property — they describe the still's HDR grading
    /// the same way video files do, just attached to an item property instead
    /// of a video sample entry. Reuses the MP4 box parsers so the byte layout
    /// stays in one place.
    public static func extractHDRMetadata(from boxes: [ISOBMFFBox]) -> HDRMetadata? {
        guard let metaBox = boxes.first(where: { $0.type == "meta" }),
              let metaChildren = try? parseMetaChildren(metaBox.data),
              let iprpBox = metaChildren.first(where: { $0.type == "iprp" }),
              let iprpChildren = try? ISOBMFFBoxReader.parseBoxes(from: iprpBox.data),
              let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }),
              let properties = try? ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data) else {
            return nil
        }
        var hdr = HDRMetadata()
        var found = false
        for prop in properties {
            switch prop.type {
            case "mdcv":
                if let md = MP4Parser.parseMDCVBox(prop.data) {
                    hdr.masteringDisplay = md
                    found = true
                }
            case "clli":
                if let cll = MP4Parser.parseCLLIBox(prop.data) {
                    hdr.contentLightLevel = cll
                    found = true
                }
            default:
                break
            }
        }
        return found ? hdr : nil
    }

    private static func parseColrBox(_ box: ISOBMFFBox) -> ICCProfile? {
        guard box.data.count > 4 else { return nil }
        let colorType = String(data: box.data.prefix(4), encoding: .ascii) ?? ""
        // `prof` = unrestricted ICC profile, `rICC` = restricted ICC profile.
        guard colorType == "prof" || colorType == "rICC" else { return nil }
        let profileData = Data(box.data.suffix(from: box.data.startIndex + 4))
        return ICCProfile(data: profileData)
    }

    /// Hard cap on ISOBMFF box-tree descent. Real container hierarchies top
    /// out at `moov → trak → mdia → minf → stbl → stsd` (depth ~6) and
    /// HEIF/AVIF `meta → iprp → ipco` (depth 3); 32 leaves plenty of
    /// headroom while keeping a crafted file from blowing the thread stack
    /// via chained 8-byte container boxes. Mirrors `GPMFReader.maxRecursionDepth`.
    static let maxRecursionDepth = 32

    /// ISOBMFF box types whose payload is a plain concatenation of child
    /// boxes (no version/flags or other prefix). `findBox` descends only
    /// into these; everything else is treated as a leaf so we don't waste
    /// work re-parsing payloads of `mdat`, `Exif`, `iloc`, `ipma`, `ispe`,
    /// `colr`, `hvcC`, etc. — none of which are box-formatted.
    ///
    /// Intentionally excluded:
    /// - `meta` has a 4-byte FullBox header; `parseMetaChildren` handles it.
    /// - `stsd` has a version/flags + entry_count prefix before its entries.
    /// - `uuid` starts with a 16-byte UUID; format-specific readers (e.g.
    ///   `CR3Parser`) know how to descend it.
    private static let containerBoxTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "dinf", "udta",
        "edts", "mvex", "moof", "traf", "mfra", "iprp", "ipco",
    ]

    /// Recursively find a box of the given type. Only descends into box
    /// types listed in `containerBoxTypes`; payloads of other boxes are
    /// treated as opaque leaves.
    public static func findBox(type: String, in boxes: [ISOBMFFBox], depth: Int = 0) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            guard containerBoxTypes.contains(box.type) else { continue }
            // Stop descending once `maxRecursionDepth` levels deep — an attacker
            // can chain 8-byte container boxes to exhaust the thread stack.
            // Graceful degradation: skip the descent and continue with siblings,
            // matching the GPMF depth-clamp posture.
            guard depth < ISOBMFFMetadata.maxRecursionDepth else { continue }
            if let children = try? ISOBMFFBoxReader.parseBoxes(from: box.data) {
                if let found = findBox(type: type, in: children, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Update or create the meta box in a list of top-level boxes with new
    /// Exif/XMP data, storing both as spec-conformant **metadata items**
    /// (`iinf`/`infe` + `iloc` + `iref cdsc`, payload in `idat`) rather than as
    /// `iprp/ipco` properties. Item placement is what `exiftool`, Apple ImageIO,
    /// Preview, Lightroom, etc. read; `ipco` placement is invisible to them.
    /// When exif or xmp is nil, the corresponding item (and any legacy `ipco`
    /// property a prior SwiftExif version wrote) is removed.
    public static func updateMetadata(in boxes: inout [ISOBMFFBox], exif: ExifData?, xmp: XMPData?) throws {
        // EXIF item payload: 4-byte offset-to-TIFF-header prefix + TIFF stream
        // (identical bytes to the old `Exif` box; only the placement changes).
        let exifPayload: Data? = exif.map {
            var data = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            data.append(ExifWriter.writeTIFF($0))
            return data
        }
        // XMP item payload: raw RDF/XML. Unlike the `mime` *property* form, an
        // iloc-located `mime` *item* keeps its content_type in the infe entry,
        // not prepended to the payload.
        let xmpPayload: Data? = xmp.map { Data(XMPWriter.generateXML($0).utf8) }

        guard let metaIndex = boxes.firstIndex(where: { $0.type == "meta" }) else {
            guard exifPayload != nil || xmpPayload != nil else { return }
            // No meta box yet: build a fresh one. There is no primary image item
            // to describe, so no `iref` — SwiftExif still reads the items back.
            let metaData = try buildMetaBox(fromMeta: nil, shiftThreshold: Int.max,
                                            exifPayload: exifPayload, xmpPayload: xmpPayload,
                                            removeExif: exif == nil, removeXMP: xmp == nil)
            let insertAt = boxes.firstIndex(where: { $0.type == "ftyp" }).map { $0 + 1 } ?? 0
            boxes.insert(ISOBMFFBox(type: "meta", data: metaData), at: insertAt)
            return
        }

        // Absolute file offset where the meta box ends in the re-serialized
        // output (the writer always emits 8-byte box headers). Growing or
        // shrinking meta shifts every construction-method-0 `iloc` offset that
        // points at or beyond this position (i.e. into `mdat`, which follows
        // meta in still AVIF/HEIC) — those get patched by the size delta.
        func boxHeaderSize(_ box: ISOBMFFBox) -> Int { (8 + box.data.count > Int(UInt32.max) || box.usesLargeSize) ? 16 : 8 }
        let bytesBeforeMeta = boxes[0..<metaIndex].reduce(0) { $0 + boxHeaderSize($1) + $1.data.count }
        let shiftThreshold = bytesBeforeMeta + boxHeaderSize(boxes[metaIndex]) + boxes[metaIndex].data.count

        let newMetaData = try buildMetaBox(fromMeta: boxes[metaIndex].data, shiftThreshold: shiftThreshold,
                                           exifPayload: exifPayload, xmpPayload: xmpPayload,
                                           removeExif: exif == nil, removeXMP: xmp == nil)
        // Preserve the original meta box's header width: `shiftThreshold` (and
        // thus the method-0 offset patching) assumed `boxHeaderSize(meta)`, so
        // the re-serialized header must match it. Dropping a 64-bit header to
        // 32-bit would shift `mdat` 8 bytes past where the patched offsets point.
        boxes[metaIndex] = ISOBMFFBox(type: "meta", data: newMetaData, usesLargeSize: boxes[metaIndex].usesLargeSize)
    }

    // MARK: - Private (Reading)

    private static func parseExifBox(_ box: ISOBMFFBox) throws -> ExifData? {
        try ExifReader.readFromExifBox(data: box.data)
    }

    private static func extractExifFromMeta(_ metaBox: ISOBMFFBox) throws -> ExifData? {
        let metaChildren = try parseMetaChildren(metaBox.data)

        if let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) {
            let iprpChildren = try ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)
            if let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }) {
                let properties = try ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data)
                if let exifBox = properties.first(where: { $0.type == "Exif" }) {
                    return try parseExifBox(exifBox)
                }
            }
        }

        return nil
    }

    private static func extractXMPFromMeta(_ metaBox: ISOBMFFBox) throws -> XMPData? {
        let metaChildren = try parseMetaChildren(metaBox.data)

        if let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) {
            let iprpChildren = try ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)
            if let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }) {
                let properties = try ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data)
                for prop in properties {
                    if prop.type == "mime" {
                        if let xmp = try parseMimeBoxForXMP(prop) {
                            return xmp
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Parse meta box children, skipping the 4-byte FullBox header if present.
    static func parseMetaChildren(_ data: Data) throws -> [ISOBMFFBox] {
        guard data.count > 4 else { return [] }

        let skippedData = Data(data.suffix(from: data.startIndex + 4))
        if let boxes = try? ISOBMFFBoxReader.parseBoxes(from: skippedData), !boxes.isEmpty {
            return boxes
        }

        return try ISOBMFFBoxReader.parseBoxes(from: data)
    }

    /// Parse a "mime" property box for XMP content.
    private static func parseMimeBoxForXMP(_ box: ISOBMFFBox) throws -> XMPData? {
        let bytes = [UInt8](box.data)
        guard let nullIndex = bytes.firstIndex(of: 0) else { return nil }

        let contentType = String(bytes: bytes[0..<nullIndex], encoding: .utf8)
        guard contentType == "application/rdf+xml" else { return nil }

        let xmpData = Data(bytes[(nullIndex + 1)...])
        guard !xmpData.isEmpty else { return nil }

        return try XMPReader.readFromXML(xmpData)
    }

    // MARK: - Item-Based Extraction (iloc/iinf)

    /// Represents an item entry from the iinf box.
    private struct ItemInfo {
        let itemID: UInt32
        let itemType: String // 4-char type code
        /// For `mime` items, the MIME type from the infe entry
        /// (e.g. `application/rdf+xml` for XMP). nil for other item types.
        let contentType: String?
    }

    /// Represents an item's location from the iloc box.
    private struct ItemLocation {
        let itemID: UInt32
        let constructionMethod: UInt8 // 0 = file offset, 1 = idat offset
        let baseOffset: UInt64
        let extents: [(offset: UInt64, length: UInt64)]
    }

    /// Extract Exif by finding an "Exif" item in iinf and reading its data via iloc.
    private static func extractExifViaItem(metaBox: ISOBMFFBox, fileData: Data) throws -> ExifData? {
        let metaChildren = try parseMetaChildren(metaBox.data)
        let items = parseItemInfo(from: metaChildren)
        let locations = parseItemLocations(from: metaChildren)

        guard let exifItem = items.first(where: { $0.itemType == "Exif" }),
              let exifLoc = locations.first(where: { $0.itemID == exifItem.itemID }) else {
            return nil
        }

        let itemData: Data
        if exifLoc.constructionMethod == 1 {
            // idat-based: read from the idat box payload
            guard let idatBox = metaChildren.first(where: { $0.type == "idat" }) else { return nil }
            itemData = readExtents(from: idatBox.data, location: exifLoc)
        } else {
            // File offset-based
            itemData = readExtents(from: fileData, location: exifLoc)
        }

        guard !itemData.isEmpty else { return nil }
        return try ExifReader.readFromExifBox(data: itemData)
    }

    /// Extract XMP by finding a "mime" item whose iinf content_type is
    /// `application/rdf+xml` and reading its iloc-pointed payload.
    /// The content_type lives on the infe entry, NOT prepended to the
    /// payload — for iloc-located items the payload is just the raw XMP.
    private static func extractXMPViaItem(metaBox: ISOBMFFBox, fileData: Data) throws -> XMPData? {
        let metaChildren = try parseMetaChildren(metaBox.data)
        let items = parseItemInfo(from: metaChildren)
        let locations = parseItemLocations(from: metaChildren)

        for item in items where item.itemType == "mime"
            && item.contentType == "application/rdf+xml" {
            guard let loc = locations.first(where: { $0.itemID == item.itemID }) else { continue }

            let itemData: Data
            if loc.constructionMethod == 1 {
                guard let idatBox = metaChildren.first(where: { $0.type == "idat" }) else { continue }
                itemData = readExtents(from: idatBox.data, location: loc)
            } else {
                itemData = readExtents(from: fileData, location: loc)
            }

            guard !itemData.isEmpty else { continue }
            return try XMPReader.readFromXML(itemData)
        }

        return nil
    }

    /// Read a null-terminated UTF-8 string from a BinaryReader, advancing
    /// past the terminator. Returns nil if no terminator is found before
    /// the buffer ends.
    private static func readCString(_ reader: inout BinaryReader) -> String? {
        var bytes: [UInt8] = []
        while reader.remainingCount > 0 {
            guard let b = try? reader.readUInt8() else { return nil }
            if b == 0 {
                return String(bytes: bytes, encoding: .utf8)
            }
            bytes.append(b)
        }
        return nil
    }

    /// Read concatenated extent data from a source buffer.
    private static func readExtents(from source: Data, location: ItemLocation) -> Data {
        var result = Data()
        for extent in location.extents {
            let offset = Int(location.baseOffset + extent.offset)
            let length = Int(extent.length)
            guard offset >= 0, offset + length <= source.count else { continue }
            result.append(source[source.startIndex + offset ..< source.startIndex + offset + length])
        }
        return result
    }

    /// Parse item info entries from the iinf box within meta children.
    private static func parseItemInfo(from metaChildren: [ISOBMFFBox]) -> [ItemInfo] {
        guard let iinfBox = metaChildren.first(where: { $0.type == "iinf" }) else { return [] }
        guard iinfBox.data.count >= 6 else { return [] }

        var reader = BinaryReader(data: iinfBox.data)
        var items: [ItemInfo] = []

        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24

            let entryCount: Int
            if version == 0 {
                entryCount = Int(try reader.readUInt16BigEndian())
            } else {
                entryCount = Int(try reader.readUInt32BigEndian())
            }

            // Each entry is an infe box
            for _ in 0..<entryCount {
                guard reader.remainingCount >= 8 else { break }
                let boxSize = try reader.readUInt32BigEndian()
                let boxType = try reader.readBytes(4)
                guard String(data: boxType, encoding: .ascii) == "infe" else {
                    // Skip unknown box
                    if boxSize > 8 { try reader.skip(Int(boxSize) - 8) }
                    continue
                }

                let payloadSize = Int(boxSize) - 8
                guard payloadSize > 4, reader.remainingCount >= payloadSize else { break }
                let payload = try reader.readBytes(payloadSize)
                var payloadReader = BinaryReader(data: payload)

                let infeVersionFlags = try payloadReader.readUInt32BigEndian()
                let infeVersion = infeVersionFlags >> 24

                let itemID: UInt32
                if infeVersion < 2 {
                    itemID = UInt32(try payloadReader.readUInt16BigEndian())
                    try payloadReader.skip(2) // protection_index
                    // v0/v1: no item_type field
                    continue
                } else if infeVersion == 2 {
                    itemID = UInt32(try payloadReader.readUInt16BigEndian())
                } else {
                    // v3+: 32-bit item_ID
                    itemID = try payloadReader.readUInt32BigEndian()
                }
                try payloadReader.skip(2) // protection_index
                guard payloadReader.remainingCount >= 4 else { continue }
                let typeData = try payloadReader.readBytes(4)
                let itemType = String(data: typeData, encoding: .ascii) ?? "????"

                // After item_type comes a null-terminated item_name. If the
                // item_type is "mime" there's a second null-terminated string
                // holding the content_type (the spec calls this the
                // ItemInfoExtension for FDIs / mime types).
                _ = readCString(&payloadReader) // item_name (often empty)
                let contentType: String? = (itemType == "mime")
                    ? readCString(&payloadReader)
                    : nil
                items.append(ItemInfo(itemID: itemID, itemType: itemType,
                                      contentType: contentType))
            }
        } catch {
            // Best-effort parsing
        }

        return items
    }

    /// Parse item locations from the iloc box within meta children.
    private static func parseItemLocations(from metaChildren: [ISOBMFFBox]) -> [ItemLocation] {
        guard let ilocBox = metaChildren.first(where: { $0.type == "iloc" }) else { return [] }
        guard ilocBox.data.count >= 8 else { return [] }

        var reader = BinaryReader(data: ilocBox.data)
        var locations: [ItemLocation] = []

        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24

            // Size fields (packed into 2 bytes)
            let sizeByte1 = try reader.readUInt8()
            let sizeByte2 = try reader.readUInt8()
            let offsetSize = Int(sizeByte1 >> 4)
            let lengthSize = Int(sizeByte1 & 0x0F)
            let baseOffsetSize = Int(sizeByte2 >> 4)
            let indexSize = (version == 1 || version == 2) ? Int(sizeByte2 & 0x0F) : 0

            let itemCount: Int
            if version < 2 {
                itemCount = Int(try reader.readUInt16BigEndian())
            } else {
                itemCount = Int(try reader.readUInt32BigEndian())
            }

            for _ in 0..<itemCount {
                let itemID: UInt32
                if version < 2 {
                    itemID = UInt32(try reader.readUInt16BigEndian())
                } else {
                    itemID = try reader.readUInt32BigEndian()
                }

                let constructionMethod: UInt8
                if version == 1 || version == 2 {
                    let cm = try reader.readUInt16BigEndian()
                    constructionMethod = UInt8(cm & 0x0F)
                } else {
                    constructionMethod = 0
                }

                try reader.skip(2) // data_reference_index

                let baseOffset = try readSizedUInt(&reader, size: baseOffsetSize)

                let extentCount = Int(try reader.readUInt16BigEndian())
                var extents: [(offset: UInt64, length: UInt64)] = []

                for _ in 0..<extentCount {
                    if indexSize > 0 {
                        _ = try readSizedUInt(&reader, size: indexSize)
                    }
                    let extentOffset = try readSizedUInt(&reader, size: offsetSize)
                    let extentLength = try readSizedUInt(&reader, size: lengthSize)
                    extents.append((offset: extentOffset, length: extentLength))
                }

                locations.append(ItemLocation(
                    itemID: itemID,
                    constructionMethod: constructionMethod,
                    baseOffset: baseOffset,
                    extents: extents
                ))
            }
        } catch {
            // Best-effort parsing
        }

        return locations
    }

    /// Read a variable-sized unsigned integer (0, 2, 4, or 8 bytes).
    private static func readSizedUInt(_ reader: inout BinaryReader, size: Int) throws -> UInt64 {
        switch size {
        case 0: return 0
        case 2: return UInt64(try reader.readUInt16BigEndian())
        case 4: return UInt64(try reader.readUInt32BigEndian())
        case 8: return try reader.readUInt64BigEndian()
        default: return 0
        }
    }

    // MARK: - Private (Writing)

    /// MIME content_type that marks a `mime` item (or legacy `ipco` property) as XMP.
    private static let xmpContentType = "application/rdf+xml"

    /// A normalized `iloc` entry used while rebuilding the box. Offsets are
    /// absolute: for construction-method 0 they are file offsets, for method 1
    /// they are offsets into the `idat` payload. `base_offset` is always folded
    /// to 0 so a single offset field describes each extent.
    private struct LocationEntry {
        let itemID: UInt32
        let constructionMethod: UInt8
        var extents: [(offset: UInt64, length: UInt64)]
    }

    /// Rebuild (or create) a meta box so that EXIF and XMP are stored as
    /// metadata items. `shiftThreshold` is the old absolute file offset of the
    /// end of the meta box; method-0 `iloc` offsets at or beyond it are patched
    /// by the meta size delta so the primary image item keeps pointing at its
    /// (now shifted) `mdat` bytes. Returns the new meta box *payload*.
    private static func buildMetaBox(fromMeta: Data?, shiftThreshold: Int,
                                     exifPayload: Data?, xmpPayload: Data?,
                                     removeExif: Bool, removeXMP: Bool) throws -> Data {
        var fullBoxHeader = Data([0x00, 0x00, 0x00, 0x00]) // version 0, flags 0
        var children: [ISOBMFFBox] = []
        if let meta = fromMeta, meta.count >= 4 {
            fullBoxHeader = Data(meta.prefix(4))
            children = (try? parseMetaChildren(meta)) ?? []
        }

        let primaryItemID = parsePrimaryItemID(from: children)
        let existingItems = parseItemInfo(from: children)
        let existingLocations = parseItemLocations(from: children)

        // Items SwiftExif owns: EXIF items and XMP `mime` items. These are
        // removed and (when still present) re-added, so repeated writes never
        // accumulate duplicates.
        let managedIDs = Set(existingItems.filter { isManaged($0) }.map { $0.itemID })

        // Allocate fresh IDs above every existing item.
        let maxExistingID = existingItems.map { $0.itemID }.max() ?? 0
        var nextID = maxExistingID + 1
        let exifID: UInt32? = exifPayload != nil ? nextID : nil
        if exifID != nil { nextID += 1 }
        let xmpID: UInt32? = xmpPayload != nil ? nextID : nil

        // --- idat payload: keep the prefix referenced by non-managed method-1
        // items, then append our payloads after it (dropping any orphaned bytes
        // a removed managed item left behind). ---
        let oldIdat = children.first(where: { $0.type == "idat" })?.data ?? Data()
        var keepIdatLen = 0
        for loc in existingLocations where loc.constructionMethod == 1 && !managedIDs.contains(loc.itemID) {
            for ext in loc.extents {
                keepIdatLen = max(keepIdatLen, Int(min(loc.baseOffset + ext.offset + ext.length, UInt64(oldIdat.count))))
            }
        }
        var newIdat = Data(oldIdat.prefix(keepIdatLen))
        var exifIdatOffset = 0
        var xmpIdatOffset = 0
        if let payload = exifPayload {
            exifIdatOffset = newIdat.count
            newIdat.append(payload)
        }
        if let payload = xmpPayload {
            xmpIdatOffset = newIdat.count
            newIdat.append(payload)
        }

        // --- iloc entries: carry over non-managed items (normalized to
        // base_offset 0, absolute offsets), then add our method-1 items. ---
        var locations: [LocationEntry] = []
        for loc in existingLocations where !managedIDs.contains(loc.itemID) {
            let extents = loc.extents.map { (offset: loc.baseOffset + $0.offset, length: $0.length) }
            locations.append(LocationEntry(itemID: loc.itemID, constructionMethod: loc.constructionMethod, extents: extents))
        }
        if let id = exifID {
            locations.append(LocationEntry(itemID: id, constructionMethod: 1,
                                           extents: [(offset: UInt64(exifIdatOffset), length: UInt64(exifPayload!.count))]))
        }
        if let id = xmpID {
            locations.append(LocationEntry(itemID: id, constructionMethod: 1,
                                           extents: [(offset: UInt64(xmpIdatOffset), length: UInt64(xmpPayload!.count))]))
        }

        // --- iinf entries: drop managed infe, append fresh ones. ---
        var infeBoxes = parseInfeBoxes(from: children).filter { !managedIDs.contains($0.itemID) }.map { $0.box }
        if let id = exifID {
            infeBoxes.append(buildInfe(itemID: id, itemType: "Exif", contentType: nil))
        }
        if let id = xmpID {
            infeBoxes.append(buildInfe(itemID: id, itemType: "mime", contentType: xmpContentType))
        }

        // --- iref cdsc entries: each metadata item "describes" the primary
        // image item. Drop stale references from removed managed items. ---
        var irefVersion: UInt8 = 0
        var irefEntries: [IrefEntry] = []
        if let irefData = children.first(where: { $0.type == "iref" })?.data {
            let parsed = parseIref(irefData)
            irefVersion = parsed.version
            irefEntries = parsed.entries.filter { !managedIDs.contains($0.fromID) }
        }
        if let primary = primaryItemID {
            if let id = exifID { irefEntries.append(IrefEntry(type: "cdsc", fromID: id, toIDs: [primary])) }
            if let id = xmpID { irefEntries.append(IrefEntry(type: "cdsc", fromID: id, toIDs: [primary])) }
            // A 32-bit item ID forces iref version 1.
            if irefEntries.contains(where: { $0.fromID > 0xFFFF || $0.toIDs.contains(where: { $0 > 0xFFFF }) }) {
                irefVersion = 1
            }
        }

        // Fixed iloc field widths (chosen once, with headroom for the meta-size
        // delta) so the two assembly passes below produce identical sizes.
        let maxOffset = locations.flatMap { $0.extents }.map { $0.offset }.max() ?? 0
        let maxLength = locations.flatMap { $0.extents }.map { $0.length }.max() ?? 0
        let offsetSize = (maxOffset + 64_000_000 > UInt64(UInt32.max)) ? 8 : 4
        let lengthSize = (maxLength > UInt64(UInt32.max)) ? 8 : 4

        // Strip any legacy `ipco` Exif/mime a prior SwiftExif version appended,
        // for the type(s) we now manage, so the conformant item is the only copy.
        let strippedChildren = stripLegacyIpcoProperties(children,
            stripExif: exifPayload != nil || removeExif,
            stripXMP: xmpPayload != nil || removeXMP)

        // Assemble twice: first to measure the meta size delta, then for real
        // with method-0 offsets shifted by that delta.
        func assemble(offsetDelta: Int) -> Data {
            let iloc = buildIloc(locations, offsetSize: offsetSize, lengthSize: lengthSize,
                                 offsetDelta: offsetDelta, shiftThreshold: shiftThreshold)
            let newChildren = assembleChildren(strippedChildren,
                                               iinf: buildIinf(infeBoxes),
                                               iloc: iloc,
                                               iref: irefEntries.isEmpty ? nil : buildIref(version: irefVersion, entries: irefEntries),
                                               idat: newIdat.isEmpty ? nil : ISOBMFFBox(type: "idat", data: newIdat))
            var writer = BinaryWriter(capacity: 512)
            writer.writeBytes(fullBoxHeader)
            ISOBMFFBoxWriter.writeBoxes(&writer, boxes: newChildren)
            return writer.data
        }

        let oldMetaPayloadCount = fromMeta?.count ?? 0
        let probe = assemble(offsetDelta: 0)
        // Meta box total = 8 + payload; the header is constant, so the payload
        // delta equals the box delta that shifts everything after meta.
        let delta = fromMeta == nil ? 0 : probe.count - oldMetaPayloadCount
        return delta == 0 ? probe : assemble(offsetDelta: delta)
    }

    /// True for items SwiftExif owns: EXIF items, or XMP `mime` items.
    private static func isManaged(_ item: ItemInfo) -> Bool {
        item.itemType == "Exif" || (item.itemType == "mime" && item.contentType == xmpContentType)
    }

    /// Place updated `iinf`/`iloc`/`iref`/`idat` boxes back among the meta
    /// children, replacing existing instances in place and inserting any new
    /// box near `iloc` (the conventional spot for item-location data).
    private static func assembleChildren(_ children: [ISOBMFFBox], iinf: ISOBMFFBox, iloc: ISOBMFFBox,
                                         iref: ISOBMFFBox?, idat: ISOBMFFBox?) -> [ISOBMFFBox] {
        var result: [ISOBMFFBox] = []
        var haveIinf = false, haveIloc = false, haveIref = false, haveIdat = false
        for child in children {
            switch child.type {
            case "iinf": result.append(iinf); haveIinf = true
            case "iloc": result.append(iloc); haveIloc = true
            case "iref":
                if let iref { result.append(iref); haveIref = true }
                // else drop: no references remain.
            case "idat":
                if let idat { result.append(idat); haveIdat = true }
                // else drop: idat is now empty.
            default: result.append(child)
            }
        }
        if !haveIinf { result.append(iinf) }
        // idat and iref belong just before iloc; iloc goes last among these.
        if let idat, !haveIdat {
            let anchor = result.firstIndex(where: { $0.type == "iloc" }) ?? result.count
            result.insert(idat, at: anchor)
        }
        if let iref, !haveIref {
            let anchor = result.firstIndex(where: { $0.type == "iloc" }) ?? result.count
            result.insert(iref, at: anchor)
        }
        if !haveIloc { result.append(iloc) }
        return result
    }

    /// Remove legacy `Exif` / XMP-`mime` properties that an older SwiftExif
    /// version appended to `iprp/ipco`. They were always appended last and were
    /// never referenced by `ipma`, so dropping them leaves real property
    /// associations intact.
    private static func stripLegacyIpcoProperties(_ children: [ISOBMFFBox], stripExif: Bool, stripXMP: Bool) -> [ISOBMFFBox] {
        guard stripExif || stripXMP,
              let iprpIndex = children.firstIndex(where: { $0.type == "iprp" }),
              var iprpChildren = try? ISOBMFFBoxReader.parseBoxes(from: children[iprpIndex].data),
              let ipcoIndex = iprpChildren.firstIndex(where: { $0.type == "ipco" }),
              var properties = try? ISOBMFFBoxReader.parseBoxes(from: iprpChildren[ipcoIndex].data) else {
            return children
        }
        let before = properties.count
        if stripExif { properties.removeAll { $0.type == "Exif" } }
        if stripXMP { properties.removeAll { $0.type == "mime" && isMimeXMP($0) } }
        guard properties.count != before else { return children }

        iprpChildren[ipcoIndex] = ISOBMFFBox(type: "ipco", data: ISOBMFFBoxWriter.serialize(boxes: properties))
        var result = children
        result[iprpIndex] = ISOBMFFBox(type: "iprp", data: ISOBMFFBoxWriter.serialize(boxes: iprpChildren))
        return result
    }

    private static func isMimeXMP(_ box: ISOBMFFBox) -> Bool {
        guard box.data.count > xmpContentType.utf8.count else { return false }
        return box.data.prefix(xmpContentType.utf8.count) == Data(xmpContentType.utf8)
    }

    // MARK: - Box builders

    /// Build an `infe` box (version 2): item_ID, protection_index 0, 4-char
    /// item_type, empty item_name, and — for `mime` items — a content_type.
    private static func buildInfe(itemID: UInt32, itemType: String, contentType: String?) -> ISOBMFFBox {
        var w = BinaryWriter(capacity: 32)
        let version: UInt8 = itemID > 0xFFFF ? 3 : 2
        w.writeUInt32BigEndian(UInt32(version) << 24) // version, flags 0
        if version == 2 {
            w.writeUInt16BigEndian(UInt16(itemID))
        } else {
            w.writeUInt32BigEndian(itemID)
        }
        w.writeUInt16BigEndian(0) // protection_index
        w.writeString(itemType, encoding: .isoLatin1) // exactly 4 bytes
        w.writeUInt8(0) // item_name (empty, null-terminated)
        if let contentType {
            w.writeString(contentType, encoding: .isoLatin1)
            w.writeUInt8(0) // null terminator
        }
        return ISOBMFFBox(type: "infe", data: w.data)
    }

    /// Build an `iinf` box (version 0, 16-bit entry count) wrapping the infe boxes.
    private static func buildIinf(_ infeBoxes: [ISOBMFFBox]) -> ISOBMFFBox {
        var w = BinaryWriter(capacity: 16 + infeBoxes.count * 24)
        w.writeUInt32BigEndian(0) // version 0, flags 0
        w.writeUInt16BigEndian(UInt16(min(infeBoxes.count, 0xFFFF)))
        ISOBMFFBoxWriter.writeBoxes(&w, boxes: infeBoxes)
        return ISOBMFFBox(type: "iinf", data: w.data)
    }

    /// Build an `iloc` box (version 1) with the given fixed offset/length field
    /// widths, base_offset 0 and index_size 0. Construction-method-0 offsets at
    /// or beyond `shiftThreshold` are bumped by `offsetDelta`.
    private static func buildIloc(_ entries: [LocationEntry], offsetSize: Int, lengthSize: Int,
                                  offsetDelta: Int, shiftThreshold: Int) -> ISOBMFFBox {
        var w = BinaryWriter(capacity: 16 + entries.count * 16)
        w.writeUInt32BigEndian(0x01000000) // version 1, flags 0
        w.writeUInt8(UInt8((offsetSize << 4) | lengthSize))
        w.writeUInt8(0) // base_offset_size 0, index_size 0
        w.writeUInt16BigEndian(UInt16(min(entries.count, 0xFFFF)))

        for entry in entries {
            w.writeUInt16BigEndian(UInt16(truncatingIfNeeded: entry.itemID))
            w.writeUInt16BigEndian(UInt16(entry.constructionMethod) & 0x000F)
            w.writeUInt16BigEndian(0) // data_reference_index
            w.writeUInt16BigEndian(UInt16(min(entry.extents.count, 0xFFFF)))
            for ext in entry.extents {
                var offset = ext.offset
                if entry.constructionMethod == 0 && offset >= UInt64(shiftThreshold) {
                    offset = UInt64(Int64(offset) + Int64(offsetDelta))
                }
                writeSizedUInt(&w, value: offset, size: offsetSize)
                writeSizedUInt(&w, value: ext.length, size: lengthSize)
            }
        }
        return ISOBMFFBox(type: "iloc", data: w.data)
    }

    private static func writeSizedUInt(_ w: inout BinaryWriter, value: UInt64, size: Int) {
        switch size {
        case 8: w.writeUInt64BigEndian(value)
        case 4: w.writeUInt32BigEndian(UInt32(truncatingIfNeeded: value))
        case 2: w.writeUInt16BigEndian(UInt16(truncatingIfNeeded: value))
        default: break
        }
    }

    // MARK: - Box parsers (writing side)

    /// Read the primary item ID from a `pitm` box. Needed as the `cdsc`
    /// reference target so readers link the metadata item to the image.
    private static func parsePrimaryItemID(from children: [ISOBMFFBox]) -> UInt32? {
        guard let pitm = children.first(where: { $0.type == "pitm" }), pitm.data.count >= 6 else { return nil }
        var reader = BinaryReader(data: pitm.data)
        guard let versionFlags = try? reader.readUInt32BigEndian() else { return nil }
        if versionFlags >> 24 == 0 {
            return (try? reader.readUInt16BigEndian()).map(UInt32.init)
        }
        return try? reader.readUInt32BigEndian()
    }

    /// An infe box paired with the item ID it declares, for filtering.
    private struct InfeBox { let itemID: UInt32; let box: ISOBMFFBox }

    /// Parse the `infe` child boxes out of an `iinf` box, keeping each box's
    /// raw bytes so non-managed entries pass through untouched.
    private static func parseInfeBoxes(from children: [ISOBMFFBox]) -> [InfeBox] {
        guard let iinf = children.first(where: { $0.type == "iinf" }), iinf.data.count >= 6 else { return [] }
        var reader = BinaryReader(data: iinf.data)
        guard let versionFlags = try? reader.readUInt32BigEndian() else { return [] }
        let version = versionFlags >> 24
        // Skip the entry_count (16-bit for v0, 32-bit otherwise); re-parse the
        // remaining bytes as a plain box sequence.
        if version == 0 { _ = try? reader.readUInt16BigEndian() } else { _ = try? reader.readUInt32BigEndian() }
        let rest = reader.readRemainingBytes()
        guard let boxes = try? ISOBMFFBoxReader.parseBoxes(from: rest) else { return [] }
        return boxes.compactMap { box in
            guard box.type == "infe", let id = parseInfeItemID(box.data) else { return nil }
            return InfeBox(itemID: id, box: box)
        }
    }

    private static func parseInfeItemID(_ data: Data) -> UInt32? {
        var reader = BinaryReader(data: data)
        guard let versionFlags = try? reader.readUInt32BigEndian() else { return nil }
        let version = versionFlags >> 24
        if version >= 3 { return try? reader.readUInt32BigEndian() }
        return (try? reader.readUInt16BigEndian()).map(UInt32.init)
    }

    /// A single `iref` reference: one source item describing a set of targets.
    private struct IrefEntry { let type: String; let fromID: UInt32; let toIDs: [UInt32] }

    private static func parseIref(_ data: Data) -> (version: UInt8, entries: [IrefEntry]) {
        var reader = BinaryReader(data: data)
        guard let versionFlags = try? reader.readUInt32BigEndian() else { return (0, []) }
        let version = UInt8(versionFlags >> 24)
        let rest = reader.readRemainingBytes()
        guard let boxes = try? ISOBMFFBoxReader.parseBoxes(from: rest) else { return (version, []) }
        var entries: [IrefEntry] = []
        for box in boxes {
            var r = BinaryReader(data: box.data)
            let fromID: UInt32?
            if version == 0 { fromID = (try? r.readUInt16BigEndian()).map(UInt32.init) }
            else { fromID = try? r.readUInt32BigEndian() }
            guard let from = fromID, let count = try? r.readUInt16BigEndian() else { continue }
            var toIDs: [UInt32] = []
            for _ in 0..<count {
                let to: UInt32?
                if version == 0 { to = (try? r.readUInt16BigEndian()).map(UInt32.init) }
                else { to = try? r.readUInt32BigEndian() }
                guard let toID = to else { break }
                toIDs.append(toID)
            }
            entries.append(IrefEntry(type: box.type, fromID: from, toIDs: toIDs))
        }
        return (version, entries)
    }

    private static func buildIref(version: UInt8, entries: [IrefEntry]) -> ISOBMFFBox {
        var w = BinaryWriter(capacity: 16 + entries.count * 12)
        w.writeUInt32BigEndian(UInt32(version) << 24) // version, flags 0
        for entry in entries {
            var child = BinaryWriter(capacity: 16)
            if version == 0 {
                child.writeUInt16BigEndian(UInt16(truncatingIfNeeded: entry.fromID))
                child.writeUInt16BigEndian(UInt16(entry.toIDs.count))
                for to in entry.toIDs { child.writeUInt16BigEndian(UInt16(truncatingIfNeeded: to)) }
            } else {
                child.writeUInt32BigEndian(entry.fromID)
                child.writeUInt16BigEndian(UInt16(entry.toIDs.count))
                for to in entry.toIDs { child.writeUInt32BigEndian(to) }
            }
            ISOBMFFBoxWriter.writeBox(&w, box: ISOBMFFBox(type: entry.type, data: child.data))
        }
        return ISOBMFFBox(type: "iref", data: w.data)
    }
}
