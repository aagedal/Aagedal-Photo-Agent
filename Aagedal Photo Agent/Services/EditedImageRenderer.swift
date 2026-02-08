import CoreImage

enum EditedImageRenderer {

    static func renderJPEG(from sourceURL: URL, cameraRaw: CameraRawSettings?, outputFolder: URL) throws {
        guard let input = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
            throw RenderError.unreadableImage
        }

        let originalExtent = input.extent
        var output = CameraRawApproximation.apply(to: input, settings: cameraRaw)
        output = applyCropIfNeeded(to: output, originalExtent: originalExtent, settings: cameraRaw)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = CameraRawApproximation.ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [:]) else {
            throw RenderError.encodeFailed
        }

        let destinationURL = outputURL(for: sourceURL, in: outputFolder)
        try data.write(to: destinationURL, options: .atomic)
    }

    static func outputURL(for sourceURL: URL, in outputFolder: URL) -> URL {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filenameBase = ext.isEmpty ? base : "\(base)_\(ext)"
        return outputFolder
            .appendingPathComponent(filenameBase)
            .appendingPathExtension("jpg")
    }

    private static func applyCropIfNeeded(to input: CIImage, originalExtent: CGRect, settings: CameraRawSettings?) -> CIImage {
        guard let crop = settings?.crop else { return input }
        let hasCrop = crop.hasCrop ?? false
        let angle = crop.angle ?? 0

        let region = NormalizedCropRegion(
            top: crop.top ?? 0,
            left: crop.left ?? 0,
            bottom: crop.bottom ?? 1,
            right: crop.right ?? 1
        ).clamped()

        let epsilon = 0.0001
        let hasNonDefaultBounds = abs(region.top) > epsilon
            || abs(region.left) > epsilon
            || abs(region.bottom - 1) > epsilon
            || abs(region.right - 1) > epsilon
        let hasRotation = abs(angle) > epsilon

        guard hasCrop || hasNonDefaultBounds || hasRotation else { return input }
        guard region.right > region.left, region.bottom > region.top else { return input }

        // Use original extent for crop calculation to avoid offset from filter extent changes
        let extent = originalExtent
        let x = extent.minX + (region.left * extent.width)
        let y = extent.minY + ((1 - region.bottom) * extent.height)
        let width = (region.right - region.left) * extent.width
        let height = (region.bottom - region.top) * extent.height
        let cropRect = CGRect(x: x, y: y, width: width, height: height).intersection(input.extent)
        guard !cropRect.isNull, cropRect.width > 1, cropRect.height > 1 else { return input }

        guard hasRotation else {
            return input.cropped(to: cropRect)
        }

        // With rotation, the stored crop values represent two diagonally opposite
        // corners of a rotated crop rectangle (Adobe Camera RAW convention).
        // Project the diagonal onto the rotated axes to recover actual dimensions.
        let radians = CGFloat(-angle * .pi / 180.0)
        let cosA = cos(radians)
        let sinA = sin(radians)
        let actualWidth = abs(width * cosA - height * sinA)
        let actualHeight = abs(width * sinA + height * cosA)

        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)

        let rotated = input.transformed(by: transform)
        let actualCropRect = CGRect(
            x: center.x - actualWidth / 2,
            y: center.y - actualHeight / 2,
            width: actualWidth,
            height: actualHeight
        ).intersection(rotated.extent)
        guard !actualCropRect.isNull, actualCropRect.width > 1, actualCropRect.height > 1 else { return input }

        return rotated.cropped(to: actualCropRect)
    }

    enum RenderError: LocalizedError {
        case unreadableImage
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                return "Could not decode source image."
            case .encodeFailed:
                return "Could not encode JPEG output."
            }
        }
    }
}
