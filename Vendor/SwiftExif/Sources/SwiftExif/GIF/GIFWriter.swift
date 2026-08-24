import Foundation

public struct GIFWriter: Sendable {

    /// Write a GIF file, optionally with updated XMP metadata.
    /// For lossless round-trip: modifies the raw data in-place by replacing/inserting
    /// the XMP Application Extension block.
    public static func write(_ gif: GIFFile, xmp: XMPData?) -> Data {
        // If no XMP changes needed and original data exists, return as-is
        if xmp == nil && gif.findXMPExtension() == nil && !gif.rawData.isEmpty {
            return gif.rawData
        }

        // Reconstruct from blocks
        var result = Data()

        // Header
        var version = "89a"
        for block in gif.blocks {
            if case .header(let v) = block.type { version = v; break }
        }
        result.append(Data("GIF\(version)".utf8))

        var wroteXMP = false

        for block in gif.blocks {
            switch block.type {
            case .header:
                continue // Already written

            case .logicalScreenDescriptor(let data):
                result.append(data)

            case .globalColorTable(let data):
                result.append(data)

            case .imageDescriptor(let data):
                result.append(0x2C) // Image Descriptor introducer
                result.append(data)

            case .localColorTable(let data):
                result.append(data)

            case .imageData(let data):
                result.append(data)

            case .graphicControlExtension(let data):
                result.append(0x21) // Extension introducer
                result.append(0xF9) // Graphic Control label
                result.append(UInt8(data.count))
                result.append(data)
                result.append(0x00) // Block terminator

            case .commentExtension(let text):
                result.append(0x21)
                result.append(0xFE)
                writeSubBlocks(Data(text.utf8), to: &result)

            case .applicationExtension(let identifier, let authCode, let data):
                if identifier == "XMP Data" {
                    // Replace with updated XMP or skip if removing
                    if let xmp = xmp {
                        writeXMPExtension(xmp, to: &result)
                        wroteXMP = true
                    }
                    // If xmp is nil, skip (removes XMP)
                    continue
                }
                result.append(0x21) // Extension introducer
                result.append(0xFF) // Application Extension label
                result.append(0x0B) // Block size (always 11)
                // Pad identifier to 8 bytes
                var idData = Data(identifier.prefix(8).utf8)
                while idData.count < 8 { idData.append(0x20) } // pad with spaces
                result.append(idData)
                result.append(authCode)
                writeSubBlocks(data, to: &result)

            case .plainTextExtension(let data):
                result.append(0x21)
                result.append(0x01)
                result.append(UInt8(data.count))
                result.append(data)
                result.append(0x00) // Block terminator

            case .trailer:
                // Write XMP before trailer if not yet written
                if !wroteXMP, let xmp = xmp {
                    writeXMPExtension(xmp, to: &result)
                }
                result.append(0x3B)

            case .unknown(let data):
                result.append(data)
            }
        }

        // If no trailer was found but we need to write XMP
        if !wroteXMP, let xmp = xmp {
            writeXMPExtension(xmp, to: &result)
            result.append(0x3B) // Trailer
        }

        return result
    }

    /// Write XMP as a GIF Application Extension block.
    /// Format: "XMP DataXMP" identifier + XMP XML + 258-byte magic trailer.
    private static func writeXMPExtension(_ xmp: XMPData, to data: inout Data) {
        let xml = XMPWriter.generateXML(xmp)
        guard let xmlData = xml.data(using: .utf8) else { return }

        data.append(0x21) // Extension introducer
        data.append(0xFF) // Application Extension label
        data.append(0x0B) // Block size (11)
        data.append(Data("XMP Data".utf8)) // Application identifier (8 bytes)
        data.append(Data("XMP".utf8))      // Auth code (3 bytes)

        // Write XMP as sub-blocks (max 255 bytes per sub-block)
        writeSubBlocks(xmlData, to: &data)
    }

    private static func writeSubBlocks(_ blockData: Data, to data: inout Data) {
        var offset = 0
        while offset < blockData.count {
            let remaining = blockData.count - offset
            let chunkSize = min(remaining, 255)
            data.append(UInt8(chunkSize))
            data.append(blockData[offset..<offset + chunkSize])
            offset += chunkSize
        }
        data.append(0x00) // Block terminator
    }
}
