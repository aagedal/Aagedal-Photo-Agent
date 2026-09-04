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

    /// Settings that affect the developed reference shown beside the encoded export.
    /// Encoding format, compression, and quality deliberately do not participate so
    /// changing them can reuse the already-rendered reference image and loupe crop.
    func referenceSignature(isHDR: Bool) -> String {
        [
            isHDR ? "hdr-reference" : "sdr-reference",
            isHDR ? hdrGamut.rawValue : sdrGamut.rawValue,
            resolutionLimit.rawValue
        ].joined(separator: "|")
    }

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

nonisolated struct AdvancedExportItem: Identifiable, Equatable, Sendable {
    var id: URL { sourceURL }

    let sourceURL: URL
    let filename: String
    let cameraRaw: CameraRawSettings?
    let isHDR: Bool
    let sourceFileSize: Int64?
    let sourcePixelWidth: Int?
    let sourcePixelHeight: Int?

    init(
        sourceURL: URL,
        filename: String,
        cameraRaw: CameraRawSettings?,
        isHDR: Bool,
        sourceFileSize: Int64? = nil,
        sourcePixelWidth: Int? = nil,
        sourcePixelHeight: Int? = nil
    ) {
        self.sourceURL = sourceURL
        self.filename = filename
        self.cameraRaw = cameraRaw
        self.isHDR = isHDR
        self.sourceFileSize = sourceFileSize
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
    }
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

nonisolated struct AdvancedExportPreparationInput: Equatable, Sendable {
    let sourceURL: URL
    let filename: String
    let liveCameraRaw: CameraRawSettings?
    let sourceFileSize: Int64?
    let exifOrientation: Int
    let isICloudDownloadPending: Bool
}

nonisolated struct AdvancedExportSourcePixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

nonisolated struct AdvancedExportPreparationAccess: Sendable {
    let loadCameraRawSidecar: @Sendable (URL) -> CameraRawSettings?
    let nativePixelSize: @Sendable (URL) -> AdvancedExportSourcePixelSize?

    static let live = Self(
        loadCameraRawSidecar: { imageURL in
            XMPSidecarService().loadSidecar(for: imageURL)?.cameraRaw
        },
        nativePixelSize: { imageURL in
            guard let size = FullScreenImageCache.nativePixelSize(of: imageURL) else {
                return nil
            }
            return AdvancedExportSourcePixelSize(
                width: Int(size.width.rounded()),
                height: Int(size.height.rounded())
            )
        }
    )
}

nonisolated struct AdvancedExportPreparationSnapshot: Equatable, Sendable {
    let requestID: UUID
    let requestedURLs: [URL]
    let preparedItems: [AdvancedExportItem]

    var preparedURLs: [URL] { preparedItems.map(\.sourceURL) }
    var isComplete: Bool { preparedItems.count == requestedURLs.count }
}

nonisolated enum AdvancedExportPreparationResult: Equatable, Sendable {
    case complete(AdvancedExportPreparationSnapshot)
    case cancelledBeforeRead(requestID: UUID, requestedURLs: [URL])
    case cancelledAfterPartialRead(AdvancedExportPreparationSnapshot)
    case cancelledAfterCompleteRead(AdvancedExportPreparationSnapshot)
}

/// Serializes sidecar and ImageIO reads used to construct the Advanced Export queue. The UI
/// receives only immutable items, while cooperative cancellation records the exact fully prepared
/// prefix after any synchronous Foundation or ImageIO call that could not be interrupted.
actor AdvancedExportPreparationService {
    static let shared = AdvancedExportPreparationService()

    private let access: AdvancedExportPreparationAccess

    init(access: AdvancedExportPreparationAccess = .live) {
        self.access = access
    }

    func prepare(
        _ inputs: [AdvancedExportPreparationInput],
        requestID: UUID
    ) -> AdvancedExportPreparationResult {
        let requestedURLs = inputs.map(\.sourceURL)
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, requestedURLs: requestedURLs)
        }

        var items: [AdvancedExportItem] = []
        items.reserveCapacity(inputs.count)

        for input in inputs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: requestedURLs,
                    preparedItems: items
                )
            }

            var cameraRaw = input.liveCameraRaw
            if cameraRaw == nil, SupportedImageFormats.isRaw(url: input.sourceURL) {
                cameraRaw = access.loadCameraRawSidecar(input.sourceURL)
                guard !Task.isCancelled else {
                    return cancelledResult(
                        requestID: requestID,
                        requestedURLs: requestedURLs,
                        preparedItems: items
                    )
                }
            }

            let nativeSize: AdvancedExportSourcePixelSize?
            if input.isICloudDownloadPending {
                nativeSize = nil
            } else {
                nativeSize = access.nativePixelSize(input.sourceURL)
            }

            let sourcePixelWidth: Int?
            let sourcePixelHeight: Int?
            if let nativeSize, (5...8).contains(input.exifOrientation) {
                sourcePixelWidth = nativeSize.height
                sourcePixelHeight = nativeSize.width
            } else {
                sourcePixelWidth = nativeSize?.width
                sourcePixelHeight = nativeSize?.height
            }

            items.append(AdvancedExportItem(
                sourceURL: input.sourceURL,
                filename: input.filename,
                cameraRaw: cameraRaw,
                isHDR: cameraRaw?.hdrEditMode == 1,
                sourceFileSize: input.sourceFileSize,
                sourcePixelWidth: sourcePixelWidth,
                sourcePixelHeight: sourcePixelHeight
            ))

            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: requestedURLs,
                    preparedItems: items
                )
            }
        }

        return .complete(AdvancedExportPreparationSnapshot(
            requestID: requestID,
            requestedURLs: requestedURLs,
            preparedItems: items
        ))
    }

    private func cancelledResult(
        requestID: UUID,
        requestedURLs: [URL],
        preparedItems: [AdvancedExportItem]
    ) -> AdvancedExportPreparationResult {
        let snapshot = AdvancedExportPreparationSnapshot(
            requestID: requestID,
            requestedURLs: requestedURLs,
            preparedItems: preparedItems
        )
        return snapshot.isComplete
            ? .cancelledAfterCompleteRead(snapshot)
            : .cancelledAfterPartialRead(snapshot)
    }
}
