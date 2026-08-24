import Foundation

/// A HEIC/HEIF auxiliary image — typically a depth map, alpha channel, or HDR Gain Map
/// stored as a sibling item alongside the primary picture. The pixel payload is HEVC/AV1
/// and is not decoded here; this struct only identifies the item, its kind, and the byte
/// range where its bitstream lives.
public struct HEIFAuxiliaryImage: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case depth
        case alpha
        case hdrGainMap
        case other
    }

    public let itemID: UInt32
    public let primaryItemID: UInt32
    /// The auxC URN identifying the auxiliary type, e.g.
    /// `"urn:com:apple:photo:2020:aux:hdrgainmap"` or `"urn:mpeg:hevc:2015:auxid:1"`.
    public let auxType: String
    public let kind: Kind
    /// Byte range inside the source file where the encoded bitstream lives. Nil when the
    /// item uses idat-based construction (rare for aux images) or iloc parsing failed.
    public let dataRange: Range<Int>?
}

/// Walks a HEIF file's `meta` box to enumerate auxiliary images. Layered on top of the
/// existing `iinf`/`iloc` parsing in `ISOBMFFMetadata`; adds `iref` (`auxl`) walking and
/// `iprp`/`ipco`/`ipma` resolution to identify each auxiliary item's URN.
public struct HEIFAuxiliaryImages: Sendable {

    public static func enumerate(from heifFile: HEIFFile, fileData: Data) throws -> [HEIFAuxiliaryImage] {
        guard let metaBox = heifFile.boxes.first(where: { $0.type == "meta" }) else { return [] }
        // meta is a FullBox: skip 4-byte version/flags before parsing children.
        guard metaBox.data.count > 4 else { return [] }
        let metaPayload = metaBox.data.suffix(from: metaBox.data.startIndex + 4)
        let children = (try? ISOBMFFBoxReader.parseBoxes(from: Data(metaPayload))) ?? []

        let auxlRefs = parseAuxLinks(from: children)
        guard !auxlRefs.isEmpty else { return [] }

        let propertyURNs = parseAuxCProperties(from: children)
        let itemAssociations = parseItemPropertyAssociations(from: children)
        let locations = parseItemLocations(from: children)

        var results: [HEIFAuxiliaryImage] = []
        for ref in auxlRefs {
            // Look up the auxC URN via property indices for this item.
            let propertyIndices = itemAssociations[ref.auxItemID] ?? []
            var urn: String?
            for idx in propertyIndices {
                if let str = propertyURNs[idx] {
                    urn = str
                    break
                }
            }
            let resolved = urn ?? ""
            let dataRange = locations[ref.auxItemID].flatMap { range -> Range<Int>? in
                guard range.lowerBound >= 0, range.upperBound <= fileData.count else { return nil }
                return range
            }

            results.append(HEIFAuxiliaryImage(
                itemID: ref.auxItemID,
                primaryItemID: ref.primaryItemID,
                auxType: resolved,
                kind: classify(urn: resolved),
                dataRange: dataRange
            ))
        }

        return results
    }

    private static func classify(urn: String) -> HEIFAuxiliaryImage.Kind {
        let lower = urn.lowercased()
        if lower.contains("hdrgainmap") || lower.contains("gainmap") { return .hdrGainMap }
        if lower.contains("depth") { return .depth }
        if lower.contains("alpha") { return .alpha }
        // ISO/IEC 23008-12 standard URNs: auxid:1 = alpha, auxid:2 = depth (per HEIF spec).
        if lower.hasSuffix(":auxid:1") { return .alpha }
        if lower.hasSuffix(":auxid:2") { return .depth }
        return .other
    }

    // MARK: - iref / auxl

    private struct AuxLink {
        let auxItemID: UInt32
        let primaryItemID: UInt32
    }

    private static func parseAuxLinks(from metaChildren: [ISOBMFFBox]) -> [AuxLink] {
        guard let irefBox = metaChildren.first(where: { $0.type == "iref" }) else { return [] }
        guard irefBox.data.count >= 4 else { return [] }

        var reader = BinaryReader(data: irefBox.data)
        var results: [AuxLink] = []
        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24
            let idIs32Bit = version >= 1

            // The remaining bytes are a sequence of reference-type boxes.
            let refBoxes = try ISOBMFFBoxReader.parseBoxes(from: &reader, limit: irefBox.data.count - 4)
            for refBox in refBoxes where refBox.type == "auxl" {
                var br = BinaryReader(data: refBox.data)
                let fromID: UInt32
                if idIs32Bit {
                    guard br.remainingCount >= 4 else { continue }
                    fromID = (try? br.readUInt32BigEndian()) ?? 0
                } else {
                    guard br.remainingCount >= 2 else { continue }
                    fromID = UInt32((try? br.readUInt16BigEndian()) ?? 0)
                }
                guard br.remainingCount >= 2 else { continue }
                let count = (try? br.readUInt16BigEndian()) ?? 0
                for _ in 0..<count {
                    let toID: UInt32
                    if idIs32Bit {
                        guard br.remainingCount >= 4 else { break }
                        toID = (try? br.readUInt32BigEndian()) ?? 0
                    } else {
                        guard br.remainingCount >= 2 else { break }
                        toID = UInt32((try? br.readUInt16BigEndian()) ?? 0)
                    }
                    // auxl: from_ID is the auxiliary item, references point to the primary.
                    results.append(AuxLink(auxItemID: fromID, primaryItemID: toID))
                }
            }
        } catch {
            // Best-effort.
        }
        return results
    }

    // MARK: - iprp / ipco

    /// Map of property index (1-based, as referenced by ipma) → auxC URN string.
    private static func parseAuxCProperties(from metaChildren: [ISOBMFFBox]) -> [UInt16: String] {
        guard let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) else { return [:] }
        let iprpChildren = (try? ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)) ?? []
        guard let ipcoBox = iprpChildren.first(where: { $0.type == "ipco" }) else { return [:] }

        let properties = (try? ISOBMFFBoxReader.parseBoxes(from: ipcoBox.data)) ?? []
        var urns: [UInt16: String] = [:]
        for (offset, property) in properties.enumerated() where property.type == "auxC" {
            // auxC is a FullBox: 4-byte version/flags, then null-terminated UTF-8 URN.
            guard property.data.count > 4 else { continue }
            let payload = property.data.suffix(from: property.data.startIndex + 4)
            let bytes = Array(payload)
            let nullIdx = bytes.firstIndex(of: 0) ?? bytes.endIndex
            let urn = String(bytes: bytes[bytes.startIndex..<nullIdx], encoding: .utf8) ?? ""
            urns[UInt16(offset + 1)] = urn
        }
        return urns
    }

    // MARK: - iprp / ipma

    /// Map of item_ID → list of associated property indices (1-based).
    private static func parseItemPropertyAssociations(from metaChildren: [ISOBMFFBox]) -> [UInt32: [UInt16]] {
        guard let iprpBox = metaChildren.first(where: { $0.type == "iprp" }) else { return [:] }
        let iprpChildren = (try? ISOBMFFBoxReader.parseBoxes(from: iprpBox.data)) ?? []
        guard let ipmaBox = iprpChildren.first(where: { $0.type == "ipma" }) else { return [:] }
        guard ipmaBox.data.count >= 8 else { return [:] }

        var reader = BinaryReader(data: ipmaBox.data)
        var result: [UInt32: [UInt16]] = [:]
        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24
            let flags = versionFlags & 0x00FFFFFF
            let wideIDs = version >= 1
            let wideIndices = (flags & 0x1) != 0

            let entryCount = try reader.readUInt32BigEndian()
            for _ in 0..<entryCount {
                let itemID: UInt32
                if wideIDs {
                    guard reader.remainingCount >= 4 else { break }
                    itemID = try reader.readUInt32BigEndian()
                } else {
                    guard reader.remainingCount >= 2 else { break }
                    itemID = UInt32(try reader.readUInt16BigEndian())
                }
                guard reader.remainingCount >= 1 else { break }
                let associationCount = try reader.readUInt8()
                var indices: [UInt16] = []
                for _ in 0..<associationCount {
                    if wideIndices {
                        guard reader.remainingCount >= 2 else { break }
                        let raw = try reader.readUInt16BigEndian()
                        indices.append(raw & 0x7FFF) // strip essential bit
                    } else {
                        guard reader.remainingCount >= 1 else { break }
                        let raw = try reader.readUInt8()
                        indices.append(UInt16(raw & 0x7F))
                    }
                }
                result[itemID] = indices
            }
        } catch {
            // Best-effort.
        }
        return result
    }

    // MARK: - iloc

    /// Map of item_ID → byte range within the file. Only handles the file-offset
    /// construction method (constructionMethod == 0); idat-based items are skipped.
    private static func parseItemLocations(from metaChildren: [ISOBMFFBox]) -> [UInt32: Range<Int>] {
        guard let ilocBox = metaChildren.first(where: { $0.type == "iloc" }) else { return [:] }
        guard ilocBox.data.count >= 8 else { return [:] }

        var reader = BinaryReader(data: ilocBox.data)
        var result: [UInt32: Range<Int>] = [:]
        do {
            let versionFlags = try reader.readUInt32BigEndian()
            let version = versionFlags >> 24

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

                var constructionMethod: UInt8 = 0
                if version == 1 || version == 2 {
                    let cm = try reader.readUInt16BigEndian()
                    constructionMethod = UInt8(cm & 0x0F)
                }
                try reader.skip(2) // data_reference_index
                let baseOffset = try readSizedUInt(&reader, size: baseOffsetSize)
                let extentCount = Int(try reader.readUInt16BigEndian())

                var firstOffset: UInt64 = 0
                var totalLength: UInt64 = 0
                for i in 0..<extentCount {
                    if indexSize > 0 { try reader.skip(indexSize) }
                    let extentOffset = try readSizedUInt(&reader, size: offsetSize)
                    let extentLength = try readSizedUInt(&reader, size: lengthSize)
                    if i == 0 { firstOffset = baseOffset + extentOffset }
                    totalLength += extentLength
                }

                guard constructionMethod == 0 else { continue }
                let lower = Int(firstOffset)
                let upper = Int(firstOffset + totalLength)
                guard lower >= 0, upper >= lower else { continue }
                result[itemID] = lower..<upper
            }
        } catch {
            // Best-effort.
        }
        return result
    }

    private static func readSizedUInt(_ reader: inout BinaryReader, size: Int) throws -> UInt64 {
        switch size {
        case 0: return 0
        case 4: return UInt64(try reader.readUInt32BigEndian())
        case 8: return try reader.readUInt64BigEndian()
        default:
            // Fallback for unusual sizes (1, 2): read byte-by-byte big-endian.
            var value: UInt64 = 0
            for _ in 0..<size {
                value = (value << 8) | UInt64(try reader.readUInt8())
            }
            return value
        }
    }
}
