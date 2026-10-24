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

    nonisolated static let fileExtensions = MCPPhotoFormatCatalog.fileExtensions

    nonisolated static let rawExtensions = MCPPhotoFormatCatalog.rawExtensions

    /// Ordered RAW extensions for deterministic sibling pairing.
    static let orderedRawExtensions: [String] = [
        "cr3", "cr2", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw", "raw",
    ]

    nonisolated static let jpegExtensions: Set<String> = [
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
    nonisolated static func isHDR(url: URL) -> Bool {
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
    nonisolated private static func hasGainMapContainerHint(url: URL) -> Bool {
        gainMapContainerHintProbe(url: url).hasHint
    }

    /// Result of the gain-map container preflight. `bytesRead` exists so tests can
    /// prove the probe never pulls whole files off SD cards / network volumes.
    nonisolated struct GainMapContainerHintProbeResult: Equatable, Sendable {
        let hasHint: Bool
        let bytesRead: Int
    }

    /// Maximum HEIF prefix inspected for gain-map item signatures.
    nonisolated static let heifGainMapHintPrefixLimit = 1_048_576

    /// Bounded-I/O preflight. JPEGs are walked segment by segment (only marker
    /// headers plus at most 4 KB of each APP payload are read, stopping at SOS);
    /// HEIF reads only its first `heifGainMapHintPrefixLimit` bytes.
    ///
    /// This deliberately avoids `Data(contentsOf:options:.mappedIfSafe)`: off the
    /// boot volume (SD cards, NAS, DMGs) Foundation refuses to map and reads the
    /// entire file instead, which at folder open meant reading every photo in full.
    nonisolated static func gainMapContainerHintProbe(url: URL) -> GainMapContainerHintProbeResult {
        let fileExtension = url.pathExtension.lowercased()
        let isJPEGContainer = jpegExtensions.contains(fileExtension)
        guard isJPEGContainer || fileExtension == "heic" || fileExtension == "heif" else {
            return GainMapContainerHintProbeResult(hasHint: false, bytesRead: 0)
        }
        guard let reader = BoundedFileReader(url: url) else {
            return GainMapContainerHintProbeResult(hasHint: false, bytesRead: 0)
        }
        defer { reader.close() }

        let gainMapSignatures = [
            Data("AMPF".utf8),
            Data("MPF\0".utf8),
            Data("urn:iso:std:iso:ts:21496".utf8),
            Data("HDRGainMap".utf8),
            Data("hdrgainmap".utf8),
            Data("tmap".utf8)
        ]

        if isJPEGContainer {
            let hint = jpegHasGainMapSegment(reader: reader, signatures: gainMapSignatures)
            return GainMapContainerHintProbeResult(hasHint: hint, bytesRead: reader.bytesRead)
        }

        // HEIF item metadata is normally near the start of the container. The
        // signatures only gate the authoritative ImageIO auxiliary-data check above.
        let prefix = reader.bytes(in: 0..<min(reader.fileSize, heifGainMapHintPrefixLimit)) ?? Data()
        let hint = gainMapSignatures.contains(where: { prefix.range(of: $0) != nil })
        return GainMapContainerHintProbeResult(hasHint: hint, bytesRead: reader.bytesRead)
    }

    nonisolated private static func jpegHasGainMapSegment(
        reader: BoundedFileReader,
        signatures: [Data]
    ) -> Bool {
        let size = reader.fileSize
        guard size >= 4, reader.byte(at: 0) == 0xFF, reader.byte(at: 1) == 0xD8 else {
            return false
        }

        // Walk JPEG marker segments until compressed pixel data begins. Gain-map
        // linkage lives in APP0/APP1/APP2, so this doesn't touch the image scan.
        var offset = 2
        while offset + 3 < size {
            while offset < size, reader.byte(at: offset) == 0xFF {
                offset += 1
            }
            guard offset < size, let marker = reader.byte(at: offset) else { return false }
            offset += 1

            if marker == 0xDA || marker == 0xD9 { return false } // SOS / EOI
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            guard offset + 1 < size,
                  let high = reader.byte(at: offset),
                  let low = reader.byte(at: offset + 1) else { return false }

            let length = (Int(high) << 8) | Int(low)
            guard length >= 2, offset + length <= size else { return false }
            let payloadStart = offset + 2
            let payloadEnd = min(offset + length, payloadStart + 4_096)
            if marker >= 0xE0, marker <= 0xEF, payloadStart < payloadEnd {
                guard let payload = reader.bytes(in: payloadStart..<payloadEnd) else { return false }
                if signatures.contains(where: { payload.range(of: $0) != nil }) {
                    return true
                }
            }
            offset += length
        }
        return false
    }

    /// Small windowed reader: keeps one chunk in memory and seeks past skipped
    /// regions instead of reading them, so total I/O tracks what is inspected.
    private nonisolated final class BoundedFileReader {
        private static let chunkSize = 65_536

        private let handle: FileHandle
        let fileSize: Int
        private(set) var bytesRead = 0
        private var windowStart = 0
        private var window = Data()

        init?(url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            guard let end = try? handle.seekToEnd() else {
                try? handle.close()
                return nil
            }
            self.handle = handle
            self.fileSize = Int(clamping: end)
        }

        func close() {
            try? handle.close()
        }

        func byte(at offset: Int) -> UInt8? {
            guard offset >= 0, offset < fileSize else { return nil }
            if !windowContains(offset..<(offset + 1)) {
                load(from: offset, minimumCount: 1)
            }
            let index = offset - windowStart
            guard index >= 0, index < window.count else { return nil }
            return window[window.startIndex + index]
        }

        func bytes(in range: Range<Int>) -> Data? {
            guard range.lowerBound >= 0, range.upperBound <= fileSize else { return nil }
            if range.isEmpty { return Data() }
            if !windowContains(range) {
                load(from: range.lowerBound, minimumCount: range.count)
            }
            guard windowContains(range) else { return nil }
            let lower = window.startIndex + (range.lowerBound - windowStart)
            return Data(window[lower..<(lower + range.count)])
        }

        private func windowContains(_ range: Range<Int>) -> Bool {
            range.lowerBound >= windowStart && range.upperBound <= windowStart + window.count
        }

        private func load(from offset: Int, minimumCount: Int) {
            let count = min(max(Self.chunkSize, minimumCount), fileSize - offset)
            windowStart = offset
            window = Data()
            guard count > 0 else { return }
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                bytesRead += data.count
                window = data
            } catch {
                window = Data()
            }
        }
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
