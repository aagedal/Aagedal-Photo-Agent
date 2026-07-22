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
        guard let cgImage = thumbnail(imageURL: imageURL, maxDimension: maxDimension) else { return nil }
        return crop(image: cgImage, box: box, paddingFraction: paddingFraction)
    }

    static func crop(image cgImage: CGImage, box: CGRect, paddingFraction: CGFloat = 0.6) -> CGImage? {
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

    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let crops = NSCache<NSString, ImageBox>()
    private let previews = NSCache<NSString, ImageBox>()
    private let sources = NSCache<NSString, ImageBox>()

    init() {
        // Keep the process-wide review cache useful without allowing an hours-long
        // sports session to retain every decoded photograph it has ever displayed.
        crops.countLimit = 256
        crops.totalCostLimit = 32 * 1024 * 1024
        previews.countLimit = 64
        previews.totalCostLimit = 32 * 1024 * 1024
        sources.countLimit = 24
        sources.totalCostLimit = 64 * 1024 * 1024
    }

    private func key(url: URL, box: CGRect) -> String {
        "\(fileVersionKey(url))#\(Int(box.minX * 10000)),\(Int(box.minY * 10000)),\(Int(box.width * 10000)),\(Int(box.height * 10000))"
    }

    private func fileVersionKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.standardizedFileURL.path)#\(modified)#\(values?.fileSize ?? -1)"
    }

    private func cost(of image: CGImage) -> Int {
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow ? Int.max : bytes
    }

    func crop(imageURL: URL, box: CGRect) -> CGImage? {
        let cropKey = key(url: imageURL, box: box) as NSString
        if let hit = crops.object(forKey: cropKey) { return hit.image }

        let sourceKey = fileVersionKey(imageURL) as NSString
        let source: CGImage
        if let hit = sources.object(forKey: sourceKey) {
            source = hit.image
        } else {
            guard let decoded = NumberCropService.thumbnail(imageURL: imageURL, maxDimension: 1400) else { return nil }
            sources.setObject(ImageBox(decoded), forKey: sourceKey, cost: cost(of: decoded))
            source = decoded
        }

        guard let image = NumberCropService.crop(image: source, box: box) else { return nil }
        // A cropped CGImage may retain its parent's provider, so charge the source
        // decode rather than only the crop's visible byte rectangle.
        crops.setObject(ImageBox(image), forKey: cropKey, cost: cost(of: source))
        return image
    }

    /// Whole-image preview (downsampled), keyed by path.
    func preview(imageURL: URL) -> CGImage? {
        let k = fileVersionKey(imageURL) as NSString
        if let hit = previews.object(forKey: k) { return hit.image }
        guard let image = NumberCropService.thumbnail(imageURL: imageURL) else { return nil }
        previews.setObject(ImageBox(image), forKey: k, cost: cost(of: image))
        return image
    }

    func removeAll() {
        crops.removeAllObjects()
        previews.removeAllObjects()
        sources.removeAllObjects()
    }
}
