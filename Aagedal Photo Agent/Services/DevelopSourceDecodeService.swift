import AppKit
import CoreImage
import Foundation

/// Owns concrete source-decode execution for the Develop workspace.
///
/// The view chooses when a source session starts and the preview-session coordinator decides
/// whether completed pixels are still current. This actor owns how those pixels are produced:
/// RAW quick/final/zoom/precache requests share one serialized executor, non-RAW requests retain
/// their HDR-first fallback order, and every result is corrected into the in-memory orientation
/// before it crosses back to the main actor.
actor DevelopSourceDecodeService {
    struct Source: @unchecked Sendable {
        let image: NSImage?
        let ciImage: CIImage?
    }

    typealias RAWDecoder = @Sendable (
        _ url: URL,
        _ draftMode: Bool,
        _ maxPixelSize: CGFloat?
    ) -> FullScreenImageCache.RAWDecodeResult?

    typealias OrientationReader = @Sendable (_ url: URL) -> Int

    static let shared = DevelopSourceDecodeService()

    private let rawDecoder: RAWDecoder
    private let orientationReader: OrientationReader

    init(
        rawDecoder: @escaping RAWDecoder = { url, draftMode, maxPixelSize in
            FullScreenImageCache.loadRAWImage(
                from: url,
                draftMode: draftMode,
                maxPixelSize: maxPixelSize
            )
        },
        orientationReader: @escaping OrientationReader = {
            FullScreenImageCache.fileEXIFOrientation(at: $0)
        }
    ) {
        self.rawDecoder = rawDecoder
        self.orientationReader = orientationReader
    }

    func loadEmbeddedRAWPreview(
        from url: URL,
        targetOrientation: Int
    ) async -> Source? {
        guard !Task.isCancelled,
              let result = await FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation(
                  from: url
              ),
              !Task.isCancelled else { return nil }
        let nsImage = NSImage(
            cgImage: result.image,
            size: NSSize(width: result.image.width, height: result.image.height)
        )
        let oriented = Self.orientedToTarget(
            ciImage: CIImage(cgImage: result.image),
            nsImage: nsImage,
            from: result.orientation,
            to: targetOrientation
        )
        return Source(image: oriented.nsImage, ciImage: oriented.ciImage)
    }

    /// Produces the draft RAW pixels used by passive, screen-resolution consumers such as
    /// Clean Feed. The caller owns the adjacent file-orientation snapshot because it must apply
    /// crop coordinates before rotating into the in-memory display orientation. Keeping the
    /// demosaic on this actor prevents passive output from racing Develop's foreground, zoom,
    /// or adjacent-image RAW requests on separate CIRAWFilter executors.
    func loadRAWPreviewSource(
        from url: URL,
        maxPixelSize: CGFloat
    ) -> CIImage? {
        guard !Task.isCancelled,
              let result = rawDecoder(url, true, maxPixelSize),
              !Task.isCancelled else { return nil }
        return FullScreenImageCache.downsample(result.image, maxPixelSize: maxPixelSize)
    }

    /// Serial actor isolation is intentional here. CIRAWFilter can retain hundreds of MiB while
    /// demosaicing, so the foreground decode, zoom upgrade, and adjacent-image pre-cache must not
    /// establish independent transient memory peaks.
    func loadRAW(
        from url: URL,
        maxPixelSize: CGFloat?,
        targetOrientation: Int
    ) -> FullScreenImageCache.RAWDecodeResult? {
        guard !Task.isCancelled else { return nil }
        let fileOrientation = orientationReader(url)
        guard let result = rawDecoder(url, false, maxPixelSize),
              !Task.isCancelled else { return nil }
        let oriented = Self.orientedToTarget(
            ciImage: result.image,
            nsImage: nil,
            from: fileOrientation,
            to: targetOrientation
        ).ciImage ?? result.image
        return FullScreenImageCache.RAWDecodeResult(
            image: oriented,
            neutralTemperature: result.neutralTemperature,
            neutralTint: result.neutralTint
        )
    }

    func loadNonRAWPreview(
        from url: URL,
        maxPixelSize: CGFloat,
        targetOrientation: Int
    ) async -> Source? {
        guard !Task.isCancelled else { return nil }

        if let result = await FullScreenImageCache.loadHDRPreviewOffPoolWithOrientation(
            from: url,
            maxPixelSize: maxPixelSize
        ), !Task.isCancelled {
            let correction = ImageFile.orientationCorrection(
                from: result.orientation,
                to: targetOrientation
            )
            let ciImage = correction == .up ? result.image : result.image.oriented(correction)
            if let cgImage = CameraRawApproximation.createDisplayCGImage(
                ciImage,
                from: ciImage.extent
            ) {
                return Source(
                    image: NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    ),
                    ciImage: ciImage
                )
            }
        }

        if let result = await FullScreenImageCache.loadDownsampledOffPoolWithOrientation(
            from: url,
            maxPixelSize: maxPixelSize
        ), !Task.isCancelled {
            let image = NSImage(
                cgImage: result.image,
                size: NSSize(width: result.image.width, height: result.image.height)
            )
            let oriented = Self.orientedToTarget(
                ciImage: CIImage(cgImage: result.image),
                nsImage: image,
                from: result.orientation,
                to: targetOrientation
            )
            return Source(image: oriented.nsImage, ciImage: oriented.ciImage)
        }

        guard !Task.isCancelled, let image = NSImage(contentsOf: url) else { return nil }
        let ciImage = image.tiffRepresentation.flatMap { CIImage(data: $0) }
        let oriented = Self.orientedToTarget(
            ciImage: ciImage,
            nsImage: nil,
            from: orientationReader(url),
            to: targetOrientation
        )
        return Source(image: image, ciImage: oriented.ciImage)
    }

    func loadNonRAWFullResolution(
        from url: URL,
        targetOrientation: Int
    ) async -> CIImage? {
        guard !Task.isCancelled else { return nil }
        let decoded: (image: CIImage, orientation: Int)?
        if let result = await FullScreenImageCache.loadHDRFullResolutionOffPoolWithOrientation(
            from: url
        ) {
            decoded = result
        } else if let result = await FullScreenImageCache.loadFullResolutionOffPoolWithOrientation(
            from: url
        ) {
            decoded = (CIImage(cgImage: result.image), result.orientation)
        } else {
            decoded = nil
        }
        guard let decoded, !Task.isCancelled else { return nil }
        return Self.orientedToTarget(
            ciImage: decoded.image,
            nsImage: nil,
            from: decoded.orientation,
            to: targetOrientation
        ).ciImage
    }

    func materialize(_ source: CIImage, maxPixelSize: CGFloat) -> CIImage? {
        guard !Task.isCancelled else { return nil }
        let extent = source.extent
        let maxDimension = max(extent.width, extent.height)
        let scale = maxDimension > maxPixelSize * 1.5 ? maxPixelSize / maxDimension : 1.0
        let downsampled = scale < 1.0
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        guard let cgImage = CameraRawApproximation.ciContext.createCGImage(
            downsampled,
            from: downsampled.extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        ), !Task.isCancelled else { return nil }
        return CIImage(cgImage: cgImage)
    }

    nonisolated static func orientedToTarget(
        ciImage: CIImage?,
        nsImage: NSImage?,
        from fileOrientation: Int,
        to targetOrientation: Int
    ) -> (ciImage: CIImage?, nsImage: NSImage?) {
        let correction = ImageFile.orientationCorrection(
            from: fileOrientation,
            to: targetOrientation
        )
        guard correction != .up else { return (ciImage, nsImage) }
        guard let orientedCI = ciImage?.oriented(correction) else { return (ciImage, nsImage) }
        var orientedNS = nsImage
        if nsImage != nil,
           let cgImage = CameraRawApproximation.ciContext.createCGImage(
               orientedCI,
               from: orientedCI.extent,
               format: .RGBAh,
               colorSpace: CameraRawApproximation.workingColorSpace
           ) {
            orientedNS = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
        return (orientedCI, orientedNS)
    }
}
