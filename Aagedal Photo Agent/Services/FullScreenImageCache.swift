import AppKit
import os.log

nonisolated(unsafe) private let cacheLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FullScreenCache")

/// LRU image cache with directional prefetching for full-screen image navigation.
/// Holds up to 7 screen-resolution images (~280MB). NSCache auto-evicts under memory pressure.
final class FullScreenImageCache: @unchecked Sendable {
    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    private let lock = NSLock()

    init() {
        cache.countLimit = 7
    }

    // MARK: - Cache Access

    nonisolated func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: NSImage, for url: URL) {
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
                cacheLogger.info("Prefetched \(filename) (\(image.size.width)x\(image.size.height))")
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
    /// For images already near the target size, loads at full resolution (faster).
    nonisolated static func loadDownsampled(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let needsDownsample: Bool
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int,
           let ph = props[kCGImagePropertyPixelHeight] as? Int {
            let longest = max(pw, ph)
            needsDownsample = CGFloat(longest) > maxPixelSize * 1.5
        } else {
            needsDownsample = true
        }

        if needsDownsample {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }

        return NSImage(contentsOf: url)
    }

    /// Extract the embedded JPEG preview from a RAW file.
    nonisolated static func extractEmbeddedPreview(from url: URL) -> NSImage? {
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
            return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
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
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 1, nil) {
                cacheLogger.info("\(filename): Using secondary image \(cgImage.width)x\(cgImage.height)")
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
