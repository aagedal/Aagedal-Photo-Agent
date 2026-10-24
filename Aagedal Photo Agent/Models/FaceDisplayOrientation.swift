import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// The single mapping from stored face geometry to what the user sees.
///
/// Face detection orients its working image by the file's embedded EXIF tag only, so every
/// stored `faceRect` / `jerseyNumberBox` / number box is Vision-normalized (bottom-left origin)
/// in the *file-tag* frame. A culling rotation of a RAW (or any sidecar-only rotation) lives
/// only in the sidecar, so the displayed photo can be 90°/180°/270° away from that frame.
/// Every consumer that orders faces left to right or draws them over the displayed image must
/// map through this type first — never treat stored rects as display-oriented.
///
/// Boxes stay stored in the file frame (a non-RAW rotation rewrites the file tag, which changes
/// the scan fingerprint and forces a rescan, so the stored frame always equals the current tag
/// while faces are current).
nonisolated struct FaceDisplayOrientation: Equatable, Sendable {
    /// EXIF orientation the detector baked into its working pixels (the file's embedded tag).
    let fileOrientation: Int
    /// Sidecar-first display orientation (`ImageFile.exifOrientation`).
    let displayOrientation: Int

    init(fileOrientation: Int, displayOrientation: Int) {
        self.fileOrientation = fileOrientation
        self.displayOrientation = displayOrientation
    }

    /// No residual rotation: the display frame equals the detection frame.
    static let identity = Self(fileOrientation: 1, displayOrientation: 1)

    /// Corrective rotation from the detection frame to the display frame.
    var correction: CGImagePropertyOrientation {
        ImageFile.orientationCorrection(from: fileOrientation, to: displayOrientation)
    }

    /// Maps a Vision-normalized rect (bottom-left origin, y up) from the file-tag frame into
    /// the full, uncropped display-oriented frame. Crop/straighten is applied afterwards by
    /// `CaptionPreviewGeometry.croppedVisionRect` / the full-screen `detectionCorners`, which
    /// expect exactly this frame — neither rotates the rect again.
    func displayRect(forFileRect rect: CGRect) -> CGRect {
        switch correction {
        case .right:
            // 90° CW (visual): (x, y) → (y, 1 − x)
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case .down:
            // 180°: (x, y) → (1 − x, 1 − y)
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case .left:
            // 270° CW (visual): (x, y) → (1 − y, x)
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    /// Resolves the frame for `imageURL` with the sidecar-first display policy. Pass the
    /// model's display orientation when the caller has one (it is what the view renders);
    /// otherwise the sidecar (JSON draft, then XMP) wins over the embedded tag. Performs file
    /// I/O — call off the main actor (see `resolved(for:modelDisplayOrientation:access:)`).
    static func resolve(
        for imageURL: URL,
        modelDisplayOrientation: Int? = nil,
        access: ThumbnailSourceAccess = .system
    ) -> Self {
        let file = access.fileOrientation(imageURL)
        let display = modelDisplayOrientation ?? access.sidecarOrientation(imageURL) ?? file
        return Self(fileOrientation: file, displayOrientation: display)
    }

    /// Off-main wrapper around `resolve`.
    @concurrent
    static func resolved(
        for imageURL: URL,
        modelDisplayOrientation: Int? = nil,
        access: ThumbnailSourceAccess = .system
    ) async -> Self {
        resolve(for: imageURL, modelDisplayOrientation: modelDisplayOrientation, access: access)
    }

    /// Applies the residual file → display rotation to an image already decoded with the
    /// file tag baked in (e.g. an ImageIO thumbnail made with `…WithTransform`). Returns the
    /// input unchanged when no correction is needed, nil if rendering fails.
    func orientImage(_ image: CGImage) -> CGImage? {
        let correction = correction
        guard correction != .up else { return image }
        let rotated = CIImage(cgImage: image).oriented(correction)
        return CameraRawApproximation.ciContext.createCGImage(rotated, from: rotated.extent)
    }
}
