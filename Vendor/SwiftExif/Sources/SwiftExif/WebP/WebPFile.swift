import Foundation

/// A single chunk in a RIFF/WebP file.
public struct WebPChunk: Sendable {
    /// FourCC chunk identifier (e.g. "VP8 ", "VP8X", "EXIF", "XMP ", "ICCP").
    public let fourCC: String
    /// Raw chunk payload (excludes the 8-byte chunk header).
    public var data: Data

    public init(fourCC: String, data: Data) {
        self.fourCC = fourCC
        self.data = data
    }
}

/// Parsed representation of a WebP file (RIFF container).
public struct WebPFile: Sendable {
    /// All chunks in file order.
    public var chunks: [WebPChunk]

    public init(chunks: [WebPChunk] = []) {
        self.chunks = chunks
    }

    /// Find the first chunk with the given FourCC.
    public func findChunk(_ fourCC: String) -> WebPChunk? {
        chunks.first { $0.fourCC == fourCC }
    }

    /// Returns the index of the first chunk with the given FourCC.
    public func indexOfChunk(_ fourCC: String) -> Int? {
        chunks.firstIndex { $0.fourCC == fourCC }
    }
}
