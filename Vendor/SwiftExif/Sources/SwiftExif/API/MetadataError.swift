import Foundation

public enum MetadataError: LocalizedError, Sendable, CustomStringConvertible {
    case notAJPEG
    case unexpectedEndOfData
    case invalidSegmentLength
    case invalidMarker(UInt8)
    case invalidPhotoshopHeader
    case invalid8BIMBlock
    case invalidIPTCData(String)
    case invalidTIFFHeader
    case invalidIFDEntry
    case unsupportedExifType(UInt16)
    case invalidXMP(String)
    case encodingError(String)
    case fileNotFound(String)
    case fileWriteError(String)
    case dataExceedsMaxLength(tag: String, max: Int, actual: Int)
    case unsupportedFormat
    /// Refused an attempt to embed metadata into a proprietary TIFF-based RAW
    /// (e.g. Sony ARW, Nikon NEF). Rewriting these containers cannot preserve
    /// maker-private structures such as Sony's encrypted SR2Private white-balance
    /// block, so the write would corrupt the file. Write metadata to an XMP
    /// sidecar instead, or pass `WriteOptions.allowUnsafeRawEmbed` to override.
    case rawWriteUnsupported(ImageFormat.RawFormat)
    case invalidPNG(String)
    case invalidJPEGXL(String)
    case invalidAVIF(String)
    case invalidHEIF(String)
    case invalidTIFFFile(String)
    case invalidRAW(String)
    case crcMismatch(expected: UInt32, actual: UInt32)
    case invalidCBOR(String)
    case invalidJUMBF(String)
    case invalidC2PA(String)
    case writeNotSupported(String)
    case invalidGPX(String)
    case invalidMakerNote(String)
    case invalidWebP(String)
    case invalidCR3(String)
    case invalidVideo(String)
    case invalidPDF(String)
    case invalidPSD(String)
    case invalidGIF(String)
    case invalidBMP(String)
    case invalidSVG(String)
    case invalidMP3(String)
    case invalidFLAC(String)
    case invalidAAE(String)
    case invalidWAV(String)
    case invalidAIFF(String)

    public var description: String {
        switch self {
        case .notAJPEG:
            return "Not a valid JPEG file (missing SOI marker)"
        case .unexpectedEndOfData:
            return "Unexpected end of data"
        case .invalidSegmentLength:
            return "Invalid JPEG segment length"
        case .invalidMarker(let byte):
            return "Invalid JPEG marker: 0x\(String(byte, radix: 16, uppercase: true))"
        case .invalidPhotoshopHeader:
            return "Invalid Photoshop 3.0 header in APP13"
        case .invalid8BIMBlock:
            return "Invalid 8BIM resource block"
        case .invalidIPTCData(let detail):
            return "Invalid IPTC data: \(detail)"
        case .invalidTIFFHeader:
            return "Invalid TIFF header"
        case .invalidIFDEntry:
            return "Invalid IFD entry"
        case .unsupportedExifType(let type):
            return "Unsupported Exif data type: \(type)"
        case .invalidXMP(let detail):
            return "Invalid XMP data: \(detail)"
        case .encodingError(let detail):
            return "Encoding error: \(detail)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileWriteError(let detail):
            return "File write error: \(detail)"
        case .dataExceedsMaxLength(let tag, let max, let actual):
            return "Data for \(tag) exceeds max length (\(actual) > \(max))"
        case .unsupportedFormat:
            return "Unsupported image format"
        case .rawWriteUnsupported(let format):
            return "Refusing to embed metadata into proprietary RAW (.\(format.rawValue)) — rewriting it would corrupt maker-private data (e.g. Sony SR2Private). Use an XMP sidecar, or pass WriteOptions.allowUnsafeRawEmbed to override."
        case .invalidPNG(let detail):
            return "Invalid PNG: \(detail)"
        case .invalidJPEGXL(let detail):
            return "Invalid JPEG XL: \(detail)"
        case .invalidAVIF(let detail):
            return "Invalid AVIF: \(detail)"
        case .invalidHEIF(let detail):
            return "Invalid HEIF: \(detail)"
        case .invalidTIFFFile(let detail):
            return "Invalid TIFF file: \(detail)"
        case .invalidRAW(let detail):
            return "Invalid RAW file: \(detail)"
        case .crcMismatch(let expected, let actual):
            return "CRC32 mismatch: expected 0x\(String(expected, radix: 16)), got 0x\(String(actual, radix: 16))"
        case .invalidCBOR(let detail):
            return "Invalid CBOR data: \(detail)"
        case .invalidJUMBF(let detail):
            return "Invalid JUMBF data: \(detail)"
        case .invalidC2PA(let detail):
            return "Invalid C2PA data: \(detail)"
        case .writeNotSupported(let detail):
            return "Write not supported: \(detail)"
        case .invalidGPX(let detail):
            return "Invalid GPX data: \(detail)"
        case .invalidMakerNote(let detail):
            return "Invalid MakerNote: \(detail)"
        case .invalidWebP(let detail):
            return "Invalid WebP file: \(detail)"
        case .invalidCR3(let detail):
            return "Invalid CR3 file: \(detail)"
        case .invalidVideo(let detail):
            return "Invalid video file: \(detail)"
        case .invalidPDF(let detail):
            return "Invalid PDF file: \(detail)"
        case .invalidPSD(let detail):
            return "Invalid PSD file: \(detail)"
        case .invalidGIF(let detail):
            return "Invalid GIF file: \(detail)"
        case .invalidBMP(let detail):
            return "Invalid BMP file: \(detail)"
        case .invalidSVG(let detail):
            return "Invalid SVG file: \(detail)"
        case .invalidMP3(let detail):
            return "Invalid MP3 file: \(detail)"
        case .invalidFLAC(let detail):
            return "Invalid FLAC file: \(detail)"
        case .invalidAAE(let detail):
            return "Invalid AAE sidecar: \(detail)"
        case .invalidWAV(let detail):
            return "Invalid WAV / BWF file: \(detail)"
        case .invalidAIFF(let detail):
            return "Invalid AIFF file: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
