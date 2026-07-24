import Foundation
import CoreGraphics

/// Default output format for SDR images
nonisolated enum ExportFormatSDR: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "jpeg"
    case png = "png"
    case tiff = "tiff"
    case heic = "heic"
    case avif = "avif"
    case avifFFmpeg = "avifFFmpeg"
    case jxl = "jxl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        case .avif: return "AVIF (macOS)"
        case .avifFFmpeg: return "AVIF (FFmpeg)"
        case .jxl: return "JPEG XL"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .avif, .avifFFmpeg: return "avif"
        case .jxl: return "jxl"
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .avif, .avifFFmpeg, .jxl: return true
        case .png, .tiff: return false
        }
    }

    var description: String {
        switch self {
        case .jpeg: return "Widely compatible, lossy compression. Best for photos shared online."
        case .png: return "Lossless compression. Larger files, best for graphics or when quality is critical."
        case .tiff: return "Uncompressed or lossless. Very large files, used in print workflows."
        case .heic: return "Modern Apple format with excellent compression. May not be compatible with all software."
        case .avif: return "Native macOS AVIF encoding with embedded color-profile support."
        case .avifFFmpeg: return "AVIF encoded with FFmpeg and libaom for improved compression efficiency."
        case .jxl: return "JPEG XL — excellent quality and compression. Very limited software support currently."
        }
    }
}

/// Default output format for HDR images
nonisolated enum ExportFormatHDR: String, CaseIterable, Identifiable, Sendable {
    case jpegGainMap = "jpegGainMap"
    case heic10bit = "heic10bit"
    case avif10bit = "avif10bit"
    case avifFFmpeg10bit = "avifFFmpeg10bit"
    case jxl = "jxl"
    case tiff16bit = "tiff16bit"
    case png16bit = "png16bit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpegGainMap: return "JPEG (HDR Gain Map)"
        case .heic10bit: return "HEIC (10-bit)"
        case .avif10bit: return "AVIF (macOS, 10-bit)"
        case .avifFFmpeg10bit: return "AVIF (FFmpeg, 10-bit)"
        case .jxl: return "JPEG XL"
        case .tiff16bit: return "TIFF (16-bit)"
        case .png16bit: return "PNG (16-bit)"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpegGainMap: return "jpg"
        case .heic10bit: return "heic"
        case .avif10bit, .avifFFmpeg10bit: return "avif"
        case .jxl: return "jxl"
        case .tiff16bit: return "tiff"
        case .png16bit: return "png"
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .jpegGainMap, .heic10bit, .avif10bit, .avifFFmpeg10bit, .jxl: return true
        case .tiff16bit, .png16bit: return false
        }
    }

    var description: String {
        switch self {
        case .jpegGainMap: return "Adaptive HDR JPEG with an SDR-compatible base image and an ISO HDR gain map. Best compatibility with JPEG workflows."
        case .heic10bit: return "10-bit HEIC preserves HDR data with good compression. Best Apple ecosystem compatibility."
        case .avif10bit: return "Native macOS 10-bit AVIF with embedded HDR color information."
        case .avifFFmpeg10bit: return "10-bit HLG AVIF encoded with FFmpeg and libaom."
        case .jxl: return "JPEG XL supports HDR natively with excellent quality. Very limited software support."
        case .tiff16bit: return "16-bit TIFF preserves full dynamic range. Very large files, best for archival."
        case .png16bit: return "16-bit PNG preserves full dynamic range. Large files, lossless."
        }
    }
}

/// Target color gamut for export
nonisolated enum TargetColorGamut: String, CaseIterable, Identifiable, Sendable {
    case sRGB = "sRGB"
    case displayP3 = "displayP3"
    case rec2020 = "rec2020"
    case adobeRGB = "adobeRGB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .rec2020: return "Rec. 2020"
        case .adobeRGB: return "Adobe RGB"
        }
    }

    var description: String {
        switch self {
        case .sRGB: return "Standard gamut for web and most displays. Widest compatibility."
        case .displayP3: return "Wider gamut used by modern Apple displays. 25% more colors than sRGB."
        case .rec2020: return "Ultra-wide gamut for HDR and cinema workflows. Limited display support."
        case .adobeRGB: return "Wide gamut for print and photography workflows. Common in Adobe software."
        }
    }

    /// Index used in Metal shader params (targetGamut / displayGamut fields).
    var shaderIndex: UInt32 {
        switch self {
        case .sRGB: return 0
        case .displayP3: return 1
        case .rec2020: return 2
        case .adobeRGB: return 3
        }
    }

    /// Color space for integer SDR output (JPEG/PNG/TIFF/HEIC). The embedded ICC profile
    /// lets viewers map the wider gamut instead of clipping to sRGB.
    var sdrColorSpace: CGColorSpace {
        let name: CFString = switch self {
        case .sRGB: CGColorSpace.sRGB
        case .displayP3: CGColorSpace.displayP3
        case .rec2020: CGColorSpace.itur_2020
        case .adobeRGB: CGColorSpace.adobeRGB1998
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// HLG-encoded HDR color space (HEIC 10-bit, PNG 16-bit, FFmpeg HDR intermediate).
    /// HDR requires a transfer function, so gamuts without an HLG variant fall back to
    /// Display P3 HLG (the prior hardcoded default).
    var hdrHLGColorSpace: CGColorSpace {
        let name: CFString = switch self {
        case .rec2020: CGColorSpace.itur_2100_HLG
        case .displayP3, .sRGB, .adobeRGB: CGColorSpace.displayP3_HLG
        }
        return CGColorSpace(name: name) ?? CGColorSpace(name: CGColorSpace.displayP3)!
    }

    /// Extended-linear (half-float) HDR color space for gain-map JPEG and TIFF 16-bit output.
    /// Adobe RGB has no extended-linear variant, so it falls back to extended-linear Display P3.
    var hdrLinearColorSpace: CGColorSpace {
        let name: CFString = switch self {
        case .sRGB: CGColorSpace.extendedLinearSRGB
        case .displayP3, .adobeRGB: CGColorSpace.extendedLinearDisplayP3
        case .rec2020: CGColorSpace.extendedLinearITUR_2020
        }
        return CGColorSpace(name: name) ?? CGColorSpace(name: CGColorSpace.displayP3)!
    }
}

/// TIFF compression method
nonisolated enum TIFFCompression: String, CaseIterable, Identifiable, Sendable {
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
