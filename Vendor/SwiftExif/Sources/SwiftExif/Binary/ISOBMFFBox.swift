import Foundation

/// An ISO Base Media File Format box (used by JPEG XL and AVIF).
public struct ISOBMFFBox: Sendable, Equatable {
    /// 4-character ASCII box type (e.g. "Exif", "xml ", "ftyp").
    public let type: String
    /// Box payload data (not including the size + type header).
    public let data: Data
    /// True when the source box used a 64-bit extended size header (the
    /// `size == 1` form). The writer preserves this so re-serializing a file
    /// does not shrink a box's header from 16 to 8 bytes — which would shift
    /// every absolute `iloc` file offset that points past it (e.g. a `mdat`
    /// written by Apple/`sips`). Purely a serialization hint: it is excluded
    /// from equality so semantically identical boxes still compare equal.
    public var usesLargeSize: Bool = false

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    public init(type: String, data: Data, usesLargeSize: Bool) {
        self.type = type
        self.data = data
        self.usesLargeSize = usesLargeSize
    }

    public static func == (lhs: ISOBMFFBox, rhs: ISOBMFFBox) -> Bool {
        lhs.type == rhs.type && lhs.data == rhs.data
    }
}

/// Serialize ISOBMFF boxes.
public struct ISOBMFFBoxWriter: Sendable {

    /// Write a single box (size + type + payload). Uses extended (64-bit) size
    /// when the payload exceeds the 32-bit limit, or when the source box used
    /// one — preserving the original header length so absolute `iloc` offsets
    /// past this box stay valid.
    public static func writeBox(_ writer: inout BinaryWriter, box: ISOBMFFBox) {
        let totalSize = 8 + box.data.count
        if totalSize > UInt32.max || box.usesLargeSize {
            // Extended size: size32 = 1 signals 64-bit size follows
            writer.writeUInt32BigEndian(1)
            writer.writeString(box.type, encoding: .isoLatin1)
            writer.writeUInt64BigEndian(UInt64(16 + box.data.count))
        } else {
            writer.writeUInt32BigEndian(UInt32(totalSize))
            writer.writeString(box.type, encoding: .isoLatin1)
        }
        writer.writeBytes(box.data)
    }

    /// Write a sequence of boxes.
    public static func writeBoxes(_ writer: inout BinaryWriter, boxes: [ISOBMFFBox]) {
        for box in boxes {
            writeBox(&writer, box: box)
        }
    }

    /// Serialize a sequence of boxes to Data.
    public static func serialize(boxes: [ISOBMFFBox]) -> Data {
        let capacity = boxes.reduce(0) { total, box in
            let headerSize = (8 + box.data.count > UInt32.max || box.usesLargeSize) ? 16 : 8
            return total + headerSize + box.data.count
        }
        var writer = BinaryWriter(capacity: capacity)
        writeBoxes(&writer, boxes: boxes)
        return writer.data
    }
}

/// Parse ISOBMFF box sequences.
public struct ISOBMFFBoxReader: Sendable {

    /// Parse a flat sequence of top-level boxes from the given data.
    public static func parseBoxes(from data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        return try parseBoxes(from: &reader, limit: data.count)
    }

    /// Parse top-level boxes from a full file buffer, but skip `mdat` payloads
    /// without copying them. Returns each box with its original `type` and a
    /// payload `Data` that is empty for `mdat` (since callers typically only
    /// want metadata and the `mdat` payload can be gigabytes of media data).
    ///
    /// Used by the CR3 image pipeline and the CRM video reader, both of which
    /// walk the moov tree but never need the bulk media buffer.
    public static func parseTopLevelBoxesSkippingMdat(_ data: Data) throws -> [ISOBMFFBox] {
        var reader = BinaryReader(data: data)
        var boxes: [ISOBMFFBox] = []

        while !reader.isAtEnd && reader.remainingCount >= 8 {
            let boxStart = reader.offset
            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else { break }

            let payloadSize: Int
            let headerSize: Int
            if size32 == 1 {
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16, size64 <= UInt64(Int.max) else { break }
                payloadSize = Int(size64) - 16
                headerSize = 16
            } else if size32 == 0 {
                payloadSize = data.count - reader.offset
                headerSize = 8
            } else {
                guard size32 >= 8 else { break }
                payloadSize = Int(size32) - 8
                headerSize = 8
            }

            // Compare via subtraction, not `reader.offset + payloadSize`: an
            // extended size near Int.max makes that addition overflow and trap.
            guard payloadSize >= 0 && payloadSize <= data.count - reader.offset else { break }

            if type == "mdat" {
                boxes.append(ISOBMFFBox(type: "mdat", data: Data(), usesLargeSize: headerSize == 16))
                try reader.seek(to: reader.offset + payloadSize)
            } else {
                let payload = try reader.readBytes(payloadSize)
                boxes.append(ISOBMFFBox(type: type, data: payload, usesLargeSize: headerSize == 16))
            }

            let expectedEnd = boxStart + headerSize + payloadSize
            if expectedEnd > reader.offset {
                try reader.seek(to: min(expectedEnd, data.count))
            }
        }

        return boxes
    }

    /// Parse boxes from a BinaryReader up to the given byte limit.
    public static func parseBoxes(from reader: inout BinaryReader, limit: Int) throws -> [ISOBMFFBox] {
        var boxes: [ISOBMFFBox] = []
        let endOffset = reader.offset + limit

        while reader.offset < endOffset && !reader.isAtEnd {
            let boxStart = reader.offset
            guard reader.remainingCount >= 8 else { break }

            let size32 = try reader.readUInt32BigEndian()
            let typeBytes = try reader.readBytes(4)
            guard let type = String(data: typeBytes, encoding: .isoLatin1) else {
                break
            }

            let payloadSize: Int
            var usesLargeSize = false
            if size32 == 1 {
                // Extended size (UInt64). Guard against values that don't fit in
                // Int — Int(UInt64) traps on overflow, which a malformed file could
                // trigger to crash the parser.
                let size64 = try reader.readUInt64BigEndian()
                guard size64 >= 16, size64 <= UInt64(Int.max) else { break }
                payloadSize = Int(size64) - 16 // 16 = 4 (size32) + 4 (type) + 8 (size64)
                usesLargeSize = true
            } else if size32 == 0 {
                // Box extends to end of data
                payloadSize = endOffset - reader.offset
            } else {
                guard size32 >= 8 else { break } // Header is 8 bytes minimum
                payloadSize = Int(size32) - 8 // 8 = 4 (size32) + 4 (type)
            }

            // Compare via subtraction, not `reader.offset + payloadSize`: an
            // extended size near Int.max makes that addition overflow and trap.
            // `endOffset - reader.offset` can go negative (a short final box),
            // which correctly fails the `payloadSize <=` test and breaks.
            guard payloadSize >= 0 && payloadSize <= endOffset - reader.offset else {
                break
            }

            let payload = try reader.readBytes(payloadSize)
            boxes.append(ISOBMFFBox(type: type, data: payload, usesLargeSize: usesLargeSize))

            // Ensure we advance past the box (handles padding)
            if size32 > 0 && size32 != 1 {
                let expectedEnd = boxStart + Int(size32)
                if expectedEnd > reader.offset && expectedEnd <= endOffset {
                    try reader.seek(to: expectedEnd)
                }
            }
        }

        return boxes
    }
}
