import Foundation

/// Derive ffprobe-style `pix_fmt` strings from the container-reported codec,
/// bit depth, chroma subsampling and color range. The goal is to match the
/// strings `ffprobe -show_streams` emits closely enough that downstream
/// consumers (e.g. Aagedal Media Converter) can treat them as a drop-in
/// replacement for the ffprobe field.
///
/// Coverage is intentionally limited to the common YUV/RGB planar formats
/// that ship in the codecs SwiftExif recognises. Rare endian/interleave
/// variants (NV12, packed YUYV, p010le …) aren't synthesised here — the
/// container doesn't usually tell us the difference anyway.
enum PixelFormatDerivation {

    /// Produce a ffprobe-compatible `pix_fmt` label, or `nil` if the inputs
    /// don't narrow down to a single common format.
    ///
    /// - Parameters:
    ///   - chromaSubsampling: "4:0:0", "4:2:0", "4:2:2", "4:4:4" (or nil).
    ///   - bitDepth: bits per luma sample (8/10/12/16).
    ///   - fullRange: JPEG/PC full-range flag from the container's colr box or
    ///     Matroska Colour.Range element.
    ///   - codec: container-reported codec identifier (optional — used only to
    ///     distinguish RGB-native codecs from YUV).
    static func derive(
        chromaSubsampling: String?,
        bitDepth: Int?,
        fullRange: Bool?,
        codec: String?
    ) -> String? {
        guard let chroma = chromaSubsampling else { return nil }

        // Bit depth defaults to 8 when the container doesn't spell one out —
        // the vast majority of codecs we surface are 8-bit and ffprobe would
        // report the 8-bit label for them anyway.
        let depth = bitDepth ?? 8

        // Monochrome — ffprobe spells this out per bit-depth.
        if chroma == "4:0:0" {
            switch depth {
            case 8: return "gray"
            case 10: return "gray10le"
            case 12: return "gray12le"
            case 16: return "gray16le"
            default: return "gray"
            }
        }

        // Full-range YUV for 8-bit 4:2:0/4:2:2/4:4:4 gets the `yuvjXXXp` label
        // (ffprobe's MJPEG path; matches yuvj420p/yuvj422p/yuvj444p). Other
        // depths ffprobe leaves as plain yuv420p + a separate color_range flag.
        let suffix: String
        switch chroma {
        case "4:2:0": suffix = "420p"
        case "4:2:2": suffix = "422p"
        case "4:4:4": suffix = "444p"
        default: return nil
        }

        let base: String
        if depth == 8, fullRange == true,
           chroma == "4:2:0" || chroma == "4:2:2" || chroma == "4:4:4" {
            base = "yuvj\(suffix)"
        } else {
            base = "yuv\(suffix)"
        }

        if depth == 8 {
            return base
        }
        return "\(base)\(depth)le"
    }
}
