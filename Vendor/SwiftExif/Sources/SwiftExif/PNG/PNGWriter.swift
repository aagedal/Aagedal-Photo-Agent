import Foundation

/// Reconstructs a PNG file from parsed components.
public struct PNGWriter: Sendable {

    /// Reconstruct a PNG file from its chunks.
    public static func write(_ file: PNGFile) -> Data {
        var writer = BinaryWriter(capacity: estimateSize(file))

        // PNG signature
        writer.writeBytes(PNGParser.signature)

        // Write each chunk: length (4) + type (4) + data + CRC (4)
        for chunk in file.chunks {
            writer.writeUInt32BigEndian(UInt32(chunk.data.count))
            writer.writeString(chunk.type, encoding: .ascii)
            writer.writeBytes(chunk.data)
            let crc = CRC32.compute(type: chunk.type, data: chunk.data)
            writer.writeUInt32BigEndian(crc)
        }

        return writer.data
    }

    private static func estimateSize(_ file: PNGFile) -> Int {
        var size = 8 // signature
        for chunk in file.chunks {
            size += 4 + 4 + chunk.data.count + 4 // length + type + data + CRC
        }
        return size
    }
}
