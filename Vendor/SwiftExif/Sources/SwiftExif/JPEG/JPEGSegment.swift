import Foundation

/// A single JPEG segment (marker + payload data).
public struct JPEGSegment: Sendable {
    /// The marker identifying this segment type.
    public let marker: JPEGMarker

    /// The raw marker value (used when marker is not a known enum case).
    public let rawMarker: UInt16

    /// Segment payload (excluding the marker and length bytes).
    public var data: Data

    public init(marker: JPEGMarker, data: Data = Data()) {
        self.marker = marker
        self.rawMarker = marker.rawValue
        self.data = data
    }

    public init(rawMarker: UInt16, data: Data = Data()) {
        self.rawMarker = rawMarker
        self.marker = JPEGMarker(rawValue: rawMarker) ?? .app0
        self.data = data
    }

    /// Total size this segment occupies in the file:
    /// 2 (marker) + 2 (length) + data.count
    public var totalLength: Int {
        if marker.isStandalone {
            return 2
        }
        return 2 + 2 + data.count
    }
}

// MARK: - APP Segment Identifiers

extension JPEGSegment {
    /// The Exif identifier at the start of an Exif APP1 segment.
    public static let exifIdentifier = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"

    /// The XMP identifier at the start of an XMP APP1 segment.
    public static let xmpIdentifier = "http://ns.adobe.com/xap/1.0/\0".data(using: .ascii)!

    /// The ICC profile identifier at the start of an ICC APP2 segment.
    public static let iccProfileIdentifier = "ICC_PROFILE\0".data(using: .ascii)!

    /// The Photoshop identifier at the start of an IPTC APP13 segment.
    public static let photoshopIdentifier = "Photoshop 3.0\0".data(using: .ascii)!

    /// The MPF identifier at the start of an MPF APP2 segment ("MPF\0").
    public static let mpfIdentifier = MPFParser.mpfIdentifier

    /// Whether this is an Exif APP1 segment.
    public var isExif: Bool {
        rawMarker == JPEGMarker.app1.rawValue && data.starts(with: JPEGSegment.exifIdentifier)
    }

    /// Whether this is an XMP APP1 segment.
    public var isXMP: Bool {
        rawMarker == JPEGMarker.app1.rawValue && data.starts(with: JPEGSegment.xmpIdentifier)
    }

    /// Whether this is an ICC profile APP2 segment.
    public var isICCProfile: Bool {
        rawMarker == JPEGMarker.app2.rawValue && data.starts(with: JPEGSegment.iccProfileIdentifier)
    }

    /// Whether this is a Photoshop/IPTC APP13 segment.
    public var isPhotoshop: Bool {
        rawMarker == JPEGMarker.app13.rawValue && data.starts(with: JPEGSegment.photoshopIdentifier)
    }

    /// Whether this is an MPF (Multi-Picture Format) APP2 segment.
    public var isMPF: Bool {
        rawMarker == JPEGMarker.app2.rawValue && data.starts(with: JPEGSegment.mpfIdentifier)
    }
}
