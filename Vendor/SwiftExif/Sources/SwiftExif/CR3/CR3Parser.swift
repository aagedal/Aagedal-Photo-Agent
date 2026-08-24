import Foundation

/// Parses Canon CR3 files (ISOBMFF-based RAW format).
public struct CR3Parser: Sendable {

    /// Parse a CR3 file and extract metadata.
    /// - Returns: Tuple of (CR3File, ExifData?, XMPData?, IPTCData)
    public static func parse(_ data: Data) throws -> (file: CR3File, exif: ExifData?, xmp: XMPData?, iptc: IPTCData) {
        let topBoxes = try ISOBMFFBoxReader.parseTopLevelBoxesSkippingMdat(data)

        var exif: ExifData?
        var xmp: XMPData?
        var thumbnailData: Data?
        var previewData: Data?

        // Process moov box — contains Canon metadata uuid containers
        if let moovBox = topBoxes.first(where: { $0.type == "moov" }) {
            let moovChildren = try ISOBMFFBoxReader.parseBoxes(from: moovBox.data)

            for child in moovChildren {
                if child.type == "uuid" && child.data.count >= 16 {
                    let uuid = child.data.prefix(16)
                    let payload = child.data.dropFirst(16)

                    if uuid == CanonUUID.canonMetadata {
                        let result = try CanonUUIDExtractor.parseCanonMetadata(Data(payload))
                        exif = result.exif
                        thumbnailData = result.thumbnail
                    } else if uuid == CanonUUID.canonPreview {
                        previewData = try CanonUUIDExtractor.parsePreview(Data(payload))
                    }
                }
            }
        }

        // Process top-level uuid boxes for XMP and the preview container. The
        // preview uuid (eaf42b5e…) sits at the top level in real Canon files —
        // not inside moov — so it must be scanned here too.
        for box in topBoxes where box.type == "uuid" && box.data.count >= 16 {
            let uuid = box.data.prefix(16)
            if uuid == CanonUUID.xmpUUID {
                let xmpData = Data(box.data.dropFirst(16))
                xmp = try? XMPReader.readFromXML(xmpData)
            } else if uuid == CanonUUID.canonPreview, previewData == nil {
                previewData = try? CanonUUIDExtractor.parsePreview(Data(box.data.dropFirst(16)))
            }
        }

        let file = CR3File(boxes: topBoxes, thumbnailData: thumbnailData, previewData: previewData, originalData: data)
        return (file, exif, xmp, IPTCData())
    }
}
