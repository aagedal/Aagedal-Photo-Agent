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

    /// Detect whether an image is natively HDR.
    ///
    /// Adaptive HDR JPEG/HEIF files keep an ordinary SDR profile on their primary
    /// image, so profile inspection alone cannot identify them. This checks both the
    /// transfer curve used by directly encoded HDR images (PQ or HLG) and the ISO /
    /// legacy Apple auxiliary gain-map channels.
    /// All checks inspect container metadata only; primary image pixels are not decoded.
    static func isHDR(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        if let profileName = props?[kCGImagePropertyProfileName as String] as? String {
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
                        if transfer == 16 || transfer == 18 { return true }
                    }
                }
            }
        }

        // Gain-map images deliberately advertise an SDR primary profile. Preflight
        // their JPEG/HEIF container signatures before asking ImageIO for auxiliary
        // data: probing absent auxiliary keys directly emits decoder errors for every
        // ordinary image in a folder scan.
        guard hasGainMapContainerHint(url: url) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap
        ) != nil || CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        ) != nil
    }

    /// Quick container-only preflight for Adaptive HDR and legacy Apple gain maps.
    private static func hasGainMapContainerHint(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        let isJPEGContainer = jpegExtensions.contains(fileExtension)
        guard isJPEGContainer || fileExtension == "heic" || fileExtension == "heif" else {
            return false
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return false
        }

        let gainMapSignatures = [
            Data("AMPF".utf8),
            Data("MPF\0".utf8),
            Data("urn:iso:std:iso:ts:21496".utf8),
            Data("HDRGainMap".utf8),
            Data("hdrgainmap".utf8),
            Data("tmap".utf8)
        ]

        if isJPEGContainer {
            guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
                return false
            }

            // Walk JPEG marker segments until compressed pixel data begins. Gain-map
            // linkage lives in APP0/APP1/APP2, so this doesn't touch the image scan.
            var offset = 2
            while offset + 3 < data.count {
                while offset < data.count, data[offset] == 0xFF {
                    offset += 1
                }
                guard offset < data.count else { return false }
                let marker = data[offset]
                offset += 1

                if marker == 0xDA || marker == 0xD9 { return false } // SOS / EOI
                if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
                guard offset + 1 < data.count else { return false }

                let length = (Int(data[offset]) << 8) | Int(data[offset + 1])
                guard length >= 2, offset + length <= data.count else { return false }
                let payloadStart = offset + 2
                let payloadEnd = min(offset + length, payloadStart + 4_096)
                if marker >= 0xE0, marker <= 0xEF, payloadStart < payloadEnd {
                    let payload = Data(data[payloadStart..<payloadEnd])
                    if gainMapSignatures.contains(where: { payload.range(of: $0) != nil }) {
                        return true
                    }
                }
                offset += length
            }
            return false
        }

        // HEIF item metadata is normally near the start of the container. The
        // signatures only gate the authoritative ImageIO auxiliary-data check above.
        let prefix = Data(data.prefix(min(data.count, 1_048_576)))
        return gainMapSignatures.contains(where: { prefix.range(of: $0) != nil })
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
