import Foundation

/// Represents a parsed JPEG file: metadata segments + opaque scan data.
public struct JPEGFile: Sendable {
    /// All segments before SOS (metadata, quantization tables, etc.).
    public var segments: [JPEGSegment]

    /// Raw bytes from SOS marker through EOI (inclusive).
    /// This is preserved verbatim to maintain image data integrity.
    public var scanData: Data

    public init(segments: [JPEGSegment] = [], scanData: Data = Data()) {
        self.segments = segments
        self.scanData = scanData
    }

    // MARK: - Segment Lookup

    /// Find the first segment with the given marker.
    public func findSegment(_ marker: JPEGMarker) -> JPEGSegment? {
        segments.first { $0.rawMarker == marker.rawValue }
    }

    /// Find all segments with the given marker.
    public func findSegments(_ marker: JPEGMarker) -> [JPEGSegment] {
        segments.filter { $0.rawMarker == marker.rawValue }
    }

    /// Find the Exif APP1 segment (identified by "Exif\0\0" prefix).
    public func exifSegment() -> JPEGSegment? {
        segments.first { $0.isExif }
    }

    /// Find the XMP APP1 segment (identified by XMP namespace prefix).
    public func xmpSegment() -> JPEGSegment? {
        segments.first { $0.isXMP }
    }

    /// Find all ICC profile APP2 segments.
    public func iccProfileSegments() -> [JPEGSegment] {
        segments.filter { $0.isICCProfile }
    }

    /// Find the MPF (Multi-Picture Format) APP2 segment, if present.
    /// MPF carries Apple Live Photo aux frames, Sony multi-shot, and stereo JPEGs.
    public func mpfSegment() -> JPEGSegment? {
        segments.first { $0.isMPF }
    }

    /// Find the Photoshop/IPTC APP13 segment.
    public func iptcSegment() -> JPEGSegment? {
        segments.first { $0.isPhotoshop }
    }

    /// Image dimensions read from the SOF (Start Of Frame) marker.
    /// SOF carries the canonical pixel dimensions of the encoded JPEG, which
    /// don't always match Exif's ImageWidth/PixelXDimension when the file was
    /// edited or cropped after metadata was written. Returns nil if no SOF is
    /// present or its payload is too short.
    public var imageDimensions: (width: Int, height: Int)? {
        // All SOF markers (FFC0-FFCF) except DHT (FFC4) and JPG (FFC8).
        let sofMarkers: Set<UInt16> = [
            0xFFC0, 0xFFC1, 0xFFC2, 0xFFC3,
            0xFFC5, 0xFFC6, 0xFFC7,
            0xFFC9, 0xFFCA, 0xFFCB,
            0xFFCD, 0xFFCE, 0xFFCF,
        ]
        guard let sof = segments.first(where: { sofMarkers.contains($0.rawMarker) }),
              sof.data.count >= 5 else { return nil }
        // Payload: 1 byte precision, 2 bytes height, 2 bytes width (big-endian).
        let bytes = [UInt8](sof.data)
        let height = (Int(bytes[1]) << 8) | Int(bytes[2])
        let width  = (Int(bytes[3]) << 8) | Int(bytes[4])
        return (width, height)
    }

    // MARK: - Segment Mutation

    /// Replace the first segment matching the marker with a new segment.
    public mutating func replaceSegment(_ marker: JPEGMarker, with segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.rawMarker == marker.rawValue }) {
            segments[index] = segment
        }
    }

    /// Replace or add a Photoshop/IPTC APP13 segment.
    public mutating func replaceOrAddIPTCSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isPhotoshop }) {
            segments[index] = segment
        } else {
            insertSegment(segment, after: .app1)
        }
    }

    /// Replace or add an Exif APP1 segment.
    public mutating func replaceOrAddExifSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isExif }) {
            segments[index] = segment
        } else {
            // Insert after APP0 if present, otherwise at the beginning
            if let app0Index = segments.firstIndex(where: { $0.rawMarker == JPEGMarker.app0.rawValue }) {
                segments.insert(segment, at: app0Index + 1)
            } else {
                segments.insert(segment, at: 0)
            }
        }
    }

    /// Replace or add an XMP APP1 segment.
    public mutating func replaceOrAddXMPSegment(_ segment: JPEGSegment) {
        if let index = segments.firstIndex(where: { $0.isXMP }) {
            segments[index] = segment
        } else {
            // Insert after Exif APP1 if present
            if let exifIndex = segments.firstIndex(where: { $0.isExif }) {
                segments.insert(segment, at: exifIndex + 1)
            } else {
                insertSegment(segment, after: .app0)
            }
        }
    }

    /// Insert a segment after the last occurrence of the given marker.
    /// If the marker is not found, appends to the end.
    public mutating func insertSegment(_ segment: JPEGSegment, after marker: JPEGMarker) {
        if let index = segments.lastIndex(where: { $0.rawMarker == marker.rawValue }) {
            segments.insert(segment, at: index + 1)
        } else {
            segments.append(segment)
        }
    }

    /// Replace or add ICC profile APP2 segments.
    /// Chunks the profile data into segments of up to 65519 bytes each.
    public mutating func replaceOrAddICCProfileSegments(_ profileData: Data) {
        // Remove existing ICC profile segments
        segments.removeAll { $0.isICCProfile }

        // ICC_PROFILE header: 12 bytes identifier + 1 byte chunk number + 1 byte total chunks = 14 bytes
        let maxPayload = 65533 - 14 // 65519 bytes of profile data per segment
        let totalChunks = max(1, (profileData.count + maxPayload - 1) / maxPayload)

        var offset = 0
        for i in 0..<totalChunks {
            let chunkSize = min(maxPayload, profileData.count - offset)
            var segmentData = JPEGSegment.iccProfileIdentifier // 12 bytes
            segmentData.append(UInt8(i + 1))                    // chunk number (1-based)
            segmentData.append(UInt8(totalChunks))              // total chunks
            segmentData.append(profileData[profileData.startIndex + offset ..< profileData.startIndex + offset + chunkSize])
            offset += chunkSize

            let segment = JPEGSegment(marker: .app2, data: segmentData)
            // Insert after APP1 segments
            if let lastApp1 = segments.lastIndex(where: { $0.rawMarker == JPEGMarker.app1.rawValue }) {
                segments.insert(segment, at: lastApp1 + 1)
            } else {
                insertSegment(segment, after: .app0)
            }
        }
    }

    /// Remove all segments with the given marker.
    public mutating func removeSegments(_ marker: JPEGMarker) {
        segments.removeAll { $0.rawMarker == marker.rawValue }
    }
}
