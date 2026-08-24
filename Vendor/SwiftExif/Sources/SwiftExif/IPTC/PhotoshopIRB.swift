import Foundation

/// A single 8BIM resource block within a Photoshop APP13 segment.
public struct IRBBlock: Equatable, Sendable {
    public let resourceID: UInt16
    public let name: String
    public var data: Data

    public init(resourceID: UInt16, name: String = "", data: Data) {
        self.resourceID = resourceID
        self.name = name
        self.data = data
    }
}

/// Parse and write Photoshop Image Resource Blocks (the container for IPTC in APP13).
public struct PhotoshopIRB: Sendable {
    public static let photoshopHeader = "Photoshop 3.0"
    public static let signature8BIM: [UInt8] = [0x38, 0x42, 0x49, 0x4D] // "8BIM"
    public static let iptcResourceID: UInt16 = 0x0404

    /// Parse APP13 segment data into IRB blocks.
    /// Input: segment payload (starts with "Photoshop 3.0\0").
    public static func parse(_ data: Data) throws -> [IRBBlock] {
        var reader = BinaryReader(data: data)

        // Read and verify Photoshop header
        let headerString = try reader.readString(13, encoding: .ascii)
        guard headerString == photoshopHeader else {
            throw MetadataError.invalidPhotoshopHeader
        }
        let terminator = try reader.readUInt8()
        guard terminator == 0x00 else {
            throw MetadataError.invalidPhotoshopHeader
        }

        var blocks: [IRBBlock] = []

        while reader.remainingCount >= 12 { // Minimum: 4 (8BIM) + 2 (ID) + 2 (name) + 4 (size)
            // Check for 8BIM signature
            guard reader.hasPrefix(signature8BIM) else {
                break // Not a valid 8BIM block — stop parsing
            }
            try reader.skip(4) // Skip "8BIM"

            let resourceID = try reader.readUInt16BigEndian()

            // Pascal string: length byte, then string, padded to even total
            let nameLength = Int(try reader.readUInt8())
            let nameData: Data
            if nameLength > 0 {
                nameData = try reader.readBytes(nameLength)
            } else {
                nameData = Data()
            }
            // Pascal string total = 1 (length byte) + nameLength
            // Must be padded to even
            let pascalTotal = 1 + nameLength
            if pascalTotal % 2 != 0 {
                try reader.skip(1) // padding byte
            }

            let dataSize = try reader.readUInt32BigEndian()
            let blockData = try reader.readBytes(Int(dataSize))

            // Data is padded to even
            if dataSize % 2 != 0 && reader.remainingCount > 0 {
                try reader.skip(1)
            }

            let name = String(data: nameData, encoding: .ascii) ?? ""
            blocks.append(IRBBlock(resourceID: resourceID, name: name, data: blockData))
        }

        return blocks
    }

    /// Parse raw 8BIM blocks without the "Photoshop 3.0\0" header prefix.
    /// Used for PSD image resources sections which start directly with 8BIM blocks.
    public static func parseRaw(_ data: Data) throws -> [IRBBlock] {
        var reader = BinaryReader(data: data)
        var blocks: [IRBBlock] = []

        while reader.remainingCount >= 12 {
            guard reader.hasPrefix(signature8BIM) else { break }
            try reader.skip(4)

            let resourceID = try reader.readUInt16BigEndian()

            let nameLength = Int(try reader.readUInt8())
            let nameData: Data
            if nameLength > 0 {
                nameData = try reader.readBytes(nameLength)
            } else {
                nameData = Data()
            }
            let pascalTotal = 1 + nameLength
            if pascalTotal % 2 != 0 {
                try reader.skip(1)
            }

            let dataSize = try reader.readUInt32BigEndian()
            let blockData = try reader.readBytes(Int(dataSize))

            if dataSize % 2 != 0 && reader.remainingCount > 0 {
                try reader.skip(1)
            }

            let name = String(data: nameData, encoding: .ascii) ?? ""
            blocks.append(IRBBlock(resourceID: resourceID, name: name, data: blockData))
        }

        return blocks
    }

    /// Reconstruct raw 8BIM blocks without the "Photoshop 3.0\0" header.
    /// Used for PSD image resources sections.
    public static func writeRaw(blocks: [IRBBlock]) -> Data {
        var writer = BinaryWriter(capacity: 1024)

        for block in blocks {
            writer.writeBytes(signature8BIM)
            writer.writeUInt16BigEndian(block.resourceID)

            let nameBytes = Data(block.name.utf8)
            writer.writeUInt8(UInt8(nameBytes.count))
            if !nameBytes.isEmpty {
                writer.writeBytes(nameBytes)
            }
            let pascalTotal = 1 + nameBytes.count
            if pascalTotal % 2 != 0 {
                writer.writeUInt8(0x00)
            }

            writer.writeUInt32BigEndian(UInt32(block.data.count))
            writer.writeBytes(block.data)

            if block.data.count % 2 != 0 {
                writer.writeUInt8(0x00)
            }
        }

        return writer.data
    }

    /// Extract just the IPTC data block (resource 0x0404) from APP13 data.
    public static func extractIPTCData(_ app13Data: Data) throws -> Data? {
        let blocks = try parse(app13Data)
        return blocks.first { $0.resourceID == iptcResourceID }?.data
    }

    /// Reconstruct APP13 segment data from IRB blocks.
    public static func write(blocks: [IRBBlock]) -> Data {
        var writer = BinaryWriter(capacity: 1024)

        // Photoshop header
        writer.writeString(photoshopHeader, encoding: .ascii)
        writer.writeUInt8(0x00)

        for block in blocks {
            // 8BIM signature
            writer.writeBytes(signature8BIM)

            // Resource ID
            writer.writeUInt16BigEndian(block.resourceID)

            // Pascal string name
            let nameBytes = Data(block.name.utf8)
            writer.writeUInt8(UInt8(nameBytes.count))
            if !nameBytes.isEmpty {
                writer.writeBytes(nameBytes)
            }
            // Pad pascal string to even total
            let pascalTotal = 1 + nameBytes.count
            if pascalTotal % 2 != 0 {
                writer.writeUInt8(0x00)
            }

            // Data size and data
            writer.writeUInt32BigEndian(UInt32(block.data.count))
            writer.writeBytes(block.data)

            // Pad data to even
            if block.data.count % 2 != 0 {
                writer.writeUInt8(0x00)
            }
        }

        return writer.data
    }

    /// Replace just the IPTC data within existing APP13 data, preserving other resources.
    public static func replaceIPTCData(in app13Data: Data, with iptcData: Data) throws -> Data {
        var blocks = try parse(app13Data)

        if let index = blocks.firstIndex(where: { $0.resourceID == iptcResourceID }) {
            blocks[index].data = iptcData
        } else {
            blocks.append(IRBBlock(resourceID: iptcResourceID, data: iptcData))
        }

        return write(blocks: blocks)
    }
}
