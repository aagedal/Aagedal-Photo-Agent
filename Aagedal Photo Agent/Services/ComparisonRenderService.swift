import CoreGraphics
import CoreImage
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

/// Comparison keeps two completed panes resident, so its output budget is deliberately tighter
/// than an arbitrary full-screen decode. RAW decoding also has a substantially larger transient
/// footprint than the completed screen-sized bitmap; those decodes are serialized below.
nonisolated enum ComparisonRenderPolicy {
    static let maximumLongEdge: CGFloat = 4_096
    static let maximumBytesPerPixel = 8
    static let paneCount = 2

    static var maximumResidentOutputBytes: Int {
        Int(maximumLongEdge) * Int(maximumLongEdge) * maximumBytesPerPixel * paneCount
    }

    static func boundedLongEdge(_ requested: CGFloat) -> CGFloat {
        guard requested.isFinite else { return maximumLongEdge }
        return min(max(requested, 1), maximumLongEdge)
    }

    static func acceptsCachedImage(_ image: CGImage, maximumLongEdge: CGFloat) -> Bool {
        max(image.width, image.height) <= Int(maximumLongEdge.rounded(.up))
    }

    static func requiresSerializedDecode(for url: URL) -> Bool {
        FullScreenImageCache.isRawFile(url)
    }

    static func usesEditedPixels(for representation: ComparisonRepresentation) -> Bool {
        if case .original = representation { return false }
        return true
    }
}

/// Cancellation-aware FIFO gate used to keep transient RAW decode memory bounded. A waiting pane
/// can be cancelled without receiving a permit later, which matters when Compare is closed or a
/// filmstrip replacement supersedes an in-flight request.
actor ComparisonDecodeGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var waiterHead = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if inUse < limit {
            inUse += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[id] = continuation
                    waiterOrder.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        while waiterHead < waiterOrder.count {
            let id = waiterOrder[waiterHead]
            waiterHead += 1
            if let continuation = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                continuation.resume(returning: true)
                return
            }
        }
        compactWaiterOrderIfNeeded(force: true)
        inUse = max(0, inUse - 1)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
    }

    private func compactWaiterOrderIfNeeded(force: Bool = false) {
        guard waiterHead > 0,
              force || (waiterHead >= 64 && waiterHead * 2 >= waiterOrder.count) else { return }
        waiterOrder.removeFirst(waiterHead)
        waiterHead = 0
    }
}

/// Reuses the bounded full-screen caches and decode pipeline so Compare does not establish a
/// second unbounded pool of high-resolution images.
nonisolated struct ComparisonRenderService: Sendable {
    private static let rawDecodeGate = ComparisonDecodeGate(limit: 1)

    @concurrent
    func render(
        imageFile: ImageFile,
        settings: CameraRawSettings?,
        representation: ComparisonRepresentation = .committedEdit,
        cache: FullScreenImageCache,
        maxPixelSize: CGFloat
    ) async throws -> ComparisonRenderedSource {
        try Task.checkCancellation()
        guard !imageFile.isICloudDownloadPending else {
            throw ComparisonRenderError.sourceUnavailable(imageFile.filename)
        }

        let boundedMaxPixelSize = ComparisonRenderPolicy.boundedLongEdge(maxPixelSize)

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
        let isEdited: Bool
        let effectiveSettings: CameraRawSettings?
        if !ComparisonRenderPolicy.usesEditedPixels(for: representation) {
            isEdited = false
            effectiveSettings = nil
        } else {
            isEdited = true
            effectiveSettings = settings
        }
        let renderToken = FullScreenImageCache.renderToken(
            settings: effectiveSettings,
            isEdited: isEdited
        )
        let rendered: CGImage
        if let cached = cache.cachedImage(
            for: imageFile.url,
            orientation: orientation,
            renderToken: renderToken,
            isEdited: isEdited
        ), let boundedCached = Self.boundedCachedImage(
            cached,
            maximumLongEdge: boundedMaxPixelSize
        ) {
            rendered = boundedCached
        } else {
            let decoded = try await decode(
                imageFile: imageFile,
                settings: effectiveSettings,
                orientation: orientation,
                maxPixelSize: boundedMaxPixelSize
            )
            guard let decoded else {
                try Task.checkCancellation()
                throw ComparisonRenderError.decodeFailed(imageFile.filename)
            }
            try Task.checkCancellation()
            cache.store(
                decoded,
                for: imageFile.url,
                orientation: orientation,
                renderToken: renderToken,
                isEdited: isEdited
            )
            rendered = decoded
        }

        return ComparisonRenderedSource(
            source: ComparisonSource(
                revision: revision,
                representation: representation,
                dynamicRange: imageFile.isNativeHDR ? .hdr : .sdr
            ),
            image: rendered
        )
    }

    /// Produces a bounded snapshot of the current in-memory Develop buffer. This deliberately
    /// uses the same Metal edit graph as the live editor instead of exporting or reading the XMP
    /// sidecar, so uncommitted adjustments are represented honestly as `Live Edit`.
    @concurrent
    func renderLiveEdit(
        imageFile: ImageFile,
        sourceImage: CIImage,
        settings: CameraRawSettings?,
        renderToken: String,
        representation: ComparisonRepresentation? = nil,
        revision existingRevision: SourceImageRevision? = nil,
        maxPixelSize: CGFloat
    ) async throws -> ComparisonRenderedSource {
        try Task.checkCancellation()
        guard !imageFile.isICloudDownloadPending else {
            throw ComparisonRenderError.sourceUnavailable(imageFile.filename)
        }

        let boundedMaxPixelSize = ComparisonRenderPolicy.boundedLongEdge(maxPixelSize)
        let revision: SourceImageRevision
        if let existingRevision,
           existingRevision.canonicalURL.standardizedFileURL
                == imageFile.url.standardizedFileURL {
            revision = existingRevision
        } else {
            let pixelSize = FullScreenImageCache.nativePixelSize(of: imageFile.url)
            revision = try await SourceImageRevision.capture(
                at: imageFile.url,
                pixelWidth: pixelSize.map { Int($0.width) },
                pixelHeight: pixelSize.map { Int($0.height) },
                exifOrientation: imageFile.exifOrientation
            )
        }
        try Task.checkCancellation()

        let workingSource = Self.boundedSource(sourceImage, maximumLongEdge: boundedMaxPixelSize)
        let orientation = imageFile.exifOrientation
        let renderedOutput: CIImage?
        if settings?.crop?.isEffectiveCrop == true {
            renderedOutput = await MetalEditPipeline.renderOffscreenCroppedAsync(
                source: workingSource,
                settings: settings,
                exifOrientation: orientation
            )
        } else {
            renderedOutput = await MetalEditPipeline.renderOffscreenAsync(
                source: workingSource,
                settings: settings,
                exifOrientation: orientation
            )
        }
        try Task.checkCancellation()

        let output: CIImage
        if let renderedOutput {
            output = renderedOutput
        } else if let settings, MetalEditPipeline.isIdentitySettings(settings) {
            output = CameraRawApproximation.applyCrop(
                to: workingSource,
                originalExtent: workingSource.extent,
                settings: settings,
                exifOrientation: orientation
            )
        } else if settings == nil {
            output = workingSource
        } else {
            throw ComparisonRenderError.decodeFailed(imageFile.filename)
        }

        guard let image = CameraRawApproximation.ciContext.createCGImage(
            output,
            from: output.extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        ) else {
            throw ComparisonRenderError.decodeFailed(imageFile.filename)
        }

        return ComparisonRenderedSource(
            source: ComparisonSource(
                revision: revision,
                representation: representation ?? .liveEdit(renderToken: renderToken),
                dynamicRange: imageFile.isNativeHDR ? .hdr : .sdr
            ),
            image: image
        )
    }

    /// A full-screen render can be larger than Compare's two-pane budget. Reuse those
    /// already-decoded, edit-matched pixels instead of opening and rendering the source again.
    /// Keep the larger entry in the shared cache for a later return to full screen.
    static func boundedCachedImage(_ image: CGImage, maximumLongEdge: CGFloat) -> CGImage? {
        let limit = ComparisonRenderPolicy.boundedLongEdge(maximumLongEdge)
        if ComparisonRenderPolicy.acceptsCachedImage(image, maximumLongEdge: limit) {
            return image
        }
        let source = boundedSource(CIImage(cgImage: image), maximumLongEdge: limit)
        return CameraRawApproximation.createDisplayCGImage(source, from: source.extent)
    }

    private static func boundedSource(
        _ source: CIImage,
        maximumLongEdge: CGFloat
    ) -> CIImage {
        let longEdge = max(source.extent.width, source.extent.height)
        guard longEdge.isFinite,
              longEdge > maximumLongEdge,
              longEdge > 0 else { return source }
        let scale = maximumLongEdge / longEdge
        return source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func decode(
        imageFile: ImageFile,
        settings: CameraRawSettings?,
        orientation: Int,
        maxPixelSize: CGFloat
    ) async throws -> CGImage? {
        if ComparisonRenderPolicy.requiresSerializedDecode(for: imageFile.url) {
            guard await Self.rawDecodeGate.acquire() else { throw CancellationError() }
            if Task.isCancelled {
                await Self.rawDecodeGate.release()
                throw CancellationError()
            }

            let image = await FullScreenImageCache.decodedEditedPreview(
                for: imageFile.url,
                settings: settings,
                orientation: orientation,
                screenMaxPx: maxPixelSize
            )
            await Self.rawDecodeGate.release()
            try Task.checkCancellation()
            return image
        }

        let image = await FullScreenImageCache.decodedEditedPreview(
            for: imageFile.url,
            settings: settings,
            orientation: orientation,
            screenMaxPx: maxPixelSize
        )
        try Task.checkCancellation()
        return image
    }
}
