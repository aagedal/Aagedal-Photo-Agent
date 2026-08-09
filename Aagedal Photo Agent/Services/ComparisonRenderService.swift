import CoreGraphics
import Foundation

nonisolated enum ComparisonRenderError: Error, LocalizedError, Sendable {
    case sourceUnavailable(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .sourceUnavailable(filename):
            "\(filename) is not available locally. Download or reconnect it, then try again."
        case let .decodeFailed(filename):
            "\(filename) could not be decoded for comparison."
        }
    }
}

/// A revision-bound, display-ready comparison result. Core Graphics image objects are immutable;
/// the unchecked conformance only permits the completed bitmap to cross the async decode boundary.
nonisolated struct ComparisonRenderedSource: @unchecked Sendable {
    let source: ComparisonSource
    let image: CGImage
}

/// Reuses the bounded full-screen caches and decode pipeline so Compare does not establish a
/// second unbounded pool of high-resolution images.
nonisolated struct ComparisonRenderService: Sendable {
    func render(
        imageFile: ImageFile,
        settings: CameraRawSettings?,
        cache: FullScreenImageCache,
        maxPixelSize: CGFloat
    ) async throws -> ComparisonRenderedSource {
        guard !imageFile.isICloudDownloadPending else {
            throw ComparisonRenderError.sourceUnavailable(imageFile.filename)
        }

        let pixelSize = FullScreenImageCache.nativePixelSize(of: imageFile.url)
        let revision = try await SourceImageRevision.capture(
            at: imageFile.url,
            pixelWidth: pixelSize.map { Int($0.width) },
            pixelHeight: pixelSize.map { Int($0.height) },
            exifOrientation: imageFile.exifOrientation
        )
        try Task.checkCancellation()

        let orientation = FullScreenImageCache.displayOrientation(
            for: imageFile.url,
            fallback: imageFile.exifOrientation
        )
        let renderToken = FullScreenImageCache.renderToken(settings: settings, isEdited: true)
        let rendered: CGImage
        if let cached = cache.cachedImage(
            for: imageFile.url,
            orientation: orientation,
            renderToken: renderToken,
            isEdited: true
        ) {
            rendered = cached
        } else {
            guard let decoded = await FullScreenImageCache.decodedEditedPreview(
                for: imageFile.url,
                settings: settings,
                orientation: orientation,
                screenMaxPx: maxPixelSize
            ) else {
                try Task.checkCancellation()
                throw ComparisonRenderError.decodeFailed(imageFile.filename)
            }
            try Task.checkCancellation()
            cache.store(
                decoded,
                for: imageFile.url,
                orientation: orientation,
                renderToken: renderToken,
                isEdited: true
            )
            rendered = decoded
        }

        return ComparisonRenderedSource(
            source: ComparisonSource(
                revision: revision,
                representation: .committedEdit,
                dynamicRange: imageFile.isNativeHDR ? .hdr : .sdr
            ),
            image: rendered
        )
    }
}
