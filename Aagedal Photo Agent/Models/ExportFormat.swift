import Foundation

/// Default output format for SDR images
nonisolated enum ExportFormatSDR: String, CaseIterable, Identifiable {
    case jpeg = "jpeg"
    case png = "png"
    case tiff = "tiff"
    case heic = "heic"
    case avif = "avif"
    case jxl = "jxl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .jxl: return "JPEG XL"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .avif: return "avif"
        case .jxl: return "jxl"
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .jxl: return true
        case .png, .tiff: return false
        }
    }

    var description: String {
        switch self {
        case .jpeg: return "Widely compatible, lossy compression. Best for photos shared online."
        case .png: return "Lossless compression. Larger files, best for graphics or when quality is critical."
        case .tiff: return "Uncompressed or lossless. Very large files, used in print workflows."
        case .heic: return "Modern Apple format with excellent compression. May not be compatible with all software."
        case .avif: return "Next-gen format based on AV1. Excellent compression, limited software support."
        case .jxl: return "JPEG XL — excellent quality and compression. Very limited software support currently."
        }
    }
}

/// Default output format for HDR images
nonisolated enum ExportFormatHDR: String, CaseIterable, Identifiable {
    case heic10bit = "heic10bit"
    case avif10bit = "avif10bit"
    case jxl = "jxl"
    case tiff16bit = "tiff16bit"
    case png16bit = "png16bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heic10bit: return "HEIC (10-bit)"
        case .avif10bit: return "AVIF (10-bit)"
        case .jxl: return "JPEG XL"
        case .tiff16bit: return "TIFF (16-bit)"
        case .png16bit: return "PNG (16-bit)"
        }
    }

    var fileExtension: String {
        switch self {
        case .heic10bit: return "heic"
        case .avif10bit: return "avif"
        case .jxl: return "jxl"
        case .tiff16bit: return "tiff"
        case .png16bit: return "png"
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .heic10bit, .avif10bit, .jxl: return true
        case .tiff16bit, .png16bit: return false
        }
    }

    var description: String {
        switch self {
        case .heic10bit: return "10-bit HEIC preserves HDR data with good compression. Best Apple ecosystem compatibility."
        case .avif10bit: return "10-bit AVIF with HDR support. Excellent compression, limited software support."
        case .jxl: return "JPEG XL supports HDR natively with excellent quality. Very limited software support."
        case .tiff16bit: return "16-bit TIFF preserves full dynamic range. Very large files, best for archival."
        case .png16bit: return "16-bit PNG preserves full dynamic range. Large files, lossless."
        }
    }
}

/// TIFF compression method
nonisolated enum TIFFCompression: String, CaseIterable, Identifiable {
    case none = "none"
    case lzw = "lzw"
    case zip = "zip"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .lzw: return "LZW"
        case .zip: return "ZIP"
        }
    }

    var description: String {
        switch self {
        case .none: return "No compression. Largest files, fastest processing."
        case .lzw: return "Lossless LZW compression. Good balance of size and compatibility."
        case .zip: return "Lossless ZIP/Deflate compression. Slightly better compression than LZW."
        }
    }
}
