import Foundation

/// Supported image file formats.
public enum ImageFormat: Sendable, Equatable {
    case jpeg
    case tiff
    case raw(RawFormat)
    case jpegXL
    case png
    case avif
    case heif
    case webp
    case pdf
    case psd
    case gif
    case bmp
    case svg

    /// RAW camera formats. Most are TIFF-based; CR3 is ISOBMFF-based; X3F is fully proprietary.
    public enum RawFormat: String, Sendable, CaseIterable, Equatable {
        case dng, cr2, cr3, nef, nrw, arw, raf, rw2, orf, pef, srw, raw
        /// Phase One IIQ — has a custom 8-byte header before the TIFF magic.
        case iiq
        /// Hasselblad 3FR (compressed-sensor) — TIFF-based.
        case threefr = "3fr"
        /// Hasselblad FFF (Phocus internal) — TIFF-based.
        case fff
        /// Sigma X3F — fully proprietary container, "FOVb" magic.
        case x3f
        /// Minolta MRW — `\0MRM` (or `\0MRI`) header followed by TIFF/Exif IFD.
        case mrw
        /// GoPro GPR — a DNG-compatible (TIFF-based) container using VC-5 compression.
        /// Distinguished from generic DNG by the `.gpr` extension or a GoPro Make.
        case gpr
    }
}
