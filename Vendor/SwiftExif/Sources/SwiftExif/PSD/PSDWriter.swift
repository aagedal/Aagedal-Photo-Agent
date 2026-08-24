import Foundation

/// Write PSD files with modified metadata.
/// Reconstructs the image resources section while preserving all other sections byte-for-byte.
public struct PSDWriter: Sendable {

    /// Write a PSD file with updated metadata.
    public static func write(
        _ file: PSDFile,
        iptc: IPTCData,
        exif: ExifData?,
        xmp: XMPData?,
        iccProfile: ICCProfile?
    ) throws -> Data {
        var writer = BinaryWriter(capacity: file.rawData.count)

        // 1. Copy header (26 bytes) verbatim
        writer.writeBytes(file.rawData.prefix(26))

        // 2. Copy color mode data section verbatim
        let colorModeData = Data(file.rawData[file.rawData.startIndex + file.colorModeDataRange.lowerBound ..<
                                               file.rawData.startIndex + file.colorModeDataRange.upperBound])
        writer.writeBytes(colorModeData)

        // 3. Reconstruct image resources section
        var blocks = file.irbBlocks

        // Replace/add IPTC (0x0404)
        let iptcData = try IPTCWriter.write(iptc)
        replaceOrAddBlock(&blocks, resourceID: PSDFile.iptcResourceID, data: iptcData)

        // Replace/add EXIF (0x0422)
        if let exif {
            let exifData = ExifWriter.writeTIFF(exif)
            replaceOrAddBlock(&blocks, resourceID: PSDFile.exifResourceID, data: exifData)
        } else {
            blocks.removeAll { $0.resourceID == PSDFile.exifResourceID }
        }

        // Replace/add XMP (0x0424)
        if let xmp {
            let xmpData = Data(XMPWriter.generateXML(xmp).utf8)
            replaceOrAddBlock(&blocks, resourceID: PSDFile.xmpResourceID, data: xmpData)
        } else {
            blocks.removeAll { $0.resourceID == PSDFile.xmpResourceID }
        }

        // Replace/add ICC (0x040F)
        if let icc = iccProfile {
            replaceOrAddBlock(&blocks, resourceID: PSDFile.iccProfileResourceID, data: icc.data)
        } else {
            blocks.removeAll { $0.resourceID == PSDFile.iccProfileResourceID }
        }

        // Serialize image resources
        let resourcesData = PhotoshopIRB.writeRaw(blocks: blocks)
        writer.writeUInt32BigEndian(UInt32(resourcesData.count))
        writer.writeBytes(resourcesData)

        // 4. Copy layer/mask data section verbatim
        let layerMaskData = Data(file.rawData[file.rawData.startIndex + file.layerMaskDataRange.lowerBound ..<
                                               file.rawData.startIndex + file.layerMaskDataRange.upperBound])
        writer.writeBytes(layerMaskData)

        // 5. Copy image data verbatim (everything from imageDataOffset to end)
        if file.imageDataOffset < file.rawData.count {
            let imageData = Data(file.rawData[file.rawData.startIndex + file.imageDataOffset ..< file.rawData.endIndex])
            writer.writeBytes(imageData)
        }

        return writer.data
    }

    private static func replaceOrAddBlock(_ blocks: inout [IRBBlock], resourceID: UInt16, data: Data) {
        if let idx = blocks.firstIndex(where: { $0.resourceID == resourceID }) {
            blocks[idx] = IRBBlock(resourceID: resourceID, name: blocks[idx].name, data: data)
        } else {
            blocks.append(IRBBlock(resourceID: resourceID, data: data))
        }
    }
}
