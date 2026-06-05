import AppKit
import CoreImage
import os.log

nonisolated private let cacheLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FullScreenCache")

/// LRU image cache with directional prefetching for full-screen image navigation.
/// Maintains separate caches for unedited and edited (CameraRaw) versions so toggling
/// edit rendering doesn't require re-decoding previously viewed images.
/// Each retina cache holds up to 12 screen-resolution images with a 256 MB cost limit;
/// preview caches hold up to 50 items with a 128 MB cost limit. Cost is the decoded
/// byte size of each CGImage, so HDR (RGBAh, 8 B/px) images evict sooner than SDR.
/// NSCache also auto-evicts under system memory pressure.
final class FullScreenImageCache: @unchecked Sendable {
    // Unedited image caches
    nonisolated(unsafe) private let cache = NSCache<NSURL, CGImage>()
    nonisolated(unsafe) private let displayPreviewCache = NSCache<NSURL, CGImage>()
    // Edited image caches (CameraRaw applied)
    nonisolated(unsafe) private let editedCache = NSCache<NSURL, CGImage>()
    nonisolated(unsafe) private let editedDisplayPreviewCache = NSCache<NSURL, CGImage>()

    nonisolated(unsafe) private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    nonisolated(unsafe) private var previewGenerationTask: Task<Void, Never>?
    nonisolated(unsafe) private var _isGeneratingPreviews = false
    nonisolated(unsafe) private var _previewsCompleted = 0
    nonisolated(unsafe) private var _previewsTotal = 0
    nonisolated(unsafe) private var _previewGeneration: UInt64 = 0
    private let lock = NSLock()

    init() {
        cache.countLimit = 12
        cache.totalCostLimit = 256 * 1024 * 1024            // 256 MB
        displayPreviewCache.countLimit = 50
        displayPreviewCache.totalCostLimit = 128 * 1024 * 1024  // 128 MB
        editedCache.countLimit = 12
        editedCache.totalCostLimit = 256 * 1024 * 1024          // 256 MB
        editedDisplayPreviewCache.countLimit = 50
        editedDisplayPreviewCache.totalCostLimit = 128 * 1024 * 1024  // 128 MB
    }

    // MARK: - Cache Access

    nonisolated func cachedImage(for url: URL, isEdited: Bool = false) -> CGImage? {
        let c = isEdited ? editedCache : cache
        return c.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: CGImage, for url: URL, isEdited: Bool = false) {
        let c = isEdited ? editedCache : cache
        c.setObject(image, forKey: url as NSURL, cost: Self.byteSize(of: image))
    }

    // MARK: - Display Preview Cache (960px)

    nonisolated func cachedDisplayPreview(for url: URL, isEdited: Bool = false) -> CGImage? {
        let c = isEdited ? editedDisplayPreviewCache : displayPreviewCache
        return c.object(forKey: url as NSURL)
    }

    nonisolated func storeDisplayPreview(_ image: CGImage, for url: URL, isEdited: Bool = false) {
        let c = isEdited ? editedDisplayPreviewCache : displayPreviewCache
        c.setObject(image, forKey: url as NSURL, cost: Self.byteSize(of: image))
    }

    nonisolated func clearDisplayPreviews() {
        displayPreviewCache.removeAllObjects()
        editedDisplayPreviewCache.removeAllObjects()
    }

    nonisolated func invalidateImage(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
        displayPreviewCache.removeObject(forKey: url as NSURL)
        editedCache.removeObject(forKey: url as NSURL)
        editedDisplayPreviewCache.removeObject(forKey: url as NSURL)
        // Cancel any in-flight prefetch for this URL — otherwise after a move/delete
        // it'll resume against a missing path and log a flood of IIOImageSource errors.
        let prefetch = lock.withLock { prefetchTasks.removeValue(forKey: url) }
        prefetch?.cancel()
    }

    /// Clear edited caches only (e.g. when edit parameters change globally).
    nonisolated func clearEdited() {
        editedCache.removeAllObjects()
        editedDisplayPreviewCache.removeAllObjects()
    }

    /// Clear all cached images and cancel in-flight tasks.
    /// Call on folder switch to avoid stale cache hits.
    nonisolated func clearAll() {
        cache.removeAllObjects()
        displayPreviewCache.removeAllObjects()
        editedCache.removeAllObjects()
        editedDisplayPreviewCache.removeAllObjects()
        cancelAllPrefetch()
        cancelPreviewGeneration()
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
        // Filter outside the lock — NSCache is thread-safe
        let uncached = urls.filter { displayPreviewCache.object(forKey: $0 as NSURL) == nil }

        lock.withLock {
            // Cancel existing task atomically with new task creation
            previewGenerationTask?.cancel()

            guard !uncached.isEmpty else {
                previewGenerationTask = nil
                _isGeneratingPreviews = false
                _previewsCompleted = 0
                _previewsTotal = 0
                return
            }

            _isGeneratingPreviews = true
            _previewsCompleted = 0
            _previewsTotal = uncached.count
            _previewGeneration += 1
            let generation = _previewGeneration

            previewGenerationTask = Task.detached(priority: .utility) { [weak self] in
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
                                self.storeDisplayPreview(image, for: url)
                            }
                        }
                    }

                    self.lock.withLock {
                        guard self._previewGeneration == generation else { return }
                        self._previewsCompleted = batchEnd
                    }
                }
                self.lock.withLock {
                    guard self._previewGeneration == generation else { return }
                    self._isGeneratingPreviews = false
                }
            }
        }
    }

    nonisolated func cancelPreviewGeneration() {
        lock.withLock {
            previewGenerationTask?.cancel()
            previewGenerationTask = nil
            _previewGeneration += 1
            _isGeneratingPreviews = false
            _previewsCompleted = 0
            _previewsTotal = 0
        }
    }

    // MARK: - Prefetching

    /// Prefetch adjacent images based on navigation direction.
    /// Loads 4 images ahead in travel direction and 2 behind, at medium priority.
    nonisolated func startPrefetch(currentIndex: Int, images: [URL], direction: NavigationDirection, screenMaxPx: CGFloat, isEdited: Bool = false, settingsForURL: (@Sendable (URL) -> CameraRawSettings?)? = nil, orientationForURL: (@Sendable (URL) -> Int)? = nil) {
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
                if cachedImage(for: url, isEdited: isEdited) != nil { return true }
                if prefetchTasks[url] != nil { return true }

                let task = Task.detached(priority: .medium) { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    defer { self.removePrefetchTask(for: url) }
                    let filename = url.lastPathComponent
                    cacheLogger.info("Prefetching \(filename) (edited=\(isEdited))")

                    var settings = settingsForURL?(url)
                    let orientation = orientationForURL?(url) ?? 1
                    var image: CGImage?
                    let isRAW = Self.isRawFile(url)

                    if settings != nil {
                        let ciImage: CIImage?
                        if isRAW {
                            // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering
                            if let rawResult = Self.loadRAWImage(from: url, draftMode: false, isHDR: settings?.hdrEditMode == 1) {
                                guard !Task.isCancelled else { return }
                                settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                                settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                                ciImage = Self.downsample(rawResult.image, maxPixelSize: screenMaxPx)
                            } else {
                                ciImage = nil
                            }
                        } else {
                            ciImage = Self.loadHDRPreview(from: url, maxPixelSize: screenMaxPx)
                            guard !Task.isCancelled else { return }
                        }
                        if let ciImage {
                            let processed = settings.map { CameraRawApproximation.applyWithCrop(to: ciImage, settings: $0, exifOrientation: orientation) } ?? ciImage
                            guard !Task.isCancelled else { return }
                            image = CameraRawApproximation.ciContext.createCGImage(
                                processed, from: processed.extent,
                                format: .RGBAh,
                                colorSpace: CameraRawApproximation.workingColorSpace
                            )
                        }
                    }
                    guard !Task.isCancelled else { return }
                    if image == nil {
                        // SDR fallback (or no edits active)
                        guard var loaded = Self.loadDownsampled(from: url, maxPixelSize: screenMaxPx) else {
                            cacheLogger.info("Prefetch failed: \(filename)")
                            return
                        }
                        guard !Task.isCancelled else { return }
                        if let settings {
                            loaded = Self.applyCameraRaw(to: loaded, settings: settings, exifOrientation: orientation)
                        }
                        image = loaded
                    }
                    guard let image, !Task.isCancelled else {
                        cacheLogger.info("Prefetch cancelled: \(filename)")
                        return
                    }

                    self.store(image, for: url, isEdited: isEdited)
                    cacheLogger.info("Prefetched \(filename) (\(image.width)x\(image.height), edited=\(isEdited))")
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

    /// If a prefetch for `url` is already in flight, await it instead of launching a
    /// duplicate decode, then return the freshly-cached image. Returns nil when no
    /// prefetch is in flight (or it produced a different edit variant / failed), in
    /// which case the caller decodes itself. Lets fast navigation reuse a decode that
    /// is already running rather than decoding the same image twice concurrently.
    nonisolated func awaitPrefetchedImage(for url: URL, isEdited: Bool = false) async -> CGImage? {
        guard let task = lock.withLock({ prefetchTasks[url] }) else { return nil }
        await task.value
        return cachedImage(for: url, isEdited: isEdited)
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
    
    struct RAWDecodeResult: @unchecked Sendable {
        let image: CIImage
        let neutralTemperature: Float
        let neutralTint: Float
    }

    /// Downsample a CIImage if its longest side exceeds the target by more than 1.5×.
    nonisolated static func downsample(_ ciImage: CIImage, maxPixelSize: CGFloat) -> CIImage {
        let extent = ciImage.extent
        let longestSide = max(extent.width, extent.height)
        guard longestSide > maxPixelSize * 1.5 else { return ciImage }
        let scale = maxPixelSize / longestSide
        return ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Load a RAW image via CIRAWFilter at a target max pixel size.
    /// Uses flat/neutral decode (no auto-boost) matching EditWorkspaceView's pipeline,
    /// then downsamples to the target resolution. Returns CIImage for downstream processing.
    nonisolated static func loadRAWPreview(from url: URL, maxPixelSize: CGFloat, draftMode: Bool = false, isHDR: Bool = false) -> CIImage? {
        guard let result = loadRAWImage(from: url, draftMode: draftMode, isHDR: isHDR) else { return nil }
        return downsample(result.image, maxPixelSize: maxPixelSize)
    }

    /// Load a RAW image using CIRAWFilter for optimized decoding.
    /// draftMode: true = bilinear demosaicing (2-5x faster), false = full quality AHD.
    /// Always decodes at full sensor resolution. Returns nil for unsupported formats
    /// (caller should fall back to loadHDRFullResolution).
    nonisolated static func loadRAWImage(
        from url: URL,
        draftMode: Bool = false,
        isHDR: Bool = false
    ) -> RAWDecodeResult? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            cacheLogger.info("CIRAWFilter unsupported for \(url.lastPathComponent), falling back")
            return nil
        }
        rawFilter.isDraftModeEnabled = draftMode
        rawFilter.boostAmount = 0        // disable auto-boost (Metal shader handles exposure)
        rawFilter.boostShadowAmount = 0  // disable shadow recovery boost
        // HDR: preserve highlight detail above SDR white as float values >1.0 so the
        // pipeline can expand it into HDR headroom. Default 0 = tone-map/clamp to SDR;
        // 1.0 = "use the most headroom present in the file" (lands ~4× / 800 nits for
        // typical RAWs); 2.0 = maximum, pushing highlights toward the ~8× / 1600-nit
        // ceiling to match Adobe Camera Raw's brighter HDR rendering.
        if isHDR { rawFilter.extendedDynamicRangeAmount = 2.0 }
        let neutralTemp = rawFilter.neutralTemperature
        let neutralTint = rawFilter.neutralTint
        guard let output = rawFilter.outputImage else {
            cacheLogger.warning("CIRAWFilter outputImage nil for \(url.lastPathComponent)")
            return nil
        }
        let extent = output.extent
        cacheLogger.info("RAW decoded \(url.lastPathComponent) draft=\(draftMode) \(Int(extent.width))x\(Int(extent.height)) asShot=\(Int(neutralTemp))K tint=\(Int(neutralTint))")
        return RAWDecodeResult(image: output, neutralTemperature: neutralTemp, neutralTint: neutralTint)
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

    /// Decoded byte size of a CGImage (actual backing-store footprint).
    nonisolated private static func byteSize(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    // RAW extension check usable from nonisolated context (avoids MainActor-isolated SupportedImageFormats)
    nonisolated private static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "nrw", "arw", "raf",
        "dng", "rw2", "orf", "pef", "srw",
    ]

    nonisolated static func isRawFile(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    enum NavigationDirection {
        case forward
        case backward
        case none
    }
}
