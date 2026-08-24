import Foundation

/// A single block in a GIF file.
public struct GIFBlock: Sendable {
    public enum BlockType: Sendable, Equatable {
        case header(version: String)           // GIF87a or GIF89a
        case logicalScreenDescriptor(Data)
        case globalColorTable(Data)
        case imageDescriptor(Data)
        case localColorTable(Data)
        case imageData(Data)
        case graphicControlExtension(Data)
        case commentExtension(String)
        case applicationExtension(identifier: String, authCode: Data, data: Data)
        case plainTextExtension(Data)
        case trailer
        case unknown(Data)
    }

    public let type: BlockType

    public init(type: BlockType) {
        self.type = type
    }
}

/// Parsed representation of a GIF file.
public struct GIFFile: Sendable {
    public var blocks: [GIFBlock]
    /// Pixel width from the Logical Screen Descriptor.
    public var width: UInt16
    /// Pixel height from the Logical Screen Descriptor.
    public var height: UInt16
    /// The raw file data (preserved for lossless round-trip).
    public var rawData: Data

    public init(blocks: [GIFBlock] = [], width: UInt16 = 0, height: UInt16 = 0, rawData: Data = Data()) {
        self.blocks = blocks
        self.width = width
        self.height = height
        self.rawData = rawData
    }

    /// Find XMP data stored in an Application Extension block.
    public func findXMPExtension() -> Data? {
        for block in blocks {
            if case .applicationExtension(let id, _, let data) = block.type,
               id == "XMP Data" {
                return data
            }
        }
        return nil
    }

    /// Find comment extension text.
    public var comments: [String] {
        blocks.compactMap { block in
            if case .commentExtension(let text) = block.type { return text }
            return nil
        }
    }
}
