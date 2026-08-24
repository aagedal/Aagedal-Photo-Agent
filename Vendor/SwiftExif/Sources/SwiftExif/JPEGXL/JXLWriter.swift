import Foundation

/// Reconstructs a JPEG XL container file from parsed components.
public struct JXLWriter: Sendable {

    /// Standard JPEG XL `ftyp` box payload (ISO/IEC 18181-2 §3): major brand
    /// "jxl ", minor version 0, one compatible brand "jxl ".
    private static let ftypPayload: [UInt8] = [
        0x6A, 0x78, 0x6C, 0x20,  // "jxl " major brand
        0x00, 0x00, 0x00, 0x00,  // minor version 0
        0x6A, 0x78, 0x6C, 0x20,  // "jxl " compatible brand
    ]

    /// Reconstruct a JPEG XL file from its parsed components.
    ///
    /// For container files this re-serializes the boxes. For a bare codestream
    /// that has had metadata boxes added, the codestream is losslessly wrapped
    /// into container format (signature + `ftyp` + metadata boxes + `jxlc`) so
    /// those boxes have somewhere to live — the pixel data is copied verbatim,
    /// never re-encoded. A bare codestream with no metadata to add is returned
    /// unchanged.
    public static func write(_ file: JXLFile) throws -> Data {
        guard file.isContainer else {
            return try wrapBareCodestream(file)
        }

        var writer = BinaryWriter(capacity: estimateSize(file))

        // JXL file type box (12-byte signature)
        writer.writeBytes(JXLParser.containerSignature)

        // Write all boxes
        ISOBMFFBoxWriter.writeBoxes(&writer, boxes: file.boxes)

        return writer.data
    }

    /// Wrap a bare codestream into container format, inserting any metadata
    /// boxes the caller added (`file.boxes`, e.g. Exif/XMP) ahead of the
    /// codestream. With no boxes to add, the original bare bytes are returned
    /// unchanged so a no-op write stays byte-for-byte identical.
    private static func wrapBareCodestream(_ file: JXLFile) throws -> Data {
        guard let codestream = file.rawCodestream else {
            throw MetadataError.writeNotSupported(
                "Cannot write metadata to bare JPEG XL codestream; original codestream bytes unavailable")
        }
        guard !file.boxes.isEmpty else {
            return codestream
        }

        var boxes: [ISOBMFFBox] = [ISOBMFFBox(type: "ftyp", data: Data(ftypPayload))]
        boxes.append(contentsOf: file.boxes)
        boxes.append(ISOBMFFBox(type: "jxlc", data: codestream))

        let capacity = 12 + boxes.reduce(0) { $0 + 8 + $1.data.count }
        var writer = BinaryWriter(capacity: capacity)
        writer.writeBytes(JXLParser.containerSignature)
        ISOBMFFBoxWriter.writeBoxes(&writer, boxes: boxes)
        return writer.data
    }

    private static func estimateSize(_ file: JXLFile) -> Int {
        var size = 12 // JXL signature
        for box in file.boxes {
            size += 8 + box.data.count
        }
        return size
    }
}
