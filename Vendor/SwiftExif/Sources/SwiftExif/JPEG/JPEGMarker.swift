import Foundation

/// JPEG marker identifiers (2-byte codes starting with 0xFF).
public enum JPEGMarker: UInt16, Sendable {
    case soi   = 0xFFD8  // Start of Image
    case eoi   = 0xFFD9  // End of Image
    case sos   = 0xFFDA  // Start of Scan
    case app0  = 0xFFE0  // JFIF
    case app1  = 0xFFE1  // Exif / XMP
    case app2  = 0xFFE2  // ICC Profile
    case app3  = 0xFFE3
    case app4  = 0xFFE4
    case app5  = 0xFFE5
    case app6  = 0xFFE6
    case app7  = 0xFFE7
    case app8  = 0xFFE8
    case app9  = 0xFFE9
    case app10 = 0xFFEA
    case app11 = 0xFFEB
    case app12 = 0xFFEC
    case app13 = 0xFFED  // Photoshop / IPTC
    case app14 = 0xFFEE  // Adobe
    case app15 = 0xFFEF
    case dqt   = 0xFFDB  // Quantization table
    case dht   = 0xFFC4  // Huffman table
    case sof0  = 0xFFC0  // Start of Frame (baseline)
    case sof1  = 0xFFC1  // Start of Frame (extended sequential)
    case sof2  = 0xFFC2  // Start of Frame (progressive)
    case sof3  = 0xFFC3  // Start of Frame (lossless)
    case dri   = 0xFFDD  // Restart interval
    case rst0  = 0xFFD0  // Restart marker 0
    case rst1  = 0xFFD1
    case rst2  = 0xFFD2
    case rst3  = 0xFFD3
    case rst4  = 0xFFD4
    case rst5  = 0xFFD5
    case rst6  = 0xFFD6
    case rst7  = 0xFFD7  // Restart marker 7
    case com   = 0xFFFE  // Comment

    /// Whether this marker has an associated length field.
    /// SOI, EOI, and RST markers are standalone (no length).
    public var hasLength: Bool {
        switch self {
        case .soi, .eoi, .rst0, .rst1, .rst2, .rst3, .rst4, .rst5, .rst6, .rst7:
            return false
        default:
            return true
        }
    }

    /// Whether this is a standalone marker (no length, no data).
    public var isStandalone: Bool {
        !hasLength
    }

    /// Check if a raw UInt16 is a standalone marker (for parsing unknown markers).
    public static func isStandaloneMarker(_ raw: UInt16) -> Bool {
        let byte = UInt8(raw & 0xFF)
        // SOI (0xD8), EOI (0xD9), RST0-RST7 (0xD0-0xD7), TEM (0x01)
        return byte == 0xD8 || byte == 0xD9 || (byte >= 0xD0 && byte <= 0xD7) || byte == 0x01
    }
}
