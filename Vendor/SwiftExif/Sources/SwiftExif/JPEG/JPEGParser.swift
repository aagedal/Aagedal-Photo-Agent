import Foundation

/// Parses a JPEG file into its constituent segments and scan data.
public struct JPEGParser: Sendable {

    /// Parse JPEG data into a JPEGFile structure.
    /// Segments before SOS are stored individually; everything from SOS onward is preserved as opaque scanData.
    public static func parse(_ data: Data) throws -> JPEGFile {
        var reader = BinaryReader(data: data)

        // Verify SOI marker
        let soi = try reader.readUInt16BigEndian()
        guard soi == JPEGMarker.soi.rawValue else {
            throw MetadataError.notAJPEG
        }

        var segments: [JPEGSegment] = []

        while !reader.isAtEnd {
            // Read marker
            let markerByte1 = try reader.readUInt8()
            guard markerByte1 == 0xFF else {
                throw MetadataError.invalidMarker(markerByte1)
            }

            // Skip padding 0xFF bytes (some encoders pad with extra 0xFF)
            var markerByte2 = try reader.readUInt8()
            while markerByte2 == 0xFF && !reader.isAtEnd {
                markerByte2 = try reader.readUInt8()
            }

            let rawMarker = UInt16(0xFF00) | UInt16(markerByte2)

            // EOI — end of image
            if rawMarker == JPEGMarker.eoi.rawValue {
                return JPEGFile(segments: segments, scanData: Data([0xFF, 0xD9]))
            }

            // SOS — everything from here through EOI is scan data
            if rawMarker == JPEGMarker.sos.rawValue {
                // Read SOS header length
                let length = try reader.readUInt16BigEndian()
                guard length >= 2 else {
                    throw MetadataError.invalidSegmentLength
                }
                let headerData = try reader.readBytes(Int(length) - 2)

                // Build scan data: SOS marker + length + header + entropy-coded data + EOI
                var scanBuilder = BinaryWriter(capacity: reader.remainingCount + 4 + headerData.count)
                scanBuilder.writeUInt16BigEndian(rawMarker)
                scanBuilder.writeUInt16BigEndian(length)
                scanBuilder.writeBytes(headerData)

                // Copy all remaining bytes (entropy-coded data through EOI)
                let remaining = reader.readRemainingBytes()
                scanBuilder.writeBytes(remaining)

                return JPEGFile(segments: segments, scanData: scanBuilder.data)
            }

            // Standalone markers (no length)
            if JPEGMarker.isStandaloneMarker(rawMarker) {
                if let marker = JPEGMarker(rawValue: rawMarker) {
                    segments.append(JPEGSegment(marker: marker, data: Data()))
                }
                continue
            }

            // Regular segment with length
            let length = try reader.readUInt16BigEndian()
            guard length >= 2 else {
                throw MetadataError.invalidSegmentLength
            }
            let payloadSize = Int(length) - 2
            let payload = try reader.readBytes(payloadSize)

            segments.append(JPEGSegment(rawMarker: rawMarker, data: payload))
        }

        // Reached end without SOS or EOI — still return what we have
        return JPEGFile(segments: segments, scanData: Data())
    }
}
