import CoreGraphics
import CoreImage
import Foundation
import os

nonisolated struct AdvancedExportPreviewCleanupFileAccess: Sendable {
    let removeItem: @Sendable (URL) throws -> Void

    static let system = AdvancedExportPreviewCleanupFileAccess(
        removeItem: { try FileManager.default.removeItem(at: $0) }
    )
}

nonisolated enum AdvancedExportPreviewCleanupResult: Equatable, Sendable {
    case cancelledBeforeRemoval(URL)
    case removed(URL, cancellationRequestedAfterCommit: Bool)
    case failed(URL)
}

/// Serializes best-effort removal of full-resolution Advanced Export preview artifacts.
///
/// Preview storage is retained by SwiftUI state, so its final release commonly occurs on
/// MainActor. The synchronous Foundation removal can recursively delete a large artifact folder
/// and must therefore never run from `deinit`. Cancellation is sampled before the non-preemptible
/// removal and after its durable commit so explicit callers can reconcile the actual disk state.
actor AdvancedExportPreviewCleanupService {
    static let shared = AdvancedExportPreviewCleanupService()

    private let access: AdvancedExportPreviewCleanupFileAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "AdvancedExportPreviewCleanup"
    )

    init(access: AdvancedExportPreviewCleanupFileAccess = .system) {
        self.access = access
    }

    func removePreviewFolder(at folderURL: URL) -> AdvancedExportPreviewCleanupResult {
        let interval = signposter.beginInterval(
            "RemovePreviewFolder",
            id: signposter.makeSignpostID()
        )
        guard !Task.isCancelled else {
            signposter.endInterval(
                "RemovePreviewFolder",
                interval,
                "result=cancelled stage=before-removal"
            )
            return .cancelledBeforeRemoval(folderURL)
        }

        do {
            try access.removeItem(folderURL)
            let cancellationRequestedAfterCommit = Task.isCancelled
            signposter.endInterval(
                "RemovePreviewFolder",
                interval,
                "result=removed cancelledAfterCommit=\(cancellationRequestedAfterCommit)"
            )
            return .removed(
                folderURL,
                cancellationRequestedAfterCommit: cancellationRequestedAfterCommit
            )
        } catch {
            signposter.endInterval("RemovePreviewFolder", interval, "result=failed")
            return .failed(folderURL)
        }
    }

    /// `deinit` cannot await actor cleanup. This nonisolated handoff is intentionally
    /// non-cancellable: once a preview loses its final owner, its private artifacts are no longer
    /// useful and should be reclaimed even if the UI task that released them was cancelled.
    nonisolated func removeEventually(_ folderURL: URL) {
        Task {
            _ = await self.removePreviewFolder(at: folderURL)
        }
    }
}

nonisolated final class AdvancedExportPreviewStorage: @unchecked Sendable {
    let folderURL: URL
    let outputURL: URL
    private let cleanupService: AdvancedExportPreviewCleanupService

    init(
        folderURL: URL,
        outputURL: URL,
        cleanupService: AdvancedExportPreviewCleanupService = .shared
    ) {
        self.folderURL = folderURL
        self.outputURL = outputURL
        self.cleanupService = cleanupService
    }

    deinit {
        cleanupService.removeEventually(folderURL)
    }
}

nonisolated struct AdvancedExportPreview: @unchecked Sendable {
    let referenceImage: CGImage
    let exportImage: CGImage
    let encodedFileSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let configuration: AdvancedExportConfiguration
    let storage: AdvancedExportPreviewStorage
}

nonisolated struct AdvancedExportLoupe: @unchecked Sendable {
    let referenceImage: CGImage
    let exportImage: CGImage
    let configuration: AdvancedExportConfiguration
}

/// Creates real, full-resolution export artifacts in a private temporary folder,
/// then decodes display-sized versions for side-by-side inspection.
actor AdvancedExportPreviewService {
    private struct ReferenceCacheKey: Hashable {
        let sourceURL: URL
        let signature: String
    }

    private struct ReferenceLoupeCacheKey: Hashable {
        let reference: ReferenceCacheKey
        let normalizedX: Double
        let normalizedY: Double
        let pixelSize: Int
    }

    private let maxDisplayPixelSize: CGFloat = 1_600
    private var isRendering = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []
    private var referenceImages: [ReferenceCacheKey: CGImage] = [:]
    private var referenceLoupeImages: [ReferenceLoupeCacheKey: CGImage] = [:]

    func makePreview(
        item: AdvancedExportItem,
        configuration: AdvancedExportConfiguration
    ) async throws -> AdvancedExportPreview {
        await acquireRenderSlot()
        defer { releaseRenderSlot() }
        try Task.checkCancellation()

        let previewFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apa-advanced-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewFolder,
            withIntermediateDirectories: true
        )
        let referenceKey = ReferenceCacheKey(
            sourceURL: item.sourceURL,
            signature: configuration.referenceSignature(isHDR: item.isHDR)
        )

        let artifact: AdvancedExportRenderedArtifact
        do {
            artifact = try await EditedImageRenderer.renderAdvancedPreview(
                from: item.sourceURL,
                cameraRaw: item.cameraRaw,
                isHDR: item.isHDR,
                configuration: configuration,
                outputFolder: previewFolder,
                maxReferencePixelSize: maxDisplayPixelSize,
                cachedReferenceImage: referenceImages[referenceKey]
            )
        } catch {
            try? FileManager.default.removeItem(at: previewFolder)
            throw error
        }
        referenceImages[referenceKey] = artifact.referenceImage
        let storage = AdvancedExportPreviewStorage(
            folderURL: previewFolder,
            outputURL: artifact.outputURL
        )
        try Task.checkCancellation()

        let values = try artifact.outputURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values.fileSize ?? 0)
        let exportImage = try await decodePreview(
            at: artifact.outputURL,
            isHDR: item.isHDR,
            configuration: configuration,
            workingFolder: previewFolder
        )

        return AdvancedExportPreview(
            referenceImage: artifact.referenceImage,
            exportImage: exportImage,
            encodedFileSize: fileSize,
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight,
            configuration: configuration,
            storage: storage
        )
    }

    func makeLoupe(
        item: AdvancedExportItem,
        configuration: AdvancedExportConfiguration,
        preview: AdvancedExportPreview,
        normalizedPoint: CGPoint,
        pixelSize: Int
    ) async throws -> AdvancedExportLoupe {
        await acquireRenderSlot()
        defer { releaseRenderSlot() }
        try Task.checkCancellation()

        let outputURL = preview.storage.outputURL
        let referenceKey = ReferenceCacheKey(
            sourceURL: item.sourceURL,
            signature: configuration.referenceSignature(isHDR: item.isHDR)
        )
        let loupeKey = ReferenceLoupeCacheKey(
            reference: referenceKey,
            normalizedX: normalizedPoint.x,
            normalizedY: normalizedPoint.y,
            pixelSize: pixelSize
        )
        let cachedReferenceImage = referenceLoupeImages[loupeKey]
        let result = try await Task.detached(priority: .userInitiated) {
            let referenceImage: CGImage
            if let cachedReferenceImage {
                referenceImage = cachedReferenceImage
            } else {
                referenceImage = try EditedImageRenderer.makeAdvancedReferenceLoupe(
                    from: item.sourceURL,
                    cameraRaw: item.cameraRaw,
                    isHDR: item.isHDR,
                    configuration: configuration,
                    normalizedPoint: normalizedPoint,
                    pixelSize: pixelSize
                )
            }
            try Task.checkCancellation()

            let options: [CIImageOption: Any] = item.isHDR
                ? [.expandToHDR: true, .toneMapHDRtoSDR: false, .applyOrientationProperty: true]
                : [.applyOrientationProperty: true]
            guard let encoded = CIImage(contentsOf: outputURL, options: options) else {
                throw EditedImageRenderer.RenderError.unreadableImage
            }
            let exportImage = try EditedImageRenderer.makeLoupeCrop(
                from: encoded,
                isHDR: item.isHDR,
                configuration: configuration,
                normalizedPoint: normalizedPoint,
                pixelSize: pixelSize
            )
            return AdvancedExportLoupe(
                referenceImage: referenceImage,
                exportImage: exportImage,
                configuration: configuration
            )
        }.value
        referenceLoupeImages[loupeKey] = result.referenceImage
        return result
    }

    /// Full-resolution RAW processing and image encoding are deliberately serialized.
    /// Lazy rows may overlap while scrolling, and running several of these jobs at once
    /// can multiply Metal textures and temporary 16-bit intermediates.
    private func acquireRenderSlot() async {
        if !isRendering {
            isRendering = true
            return
        }
        await withCheckedContinuation { continuation in
            renderWaiters.append(continuation)
        }
    }

    private func releaseRenderSlot() {
        if renderWaiters.isEmpty {
            isRendering = false
        } else {
            renderWaiters.removeFirst().resume()
        }
    }

    private func decodePreview(
        at url: URL,
        isHDR: Bool,
        configuration: AdvancedExportConfiguration,
        workingFolder: URL
    ) async throws -> CGImage {
        if isHDR,
           let image = FullScreenImageCache.loadHDRPreview(
               from: url,
               maxPixelSize: maxDisplayPixelSize
           ),
           let cgImage = CameraRawApproximation.ciContext.createCGImage(
               image,
               from: image.extent,
               format: .RGBAh,
               colorSpace: configuration.hdrGamut.hdrLinearColorSpace
           ) {
            return cgImage
        }

        if let image = FullScreenImageCache.loadDownsampled(
            from: url,
            maxPixelSize: maxDisplayPixelSize
        ) {
            return image
        }

        try Task.checkCancellation()
        let fallbackURL = workingFolder
            .appendingPathComponent("decoded-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try await FFmpegService.decodePreview(
            input: url.path,
            output: fallbackURL.path,
            maxPixelSize: Int(maxDisplayPixelSize)
        )
        try Task.checkCancellation()

        guard let image = FullScreenImageCache.loadDownsampled(
            from: fallbackURL,
            maxPixelSize: maxDisplayPixelSize
        ) else {
            throw EditedImageRenderer.RenderError.unreadableImage
        }
        return image
    }
}
