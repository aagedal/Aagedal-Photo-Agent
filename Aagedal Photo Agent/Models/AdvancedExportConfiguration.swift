import Foundation

/// A stable snapshot of the pixel-affecting choices used by the advanced export
/// preview. The ordinary renderer still reads the persisted defaults; advanced
/// export applies this snapshot immediately before handing the queue to it.
nonisolated struct AdvancedExportConfiguration: Equatable, Sendable {
    var sdrFormat: ExportFormatSDR
    var sdrQuality: Double
    var sdrGamut: TargetColorGamut
    var hdrFormat: ExportFormatHDR
    var hdrQuality: Double
    var hdrGamut: TargetColorGamut
    var tiffCompression: TIFFCompression
    var locationMode: ExportLocationMode
    var customSubfolderName: String

    func previewSignature(isHDR: Bool) -> String {
        if isHDR {
            return [
                "hdr",
                hdrFormat.rawValue,
                String(format: "%.4f", hdrQuality),
                hdrGamut.rawValue,
                tiffCompression.rawValue
            ].joined(separator: "|")
        }
        return [
            "sdr",
            sdrFormat.rawValue,
            String(format: "%.4f", sdrQuality),
            sdrGamut.rawValue,
            tiffCompression.rawValue
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
