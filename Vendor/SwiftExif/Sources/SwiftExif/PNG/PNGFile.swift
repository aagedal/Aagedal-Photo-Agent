import Foundation

/// Parsed representation of a PNG file.
public struct PNGFile: Sendable {
    /// All chunks in order.
    public var chunks: [PNGChunk]

    public init(chunks: [PNGChunk] = []) {
        self.chunks = chunks
    }

    /// Find the first chunk of the given type.
    public func findChunk(_ type: String) -> PNGChunk? {
        chunks.first { $0.type == type }
    }

    /// Find all chunks of the given type.
    public func findChunks(_ type: String) -> [PNGChunk] {
        chunks.filter { $0.type == type }
    }

    // MARK: - Chunk Mutation

    /// Replace the first chunk of the given type, or insert before IDAT if not present.
    public mutating func replaceOrAddChunk(_ type: String, data: Data) {
        let crc = CRC32.compute(type: type, data: data)
        let newChunk = PNGChunk(type: type, data: data, crc: crc)

        if let index = chunks.firstIndex(where: { $0.type == type }) {
            chunks[index] = newChunk
        } else {
            // Insert before the first IDAT chunk
            if let idatIndex = chunks.firstIndex(where: { $0.type == "IDAT" }) {
                chunks.insert(newChunk, at: idatIndex)
            } else {
                // Insert before IEND as last resort
                if let iendIndex = chunks.firstIndex(where: { $0.type == "IEND" }) {
                    chunks.insert(newChunk, at: iendIndex)
                } else {
                    chunks.append(newChunk)
                }
            }
        }
    }

    /// Replace or add an eXIf chunk with raw TIFF data.
    public mutating func replaceOrAddExifChunk(_ tiffData: Data) {
        replaceOrAddChunk("eXIf", data: tiffData)
    }

    /// Replace or add an iTXt chunk for XMP data.
    public mutating func replaceOrAddXMPChunk(_ xml: String) {
        var payload = Data()

        // Keyword: "XML:com.adobe.xmp" + null terminator
        payload.append(Data("XML:com.adobe.xmp".utf8))
        payload.append(0x00)

        // Compression flag: 0 (uncompressed)
        payload.append(0x00)
        // Compression method: 0
        payload.append(0x00)

        // Language tag: empty + null
        payload.append(0x00)
        // Translated keyword: empty + null
        payload.append(0x00)

        // XMP text
        payload.append(Data(xml.utf8))

        // Replace existing XMP iTXt or add new one
        if let index = chunks.firstIndex(where: { $0.type == "iTXt" && Self.isXMPiTXt($0)}) {
            let crc = CRC32.compute(type: "iTXt", data: payload)
            chunks[index] = PNGChunk(type: "iTXt", data: payload, crc: crc)
        } else {
            replaceOrAddChunk("iTXt", data: payload)
        }
    }

    /// Remove the first chunk of the given type.
    public mutating func removeChunk(_ type: String) {
        chunks.removeAll { $0.type == type }
    }

    /// Remove the XMP iTXt chunk, if present. Targets only the
    /// `XML:com.adobe.xmp` iTXt chunk, leaving any other iTXt text intact.
    public mutating func removeXMPChunk() {
        chunks.removeAll { $0.type == "iTXt" && Self.isXMPiTXt($0)}
    }

    private static func isXMPiTXt(_ chunk: PNGChunk) -> Bool {
        let keyword = "XML:com.adobe.xmp"
        guard chunk.data.count > keyword.utf8.count else { return false }
        return chunk.data.prefix(keyword.utf8.count) == Data(keyword.utf8)
    }
}
