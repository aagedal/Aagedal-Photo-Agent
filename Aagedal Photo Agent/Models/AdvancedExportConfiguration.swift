import Foundation

/// Caps the exported image's longest edge while preserving its aspect ratio.
/// A cap never enlarges an image that is already smaller.
nonisolated enum ExportResolutionLimit: String, CaseIterable, Identifiable, Sendable {
    case original
    case pixels6000
    case pixels4000
    case pixels3000
    case pixels2048
    case pixels1600

    var id: String { rawValue }

    var maximumPixelSize: Int? {
        switch self {
        case .original: nil
        case .pixels6000: 6_000
        case .pixels4000: 4_000
        case .pixels3000: 3_000
        case .pixels2048: 2_048
        case .pixels1600: 1_600
        }
    }

    var displayName: String {
        guard let maximumPixelSize else { return "Original" }
        return "\(maximumPixelSize.formatted()) px"
    }
}

/// A stable snapshot of the pixel-affecting choices used by the advanced export
/// preview. The ordinary renderer still reads the persisted defaults; advanced
/// export applies this snapshot immediately before handing the queue to it.
nonisolated struct AdvancedExportConfiguration: Equatable, Sendable {
    static let minimumQuality = 0.10

    var sdrFormat: ExportFormatSDR
    var sdrQuality: Double
    var sdrGamut: TargetColorGamut
    var hdrFormat: ExportFormatHDR
    var hdrQuality: Double
    var hdrGamut: TargetColorGamut
    var tiffCompression: TIFFCompression
    var resolutionLimit: ExportResolutionLimit
    var locationMode: ExportLocationMode
    var customSubfolderName: String

    func previewSignature(isHDR: Bool) -> String {
        if isHDR {
            return [
                "hdr",
                hdrFormat.rawValue,
                String(format: "%.4f", hdrQuality),
                hdrGamut.rawValue,
                tiffCompression.rawValue,
                resolutionLimit.rawValue
            ].joined(separator: "|")
        }
        return [
            "sdr",
            sdrFormat.rawValue,
            String(format: "%.4f", sdrQuality),
            sdrGamut.rawValue,
            tiffCompression.rawValue,
            resolutionLimit.rawValue
        ].joined(separator: "|")
    }

    func formatName(isHDR: Bool) -> String {
        isHDR ? hdrFormat.displayName : sdrFormat.displayName
    }

    func quality(isHDR: Bool) -> Double? {
        if isHDR {
            return hdrFormat.supportsQuality ? hdrQuality : nil
        }
        return sdrFormat.supportsQuality ? sdrQuality : nil
    }
}

nonisolated struct AdvancedExportItem: Identifiable, Sendable {
    var id: URL { sourceURL }

    let sourceURL: URL
    let filename: String
    let cameraRaw: CameraRawSettings?
    let isHDR: Bool
}

nonisolated struct AdvancedExportSession: Identifiable, Sendable {
    let id = UUID()
    let items: [AdvancedExportItem]
}

nonisolated enum AdvancedExportQueueBuilder {
    static func orderedSelection(
        from visibleImages: [ImageFile],
        selectedIDs: Set<URL>
    ) -> [ImageFile] {
        visibleImages.filter { selectedIDs.contains($0.url) }
    }
}
