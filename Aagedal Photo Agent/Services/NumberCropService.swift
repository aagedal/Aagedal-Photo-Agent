import Foundation
import CoreGraphics
import ImageIO

/// Produces a small cropped image of a detected jersey/bib number, so the photographer can verify
/// what the OCR actually read (a "6" vs an "8") instead of trusting the parsed digit. Crops are
/// taken from a downsampled decode of the source image — legible at thumbnail size, cheap to make —
/// and memoised so scrolling the review queue doesn't re-decode.
nonisolated enum NumberCropService {

    /// Crop the number's box (with padding for context) from `imageURL`. `box` is a normalised
    /// Vision rect (origin bottom-left), matching `NumberDetection.boundingBox`. Returns `nil` if
    /// the image can't be decoded — callers fall back to showing the digit.
    static func crop(imageURL: URL, box: CGRect, maxDimension: CGFloat = 1400, paddingFraction: CGFloat = 0.6) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Pad the box so the crop shows the number in a little context, then clamp to 0...1.
        let padX = box.width * paddingFraction
        let padY = box.height * paddingFraction
        let padded = CGRect(
            x: max(0, box.minX - padX),
            y: max(0, box.minY - padY),
            width: min(1, box.width + 2 * padX),
            height: min(1, box.height + 2 * padY)
        )

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        // Vision origin is bottom-left; CGImage cropping origin is top-left → flip y.
        let pixelRect = CGRect(
            x: padded.minX * w,
            y: (1 - padded.minY - padded.height) * h,
            width: padded.width * w,
            height: padded.height * h
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return cgImage }
        return cgImage.cropping(to: pixelRect)
    }

    /// A downsampled decode of the whole image (EXIF-oriented), for showing a number in context
    /// with its box drawn on top.
    static func thumbnail(imageURL: URL, maxDimension: CGFloat = 520) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Process-wide memo of number crops, keyed by image path + box. `CGImage` is `Sendable`.
actor NumberCropCache {
    static let shared = NumberCropCache()
    private var cache: [String: CGImage] = [:]
    private var previews: [String: CGImage] = [:]

    private func key(url: URL, box: CGRect) -> String {
        "\(url.path)#\(Int(box.minX * 10000)),\(Int(box.minY * 10000)),\(Int(box.width * 10000)),\(Int(box.height * 10000))"
    }

    func crop(imageURL: URL, box: CGRect) -> CGImage? {
        let k = key(url: imageURL, box: box)
        if let hit = cache[k] { return hit }
        guard let image = NumberCropService.crop(imageURL: imageURL, box: box) else { return nil }
        cache[k] = image
        return image
    }

    /// Whole-image preview (downsampled), keyed by path.
    func preview(imageURL: URL) -> CGImage? {
        let k = imageURL.path
        if let hit = previews[k] { return hit }
        guard let image = NumberCropService.thumbnail(imageURL: imageURL) else { return nil }
        previews[k] = image
        return image
    }
}
