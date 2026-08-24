import Foundation

/// Reconstructs a JPEG file from parsed components.
public struct JPEGWriter: Sendable {

    /// Maximum payload size for a single JPEG segment (UInt16 length field minus 2 bytes for the field itself).
    public static let maxSegmentPayload = 65533

    /// Reconstruct a JPEG file from its segments and scan data.
    /// Output: SOI + segments (with proper length headers) + scanData
    /// - Throws: `MetadataError.invalidSegmentLength` if any segment exceeds the 65,533-byte JPEG payload limit.
    public static func write(_ file: JPEGFile) throws -> Data {
        var writer = BinaryWriter(capacity: estimateSize(file))

        // Write SOI marker
        writer.writeUInt16BigEndian(JPEGMarker.soi.rawValue)

        // Write each segment
        for segment in file.segments {
            writer.writeUInt16BigEndian(segment.rawMarker)

            if segment.marker.isStandalone {
                // Standalone markers have no length or data
                continue
            }

            guard segment.data.count <= maxSegmentPayload else {
                throw MetadataError.invalidSegmentLength
            }

            // Length = data size + 2 (for the length field itself)
            let length = UInt16(segment.data.count + 2)
            writer.writeUInt16BigEndian(length)
            writer.writeBytes(segment.data)
        }

        // Write scan data verbatim (includes SOS marker, header, entropy data, and EOI)
        writer.writeBytes(file.scanData)

        return writer.data
    }

    private static func estimateSize(_ file: JPEGFile) -> Int {
        var size = 2 // SOI
        for segment in file.segments {
            size += segment.totalLength
        }
        size += file.scanData.count
        return size
    }
}
