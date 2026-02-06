import AppKit
import os.log

nonisolated(unsafe) private let cacheLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FullScreenCache")

/// LRU image cache with directional prefetching for full-screen image navigation.
/// Holds up to 7 screen-resolution images (~280MB). NSCache auto-evicts under memory pressure.
final class FullScreenImageCache: @unchecked Sendable {
    nonisolated(unsafe) private let cache = NSCache<NSURL, CGImage>()
    nonisolated(unsafe) private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init() {
        cache.countLimit = 7
    }

    // MARK: - Cache Access

    nonisolated func cachedImage(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: CGImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    // MARK: - Prefetching

    /// Prefetch adjacent images based on navigation direction.
    /// Loads 2 images ahead in travel direction and 1 behind, at utility priority.
    nonisolated func startPrefetch(currentIndex: Int, images: [URL], direction: NavigationDirection, screenMaxPx: CGFloat) {
        let ahead: [Int]
        let behind: [Int]

        switch direction {
        case .forward:
            ahead = [currentIndex + 1, currentIndex + 2]
            behind = [currentIndex - 1]
        case .backward:
            ahead = [currentIndex - 1, currentIndex - 2]
            behind = [currentIndex + 1]
        case .none:
            ahead = [currentIndex + 1, currentIndex - 1]
            behind = [currentIndex + 2, currentIndex - 2]
        }

        let targetIndices = (ahead + behind).filter { $0 >= 0 && $0 < images.count }
        let targetURLs = Set(targetIndices.map { images[$0] })

        lock.lock()
        // Cancel prefetch tasks for URLs no longer needed
        for (url, task) in prefetchTasks where !targetURLs.contains(url) {
            task.cancel()
            prefetchTasks.removeValue(forKey: url)
        }
        lock.unlock()

        for url in targetURLs {
            // Skip if already cached
            if cachedImage(for: url) != nil { continue }

            lock.lock()
            let alreadyPrefetching = prefetchTasks[url] != nil
            lock.unlock()
            if alreadyPrefetching { continue }

            let task = Task.detached(priority: .utility) { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let filename = url.lastPathComponent
                cacheLogger.info("Prefetching \(filename)")

                let image = Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx)
                guard !Task.isCancelled, let image else {
                    cacheLogger.info("Prefetch cancelled or failed: \(filename)")
                    return
                }

                self.store(image, for: url)
                cacheLogger.info("Prefetched \(filename) (\(image.width)x\(image.height))")
                self.removePrefetchTask(for: url)
            }

            lock.lock()
            prefetchTasks[url] = task
            lock.unlock()
        }
    }

    nonisolated private func removePrefetchTask(for url: URL) {
        lock.lock()
        prefetchTasks.removeValue(forKey: url)
        lock.unlock()
    }

    nonisolated func cancelAllPrefetch() {
        lock.lock()
        for (_, task) in prefetchTasks {
            task.cancel()
        }
        prefetchTasks.removeAll()
        lock.unlock()
        cacheLogger.info("All prefetch tasks cancelled")
    }

    // MARK: - Shared Image Loading

    /// Load an image downsampled to the given max pixel size.
    /// Always uses CGImageSourceCreateThumbnailAtIndex to ensure EXIF orientation is applied.
    nonisolated static func loadDownsampled(from url: URL, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Determine target size: downsample if significantly larger, otherwise use actual size
        // (still go through the thumbnail API so orientation transform is always applied)
        let targetSize: CGFloat
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let longestSide = CGFloat(max(pw, ph))
            targetSize = longestSide > maxPixelSize * 1.5 ? maxPixelSize : longestSide
        } else {
            targetSize = maxPixelSize
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Load an image at full source resolution, preserving color space and bit depth.
    /// Uses CGImageSourceCreateThumbnailAtIndex to ensure EXIF orientation is applied.
    nonisolated static func loadFullResolution(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Read actual pixel dimensions to use as maxPixelSize (no downsampling, but orientation IS applied)
        let maxDimension: CGFloat
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            maxDimension = CGFloat(max(pw, ph))
        } else {
            maxDimension = 32000 // Safe fallback
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Extract the embedded JPEG preview from a RAW file.
    nonisolated static func extractEmbeddedPreview(from url: URL) -> CGImage? {
        let filename = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            cacheLogger.warning("\(filename): CGImageSourceCreateWithURL failed")
            return nil
        }

        let imageCount = CGImageSourceGetCount(source)
        let sourceType = CGImageSourceGetType(source) as String? ?? "unknown"
        cacheLogger.info("\(filename): CGImageSource type=\(sourceType), imageCount=\(imageCount)")

        // First try to get the embedded JPEG thumbnail (fastest)
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            cacheLogger.info("\(filename): Got embedded thumbnail \(cgThumb.width)x\(cgThumb.height)")
            return cgThumb
        } else {
            cacheLogger.info("\(filename): No embedded thumbnail at index 0")
        }

        // Fallback: check for additional images in the source
        if imageCount > 1 {
            for i in 1..<imageCount {
                if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] {
                    let w = props[kCGImagePropertyPixelWidth].map { "\($0)" } ?? "?"
                    let h = props[kCGImagePropertyPixelHeight].map { "\($0)" } ?? "?"
                    cacheLogger.info("\(filename): Image at index \(i): \(w)x\(h)")
                }
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 1, options as CFDictionary) {
                cacheLogger.info("\(filename): Using secondary image \(cgImage.width)x\(cgImage.height)")
                return cgImage
            }
        }

        cacheLogger.warning("\(filename): No preview found")
        return nil
    }

    enum NavigationDirection {
        case forward
        case backward
        case none
    }
}
