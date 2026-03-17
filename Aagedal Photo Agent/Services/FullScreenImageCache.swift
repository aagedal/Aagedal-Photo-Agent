import AppKit
import CoreImage
import os.log

nonisolated private let cacheLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FullScreenCache")

/// LRU image cache with directional prefetching for full-screen image navigation.
/// Holds up to 12 screen-resolution images (~480MB). NSCache auto-evicts under memory pressure.
final class FullScreenImageCache: @unchecked Sendable {
    nonisolated(unsafe) private let cache = NSCache<NSURL, CGImage>()
    nonisolated(unsafe) private let displayPreviewCache = NSCache<NSURL, CGImage>()
    nonisolated(unsafe) private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var previewGenerationTask: Task<Void, Never>?
    nonisolated(unsafe) private var _isGeneratingPreviews = false
    nonisolated(unsafe) private var _previewsCompleted = 0
    nonisolated(unsafe) private var _previewsTotal = 0
    private let lock = NSLock()

    init() {
        cache.countLimit = 12
        displayPreviewCache.countLimit = 50
    }

    // MARK: - Cache Access

    nonisolated func cachedImage(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: CGImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    // MARK: - Display Preview Cache (960px)

    nonisolated func cachedDisplayPreview(for url: URL) -> CGImage? {
        displayPreviewCache.object(forKey: url as NSURL)
    }

    nonisolated func storeDisplayPreview(_ image: CGImage, for url: URL) {
        displayPreviewCache.setObject(image, forKey: url as NSURL)
    }

    nonisolated func clearDisplayPreviews() {
        displayPreviewCache.removeAllObjects()
    }

    nonisolated func invalidateImage(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
        displayPreviewCache.removeObject(forKey: url as NSURL)
    }

    /// Clear all cached images (retina + display preview).
    /// Call when rendering mode changes (e.g. edit toggle) to avoid stale cache hits.
    nonisolated func clearAll() {
        cache.removeAllObjects()
        displayPreviewCache.removeAllObjects()
    }

    nonisolated var isGeneratingPreviews: Bool {
        lock.withLock { _isGeneratingPreviews }
    }

    nonisolated var previewsCompleted: Int {
        lock.withLock { _previewsCompleted }
    }

    nonisolated var previewsTotal: Int {
        lock.withLock { _previewsTotal }
    }

    // MARK: - Background Display Preview Generation

    nonisolated func startBackgroundPreviewGeneration(for urls: [URL], screenMaxPx: CGFloat) {
        cancelPreviewGeneration()
        let uncached = urls.filter { displayPreviewCache.object(forKey: $0 as NSURL) == nil }
        guard !uncached.isEmpty else { return }

        lock.withLock {
            _isGeneratingPreviews = true
            _previewsCompleted = 0
            _previewsTotal = uncached.count
        }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let batchSize = 4
            for batchStart in stride(from: 0, to: uncached.count, by: batchSize) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + batchSize, uncached.count)
                let batch = uncached[batchStart..<batchEnd]

                await withTaskGroup(of: Void.self) { group in
                    for url in batch {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            guard self.displayPreviewCache.object(forKey: url as NSURL) == nil else { return }
                            guard let image = Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else { return }
                            guard !Task.isCancelled else { return }
                            self.displayPreviewCache.setObject(image, forKey: url as NSURL)
                        }
                    }
                }

                self.lock.withLock { self._previewsCompleted = batchEnd }
            }
            self.lock.withLock { self._isGeneratingPreviews = false }
        }

        lock.withLock { previewGenerationTask = task }
    }

    nonisolated func cancelPreviewGeneration() {
        lock.withLock {
            previewGenerationTask?.cancel()
            previewGenerationTask = nil
            _isGeneratingPreviews = false
            _previewsCompleted = 0
            _previewsTotal = 0
        }
    }

    // MARK: - Prefetching

    /// Prefetch adjacent images based on navigation direction.
    /// Loads 4 images ahead in travel direction and 2 behind, at medium priority.
    nonisolated func startPrefetch(currentIndex: Int, images: [URL], direction: NavigationDirection, screenMaxPx: CGFloat, settingsForURL: (@Sendable (URL) -> CameraRawSettings?)? = nil, orientationForURL: (@Sendable (URL) -> Int)? = nil) {
        let ahead: [Int]
        let behind: [Int]

        switch direction {
        case .forward:
            ahead = [currentIndex + 1, currentIndex + 2, currentIndex + 3, currentIndex + 4]
            behind = [currentIndex - 1, currentIndex - 2]
        case .backward:
            ahead = [currentIndex - 1, currentIndex - 2, currentIndex - 3, currentIndex - 4]
            behind = [currentIndex + 1, currentIndex + 2]
        case .none:
            ahead = [currentIndex + 1, currentIndex - 1, currentIndex + 2, currentIndex - 2]
            behind = [currentIndex + 3, currentIndex - 3]
        }

        let targetIndices = (ahead + behind).filter { $0 >= 0 && $0 < images.count }
        let targetURLs = Set(targetIndices.map { images[$0] })

        let tasksToCancel = lock.withLock { () -> [Task<Void, Never>] in
            var toCancel: [Task<Void, Never>] = []
            for (url, task) in prefetchTasks where !targetURLs.contains(url) {
                toCancel.append(task)
                prefetchTasks.removeValue(forKey: url)
            }
            return toCancel
        }
        for task in tasksToCancel { task.cancel() }

        for url in targetURLs {
            // Atomically check cache/prefetch state AND register the task to prevent
            // a race where two concurrent callers both pass the guard and create duplicates.
            let alreadyHandled = lock.withLock { () -> Bool in
                if cachedImage(for: url) != nil { return true }
                if prefetchTasks[url] != nil { return true }

                let task = Task.detached(priority: .medium) { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    defer { self.removePrefetchTask(for: url) }
                    let filename = url.lastPathComponent
                    cacheLogger.info("Prefetching \(filename)")

                    let settings = settingsForURL?(url)
                    let orientation = orientationForURL?(url) ?? 1
                    var image: CGImage?

                    if settings != nil,
                       let ciImage = Self.loadHDRPreview(from: url, maxPixelSize: screenMaxPx) {
                        // HDR-preserving path: same decoder as EditWorkspaceView
                        let processed = settings.map { CameraRawApproximation.applyWithCrop(to: ciImage, settings: $0, exifOrientation: orientation) } ?? ciImage
                        image = CameraRawApproximation.ciContext.createCGImage(
                            processed, from: processed.extent,
                            format: .RGBAh,
                            colorSpace: CameraRawApproximation.workingColorSpace
                        )
                    }
                    if image == nil {
                        // SDR fallback (or no edits active)
                        guard var loaded = Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else {
                            cacheLogger.info("Prefetch failed: \(filename)")
                            return
                        }
                        if let settings {
                            loaded = Self.applyCameraRaw(to: loaded, settings: settings, exifOrientation: orientation)
                        }
                        image = loaded
                    }
                    guard let image, !Task.isCancelled else {
                        cacheLogger.info("Prefetch cancelled: \(filename)")
                        return
                    }

                    self.store(image, for: url)
                    cacheLogger.info("Prefetched \(filename) (\(image.width)x\(image.height))")
                }

                prefetchTasks[url] = task
                return false
            }
            if alreadyHandled { continue }
        }
    }

    nonisolated private func removePrefetchTask(for url: URL) {
        _ = lock.withLock { prefetchTasks.removeValue(forKey: url) }
    }

    nonisolated func cancelAllPrefetch() {
        let tasksToCancel = lock.withLock {
            let tasks = Array(prefetchTasks.values)
            prefetchTasks.removeAll()
            return tasks
        }
        for task in tasksToCancel { task.cancel() }
        cacheLogger.info("All prefetch tasks cancelled")
    }

    // MARK: - CameraRaw Processing

    nonisolated static func applyCameraRaw(to cgImage: CGImage, settings: CameraRawSettings, exifOrientation: Int = 1) -> CGImage {
        let ciImage = CIImage(cgImage: cgImage)
        let processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: exifOrientation)
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return cgImage }

        guard let result = CameraRawApproximation.ciContext.createCGImage(
            processed,
            from: extent,
            format: .RGBAh,
            colorSpace: CameraRawApproximation.workingColorSpace
        ) else {
            return cgImage
        }
        return result
    }

    // MARK: - Shared Image Loading

    /// Load an HDR-preserving preview via CoreImage, keeping float values >1.0.
    /// Returns CIImage directly so the edit pipeline can work in extended linear sRGB.
    /// Falls back to nil for formats CIImage can't decode (caller should use `loadDownsampled`).
    nonisolated static func loadHDRPreview(from url: URL, maxPixelSize: CGFloat) -> CIImage? {
        guard let ciImage = CIImage(contentsOf: url, options: [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ]) else { return nil }

        let extent = ciImage.extent
        let longestSide = max(extent.width, extent.height)
        guard longestSide > maxPixelSize * 1.5 else { return ciImage }

        let scale = maxPixelSize / longestSide
        return ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

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
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Load an HDR-preserving full-resolution image via CoreImage.
    /// Returns CIImage directly so the caller can process in extended linear sRGB.
    nonisolated static func loadHDRFullResolution(from url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ])
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
