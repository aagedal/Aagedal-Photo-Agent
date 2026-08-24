import Foundation

public struct GIFParser: Sendable {

    static let gif87aMagic = Data("GIF87a".utf8)
    static let gif89aMagic = Data("GIF89a".utf8)

    public static func parse(_ data: Data) throws -> GIFFile {
        guard data.count >= 13 else {
            throw MetadataError.invalidGIF("File too small")
        }

        let headerBytes = data.prefix(6)
        let version: String
        if headerBytes == gif87aMagic {
            version = "87a"
        } else if headerBytes == gif89aMagic {
            version = "89a"
        } else {
            throw MetadataError.invalidGIF("Invalid GIF signature")
        }

        var blocks: [GIFBlock] = []
        blocks.append(GIFBlock(type: .header(version: version)))

        var offset = 6

        // Logical Screen Descriptor (7 bytes)
        guard offset + 7 <= data.count else {
            throw MetadataError.invalidGIF("Missing Logical Screen Descriptor")
        }
        let width = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        let height = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
        let packed = data[offset + 4]
        let lsdData = Data(data[offset..<offset + 7])
        blocks.append(GIFBlock(type: .logicalScreenDescriptor(lsdData)))
        offset += 7

        // Global Color Table
        let hasGCT = (packed & 0x80) != 0
        if hasGCT {
            let gctSize = 3 * (1 << ((packed & 0x07) + 1))
            guard offset + gctSize <= data.count else {
                throw MetadataError.invalidGIF("Global Color Table truncated")
            }
            let gctData = Data(data[offset..<offset + gctSize])
            blocks.append(GIFBlock(type: .globalColorTable(gctData)))
            offset += gctSize
        }

        // Parse remaining blocks
        while offset < data.count {
            let introducer = data[offset]
            offset += 1

            switch introducer {
            case 0x2C: // Image Descriptor
                guard offset + 9 <= data.count else { break }
                let descData = Data(data[offset..<offset + 9])
                let imgPacked = data[offset + 8]
                offset += 9
                blocks.append(GIFBlock(type: .imageDescriptor(descData)))

                // Local Color Table
                let hasLCT = (imgPacked & 0x80) != 0
                if hasLCT {
                    let lctSize = 3 * (1 << ((imgPacked & 0x07) + 1))
                    guard offset + lctSize <= data.count else { break }
                    let lctData = Data(data[offset..<offset + lctSize])
                    blocks.append(GIFBlock(type: .localColorTable(lctData)))
                    offset += lctSize
                }

                // Image data: LZW minimum code size + sub-blocks
                guard offset < data.count else { break }
                let startOfImageData = offset
                offset += 1 // Skip LZW minimum code size
                offset = skipSubBlocks(data, from: offset)
                let imgData = Data(data[startOfImageData..<offset])
                blocks.append(GIFBlock(type: .imageData(imgData)))

            case 0x21: // Extension
                guard offset < data.count else { break }
                let label = data[offset]
                offset += 1

                switch label {
                case 0xF9: // Graphic Control Extension
                    guard offset < data.count else { break }
                    let blockSize = Int(data[offset])
                    offset += 1
                    guard offset + blockSize + 1 <= data.count else { break }
                    let extData = Data(data[offset..<offset + blockSize])
                    offset += blockSize + 1 // +1 for block terminator
                    blocks.append(GIFBlock(type: .graphicControlExtension(extData)))

                case 0xFE: // Comment Extension
                    let (text, newOffset) = readSubBlocksAsString(data, from: offset)
                    offset = newOffset
                    blocks.append(GIFBlock(type: .commentExtension(text)))

                case 0xFF: // Application Extension
                    guard offset < data.count else { break }
                    let blockSize = Int(data[offset])
                    offset += 1
                    guard blockSize == 11, offset + 11 <= data.count else {
                        // Skip unknown extension
                        offset = skipSubBlocks(data, from: offset)
                        break
                    }
                    let identifierData = Data(data[offset..<offset + 8])
                    let authCode = Data(data[offset + 8..<offset + 11])
                    let identifier = String(data: identifierData, encoding: .ascii) ?? ""
                    offset += 11

                    let (subBlockData, newOffset) = readSubBlocks(data, from: offset)
                    offset = newOffset
                    blocks.append(GIFBlock(type: .applicationExtension(
                        identifier: identifier, authCode: authCode, data: subBlockData)))

                case 0x01: // Plain Text Extension
                    guard offset < data.count else { break }
                    let blockSize = Int(data[offset])
                    offset += 1
                    guard offset + blockSize <= data.count else { break }
                    let headerData = Data(data[offset..<offset + blockSize])
                    offset += blockSize
                    offset = skipSubBlocks(data, from: offset)
                    blocks.append(GIFBlock(type: .plainTextExtension(headerData)))

                default:
                    offset = skipSubBlocks(data, from: offset)
                }

            case 0x3B: // Trailer
                blocks.append(GIFBlock(type: .trailer))
                offset = data.count // done

            default:
                // Unknown byte, skip
                break
            }
        }

        return GIFFile(blocks: blocks, width: width, height: height, rawData: data)
    }

    /// Extract XMP from the parsed GIF.
    public static func extractXMP(from gif: GIFFile) throws -> XMPData? {
        guard let xmpRaw = gif.findXMPExtension() else { return nil }

        // The XMP in GIF has a 258-byte "magic trailer" after the XML
        // Find the end of the XML (look for closing xmpmeta or xpacket tag)
        guard let xmlString = String(data: xmpRaw, encoding: .utf8) else { return nil }

        // Find the actual end of XMP XML content
        let searchTargets = ["</x:xmpmeta>", "<?xpacket end"]
        var endIndex = xmlString.endIndex
        for target in searchTargets {
            if let range = xmlString.range(of: target) {
                // Include the full closing tag
                if target == "</x:xmpmeta>" {
                    endIndex = range.upperBound
                } else if let packetEnd = xmlString.range(of: "?>", range: range.lowerBound..<xmlString.endIndex) {
                    endIndex = packetEnd.upperBound
                }
                break
            }
        }

        let cleanXML = String(xmlString[xmlString.startIndex..<endIndex])
        guard let xmlData = cleanXML.data(using: .utf8), !xmlData.isEmpty else { return nil }
        return try XMPReader.readFromXML(xmlData)
    }

    // MARK: - Sub-block helpers

    private static func skipSubBlocks(_ data: Data, from offset: Int) -> Int {
        var off = offset
        while off < data.count {
            let size = Int(data[off])
            off += 1
            if size == 0 { break }
            // Stop at truncation rather than overshooting — the caller slices
            // `data[start..<off]` and would trap on an out-of-range upper bound.
            guard off + size <= data.count else { return data.count }
            off += size
        }
        return off
    }

    private static func readSubBlocks(_ data: Data, from offset: Int) -> (Data, Int) {
        var result = Data()
        var off = offset
        while off < data.count {
            let size = Int(data[off])
            off += 1
            if size == 0 { break }
            guard off + size <= data.count else { break }
            result.append(data[off..<off + size])
            off += size
        }
        return (result, off)
    }

    private static func readSubBlocksAsString(_ data: Data, from offset: Int) -> (String, Int) {
        let (blockData, newOffset) = readSubBlocks(data, from: offset)
        let text = String(data: blockData, encoding: .utf8) ?? String(data: blockData, encoding: .ascii) ?? ""
        return (text, newOffset)
    }
}
