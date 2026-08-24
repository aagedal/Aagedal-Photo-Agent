import Foundation

/// Writes metadata to MP4/MOV/M4V video files.
/// Preserves all media data (mdat) and track structure, only modifying metadata boxes.
public struct MP4Writer: Sendable {

    // Seconds between 1904-01-01 and 1970-01-01 (QuickTime epoch to Unix epoch)
    private static let epochOffset: TimeInterval = 2082844800

    // XMP UUID: BE7ACFCB-97A9-42E8-9C71-999491E3AFAC
    private static let xmpUUID = Data([
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
    ])

    /// Write updated metadata to video data.
    /// Streams through the original data box-by-box, updating metadata in moov while copying mdat verbatim.
    public static func write(_ metadata: VideoMetadata, to originalData: Data) throws -> Data {
        var writer = BinaryWriter(capacity: originalData.count)
        var reader = BinaryReader(data: originalData)
        var wroteXMP = false

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let payloadSize: Int
            let headerSize: Int
            if size32 == 1 {
                guard reader.remainingCount >= 8 else { break }
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16 else { break }
                payloadSize = Int(size64) - 16
                headerSize = 16
            } else if size32 == 0 {
                payloadSize = originalData.count - reader.offset
                headerSize = 8
            } else {
                guard size32 >= 8 else { break }
                payloadSize = Int(size32) - 8
                headerSize = 8
            }

            guard payloadSize >= 0 && reader.offset + payloadSize <= originalData.count else { break }

            switch type {
            case "moov":
                let moovPayload = try reader.readBytes(payloadSize)
                let updatedMoov = try rebuildMoov(Data(moovPayload), metadata: metadata)
                ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "moov", data: updatedMoov))

            case "uuid":
                let payload = try reader.readBytes(payloadSize)
                if payload.count >= 16 && Data(payload.prefix(16)) == xmpUUID {
                    if let xmp = metadata.xmp {
                        wroteXMP = true
                        let xmpXML = XMPWriter.generateXML(xmp)
                        var xmpPayload = Data(xmpUUID)
                        xmpPayload.append(Data(xmpXML.utf8))
                        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: xmpPayload))
                    } else {
                        // XMP stripped — skip this box
                        wroteXMP = true
                    }
                } else {
                    ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: payload))
                }

            default:
                // Copy box verbatim (ftyp, mdat, free, etc.)
                let payload = try reader.readBytes(payloadSize)
                if size32 == 1 {
                    writer.writeUInt32BigEndian(1)
                    writer.writeBytes(typeBytes)
                    writer.writeUInt64BigEndian(UInt64(16 + payload.count))
                    writer.writeBytes(payload)
                } else {
                    writer.writeUInt32BigEndian(UInt32(8 + payload.count))
                    writer.writeBytes(typeBytes)
                    writer.writeBytes(payload)
                }
            }

            let expectedEnd = boxStart + headerSize + payloadSize
            if expectedEnd > reader.offset {
                try reader.seek(to: min(expectedEnd, originalData.count))
            }
        }

        // Append XMP uuid box if it didn't exist before
        if !wroteXMP, let xmp = metadata.xmp {
            let xmpXML = XMPWriter.generateXML(xmp)
            var xmpPayload = Data(xmpUUID)
            xmpPayload.append(Data(xmpXML.utf8))
            ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "uuid", data: xmpPayload))
        }

        return writer.data
    }

    // MARK: - Moov Rebuild

    /// Rebuild the moov box with updated metadata.
    private static func rebuildMoov(_ moovData: Data, metadata: VideoMetadata) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: moovData)
        var outputWriter = BinaryWriter(capacity: moovData.count)
        var hasUDTA = false

        for child in children {
            switch child.type {
            case "mvhd":
                let updatedMVHD = updateMVHD(child.data, metadata: metadata)
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "mvhd", data: updatedMVHD))

            case "udta":
                hasUDTA = true
                let updatedUDTA = try rebuildUDTA(child.data, metadata: metadata)
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "udta", data: updatedUDTA))

            default:
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
            }
        }

        // Create udta if it didn't exist and we have metadata to write
        if !hasUDTA && hasUserMetadata(metadata) {
            let udta = try buildNewUDTA(metadata: metadata)
            ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "udta", data: udta))
        }

        return outputWriter.data
    }

    // MARK: - mvhd (Movie Header) Update

    /// Update creation/modification dates in mvhd.
    private static func updateMVHD(_ data: Data, metadata: VideoMetadata) -> Data {
        guard data.count >= 4 else { return data }
        var result = data
        let version = data[data.startIndex]

        if version == 0 {
            // Version 0: 32-bit timestamps at offsets 4 and 8
            guard data.count >= 12 else { return data }
            if let date = metadata.creationDate {
                let qtTime = UInt32(date.timeIntervalSince1970 + epochOffset)
                writeUInt32BE(&result, value: qtTime, at: 4)
            }
            if let date = metadata.modificationDate {
                let qtTime = UInt32(date.timeIntervalSince1970 + epochOffset)
                writeUInt32BE(&result, value: qtTime, at: 8)
            }
        } else {
            // Version 1: 64-bit timestamps at offsets 4 and 12
            guard data.count >= 20 else { return data }
            if let date = metadata.creationDate {
                let qtTime = UInt64(date.timeIntervalSince1970 + epochOffset)
                writeUInt64BE(&result, value: qtTime, at: 4)
            }
            if let date = metadata.modificationDate {
                let qtTime = UInt64(date.timeIntervalSince1970 + epochOffset)
                writeUInt64BE(&result, value: qtTime, at: 12)
            }
        }

        return result
    }

    // MARK: - udta Rebuild

    /// Rebuild the udta box with updated metadata items.
    private static func rebuildUDTA(_ data: Data, metadata: VideoMetadata) throws -> Data {
        let children = try ISOBMFFBoxReader.parseBoxes(from: data)
        var outputWriter = BinaryWriter(capacity: data.count)
        var hasMeta = false

        for child in children {
            if child.type == "meta" {
                hasMeta = true
                let updatedMeta = try rebuildMetaBox(child.data, metadata: metadata)
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "meta", data: updatedMeta))
            } else {
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
            }
        }

        if !hasMeta && hasUserMetadata(metadata) {
            let meta = try buildNewMetaBox(metadata: metadata)
            ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "meta", data: meta))
        }

        return outputWriter.data
    }

    /// Rebuild the meta FullBox (version/flags + children including ilst).
    private static func rebuildMetaBox(_ data: Data, metadata: VideoMetadata) throws -> Data {
        guard data.count > 4 else { return data }
        let versionFlags = data.prefix(4)
        let childData = Data(data.suffix(from: data.startIndex + 4))
        let children = try ISOBMFFBoxReader.parseBoxes(from: childData)
        var outputWriter = BinaryWriter(capacity: data.count)
        outputWriter.writeBytes(versionFlags)
        var hasILST = false

        for child in children {
            if child.type == "ilst" {
                hasILST = true
                let updatedILST = rebuildILST(child.data, metadata: metadata)
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "ilst", data: updatedILST))
            } else if child.type == "xml " {
                // Update XMP
                if let xmp = metadata.xmp {
                    let xmpXML = XMPWriter.generateXML(xmp)
                    ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "xml ", data: Data(xmpXML.utf8)))
                }
                // If xmp is nil, we strip it by not writing
            } else {
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: child)
            }
        }

        if !hasILST && hasUserMetadata(metadata) {
            let ilst = buildNewILST(metadata: metadata)
            ISOBMFFBoxWriter.writeBox(&outputWriter, box: ISOBMFFBox(type: "ilst", data: ilst))
        }

        return outputWriter.data
    }

    // MARK: - ilst (iTunes-style metadata)

    /// Rebuild ilst with updated metadata items.
    private static func rebuildILST(_ data: Data, metadata: VideoMetadata) -> Data {
        let items = (try? ISOBMFFBoxReader.parseBoxes(from: data)) ?? []
        var outputWriter = BinaryWriter(capacity: data.count)

        // Track which keys we've updated
        var updatedKeys: Set<String> = []

        for item in items {
            let key = item.type
            let normalizedKey = normalizeILSTKey(key)

            switch normalizedKey {
            case "nam":
                updatedKeys.insert("nam")
                if let title = metadata.title {
                    writeILSTItem(&outputWriter, type: key, stringValue: title)
                }
            case "ART":
                updatedKeys.insert("ART")
                if let artist = metadata.artist {
                    writeILSTItem(&outputWriter, type: key, stringValue: artist)
                }
            case "cmt":
                updatedKeys.insert("cmt")
                if let comment = metadata.comment {
                    writeILSTItem(&outputWriter, type: key, stringValue: comment)
                }
            case "xyz":
                updatedKeys.insert("xyz")
                if metadata.gpsLatitude != nil || metadata.gpsLongitude != nil {
                    let gpsString = formatGPSXYZ(metadata)
                    writeILSTItem(&outputWriter, type: key, stringValue: gpsString)
                }
            default:
                // Preserve unknown items
                ISOBMFFBoxWriter.writeBox(&outputWriter, box: item)
            }
        }

        // Add new items that weren't in original
        if !updatedKeys.contains("nam"), let title = metadata.title {
            writeILSTItem(&outputWriter, type: "\u{00A9}nam", stringValue: title)
        }
        if !updatedKeys.contains("ART"), let artist = metadata.artist {
            writeILSTItem(&outputWriter, type: "\u{00A9}ART", stringValue: artist)
        }
        if !updatedKeys.contains("cmt"), let comment = metadata.comment {
            writeILSTItem(&outputWriter, type: "\u{00A9}cmt", stringValue: comment)
        }
        if !updatedKeys.contains("xyz"), metadata.gpsLatitude != nil {
            let gpsString = formatGPSXYZ(metadata)
            writeILSTItem(&outputWriter, type: "\u{00A9}xyz", stringValue: gpsString)
        }

        return outputWriter.data
    }

    /// Build a fresh ilst from metadata.
    private static func buildNewILST(metadata: VideoMetadata) -> Data {
        var writer = BinaryWriter(capacity: 256)

        if let title = metadata.title {
            writeILSTItem(&writer, type: "\u{00A9}nam", stringValue: title)
        }
        if let artist = metadata.artist {
            writeILSTItem(&writer, type: "\u{00A9}ART", stringValue: artist)
        }
        if let comment = metadata.comment {
            writeILSTItem(&writer, type: "\u{00A9}cmt", stringValue: comment)
        }
        if metadata.gpsLatitude != nil {
            writeILSTItem(&writer, type: "\u{00A9}xyz", stringValue: formatGPSXYZ(metadata))
        }

        return writer.data
    }

    /// Build a new meta FullBox containing ilst.
    private static func buildNewMetaBox(metadata: VideoMetadata) throws -> Data {
        var writer = BinaryWriter(capacity: 256)
        // FullBox: version 0 + flags 0
        writer.writeUInt32BigEndian(0)

        // hdlr box (required in meta)
        let hdlr = buildHDLR()
        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "hdlr", data: hdlr))

        // ilst
        let ilst = buildNewILST(metadata: metadata)
        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "ilst", data: ilst))

        // XMP as xml box
        if let xmp = metadata.xmp {
            let xmpXML = XMPWriter.generateXML(xmp)
            ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "xml ", data: Data(xmpXML.utf8)))
        }

        return writer.data
    }

    /// Build a new udta containing meta.
    private static func buildNewUDTA(metadata: VideoMetadata) throws -> Data {
        var writer = BinaryWriter(capacity: 256)
        let meta = try buildNewMetaBox(metadata: metadata)
        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "meta", data: meta))
        return writer.data
    }

    /// Build a minimal hdlr box for the meta box. Required by the spec.
    private static func buildHDLR() -> Data {
        var writer = BinaryWriter(capacity: 33)
        // FullBox: version 0 + flags 0
        writer.writeUInt32BigEndian(0)
        // pre_defined
        writer.writeUInt32BigEndian(0)
        // handler_type: "mdir" (metadata)
        writer.writeString("mdir", encoding: .ascii)
        // reserved (3 x UInt32)
        writer.writeUInt32BigEndian(0)
        writer.writeUInt32BigEndian(0)
        writer.writeUInt32BigEndian(0)
        // name (null-terminated)
        writer.writeUInt8(0)
        return writer.data
    }

    // MARK: - ilst Item Helpers

    /// Write an ilst item (type box containing a "data" sub-box).
    private static func writeILSTItem(_ writer: inout BinaryWriter, type: String, stringValue: String) {
        let utf8Data = Data(stringValue.utf8)
        // Build data sub-box: type_indicator (4 bytes) + locale (4 bytes) + payload
        var dataBox = BinaryWriter(capacity: 8 + utf8Data.count)
        dataBox.writeUInt32BigEndian(1) // type indicator: UTF-8
        dataBox.writeUInt32BigEndian(0) // locale: default
        dataBox.writeBytes(utf8Data)

        let dataBoxData = dataBox.data
        // Build the item box
        var itemBox = BinaryWriter(capacity: 8 + dataBoxData.count)
        ISOBMFFBoxWriter.writeBox(&itemBox, box: ISOBMFFBox(type: "data", data: dataBoxData))

        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: type, data: itemBox.data))
    }

    // MARK: - GPS Formatting

    /// Format GPS coordinates as QuickTime ©xyz string: "+DD.DDDD+DDD.DDDD/"
    private static func formatGPSXYZ(_ metadata: VideoMetadata) -> String {
        let lat = metadata.gpsLatitude ?? 0
        let lon = metadata.gpsLongitude ?? 0
        let latStr = String(format: "%+.4f", lat)
        let lonStr = String(format: "%+.4f", lon)
        if let alt = metadata.gpsAltitude {
            let altStr = String(format: "%+.2f", alt)
            return "\(latStr)\(lonStr)\(altStr)/"
        }
        return "\(latStr)\(lonStr)/"
    }

    // MARK: - Key Normalization

    /// Normalize ilst key by stripping the leading © (0xA9) if present.
    private static func normalizeILSTKey(_ key: String) -> String {
        if key.count == 4 && key.unicodeScalars.first?.value == 0xA9 {
            return String(key.dropFirst())
        }
        return key
    }

    // MARK: - Helpers

    /// Check whether metadata has any user-writable fields set.
    private static func hasUserMetadata(_ metadata: VideoMetadata) -> Bool {
        metadata.title != nil || metadata.artist != nil || metadata.comment != nil ||
        metadata.gpsLatitude != nil || metadata.xmp != nil
    }

    /// Write a big-endian UInt32 at a specific offset in Data.
    private static func writeUInt32BE(_ data: inout Data, value: UInt32, at offset: Int) {
        data[data.startIndex + offset]     = UInt8((value >> 24) & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 16) & 0xFF)
        data[data.startIndex + offset + 2] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 3] = UInt8(value & 0xFF)
    }

    /// Write a big-endian UInt64 at a specific offset in Data.
    private static func writeUInt64BE(_ data: inout Data, value: UInt64, at offset: Int) {
        data[data.startIndex + offset]     = UInt8((value >> 56) & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 48) & 0xFF)
        data[data.startIndex + offset + 2] = UInt8((value >> 40) & 0xFF)
        data[data.startIndex + offset + 3] = UInt8((value >> 32) & 0xFF)
        data[data.startIndex + offset + 4] = UInt8((value >> 24) & 0xFF)
        data[data.startIndex + offset + 5] = UInt8((value >> 16) & 0xFF)
        data[data.startIndex + offset + 6] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 7] = UInt8(value & 0xFF)
    }
}
