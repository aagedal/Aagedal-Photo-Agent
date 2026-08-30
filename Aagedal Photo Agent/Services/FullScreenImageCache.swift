import AppKit
import CoreImage
import os.log

nonisolated private let cacheLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "FullScreenCache")

/// Immutable filesystem evidence needed before the full-screen viewer starts a decode. Reading
/// the sidecar and image header together keeps the edit settings, display orientation, file
/// orientation, and dimensions on one serialized boundary instead of interleaving UI-owned reads.
nonisolated struct FullScreenImagePresentationFacts: Equatable, Sendable {
    let requestID: UUID
    let imageURL: URL
    let sidecarCameraRaw: CameraRawSettings?
    let sidecarOrientation: Int?
    let fileOrientation: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

nonisolated enum FullScreenImagePresentationFactsResult: Equatable, Sendable {
    case loaded(FullScreenImagePresentationFacts)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, imageURL: URL)
}

nonisolated struct FullScreenImagePresentationFactsAccess: Sendable {
    struct Snapshot: Equatable, Sendable {
        let sidecarCameraRaw: CameraRawSettings?
        let sidecarOrientation: Int?
        let fileOrientation: Int?
        let pixelWidth: Int?
        let pixelHeight: Int?
    }

    let read: @Sendable (URL) -> Snapshot

    static let system = FullScreenImagePresentationFactsAccess { imageURL in
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let properties: [CFString: Any]? = {
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, options) else {
                return nil
            }
            return CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        }()
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let fileOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        let sidecarService = XMPSidecarService()
        let sidecarMetadata = sidecarService.sidecarDataIfExists(for: imageURL).flatMap { data in
            sidecarService.loadSidecar(fromData: data) {
                guard let pixelWidth, let pixelHeight, pixelHeight > 0 else { return nil }
                return Double(pixelWidth) / Double(pixelHeight)
            }
        }
        return Snapshot(
            sidecarCameraRaw: sidecarMetadata?.cameraRaw,
            sidecarOrientation: sidecarMetadata?.exifOrientation,
            fileOrientation: fileOrientation,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

/// Serializes the synchronous XMP and ImageIO header reads used to start full-screen presentation.
/// Those APIs cannot be preempted once entered, so cancellation on each side of the read is
/// returned explicitly and callers never publish a partial or superseded snapshot.
actor FullScreenImagePresentationFactsService {
    static let shared = FullScreenImagePresentationFactsService()

    private let access: FullScreenImagePresentationFactsAccess

    init(access: FullScreenImagePresentationFactsAccess = .system) {
        self.access = access
    }

    func load(imageURL: URL, requestID: UUID) -> FullScreenImagePresentationFactsResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }

        let snapshot = access.read(imageURL)
        guard !Task.isCancelled else {
            return .cancelledAfterRead(requestID: requestID, imageURL: imageURL)
        }

        return .loaded(FullScreenImagePresentationFacts(
            requestID: requestID,
            imageURL: imageURL,
            sidecarCameraRaw: snapshot.sidecarCameraRaw,
            sidecarOrientation: snapshot.sidecarOrientation,
            fileOrientation: snapshot.fileOrientation,
            pixelWidth: snapshot.pixelWidth,
            pixelHeight: snapshot.pixelHeight
        ))
    }
}

/// LRU image cache with directional prefetching for full-screen image navigation.
/// Maintains separate caches for unedited and edited (CameraRaw) versions so toggling
/// edit rendering doesn't require re-decoding previously viewed images.
/// Each retina cache holds up to 12 screen-resolution images with a 256 MB cost limit;
/// preview caches hold up to 50 items with a 128 MB cost limit. Cost is the decoded
/// byte size of each CGImage, so HDR (RGBAh, 8 B/px) images evict sooner than SDR.
/// NSCache also auto-evicts under system memory pressure.
final class FullScreenImageCache: @unchecked Sendable {
    // Unedited image caches
    nonisolated(unsafe) private let cache = NSCache<NSString, CGImage>()
    nonisolated(unsafe) private let displayPreviewCache = NSCache<NSString, CGImage>()
    // Edited image caches (CameraRaw applied)
    nonisolated(unsafe) private let editedCache = NSCache<NSString, CGImage>()
    nonisolated(unsafe) private let editedDisplayPreviewCache = NSCache<NSString, CGImage>()

    nonisolated(unsafe) private var prefetchTasks: [PrefetchKey: Task<Void, Never>] = [:]
    /// When true, `startPrefetch` is a no-op and in-flight prefetch is cancelled. Set while the
    /// develop editor is active: speculative prefetch decodes call ImageIO's XMP parsing
    /// (`CGImageSourceCopyPropertiesAtIndex`), which races the editor's concurrent NSXML sidecar
    /// write on libxml2's process-global state and crashes with EXC_BAD_ACCESS. Suppressing
    /// prefetch removes that out-of-band libxml2 consumer for the duration of editing.
    nonisolated(unsafe) private var _prefetchSuppressed = false
    nonisolated(unsafe) private var _editingMemoryProfile = false
    private let lock = NSLock()
    private let memoryCoordinator: ImageMemoryCoordinator
    nonisolated(unsafe) private var memoryRegistrations: [ImageMemoryCoordinator.Registration] = []
    /// NSCache cannot enumerate or remove keys by URL. Track the exact variants written
    /// to each cache so invalidating one image does not flush every edited preview.
    nonisolated(unsafe) private var imageKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var displayPreviewKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var editedImageKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var editedDisplayPreviewKeysByURL: [URL: Set<NSString>] = [:]

    private struct PrefetchKey: Hashable, Sendable {
        let url: URL
        let orientation: Int?
        let renderToken: String?
        let isEdited: Bool
    }

    init(memoryCoordinator: ImageMemoryCoordinator = .shared) {
        self.memoryCoordinator = memoryCoordinator
        memoryRegistrations = [
            memoryCoordinator.register(
                kind: .fullScreenPreview,
                cancelSpeculativeWork: { [weak self] in self?.cancelAllPrefetch() },
                applyLimit: { [weak self] limit in self?.applyPreviewLimit(limit) },
                evict: { [weak self] in self?.clearDisplayPreviews() }
            ),
            memoryCoordinator.register(
                kind: .fullScreenPrimary,
                applyLimit: { [weak self] limit in self?.applyPrimaryLimit(limit) },
                evict: { [weak self] in self?.clearPrimaryImages() }
            ),
        ]
    }

    nonisolated private func applyPreviewLimit(_ totalLimit: Int) {
        let perVariant = max(0, totalLimit / 2)
        displayPreviewCache.countLimit = 50
        displayPreviewCache.totalCostLimit = perVariant
        editedDisplayPreviewCache.countLimit = 50
        editedDisplayPreviewCache.totalCostLimit = perVariant
    }

    nonisolated private func applyPrimaryLimit(_ totalLimit: Int) {
        let editing = lock.withLock { _editingMemoryProfile }
        let perVariant = max(0, totalLimit / 2)
        cache.countLimit = 12
        cache.totalCostLimit = perVariant
        editedCache.countLimit = editing ? 2 : 12
        editedCache.totalCostLimit = editing ? min(perVariant, 64 * 1_024 * 1_024) : perVariant
    }

    // MARK: - Cache Access

    nonisolated private static func cacheKey(for url: URL, orientation: Int?, renderToken: String? = nil) -> NSString {
        let orientationSuffix = orientation.map { "|orientation=\($0)" } ?? ""
        let renderSuffix = renderToken.map { "|render=\($0)" } ?? ""
        return "\(url.standardizedFileURL.path)\(orientationSuffix)\(renderSuffix)" as NSString
    }

    /// Display orientation for sidecar-backed files. RAW/C2PA rotations are written to
    /// XMP, so speculative full-screen renders must not rely only on the browser model:
    /// fast navigation can prefetch before the async metadata pass has populated it.
    nonisolated static func displayOrientation(for url: URL, fallback: Int = 1) -> Int {
        XMPSidecarService().sidecarOrientation(for: url) ?? fallback
    }

    nonisolated static func renderToken(settings: CameraRawSettings?, isEdited: Bool) -> String? {
        guard isEdited else { return nil }
        guard let settings else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings) else { return "settings" }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    nonisolated func cachedImage(
        for url: URL,
        orientation: Int? = nil,
        renderToken: String? = nil,
        isEdited: Bool = false
    ) -> CGImage? {
        let c = isEdited ? editedCache : cache
        return c.object(forKey: Self.cacheKey(for: url, orientation: orientation, renderToken: renderToken))
    }

    nonisolated func store(
        _ image: CGImage,
        for url: URL,
        orientation: Int? = nil,
        renderToken: String? = nil,
        isEdited: Bool = false
    ) {
        let c = isEdited ? editedCache : cache
        let key = Self.cacheKey(for: url, orientation: orientation, renderToken: renderToken)
        lock.withLock {
            c.setObject(image, forKey: key, cost: Self.byteSize(of: image))
            if isEdited {
                editedImageKeysByURL[url, default: []].insert(key)
            } else {
                imageKeysByURL[url, default: []].insert(key)
            }
        }
    }

    // MARK: - Display Preview Cache (960px)

    nonisolated func cachedDisplayPreview(
        for url: URL,
        orientation: Int? = nil,
        renderToken: String? = nil,
        isEdited: Bool = false
    ) -> CGImage? {
        let c = isEdited ? editedDisplayPreviewCache : displayPreviewCache
        return c.object(forKey: Self.cacheKey(for: url, orientation: orientation, renderToken: renderToken))
    }

    nonisolated func storeDisplayPreview(
        _ image: CGImage,
        for url: URL,
        orientation: Int? = nil,
        renderToken: String? = nil,
        isEdited: Bool = false
    ) {
        let c = isEdited ? editedDisplayPreviewCache : displayPreviewCache
        let key = Self.cacheKey(for: url, orientation: orientation, renderToken: renderToken)
        lock.withLock {
            c.setObject(image, forKey: key, cost: Self.byteSize(of: image))
            if isEdited {
                editedDisplayPreviewKeysByURL[url, default: []].insert(key)
            } else {
                displayPreviewKeysByURL[url, default: []].insert(key)
            }
        }
    }

    nonisolated func clearDisplayPreviews() {
        lock.withLock {
            displayPreviewCache.removeAllObjects()
            editedDisplayPreviewCache.removeAllObjects()
            displayPreviewKeysByURL.removeAll()
            editedDisplayPreviewKeysByURL.removeAll()
        }
    }

    nonisolated private func clearPrimaryImages() {
        lock.withLock {
            cache.removeAllObjects()
            editedCache.removeAllObjects()
            imageKeysByURL.removeAll()
            editedImageKeysByURL.removeAll()
        }
    }

    nonisolated func invalidateImage(for url: URL) {
        let prefetches = lock.withLock {
            for key in imageKeysByURL.removeValue(forKey: url) ?? [] {
                cache.removeObject(forKey: key)
            }
            for key in displayPreviewKeysByURL.removeValue(forKey: url) ?? [] {
                displayPreviewCache.removeObject(forKey: key)
            }
            for key in editedImageKeysByURL.removeValue(forKey: url) ?? [] {
                editedCache.removeObject(forKey: key)
            }
            for key in editedDisplayPreviewKeysByURL.removeValue(forKey: url) ?? [] {
                editedDisplayPreviewCache.removeObject(forKey: key)
            }
            return removePrefetchTasksLocked(for: url)
        }
        // Cancel any in-flight prefetch for this URL — otherwise after a move/delete
        // it'll resume against a missing path and log a flood of IIOImageSource errors.
        for prefetch in prefetches { prefetch.cancel() }
    }

    /// Drop only the edited (rendered) cache entries for one URL — the unedited RAW
    /// decode stays valid because decoding no longer depends on edit state (HDR toggle,
    /// slider changes only alter the render). Cancels any in-flight prefetch since it
    /// may be rendering with the old settings.
    nonisolated func invalidateEditedImage(for url: URL) {
        let prefetches = lock.withLock {
            for key in editedImageKeysByURL.removeValue(forKey: url) ?? [] {
                editedCache.removeObject(forKey: key)
            }
            for key in editedDisplayPreviewKeysByURL.removeValue(forKey: url) ?? [] {
                editedDisplayPreviewCache.removeObject(forKey: key)
            }
            return removePrefetchTasksLocked(for: url)
        }
        for prefetch in prefetches { prefetch.cancel() }
    }

    /// Clear edited caches only (e.g. when edit parameters change globally).
    nonisolated func clearEdited() {
        lock.withLock {
            editedCache.removeAllObjects()
            editedDisplayPreviewCache.removeAllObjects()
            editedImageKeysByURL.removeAll()
            editedDisplayPreviewKeysByURL.removeAll()
        }
    }

    /// Clear all cached images and cancel in-flight tasks.
    /// Call on folder switch to avoid stale cache hits.
    nonisolated func clearAll() {
        lock.withLock {
            cache.removeAllObjects()
            displayPreviewCache.removeAllObjects()
            editedCache.removeAllObjects()
            editedDisplayPreviewCache.removeAllObjects()
            imageKeysByURL.removeAll()
            displayPreviewKeysByURL.removeAll()
            editedImageKeysByURL.removeAll()
            editedDisplayPreviewKeysByURL.removeAll()
        }
        cancelAllPrefetch()
    }

    // MARK: - Prefetch Suppression (develop editor)

    nonisolated var isPrefetchSuppressed: Bool {
        lock.withLock { _prefetchSuppressed }
    }

    /// Suppress (and immediately cancel) speculative prefetch while the develop editor is active,
    /// so its ImageIO XMP parsing can't race the editor's concurrent NSXML sidecar write — see
    /// `_prefetchSuppressed`. Idempotent.
    nonisolated func setPrefetchSuppressed(_ suppressed: Bool) {
        lock.withLock { _prefetchSuppressed = suppressed }
        if suppressed { cancelAllPrefetch() }
    }

    /// Tighten the edited-image cache limits while editing, then restore them on exit. Prefetch is
    /// suppressed during editing (`setPrefetchSuppressed`), so the editor only needs the current
    /// image cached; shrinking the cache evicts the retina HDR images that were exhausting IOSurface
    /// memory (`IOSurface creation failed: e00002c2`) during heavy edit sessions. Lowering an
    /// NSCache limit evicts immediately.
    nonisolated func setEditingMemoryProfile(_ editing: Bool) {
        lock.withLock { _editingMemoryProfile = editing }
        applyPrimaryLimit(memoryCoordinator.adaptiveLimit(
            for: .fullScreenPrimary,
            sourcePixelSize: nil,
            bytesPerPixel: 8
        ))
    }

    // MARK: - Prefetching

    /// Prefetch adjacent images based on navigation direction.
    /// Loads 4 images ahead in travel direction and 2 behind, at medium priority.
    nonisolated func startPrefetch(currentIndex: Int, images: [URL], direction: NavigationDirection, screenMaxPx: CGFloat, isEdited: Bool = false, settingsForURL: (@Sendable (URL) -> CameraRawSettings?)? = nil, orientationForURL: (@Sendable (URL) -> Int)? = nil) {
        // Suppressed while the develop editor is active so prefetch's ImageIO XMP parsing can't
        // race the editor's concurrent NSXML sidecar write — see `_prefetchSuppressed`.
        if isPrefetchSuppressed { return }

        let sourceSize = CGSize(width: screenMaxPx, height: screenMaxPx)
        applyPrimaryLimit(memoryCoordinator.adaptiveLimit(
            for: .fullScreenPrimary,
            sourcePixelSize: sourceSize,
            bytesPerPixel: 8
        ))
        applyPreviewLimit(memoryCoordinator.adaptiveLimit(
            for: .fullScreenPreview,
            sourcePixelSize: sourceSize,
            bytesPerPixel: 8
        ))
        let itemLimit = memoryCoordinator.prefetchItemLimit(
            for: .fullScreenPrimary,
            sourcePixelSize: sourceSize,
            bytesPerPixel: 8,
            maximum: 6
        )
        guard itemLimit > 0 else {
            cancelAllPrefetch()
            return
        }

        let candidates: [Int]
        switch direction {
        case .forward:
            candidates = [1, 2, 3, 4, -1, -2]
        case .backward:
            candidates = [-1, -2, -3, -4, 1, 2]
        case .none:
            candidates = [1, -1, 2, -2, 3, -3]
        }

        let targetIndices = candidates.prefix(itemLimit)
            .map { currentIndex + $0 }
            .filter { $0 >= 0 && $0 < images.count }
        let targetURLs = Set(targetIndices.map { images[$0] })

        let tasksToCancel = lock.withLock { () -> [Task<Void, Never>] in
            var toCancel: [Task<Void, Never>] = []
            let keysToCancel = prefetchTasks.keys.filter { !targetURLs.contains($0.url) }
            for key in keysToCancel {
                guard let task = prefetchTasks.removeValue(forKey: key) else { continue }
                toCancel.append(task)
            }
            return toCancel
        }
        for task in tasksToCancel { task.cancel() }

        for url in targetURLs {
            let settings = settingsForURL?(url)
                ?? (isEdited ? XMPSidecarService().loadSidecar(for: url)?.cameraRaw : nil)
            let requestedOrientation = orientationForURL?(url)
            let cacheOrientation = requestedOrientation.map {
                Self.displayOrientation(for: url, fallback: $0)
            }
            let renderToken = Self.renderToken(settings: settings, isEdited: isEdited)
            let prefetchKey = PrefetchKey(
                url: url,
                orientation: cacheOrientation,
                renderToken: renderToken,
                isEdited: isEdited
            )

            // Atomically check cache/prefetch state AND register the task to prevent
            // a race where two concurrent callers both pass the guard and create duplicates.
            let alreadyHandled = lock.withLock { () -> Bool in
                if cachedImage(
                    for: url,
                    orientation: cacheOrientation,
                    renderToken: renderToken,
                    isEdited: isEdited
                ) != nil { return true }
                if prefetchTasks[prefetchKey] != nil { return true }

                let task = Task.detached(priority: .medium) { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    defer { self.removePrefetchTask(for: prefetchKey) }
                    let filename = url.lastPathComponent
                    cacheLogger.info("Prefetching \(filename) (edited=\(isEdited))")

                    let orientation = cacheOrientation ?? Self.displayOrientation(for: url)
                    guard let image = await Self.decodedEditedPreview(
                        for: url, settings: settings, orientation: orientation, screenMaxPx: screenMaxPx
                    ), !Task.isCancelled else {
                        cacheLogger.info("Prefetch failed/cancelled: \(filename)")
                        return
                    }

                    self.store(
                        image,
                        for: url,
                        orientation: cacheOrientation,
                        renderToken: renderToken,
                        isEdited: isEdited
                    )
                    cacheLogger.info("Prefetched \(filename) (\(image.width)x\(image.height), edited=\(isEdited))")
                }

                prefetchTasks[prefetchKey] = task
                return false
            }
            if alreadyHandled { continue }
        }
    }

    nonisolated private func removePrefetchTask(for key: PrefetchKey) {
        _ = lock.withLock { prefetchTasks.removeValue(forKey: key) }
    }

    nonisolated private func removePrefetchTasksLocked(for url: URL) -> [Task<Void, Never>] {
        var removed: [Task<Void, Never>] = []
        let keysToRemove = prefetchTasks.keys.filter { $0.url == url }
        for key in keysToRemove {
            if let task = prefetchTasks.removeValue(forKey: key) {
                removed.append(task)
            }
        }
        return removed
    }

    /// Return a completed prefetch cache hit, or await an in-flight prefetch for `url`
    /// instead of launching a duplicate decode. Returns nil when no matching prefetch
    /// exists (or it produced a different edit variant / failed), in which case the
    /// caller decodes itself. Lets fast navigation reuse a decode that is already
    /// running rather than decoding the same image twice concurrently.
    nonisolated func awaitPrefetchedImage(
        for url: URL,
        orientation: Int? = nil,
        renderToken: String? = nil,
        isEdited: Bool = false
    ) async -> CGImage? {
        let key = PrefetchKey(
            url: url,
            orientation: orientation,
            renderToken: renderToken,
            isEdited: isEdited
        )
        if let cached = cachedImage(for: url, orientation: orientation, renderToken: renderToken, isEdited: isEdited) {
            return cached
        }
        guard let task = lock.withLock({ prefetchTasks[key] }) else { return nil }
        await task.value
        return cachedImage(for: url, orientation: orientation, renderToken: renderToken, isEdited: isEdited)
    }

    /// Proactively re-render edited screen-res previews for specific URLs into the edited cache,
    /// replacing any stale entries. Called on develop-editor exit so the return to the grid/loupe
    /// is an instant cache hit instead of a reactive re-decode (which causes a brief stale flash).
    /// Renders via the shared `decodedEditedPreview` path — same RAW/HDR/SDR handling, as-shot WB,
    /// and EDR headroom stamp as the loupe and prefetch. Low priority; never touches the unedited
    /// caches. The reactive `onChange`/folder-poll paths remain the safety net for edits that reach
    /// an image without the editor (batch paste, reset, external app).
    nonisolated func warmEditedPreviews(
        for urls: [URL],
        screenMaxPx: CGFloat,
        settingsForURL: @escaping @Sendable (URL) -> CameraRawSettings?,
        orientationForURL: @escaping @Sendable (URL) -> Int
    ) {
        let targets = Array(Set(urls))
        guard !targets.isEmpty else { return }
        // Drop the stale edited renders synchronously so a concurrent loupe/grid read can't serve
        // an entry baked under the old settings before the fresh render lands.
        for url in targets { invalidateEditedImage(for: url) }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            for url in targets {
                guard !Task.isCancelled else { break }
                guard let settings = settingsForURL(url) else { continue }
                let orientation = orientationForURL(url)
                guard let image = await Self.decodedEditedPreview(
                    for: url, settings: settings, orientation: orientation, screenMaxPx: screenMaxPx
                ) else { continue }
                guard !Task.isCancelled else { break }
                let renderToken = Self.renderToken(settings: settings, isEdited: true)
                self.store(image, for: url, orientation: orientation, renderToken: renderToken, isEdited: true)
                cacheLogger.info("Warmed edited preview on exit: \(url.lastPathComponent) (\(image.width)x\(image.height))")
            }
        }
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

        return CameraRawApproximation.createDisplayCGImage(processed, from: extent) ?? cgImage
    }

    /// Decode `url` at screen resolution, applying `settings` if present, and return a
    /// display-ready CGImage. RAW → CIRAWFilter flat/neutral decode with as-shot WB; other
    /// formats → HDR-preserving preview; SDR fallback for formats CoreImage can't decode.
    /// When `settings` is non-nil the edit is baked in and EDR content headroom stamped so the
    /// result engages EDR on display (matches the foreground render path). Returns nil if the
    /// decode fails or the task is cancelled. Shared by `startPrefetch` and `warmEditedPreviews`
    /// so both render edited previews identically — keep this the single edited-decode path.
    nonisolated static func decodedEditedPreview(
        for url: URL,
        settings: CameraRawSettings?,
        orientation: Int,
        screenMaxPx: CGFloat
    ) async -> CGImage? {
        var settings = settings
        var image: CGImage?
        let isRAW = isRawFile(url)

        // Every decode below bakes the FILE's orientation into the pixels (CIRAWFilter,
        // CIImage's applyOrientationProperty, and CGImageSource's thumbnail transform all
        // apply the embedded tag). The requested `orientation` (the in-memory/sidecar
        // display orientation) can differ — RAW/C2PA rotations never touch the file.
        // `applyWithCrop`'s exifOrientation parameter means "the frame the PIXELS are in"
        // (it transforms sensor-frame crop/mask geometry, it does not rotate pixels), so
        // crop/masks must be applied in the FILE frame and the pixels then rotated
        // file → target as a separate step — exactly the loupe's two-step approach.
        // Passing the target orientation to applyWithCrop instead mis-framed the crop and
        // left the pixels unrotated: cropped-RAW grid thumbnails rendered 180° off from
        // the edit view for sidecar-rotated files.
        let rawFileOrientation = fileEXIFOrientation(at: url)
        let sourceMaxPx: CGFloat
        if settings?.crop?.isEffectiveCrop == true {
            sourceMaxPx = cropAwareSourceMaxPixelSize(
                outputMaxPixelSize: screenMaxPx,
                settings: settings,
                exifOrientation: rawFileOrientation,
                sourcePixelSize: nativePixelSize(of: url)
            )
        } else {
            sourceMaxPx = screenMaxPx
        }

        if settings != nil {
            let ciImage: CIImage?
            if isRAW {
                // Use CIRAWFilter for flat/neutral decode — get as-shot WB for correct rendering
                if let rawResult = loadRAWImage(from: url, draftMode: false, maxPixelSize: sourceMaxPx) {
                    guard !Task.isCancelled else { return nil }
                    settings?.asShotNeutralTemperature = Double(rawResult.neutralTemperature)
                    settings?.asShotNeutralTint = Double(rawResult.neutralTint)
                    settings?.sourceHasHDRHeadroom = true
                    ciImage = downsample(rawResult.image, maxPixelSize: sourceMaxPx)
                } else {
                    ciImage = nil
                }
            } else {
                ciImage = await loadHDRPreviewOffPool(from: url, maxPixelSize: sourceMaxPx)
                guard !Task.isCancelled else { return nil }
            }
            if let ciImage {
                var processed: CIImage
                if let settings {
                    // Async: suspends on the dedicated render queue rather than blocking this
                    // task's cooperative-pool thread across the GPU wait.
                    processed = await CameraRawApproximation.applyWithCropAsync(to: ciImage, settings: settings, exifOrientation: rawFileOrientation)
                } else {
                    processed = ciImage
                }
                let correction = ImageFile.orientationCorrection(from: rawFileOrientation, to: orientation)
                if correction != .up {
                    processed = processed.oriented(correction)
                }
                guard !Task.isCancelled else { return nil }
                image = CameraRawApproximation.createDisplayCGImage(processed, from: processed.extent)
            }
        }
        guard !Task.isCancelled else { return nil }
        if image == nil {
            // SDR fallback (or no edits active)
            guard let loadedResult = await loadDownsampledOffPoolWithOrientation(
                from: url,
                maxPixelSize: sourceMaxPx
            ) else { return nil }
            var loaded = loadedResult.image
            let loadedOrientation = loadedResult.orientation
            guard !Task.isCancelled else { return nil }
            if let settings {
                loaded = applyCameraRaw(to: loaded, settings: settings, exifOrientation: loadedOrientation)
            }
            let correction = ImageFile.orientationCorrection(from: loadedOrientation, to: orientation)
            if correction != .up {
                let rotated = CIImage(cgImage: loaded).oriented(correction)
                if let cg = CameraRawApproximation.createDisplayCGImage(rotated, from: rotated.extent) {
                    loaded = cg
                }
            }
            image = loaded
        }
        return image
    }

    /// Chooses the pre-crop decode size needed for a requested final preview size.
    ///
    /// Preview loaders normally constrain the full frame's longest edge to `outputMaxPixelSize`.
    /// A subsequent crop then throws away part of that already-small bitmap. For example, when
    /// the visible crop's longest edge covers one third of the source's longest edge, decoding
    /// the source at 3x the output target leaves the cropped result at the intended resolution.
    /// The request is capped at the native longest edge so very tight crops never ask a decoder
    /// to upscale beyond the source.
    nonisolated static func cropAwareSourceMaxPixelSize(
        outputMaxPixelSize: CGFloat,
        settings: CameraRawSettings?,
        exifOrientation: Int,
        sourcePixelSize: CGSize?
    ) -> CGFloat {
        guard outputMaxPixelSize > 0,
              let sensorCrop = settings?.crop,
              sensorCrop.isEffectiveCrop,
              let sourcePixelSize,
              sourcePixelSize.width > 0,
              sourcePixelSize.height > 0 else { return outputMaxPixelSize }

        let swapsAxes = (5...8).contains(exifOrientation)
        let displayWidth = swapsAxes ? sourcePixelSize.height : sourcePixelSize.width
        let displayHeight = swapsAxes ? sourcePixelSize.width : sourcePixelSize.height
        let sourceLongestEdge = max(displayWidth, displayHeight)

        let crop = sensorCrop.transformedForDisplay(orientation: exifOrientation)
        let cropWidth = CGFloat(abs((crop.right ?? 1) - (crop.left ?? 0))) * displayWidth
        let cropHeight = CGFloat(abs((crop.bottom ?? 1) - (crop.top ?? 0))) * displayHeight
        let croppedLongestFraction = max(cropWidth, cropHeight) / sourceLongestEdge
        guard croppedLongestFraction.isFinite, croppedLongestFraction > 0 else {
            return outputMaxPixelSize
        }

        let requiredSourceSize = outputMaxPixelSize / croppedLongestFraction
        return min(sourceLongestEdge, max(outputMaxPixelSize, requiredSourceSize))
    }

    // MARK: - Shared Image Loading

    /// Load an HDR-preserving preview via CoreImage, keeping float values >1.0.
    /// Returns CIImage directly so the edit pipeline can work in extended linear sRGB.
    /// Falls back to nil for formats CIImage can't decode (caller should use `loadDownsampled`).
    nonisolated static func loadHDRPreview(from url: URL, maxPixelSize: CGFloat) -> CIImage? {
        loadHDRPreviewWithOrientation(from: url, maxPixelSize: maxPixelSize)?.image
    }

    /// Variant of `loadHDRPreview` that also reports the EXIF orientation baked into the
    /// returned pixels. `.applyOrientationProperty` bakes the file's orientation into the
    /// pixels but RESETS the resulting CIImage's reported orientation to 1 (`up`) — so we
    /// must read the file's tag directly for the correction, not `ciImage.properties`
    /// (which would say 1 for an already-rotated file and make the caller over-rotate).
    nonisolated static func loadHDRPreviewWithOrientation(
        from url: URL, maxPixelSize: CGFloat
    ) -> (image: CIImage, orientation: Int)? {
        // Read the tag first so it reflects the same bytes the decode below bakes in.
        let orientation = fileEXIFOrientation(at: url)
        var options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ]
        // Only adaptive JPEG/HEIF containers need an auxiliary gain-map expansion.
        // Asking Core Image to expand direct-HDR TIFF/JXL/PNG files makes ImageIO probe
        // an auxiliary channel those formats do not carry. On large archive TIFFs that
        // unnecessary probe delayed the edited retina render and emitted
        // CGImageSourceCopyAuxiliaryDataInfoAtIndexWithOptionsEx errors.
        if usesAdaptiveHDRExpansion(for: url) {
            options[.expandToHDR] = true
        }
        guard let ciImage = CIImage(contentsOf: url, options: options) else { return nil }

        let extent = ciImage.extent
        let longestSide = max(extent.width, extent.height)
        guard longestSide > maxPixelSize * 1.5 else { return (ciImage, orientation) }

        let scale = maxPixelSize / longestSide
        return (ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), orientation)
    }

    /// Dedicated GCD queue for blocking Core Image and ImageIO file initialization.
    /// Core Image can synchronously wait on its own utility-QoS workers while opening a file.
    /// Running that call directly from a user-initiated Task both occupies a cooperative-pool
    /// thread and triggers Thread Performance Checker's priority-inversion warning. Awaiting a
    /// continuation from this matching utility queue suspends the caller instead.
    nonisolated private static let backgroundDecodeQueue = DispatchQueue(
        label: "com.aagedal.photo-agent.preview-decode",
        qos: .utility,
        attributes: .concurrent
    )

    /// Embedded RAW preview extraction must run at the same QoS as ImageIO's own
    /// default-QoS workers. An enforced work-item QoS prevents a foreground caller's
    /// priority from being inferred by GCD, while the continuation lets that caller
    /// suspend instead of synchronously waiting on ImageIO.
    nonisolated private static let embeddedPreviewDecodeQueue = DispatchQueue(
        label: "com.aagedal.photo-agent.embedded-preview-decode",
        qos: .default,
        attributes: .concurrent
    )

    /// Async boundary for Core Image preview initialization. Prefer this from foreground Tasks;
    /// the synchronous variant remains available to already-utility background work.
    nonisolated static func loadHDRPreviewOffPool(
        from url: URL,
        maxPixelSize: CGFloat
    ) async -> CIImage? {
        await loadHDRPreviewOffPoolWithOrientation(from: url, maxPixelSize: maxPixelSize)?.image
    }

    nonisolated static func loadHDRPreviewOffPoolWithOrientation(
        from url: URL,
        maxPixelSize: CGFloat
    ) async -> (image: CIImage, orientation: Int)? {
        await withCheckedContinuation { continuation in
            backgroundDecodeQueue.async {
                continuation.resume(returning: loadHDRPreviewWithOrientation(
                    from: url,
                    maxPixelSize: maxPixelSize
                ))
            }
        }
    }

    /// Run `loadDownsampled` off the Swift cooperative thread pool. See `backgroundDecodeQueue`.
    nonisolated static func loadDownsampledOffPool(from url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await loadDownsampledOffPoolWithOrientation(from: url, maxPixelSize: maxPixelSize)?.image
    }

    /// Run `loadDownsampledWithOrientation` off the Swift cooperative thread pool.
    /// See `backgroundDecodeQueue`.
    nonisolated static func loadDownsampledOffPoolWithOrientation(
        from url: URL, maxPixelSize: CGFloat
    ) async -> (image: CGImage, orientation: Int)? {
        await withCheckedContinuation { continuation in
            backgroundDecodeQueue.async {
                continuation.resume(returning: loadDownsampledWithOrientation(from: url, maxPixelSize: maxPixelSize))
            }
        }
    }

    nonisolated static func loadDownsampled(from url: URL, maxPixelSize: CGFloat) -> CGImage? {
        loadDownsampledWithOrientation(from: url, maxPixelSize: maxPixelSize)?.image
    }

    /// Variant of `loadDownsampled` that also reports the EXIF orientation baked into the
    /// returned pixels, read from the same `CGImageSource`. See `loadHDRPreviewWithOrientation`.
    nonisolated static func loadDownsampledWithOrientation(
        from url: URL, maxPixelSize: CGFloat
    ) -> (image: CGImage, orientation: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Determine target size: downsample if significantly larger, otherwise use actual size
        // (still go through the thumbnail API so orientation transform is always applied)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let targetSize: CGFloat
        if let pw = props?[kCGImagePropertyPixelWidth] as? Int,
           let ph = props?[kCGImagePropertyPixelHeight] as? Int {
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return (image, orientation)
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

    /// Native pixel dimensions of an image file, read from metadata only (no decode).
    nonisolated static func nativePixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: pw, height: ph)
    }

    /// Native longest-side pixel dimension. Pre-orientation, but the longest side is
    /// orientation-invariant.
    nonisolated static func nativeLongestSide(of url: URL) -> CGFloat? {
        guard let size = nativePixelSize(of: url) else { return nil }
        return max(size.width, size.height)
    }

    /// Load a RAW image via CIRAWFilter at a target max pixel size.
    /// Decode profile (Linear RAW vs Camera RAW) and decoder version are configurable
    /// in Settings. Decoding happens directly at preview scale via CIRAWFilter.scaleFactor.
    /// Returns CIImage for downstream processing.
    nonisolated static func loadRAWPreview(from url: URL, maxPixelSize: CGFloat, draftMode: Bool = false) -> CIImage? {
        guard let result = loadRAWImage(from: url, draftMode: draftMode, maxPixelSize: maxPixelSize) else { return nil }
        // Final clamp against scaleFactor rounding; a no-op once scaleFactor has shrunk it.
        return downsample(result.image, maxPixelSize: maxPixelSize)
    }

    /// Load a RAW image using CIRAWFilter for optimized decoding.
    /// draftMode: true = bilinear demosaicing (2-5x faster), false = full quality AHD.
    /// maxPixelSize: when set, the RAW engine demosaics directly at that longest-side
    /// resolution (faster + far less memory than decoding full sensor then shrinking);
    /// nil decodes at full sensor resolution. Returns nil for unsupported formats
    /// (caller should fall back to loadHDRFullResolution).
    nonisolated static func loadRAWImage(
        from url: URL,
        draftMode: Bool = false,
        maxPixelSize: CGFloat? = nil,
        decodeProfile: RAWDecodeProfile? = nil
    ) -> RAWDecodeResult? {
        guard let rawFilter = CIRAWFilter(imageURL: url) else {
            cacheLogger.info("CIRAWFilter unsupported for \(url.lastPathComponent), falling back")
            return nil
        }
        rawFilter.isDraftModeEnabled = draftMode

        // Camera RAW (default) leaves CIRAWFilter's own camera-matched boost/tone curve
        // in place, closer to Finder/Preview. Linear RAW disables that boost so the Metal
        // shader gets neutral scene-referred input.
        let profile: RAWDecodeProfile
        if let decodeProfile {
            profile = decodeProfile
        } else {
            let profileRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.rawDecodeProfile)
            profile = RAWDecodeProfile(storedRawValue: profileRaw ?? "") ?? .camera
        }
        if profile == .linear {
            rawFilter.boostAmount = 0
            rawFilter.boostShadowAmount = 0
        }

        // Auto leaves CIRAWFilter on the newest supported decoder for this image. Pinned
        // versions are matched against the image-specific supported versions, which may be
        // reported as e.g. "9" or "9DNG" depending on the container.
        let decoderVersionRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.rawDecoderVersionPreference)
        if let token = RAWDecoderVersionPreference(rawValue: decoderVersionRaw ?? "")?.matchToken,
           let match = rawFilter.supportedDecoderVersions.first(where: { $0.rawValue.contains(token) }) {
            rawFilter.decoderVersion = match
        }

        // Decode straight to the requested preview size: demosaic at the reduced scale
        // instead of decoding the full sensor and shrinking afterward. Only ever downscale,
        // and keep the same 1.5× slack the affine downsample used so output sizes are unchanged.
        if let maxPixelSize, let longestSide = nativeLongestSide(of: url),
           longestSide > maxPixelSize * 1.5 {
            rawFilter.scaleFactor = Float(maxPixelSize / longestSide)
        }
        // Always decode scene-referred with maximum EDR headroom: highlight detail
        // above SDR white survives as float values >1.0. (0 = tone-map/clamp to SDR;
        // 1.0 = "use the headroom present in the file" ~4×/800 nits; 2.0 = maximum,
        // toward the ~8×/1600-nit ceiling, matching Adobe Camera Raw's HDR rendering.)
        // SDR vs HDR is now purely an output decision: SDR mode rolls the headroom off
        // via ToneCurveGenerator's output tonemap (sourceHasHDRHeadroom), so toggling
        // HDR never requires a re-decode and SDR keeps real highlight recovery.
        rawFilter.extendedDynamicRangeAmount = 2.0
        let neutralTemp = rawFilter.neutralTemperature
        let neutralTint = rawFilter.neutralTint
        guard let output = rawFilter.outputImage else {
            cacheLogger.warning("CIRAWFilter outputImage nil for \(url.lastPathComponent)")
            return nil
        }
        let extent = output.extent
        cacheLogger.info("RAW decoded \(url.lastPathComponent) draft=\(draftMode) profile=\(profile.rawValue) decoder=\(rawFilter.decoderVersion.rawValue) scale=\(rawFilter.scaleFactor, format: .fixed(precision: 3)) \(Int(extent.width))x\(Int(extent.height)) asShot=\(Int(neutralTemp))K tint=\(Int(neutralTint))")
        return RAWDecodeResult(image: output, neutralTemperature: neutralTemp, neutralTint: neutralTint)
    }

    /// Load an HDR-preserving full-resolution image via CoreImage.
    /// Returns CIImage directly so the caller can process in extended linear sRGB.
    nonisolated static func loadHDRFullResolution(from url: URL) -> CIImage? {
        loadHDRFullResolutionWithOrientation(from: url)?.image
    }

    /// Variant of `loadHDRFullResolution` that also reports the EXIF orientation baked
    /// into the returned pixels. Reads the file's tag directly, not `ciImage.properties`,
    /// which `.applyOrientationProperty` resets to 1. See `loadHDRPreviewWithOrientation`.
    nonisolated static func loadHDRFullResolutionWithOrientation(
        from url: URL
    ) -> (image: CIImage, orientation: Int)? {
        let orientation = fileEXIFOrientation(at: url)
        var options: [CIImageOption: Any] = [
            .applyOrientationProperty: true,
            .toneMapHDRtoSDR: false
        ]
        if usesAdaptiveHDRExpansion(for: url) {
            options[.expandToHDR] = true
        }
        guard let ciImage = CIImage(contentsOf: url, options: options) else { return nil }
        return (ciImage, orientation)
    }

    /// Gain maps are currently supported by the app only in JPEG and HEIF containers.
    /// Direct-HDR formats already expose their PQ/HLG pixels without `.expandToHDR`.
    nonisolated static func usesAdaptiveHDRExpansion(for url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "heic", "heif":
            true
        default:
            false
        }
    }

    /// Async boundary for the full-resolution form of `CIImage(contentsOf:)`.
    nonisolated static func loadHDRFullResolutionOffPool(from url: URL) async -> CIImage? {
        await loadHDRFullResolutionOffPoolWithOrientation(from: url)?.image
    }

    nonisolated static func loadHDRFullResolutionOffPoolWithOrientation(
        from url: URL
    ) async -> (image: CIImage, orientation: Int)? {
        await withCheckedContinuation { continuation in
            backgroundDecodeQueue.async {
                continuation.resume(returning: loadHDRFullResolutionWithOrientation(from: url))
            }
        }
    }

    /// Load an image at full source resolution, preserving color space and bit depth.
    /// Uses CGImageSourceCreateThumbnailAtIndex to ensure EXIF orientation is applied.
    nonisolated static func loadFullResolution(from url: URL) -> CGImage? {
        loadFullResolutionWithOrientation(from: url)?.image
    }

    /// Variant of `loadFullResolution` that also reports the EXIF orientation baked into
    /// the returned pixels, read from the same `CGImageSource`. See `loadHDRPreviewWithOrientation`.
    nonisolated static func loadFullResolutionWithOrientation(
        from url: URL
    ) -> (image: CGImage, orientation: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Read actual pixel dimensions to use as maxPixelSize (no downsampling, but orientation IS applied)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let maxDimension: CGFloat
        if let pw = props?[kCGImagePropertyPixelWidth] as? Int,
           let ph = props?[kCGImagePropertyPixelHeight] as? Int {
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
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return (image, orientation)
    }

    nonisolated static func loadFullResolutionOffPool(from url: URL) async -> CGImage? {
        await loadFullResolutionOffPoolWithOrientation(from: url)?.image
    }

    nonisolated static func loadFullResolutionOffPoolWithOrientation(
        from url: URL
    ) async -> (image: CGImage, orientation: Int)? {
        await withCheckedContinuation { continuation in
            backgroundDecodeQueue.async {
                continuation.resume(returning: loadFullResolutionWithOrientation(from: url))
            }
        }
    }

    /// The file's current EXIF orientation tag (1 if absent or unreadable). For decodes
    /// whose loader can't report the orientation it baked (e.g. `CIRAWFilter`), read this
    /// adjacent to the decode so a pending rotation write can't slip in between.
    nonisolated static func fileEXIFOrientation(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let orientation = props[kCGImagePropertyOrientation] as? Int else { return 1 }
        return orientation
    }

    /// Async boundary for embedded RAW preview extraction. Keep conversion and rendering
    /// outside this helper so the enforced default-QoS work item contains only ImageIO work.
    nonisolated static func extractEmbeddedPreviewOffPool(
        from url: URL
    ) async -> CGImage? {
        await extractEmbeddedPreviewOffPoolWithOrientation(from: url)?.image
    }

    nonisolated static func extractEmbeddedPreviewOffPoolWithOrientation(
        from url: URL
    ) async -> (image: CGImage, orientation: Int)? {
        await withCheckedContinuation { continuation in
            let workItem = DispatchWorkItem(qos: .default, flags: .enforceQoS) {
                continuation.resume(returning: extractEmbeddedPreviewWithOrientation(from: url))
            }
            embeddedPreviewDecodeQueue.async(execute: workItem)
        }
    }

    /// Synchronous ImageIO implementation, reachable only through the default-QoS async
    /// boundary above so foreground Tasks never perform this blocking call directly.
    nonisolated private static func extractEmbeddedPreviewWithOrientation(
        from url: URL
    ) -> (image: CGImage, orientation: Int)? {
        let filename = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            cacheLogger.warning("\(filename): CGImageSourceCreateWithURL failed")
            return nil
        }
        let primaryOrientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1

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
            return (cgThumb, primaryOrientation)
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
                let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 1, nil)
                    as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? primaryOrientation
                return (cgImage, orientation)
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
