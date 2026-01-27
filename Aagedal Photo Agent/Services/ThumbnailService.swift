import AppKit
import QuickLookThumbnailing

@Observable
final class ThumbnailService {
    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    private let thumbnailSize = CGSize(width: 240, height: 240)

    init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadThumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        // Try QLThumbnailGenerator first
        if let image = await generateQLThumbnail(for: url) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }

        // Fallback to CGImageSource
        if let image = loadCGImageSourceThumbnail(for: url) {
            cache.setObject(image, forKey: url as NSURL)
            return image
        }

        return nil
    }

    private func generateQLThumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: thumbnailSize,
            scale: 2.0,
            representationTypes: .thumbnail
        )

        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return thumbnail.nsImage
        } catch {
            return nil
        }
    }

    nonisolated private func loadCGImageSourceThumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize.width, thumbnailSize.height) * 2,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}
