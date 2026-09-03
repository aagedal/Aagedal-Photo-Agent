import AppKit
import CoreImage
import Foundation
import os

/// Immutable input for one passive Clean Feed render. The request and image identities let the
/// MainActor owner reject an old A -> B -> A completion rather than relying on URL equality alone.
nonisolated struct CleanFeedBrowseRenderRequest: Sendable {
    let requestID: UUID
    let imageURL: URL
    let settings: CameraRawSettings?
    let displayOrientation: Int
    let maxPixelSize: CGFloat
}

nonisolated enum CleanFeedBrowseRenderCompletion: Sendable, Equatable {
    case complete
    case cancelled(renderCompleted: Bool)
}

/// Immutable output from the render boundary. `CIImage` is an immutable recipe and is passed only
/// to the MainActor-owned Clean Feed controller after request and image identity are revalidated.
nonisolated struct CleanFeedBrowseRenderSnapshot: @unchecked Sendable {
    let requestID: UUID
    let imageURL: URL
    let image: CIImage?
    let completion: CleanFeedBrowseRenderCompletion
}

/// Owns passive Clean Feed source reads and edit materialization away from MainActor. ImageIO and
/// Core Image entry points retain their established QoS queues, while RAW demosaicing reuses the
/// same serialized actor as Develop so the external display cannot create a second RAW memory peak.
actor CleanFeedBrowseRenderService {
    typealias Renderer = @Sendable (CleanFeedBrowseRenderRequest) async -> CIImage?

    static let shared = CleanFeedBrowseRenderService()

    private let renderer: Renderer
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "CleanFeedBrowseRender"
    )

    init(renderer: @escaping Renderer = CleanFeedBrowseRenderService.renderSystemSource) {
        self.renderer = renderer
    }

    func render(_ request: CleanFeedBrowseRenderRequest) async -> CleanFeedBrowseRenderSnapshot {
        let interval = signposter.beginInterval(
            "BrowseRender",
            id: signposter.makeSignpostID()
        )
        guard !Task.isCancelled else {
            signposter.endInterval("BrowseRender", interval, "result=cancelled stage=before")
            return CleanFeedBrowseRenderSnapshot(
                requestID: request.requestID,
                imageURL: request.imageURL,
                image: nil,
                completion: .cancelled(renderCompleted: false)
            )
        }

        let image = await renderer(request)
        guard !Task.isCancelled else {
            signposter.endInterval("BrowseRender", interval, "result=cancelled stage=after")
            return CleanFeedBrowseRenderSnapshot(
                requestID: request.requestID,
                imageURL: request.imageURL,
                image: image,
                completion: .cancelled(renderCompleted: true)
            )
        }

        if image == nil {
            signposter.endInterval("BrowseRender", interval, "result=unavailable")
        } else {
            signposter.endInterval("BrowseRender", interval, "result=ready")
        }
        return CleanFeedBrowseRenderSnapshot(
            requestID: request.requestID,
            imageURL: request.imageURL,
            image: image,
            completion: .complete
        )
    }

    nonisolated private static func renderSystemSource(
        _ request: CleanFeedBrowseRenderRequest
    ) async -> CIImage? {
        let factsResult = await FullScreenImagePresentationFactsService.shared.load(
            imageURL: request.imageURL,
            requestID: request.requestID
        )
        guard !Task.isCancelled,
              case .loaded(let facts) = factsResult,
              facts.requestID == request.requestID,
              facts.imageURL == request.imageURL else { return nil }

        let fileOrientation = facts.fileOrientation ?? request.displayOrientation
        var base: CIImage?
        var isRawDecode = false

        if FullScreenImageCache.isRawFile(request.imageURL) {
            base = await DevelopSourceDecodeService.shared.loadRAWPreviewSource(
                from: request.imageURL,
                maxPixelSize: request.maxPixelSize
            )
            isRawDecode = base != nil
            if base == nil,
               let embedded = await FullScreenImageCache.extractEmbeddedPreviewOffPool(
                   from: request.imageURL
               ) {
                base = CIImage(cgImage: embedded)
            }
        } else {
            base = await FullScreenImageCache.loadHDRPreviewOffPool(
                from: request.imageURL,
                maxPixelSize: request.maxPixelSize
            )
            if base == nil,
               let downsampled = await FullScreenImageCache.loadDownsampledOffPool(
                   from: request.imageURL,
                   maxPixelSize: request.maxPixelSize
               ) {
                base = CIImage(cgImage: downsampled)
            }
        }

        guard !Task.isCancelled, let base else { return nil }

        var effectiveSettings = request.settings
        if isRawDecode {
            // Flat RAW decode carries EDR headroom even when no user edits are present.
            var settings = effectiveSettings ?? CameraRawSettings()
            settings.sourceHasHDRHeadroom = true
            effectiveSettings = settings
        }

        var processed = base
        if let effectiveSettings {
            processed = CameraRawApproximation.applyWithCrop(
                to: base,
                settings: effectiveSettings,
                exifOrientation: fileOrientation
            )
        }
        guard !Task.isCancelled else { return nil }

        let correction = ImageFile.orientationCorrection(
            from: fileOrientation,
            to: request.displayOrientation
        )
        return correction == .up ? processed : processed.oriented(correction)
    }
}
