import CoreGraphics
import CoreImage
import Foundation

nonisolated final class AdvancedExportPreviewStorage: @unchecked Sendable {
    let folderURL: URL
    let outputURL: URL

    init(folderURL: URL, outputURL: URL) {
        self.folderURL = folderURL
        self.outputURL = outputURL
    }

    deinit {
        try? FileManager.default.removeItem(at: folderURL)
    }
}

nonisolated struct AdvancedExportPreview: @unchecked Sendable {
    let referenceImage: CGImage
    let exportImage: CGImage
    let encodedFileSize: Int64
    let pixelWidth: Int
    let pixelHeight: Int
    let storage: AdvancedExportPreviewStorage
}

nonisolated struct AdvancedExportLoupe: @unchecked Sendable {
    let referenceImage: CGImage
    let exportImage: CGImage
}

/// Creates real, full-resolution export artifacts in a private temporary folder,
/// then decodes display-sized versions for side-by-side inspection.
actor AdvancedExportPreviewService {
    private let maxDisplayPixelSize: CGFloat = 1_600
    private var isRendering = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []

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

        let artifact: AdvancedExportRenderedArtifact
        do {
            artifact = try await EditedImageRenderer.renderAdvancedPreview(
                from: item.sourceURL,
                cameraRaw: item.cameraRaw,
                isHDR: item.isHDR,
                configuration: configuration,
                outputFolder: previewFolder,
                maxReferencePixelSize: maxDisplayPixelSize
            )
        } catch {
            try? FileManager.default.removeItem(at: previewFolder)
            throw error
        }
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
        return try await Task.detached(priority: .userInitiated) {
            let referenceImage = try EditedImageRenderer.makeAdvancedReferenceLoupe(
                from: item.sourceURL,
                cameraRaw: item.cameraRaw,
                isHDR: item.isHDR,
                configuration: configuration,
                normalizedPoint: normalizedPoint,
                pixelSize: pixelSize
            )
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
                exportImage: exportImage
            )
        }.value
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
