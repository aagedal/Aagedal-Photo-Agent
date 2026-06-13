import UniformTypeIdentifiers
import ImageIO
import CoreGraphics

enum SupportedImageFormats {
    static let all: Set<UTType> = [
        .jpeg,
        .png,
        .tiff,
        .heic,
        .heif,
        .rawImage,
        .bmp,
        .gif,
        .webP,
        UTType("public.avif") ?? .image,
        UTType("public.jxl") ?? .image,
        UTType("com.adobe.raw-image") ?? .rawImage,
        UTType("com.canon.cr2-raw-image") ?? .rawImage,
        UTType("com.canon.cr3-raw-image") ?? .rawImage,
        UTType("com.nikon.nrw-raw-image") ?? .rawImage,
        UTType("com.nikon.raw-image") ?? .rawImage,
        UTType("com.sony.arw-raw-image") ?? .rawImage,
        UTType("com.fuji.raw-image") ?? .rawImage,
        UTType("com.adobe.dng-raw-image") ?? .rawImage,
        UTType("com.panasonic.rw2-raw-image") ?? .rawImage,
        UTType("com.olympus.raw-image") ?? .rawImage,
    ]

    nonisolated static let fileExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif",
        "bmp", "gif", "webp", "avif", "jxl",
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw",
    ]

    nonisolated static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw",
    ]

    /// Ordered RAW extensions for deterministic sibling pairing.
    static let orderedRawExtensions: [String] = [
        "cr3", "cr2", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw", "raw",
    ]

    static let jpegExtensions: Set<String> = [
        "jpg", "jpeg",
    ]

    nonisolated static func isSupported(url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isRaw(url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    static func isJPEG(url: URL) -> Bool {
        jpegExtensions.contains(url.pathExtension.lowercased())
    }

    /// Detect whether an image file has an HDR transfer curve (PQ or HLG).
    /// Uses CGImageSource metadata-only read (no pixel decode) — very fast.
    static func isHDR(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        guard let profileName = props?[kCGImagePropertyProfileName as String] as? String else { return false }
        // CICP/NCLX profile strings contain transfer function codes:
        // transfer 16 = PQ (Perceptual Quantizer), transfer 18 = HLG (Hybrid Log-Gamma)
        // Profile names like "QuickTime 'nclc' Video (9,16,9)" or "ITUR_2100_PQ"
        let lowered = profileName.lowercased()
        if lowered.contains("pq") || lowered.contains("hlg") { return true }
        // Parse CICP tuple for transfer code
        if profileName.contains("nclc") || profileName.contains("nclx") {
            if let range = profileName.range(of: #"\((\d+),(\d+),(\d+)\)"#, options: .regularExpression) {
                let match = String(profileName[range]).dropFirst().dropLast()
                let codes = match.split(separator: ",").compactMap { Int($0) }
                if codes.count >= 2 {
                    let transfer = codes[1]
                    return transfer == 16 || transfer == 18  // PQ or HLG
                }
            }
        }
        return false
    }

    static func preferredRawSibling(for nonRawURL: URL) -> (url: URL, hadMultipleMatches: Bool)? {
        guard !isRaw(url: nonRawURL) else { return (nonRawURL, false) }

        let folder = nonRawURL.deletingLastPathComponent()
        let basename = nonRawURL.deletingPathExtension().lastPathComponent
        let fm = FileManager.default

        var matches: [URL] = []
        for ext in orderedRawExtensions {
            let candidate = folder.appendingPathComponent("\(basename).\(ext)")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                matches.append(candidate)
            }
        }

        guard let first = matches.first else { return nil }
        return (first, matches.count > 1)
    }
}
