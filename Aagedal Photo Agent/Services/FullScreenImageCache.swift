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
            sidecarCameraRaw: PhotoSidecarOwnership.stemSidecarCameraRaw(sidecarMetadata?.cameraRaw, for: imageURL),
            sidecarOrientation: MetadataSidecarService().loadSidecar(for: imageURL, in: imageURL.deletingLastPathComponent())?
                .orientationDraft?.targetOrientation ?? sidecarMetadata?.exifOrientation,
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

    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }
    private let access: FullScreenImagePresentationFactsAccess

    init(
        access: FullScreenImagePresentationFactsAccess = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.presentation-facts", qos: .userInitiated
        )
    ) {
        self.access = access
        self.filesystemQueue = filesystemQueue
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

/// Speculative XMP reads run on a retained Dispatch executor, away from both
/// MainActor navigation and the cooperative thread pool.
actor FullScreenPrefetchPreparationService {
    nonisolated struct Snapshot: Sendable {
        let settings: CameraRawSettings?
        let cacheOrientation: Int?
        let decodeOrientation: Int
    }

    typealias Read = @Sendable (URL, CameraRawSettings?, Int?, Bool) -> Snapshot
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }
    private let read: Read

    init(read: @escaping Read = { url, suppliedSettings, requestedOrientation, isEdited in
        let settings = suppliedSettings
            ?? (isEdited ? XMPSidecarService().loadDevelopSettings(for: url) : nil)
        let orientation = FullScreenImageCache.displayOrientation(for: url, fallback: requestedOrientation ?? 1)
        return Snapshot(settings: settings,
                        cacheOrientation: requestedOrientation == nil ? nil : orientation,
                        decodeOrientation: orientation)
    }) {
        self.read = read
        filesystemQueue = DispatchSerialQueue(label: "com.aagedal.photo-agent.prefetch-preparation", qos: .utility)
    }

    func prepare(url: URL, settings: CameraRawSettings?, orientation: Int?, isEdited: Bool) -> Snapshot? {
        guard !Task.isCancelled else { return nil }
        let snapshot = read(url, settings, orientation, isEdited)
        guard !Task.isCancelled else { return nil }
        return snapshot
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

    nonisolated(unsafe) private var prefetchTasks: [PrefetchKey: PrefetchRequest] = [:]
    nonisolated(unsafe) private var prefetchPreparationTasks: [PrefetchKey: PrefetchRequest] = [:]
    nonisolated(unsafe) private var prefetchNavigationID: UUID?
    nonisolated(unsafe) private var revokedPrefetchURLs: Set<URL> = []
    /// When true, `startPrefetch` is a no-op and in-flight prefetch is cancelled. Set while the
    /// develop editor is active: speculative prefetch decodes call ImageIO's XMP parsing
    /// (`CGImageSourceCopyPropertiesAtIndex`), which races the editor's concurrent NSXML sidecar
    /// write on libxml2's process-global state and crashes with EXC_BAD_ACCESS. Suppressing
    /// prefetch removes that out-of-band libxml2 consumer for the duration of editing.
    nonisolated(unsafe) private var _prefetchSuppressed = false
    nonisolated(unsafe) private var _editingMemoryProfile = false
    private let lock = NSLock()
    private let memoryCoordinator: ImageMemoryCoordinator
    private let previewDecoder: @Sendable (URL, CameraRawSettings?, Int, CGFloat) async -> CGImage?
    private let prefetchPreparationService: FullScreenPrefetchPreparationService
    nonisolated(unsafe) private var memoryRegistrations: [ImageMemoryCoordinator.Registration] = []
    /// NSCache cannot enumerate or remove keys by URL. Track the exact variants written
    /// to each cache so invalidating one image does not flush every edited preview.
    nonisolated(unsafe) private var imageKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var displayPreviewKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var editedImageKeysByURL: [URL: Set<NSString>] = [:]
    nonisolated(unsafe) private var editedDisplayPreviewKeysByURL: [URL: Set<NSString>] = [:]

    nonisolated private struct PrefetchRequest: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    nonisolated private struct PrefetchKey: Hashable, Sendable {
        let url: URL
        let orientation: Int?
        let renderToken: String?
        let isEdited: Bool
    }

    init(
        memoryCoordinator: ImageMemoryCoordinator = .shared,
        previewDecoder: @escaping @Sendable (URL, CameraRawSettings?, Int, CGFloat) async -> CGImage? = {
            await FullScreenImageCache.decodedEditedPreview(
                for: $0, settings: $1, orientation: $2, screenMaxPx: $3
            )
        },
        prefetchPreparationService: FullScreenPrefetchPreparationService = FullScreenPrefetchPreparationService()
    ) {
        self.previewDecoder = previewDecoder
        self.prefetchPreparationService = prefetchPreparationService
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
        MetadataSidecarService().loadSidecar(for: url, in: url.deletingLastPathComponent())?
            .orientationDraft?.targetOrientation ?? XMPSidecarService().sidecarOrientation(for: url) ?? fallback
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
        isEdited: Bool = false,
        minimumPixelSize: CGFloat = 0
    ) -> CGImage? {
        let c = isEdited ? editedCache : cache
        guard let image = c.object(forKey: Self.cacheKey(for: url, orientation: orientation, renderToken: renderToken)),
              Self.hasEnoughPixels(image, for: minimumPixelSize) else { return nil }
        return image
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
        let tasks = lock.withLock {
            cache.removeAllObjects()
            displayPreviewCache.removeAllObjects()
            editedCache.removeAllObjects()
            editedDisplayPreviewCache.removeAllObjects()
            imageKeysByURL.removeAll()
            displayPreviewKeysByURL.removeAll()
            editedImageKeysByURL.removeAll()
            editedDisplayPreviewKeysByURL.removeAll()
            return removeAllPrefetchTasksLocked()
        }
        for task in tasks { task.cancel() }
    }

    // MARK: - Prefetch Suppression (develop editor)

    nonisolated var isPrefetchSuppressed: Bool {
        lock.withLock { _prefetchSuppressed }
    }

    /// Suppress (and immediately cancel) speculative prefetch while the develop editor is active,
    /// so its ImageIO XMP parsing can't race the editor's concurrent NSXML sidecar write — see
    /// `_prefetchSuppressed`. Idempotent.
    nonisolated func setPrefetchSuppressed(_ suppressed: Bool) {
        let tasks = lock.withLock {
            _prefetchSuppressed = suppressed
            return suppressed ? removeAllPrefetchTasksLocked() : []
        }
        for task in tasks { task.cancel() }
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

    /// The largest navigation offset is four images in either direction. Passing
    /// just this window keeps per-navigation preparation independent of folder size.
    nonisolated static func prefetchWindow(currentIndex: Int, imageCount: Int) -> Range<Int>? {
        guard currentIndex >= 0, currentIndex < imageCount else { return nil }
        return max(0, currentIndex - 4)..<min(imageCount, currentIndex + 5)
    }

    nonisolated static func prefetchTargetIndices(
        currentIndex: Int, imageCount: Int, direction: NavigationDirection, itemLimit: Int
    ) -> [Int] {
        guard currentIndex >= 0, currentIndex < imageCount, itemLimit > 0 else { return [] }
        let offsets: [Int]
        switch direction {
        case .forward: offsets = [1, 2, 3, 4, -1, -2]
        case .backward: offsets = [-1, -2, -3, -4, 1, 2]
        case .none: offsets = [1, -1, 2, -2, 3, -3]
        }
        return offsets.prefix(itemLimit).map { currentIndex + $0 }
            .filter { $0 >= 0 && $0 < imageCount }
    }

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

        let targetIndices = Self.prefetchTargetIndices(
            currentIndex: currentIndex, imageCount: images.count,
            direction: direction, itemLimit: itemLimit
        )
        let orderedTargetURLs = targetIndices.map { images[$0] }
        let targetURLs = Set(orderedTargetURLs)
        let currentURL = images.indices.contains(currentIndex) ? images[currentIndex] : nil

        let navigationID = UUID()
        let tasksToCancel = lock.withLock { () -> [Task<Void, Never>] in
            guard !_prefetchSuppressed else { return [] }
            prefetchNavigationID = navigationID
            revokedPrefetchURLs.removeAll()
            var toCancel: [Task<Void, Never>] = []
            let keysToCancel = prefetchTasks.keys.filter { !targetURLs.contains($0.url) && $0.url != currentURL }
            for key in keysToCancel {
                guard let task = prefetchTasks.removeValue(forKey: key) else { continue }
                toCancel.append(task.task)
            }
            let preparationKeys = prefetchPreparationTasks.keys.filter { !targetURLs.contains($0.url) && $0.url != currentURL }
            for key in preparationKeys {
                if let task = prefetchPreparationTasks.removeValue(forKey: key) { toCancel.append(task.task) }
            }
            return toCancel
        }
        for task in tasksToCancel { task.cancel() }

        for url in orderedTargetURLs {
            // Caller-provided closures are immutable in-memory lookups. Filesystem
            // fallbacks and sidecar orientation correction belong to preparation.
            let settings = settingsForURL?(url)
            let requestedOrientation = orientationForURL?(url)
            let renderToken = Self.renderToken(settings: settings, isEdited: isEdited)
            let preparationKey = PrefetchKey(
                url: url,
                orientation: requestedOrientation,
                renderToken: renderToken,
                isEdited: isEdited
            )

            lock.withLock {
                guard !_prefetchSuppressed, prefetchNavigationID == navigationID,
                      !revokedPrefetchURLs.contains(url),
                      prefetchPreparationTasks[preparationKey] == nil else { return }
                let requestID = UUID()
                let task = Task.detached(priority: .medium) { [weak self] in
                    guard let self else { return }
                    defer { self.removePrefetchPreparationTask(for: preparationKey, requestID: requestID) }
                    guard !Task.isCancelled else { return }
                    guard let prepared = await self.prefetchPreparationService.prepare(
                        url: url, settings: settings, orientation: requestedOrientation, isEdited: isEdited
                    ), !Task.isCancelled else { return }
                    self.registerPreparedPrefetch(prepared, for: preparationKey,
                                                  requestID: requestID, screenMaxPx: screenMaxPx)
                }
                prefetchPreparationTasks[preparationKey] = PrefetchRequest(id: requestID, task: task)
            }
        }
    }

    nonisolated private func registerPreparedPrefetch(
        _ prepared: FullScreenPrefetchPreparationService.Snapshot, for preparationKey: PrefetchKey,
        requestID: UUID, screenMaxPx: CGFloat
    ) {
        let key = PrefetchKey(url: preparationKey.url, orientation: prepared.cacheOrientation,
                             renderToken: Self.renderToken(settings: prepared.settings, isEdited: preparationKey.isEdited),
                             isEdited: preparationKey.isEdited)
        lock.withLock {
            // Removal on clear, invalidation, suppression or newer navigation revokes
            // admission even when a synchronous provider read could not be cancelled.
            guard !_prefetchSuppressed, prefetchPreparationTasks[preparationKey]?.id == requestID,
                  prefetchTasks[key] == nil,
                  cachedImage(for: key.url, orientation: key.orientation,
                              renderToken: key.renderToken, isEdited: key.isEdited) == nil else { return }
            let decodeID = UUID()
            let task = Task.detached(priority: .medium) { [weak self] in
                guard let self else { return }
                defer { self.removePrefetchTask(for: key, requestID: decodeID) }
                guard !Task.isCancelled,
                      let image = await self.previewDecoder(key.url, prepared.settings,
                                                           prepared.decodeOrientation, screenMaxPx),
                      !Task.isCancelled else { return }
                self.storePrefetchedImage(image, for: key, requestID: decodeID)
            }
            prefetchTasks[key] = PrefetchRequest(id: decodeID, task: task)
        }
    }

    nonisolated private func storePrefetchedImage(_ image: CGImage, for key: PrefetchKey, requestID: UUID) {
        lock.withLock {
            guard prefetchTasks[key]?.id == requestID else { return }
            let cacheKey = Self.cacheKey(for: key.url, orientation: key.orientation, renderToken: key.renderToken)
            let target = key.isEdited ? editedCache : cache
            target.setObject(image, forKey: cacheKey, cost: Self.byteSize(of: image))
            if key.isEdited { editedImageKeysByURL[key.url, default: []].insert(cacheKey) }
            else { imageKeysByURL[key.url, default: []].insert(cacheKey) }
        }
    }

    nonisolated private func removePrefetchPreparationTask(for key: PrefetchKey, requestID: UUID) {
        lock.withLock {
            guard prefetchPreparationTasks[key]?.id == requestID else { return }
            prefetchPreparationTasks.removeValue(forKey: key)
        }
    }

    nonisolated private func removePrefetchTask(for key: PrefetchKey, requestID: UUID) {
        lock.withLock {
            guard prefetchTasks[key]?.id == requestID else { return }
            prefetchTasks.removeValue(forKey: key)
        }
    }

    nonisolated private func removePrefetchTasksLocked(for url: URL) -> [Task<Void, Never>] {
        revokedPrefetchURLs.insert(url)
        var removed: [Task<Void, Never>] = []
        let keysToRemove = prefetchTasks.keys.filter { $0.url == url }
        for key in keysToRemove {
            if let task = prefetchTasks.removeValue(forKey: key) {
                removed.append(task.task)
            }
        }
        let preparationKeys = prefetchPreparationTasks.keys.filter { $0.url == url }
        for key in preparationKeys {
            if let task = prefetchPreparationTasks.removeValue(forKey: key) { removed.append(task.task) }
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
        isEdited: Bool = false,
        minimumPixelSize: CGFloat = 0
    ) async -> CGImage? {
        let key = PrefetchKey(
            url: url,
            orientation: orientation,
            renderToken: renderToken,
            isEdited: isEdited
        )
        if let cached = cachedImage(for: url, orientation: orientation, renderToken: renderToken, isEdited: isEdited, minimumPixelSize: minimumPixelSize) {
            return cached
        }
        let preparations = lock.withLock {
            prefetchPreparationTasks.filter { $0.key.url == url && $0.key.isEdited == isEdited }.values.map(\.task)
        }
        for preparation in preparations { await preparation.value }
        // A fast decode may publish and remove its task between independent cache and task
        // reads. Snapshot both under the publication lock so foreground reuse cannot miss it.
        let ready = lock.withLock {
            (cachedImage(for: url, orientation: orientation, renderToken: renderToken,
                         isEdited: isEdited, minimumPixelSize: minimumPixelSize), prefetchTasks[key])
        }
        if let cached = ready.0 { return cached }
        guard let task = ready.1 else { return nil }
        await task.task.value
        return cachedImage(for: url, orientation: orientation, renderToken: renderToken, isEdited: isEdited, minimumPixelSize: minimumPixelSize)
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
            removeAllPrefetchTasksLocked()
        }
        for task in tasksToCancel { task.cancel() }
        cacheLogger.info("All prefetch tasks cancelled")
    }

    nonisolated private func removeAllPrefetchTasksLocked() -> [Task<Void, Never>] {
        let tasks = prefetchTasks.values.map(\.task) + prefetchPreparationTasks.values.map(\.task)
        prefetchTasks.removeAll()
        prefetchPreparationTasks.removeAll()
        prefetchNavigationID = nil
        revokedPrefetchURLs.removeAll()
        return tasks
    }

    // MARK: - CameraRaw Processing

    /// The orientation the develop edits are applied in for pixels decoded with
    /// `fileOrientation` baked in and displayed at `displayOrientation` (sidecar-first).
    ///
    /// Every develop render (Develop, export, full screen, loupe, edited thumbnails, Clean
    /// Feed) edits in the DISPLAY frame, exactly like Develop
    /// (`DevelopSourceDecodeService.orientedToTarget` + upload with the target orientation):
    /// crops and masks land in the same place either way, but display-frame elements —
    /// watermark artwork, its width/height-relative size and margins — are only upright when
    /// the pixels are rotated before the edit. `ImageFile.orientationCorrection` models only
    /// the four rotations, so a mirrored orientation on either side keeps the file frame.
    nonisolated static func editFrameOrientation(fileOrientation: Int, displayOrientation: Int) -> Int {
        let rotationOnly: Set<Int> = [1, 3, 6, 8]
        guard rotationOnly.contains(fileOrientation),
              rotationOnly.contains(displayOrientation) else { return fileOrientation }
        return displayOrientation
    }

    /// Rotates file-oriented pixels into `editFrameOrientation` and reports the frame the
    /// returned pixels are in (the `exifOrientation` to hand `applyWithCrop`). A no-op that
    /// reports `fileOrientation` when no rotation applies, so same-orientation renders are
    /// unchanged.
    nonisolated static func orientedForEditing(
        _ image: CIImage,
        fileOrientation: Int,
        displayOrientation: Int
    ) -> (image: CIImage, pixelOrientation: Int) {
        let target = editFrameOrientation(
            fileOrientation: fileOrientation,
            displayOrientation: displayOrientation
        )
        let correction = ImageFile.orientationCorrection(from: fileOrientation, to: target)
        guard correction != .up else { return (image, fileOrientation) }
        return (image.oriented(correction), target)
    }

    /// Applies `settings` to pixels decoded with `fileOrientation` baked in and returns them in
    /// `displayOrientation`, editing in the display frame (see `editFrameOrientation`). Any
    /// rotation that could not happen before the edit (mirrored orientations) is applied after.
    nonisolated static func applyEditsInDisplayFrame(
        to image: CIImage,
        settings: CameraRawSettings?,
        fileOrientation: Int,
        displayOrientation: Int
    ) -> CIImage {
        let framed = orientedForEditing(
            image, fileOrientation: fileOrientation, displayOrientation: displayOrientation
        )
        var processed = framed.image
        if let settings {
            processed = CameraRawApproximation.applyWithCrop(
                to: processed, settings: settings, exifOrientation: framed.pixelOrientation
            )
        }
        return orientedAfterEditing(
            processed, pixelOrientation: framed.pixelOrientation, displayOrientation: displayOrientation
        )
    }

    /// Async sibling of `applyEditsInDisplayFrame`; suspends on the render queue for the edit.
    nonisolated static func applyEditsInDisplayFrameAsync(
        to image: CIImage,
        settings: CameraRawSettings?,
        fileOrientation: Int,
        displayOrientation: Int
    ) async -> CIImage {
        let framed = orientedForEditing(
            image, fileOrientation: fileOrientation, displayOrientation: displayOrientation
        )
        var processed = framed.image
        if let settings {
            processed = await CameraRawApproximation.applyWithCropAsync(
                to: processed, settings: settings, exifOrientation: framed.pixelOrientation
            )
        }
        return orientedAfterEditing(
            processed, pixelOrientation: framed.pixelOrientation, displayOrientation: displayOrientation
        )
    }

    nonisolated private static func orientedAfterEditing(
        _ image: CIImage,
        pixelOrientation: Int,
        displayOrientation: Int
    ) -> CIImage {
        let residual = ImageFile.orientationCorrection(from: pixelOrientation, to: displayOrientation)
        return residual == .up ? image : image.oriented(residual)
    }

    /// CGImage form of `applyEditsInDisplayFrame`. When the orientations agree this is a
    /// plain `applyWithCrop` in the file frame, materialized for display.
    nonisolated static func applyCameraRaw(
        to cgImage: CGImage,
        settings: CameraRawSettings,
        fileOrientation: Int,
        displayOrientation: Int
    ) -> CGImage {
        let processed = applyEditsInDisplayFrame(
            to: CIImage(cgImage: cgImage),
            settings: settings,
            fileOrientation: fileOrientation,
            displayOrientation: displayOrientation
        )
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return cgImage }
        return CameraRawApproximation.createDisplayCGImage(processed, from: extent) ?? cgImage
    }

    /// Browse-mode scope source for `url`: a small decode, edited (with crop) when `settings`
    /// is non-nil, in `displayOrientation` — the same frame and region full screen shows.
    /// Both loaders bake the FILE orientation into their pixels, so edited and unedited
    /// sources go through `applyEditsInDisplayFrame` (sidecar-only rotations included).
    /// `isNativeHDR` keeps float values above 1.0 for the nits waveform. Returns nil when the
    /// decode fails or the calling task is cancelled between stages.
    nonisolated static func browseScopeSource(
        for url: URL,
        isNativeHDR: Bool,
        settings: CameraRawSettings?,
        displayOrientation: Int,
        maxPixelSize: CGFloat = 720
    ) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if isNativeHDR,
           let decoded = loadHDRPreviewWithOrientation(from: url, maxPixelSize: maxPixelSize) {
            guard !Task.isCancelled else { return nil }
            let processed = applyEditsInDisplayFrame(
                to: decoded.image,
                settings: settings,
                fileOrientation: decoded.orientation,
                displayOrientation: displayOrientation
            )
            return CameraRawApproximation.ciContext.createCGImage(
                processed, from: processed.extent,
                format: .RGBAh,
                colorSpace: CameraRawApproximation.workingColorSpace
            )
        }
        guard !Task.isCancelled,
              let base = loadDownsampledWithOrientation(from: url, maxPixelSize: maxPixelSize) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        if let settings {
            return applyCameraRaw(
                to: base.image,
                settings: settings,
                fileOrientation: base.orientation,
                displayOrientation: displayOrientation
            )
        }
        let correction = ImageFile.orientationCorrection(from: base.orientation, to: displayOrientation)
        guard correction != .up else { return base.image }
        // Keep the decode's own RGB space so the scope's gamut readout is unchanged.
        let rotated = CIImage(cgImage: base.image).oriented(correction)
        let colorSpace = base.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CameraRawApproximation.ciContext.createCGImage(
            rotated, from: rotated.extent, format: .RGBA8, colorSpace: colorSpace
        ) ?? base.image
    }

    /// Decode `url` at screen resolution, applying `settings` if present, and return a
    /// display-ready CGImage. RAW → CIRAWFilter flat/neutral decode with as-shot WB; other
    /// formats → HDR-preserving preview; SDR fallback for formats CoreImage can't decode.
    /// When `settings` is non-nil the edit is baked in and EDR content headroom stamped so the
    /// result engages EDR on display (matches the foreground render path). Returns nil if the
    /// decode fails or the task is cancelled. Shared by `startPrefetch` and `warmEditedPreviews`
    /// so both render edited previews identically — keep this the single edited-decode path.
    // This is also called by MainActor thumbnail requests. Bind the complete operation to
    // Dispatch so ImageIO, RAW decoding and final materialization cannot block the main
    // actor or the cooperative pool. An isolated parameter retains the original task.
    static func decodedEditedPreview(
        for url: URL,
        settings: CameraRawSettings?,
        orientation: Int,
        screenMaxPx: CGFloat,
        sourceMaxPixelSize: CGFloat? = nil,
        isolation: isolated EditedPreviewRenderWorker = .shared
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        var settings = settings
        var image: CGImage?
        let isRAW = isRawFile(url)

        // Every decode below bakes the FILE's orientation into the pixels (CIRAWFilter,
        // CIImage's applyOrientationProperty, and CGImageSource's thumbnail transform all
        // apply the embedded tag). The requested `orientation` (the in-memory/sidecar
        // display orientation) can differ — RAW/C2PA rotations never touch the file.
        // `applyWithCrop`'s exifOrientation parameter means "the frame the PIXELS are in"
        // (it transforms sensor-frame crop/mask/watermark geometry, it does not rotate
        // pixels). The pixels are therefore rotated file → target FIRST and edited with the
        // target as their frame (`applyEditsInDisplayFrame`), exactly like Develop and the
        // export renderer. Editing in the file frame and rotating afterwards frames the
        // same crop but draws watermark artwork sideways; passing the target orientation
        // without rotating mis-frames the crop and leaves the pixels unrotated.
        let rawFileOrientation = isolation.fileOrientation(at: url)
        guard !Task.isCancelled else { return nil }
        let sourceMaxPx: CGFloat
        if settings?.crop?.isEffectiveCrop == true {
            sourceMaxPx = max(sourceMaxPixelSize ?? 0, cropAwareSourceMaxPixelSize(
                outputMaxPixelSize: screenMaxPx,
                settings: settings,
                exifOrientation: rawFileOrientation,
                sourcePixelSize: nativePixelSize(of: url)
            ))
        } else {
            sourceMaxPx = sourceMaxPixelSize ?? screenMaxPx
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
                // Suspend while the dedicated Metal queue waits for the GPU so this
                // preview executor can accept the next request.
                var processed = await applyEditsInDisplayFrameAsync(
                    to: ciImage,
                    settings: settings,
                    fileOrientation: rawFileOrientation,
                    displayOrientation: orientation
                )
                guard !Task.isCancelled else { return nil }
                // Crop-aware sensor decoding may deliberately retain a larger source.
                // Bound the final bitmap to the display target so oversized HDR crops
                // do not immediately evict themselves from a pane's primary cache.
                processed = screenSizedPreview(processed, maxPixelSize: screenMaxPx)
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
            let correction = ImageFile.orientationCorrection(from: loadedOrientation, to: orientation)
            if let settings {
                loaded = applyCameraRaw(
                    to: loaded,
                    settings: settings,
                    fileOrientation: loadedOrientation,
                    displayOrientation: orientation
                )
            } else if correction != .up {
                let rotated = CIImage(cgImage: loaded).oriented(correction)
                if let cg = CameraRawApproximation.createDisplayCGImage(rotated, from: rotated.extent) {
                    loaded = cg
                }
            }
            image = loaded
        }
        return Task.isCancelled ? nil : image
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
        maxPixelSize: CGFloat,
        worker: FullScreenImageDecodeWorker = FullScreenImageDecodeWorker()
    ) async -> (image: CIImage, orientation: Int)? {
        await worker.loadHDR(from: url, maxPixelSize: maxPixelSize)
    }

    /// Run `loadDownsampled` on the utility-QoS decode worker, away from the cooperative pool.
    nonisolated static func loadDownsampledOffPool(from url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await loadDownsampledOffPoolWithOrientation(from: url, maxPixelSize: maxPixelSize)?.image
    }

    /// Run `loadDownsampledWithOrientation` on the utility-QoS decode worker.
    nonisolated static func loadDownsampledOffPoolWithOrientation(
        from url: URL, maxPixelSize: CGFloat,
        worker: FullScreenImageDecodeWorker = FullScreenImageDecodeWorker()
    ) async -> (image: CGImage, orientation: Int)? {
        await worker.loadRaster(from: url, maxPixelSize: maxPixelSize)
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
        let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        let image = isRawFile(url)
            ? rawPreviewFallback(candidate: candidate, from: url, requiredSize: targetSize)
            : candidate
        guard let image else { return nil }
        return (image, orientation)
    }
    
    /// ImageIO can return an embedded RAW thumbnail even when asked to generate a
    /// larger image. Never promote those pixels to a completed screen/zoom decode.
    /// Allow 2% for active-sensor borders and decoder rounding, not thumbnail upscaling.
    nonisolated static func hasEnoughPixels(_ image: CGImage, for requiredSize: CGFloat) -> Bool {
        CGFloat(max(image.width, image.height)) >= requiredSize * 0.98
    }

    nonisolated static func resolvedRAWPreview(
        candidate: CGImage?,
        requiredSize: CGFloat,
        decode: () -> CGImage?
    ) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let candidate, hasEnoughPixels(candidate, for: requiredSize) { return candidate }
        guard let decoded = decode(), !Task.isCancelled,
              hasEnoughPixels(decoded, for: requiredSize) else { return nil }
        return decoded
    }

    /// Edited RAW renders also need a quality check after crop and materialization.
    /// A decoder's scaled output can be smaller than its requested dimensions.
    nonisolated static func resolvedRAWPreviewAsync(
        candidate: CGImage?,
        requiredSize: CGFloat,
        decode: () async -> CGImage?
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let candidate, hasEnoughPixels(candidate, for: requiredSize) { return candidate }
        guard let decoded = await decode(), !Task.isCancelled,
              hasEnoughPixels(decoded, for: requiredSize) else { return nil }
        return decoded
    }

    nonisolated private static func rawPreviewFallback(
        candidate: CGImage?, from url: URL, requiredSize: CGFloat
    ) -> CGImage? {
        resolvedRAWPreview(candidate: candidate, requiredSize: requiredSize) {
            cacheLogger.info("RAW preview below requested size for \(url.lastPathComponent): \(candidate?.width ?? 0)x\(candidate?.height ?? 0), requested \(requiredSize); decoding sensor pixels")
            guard let raw = loadRAWImage(from: url, draftMode: false, maxPixelSize: requiredSize, decodeProfile: .camera),
                  !Task.isCancelled else { return nil }
            let image = downsample(raw.image, maxPixelSize: requiredSize)
            return CameraRawApproximation.createDisplayCGImage(image, from: image.extent)
        }
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

    /// Bound final edited output exactly; the source decoder's 1.5x tolerance is
    /// useful before crop, but wastes cache memory when applied to the final bitmap.
    nonisolated static func screenSizedPreview(_ image: CIImage, maxPixelSize: CGFloat) -> CIImage {
        let longestSide = max(image.extent.width, image.extent.height)
        guard maxPixelSize > 0, longestSide.isFinite, longestSide > maxPixelSize else { return image }
        let scale = maxPixelSize / longestSide
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
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
        let decoderPreference = RAWDecoderVersionPreference(rawValue:
            AppDefaults.store.string(forKey: UserDefaultsKeys.rawDecoderVersionPreference) ?? "") ?? .auto
        let profile = decodeProfile ?? RAWDecodeProfile(storedRawValue:
            AppDefaults.store.string(forKey: UserDefaultsKeys.rawDecodeProfile) ?? "") ?? .camera
        guard let result = RAWSourceDecoder.decode(rawFilter, draftMode: draftMode,
            maxPixelSize: maxPixelSize, nativeLongestSide: nativeLongestSide(of: url),
            profile: profile, decoderPreference: decoderPreference) else {
            cacheLogger.warning("CIRAWFilter outputImage/state unavailable for \(url.lastPathComponent)")
            return nil
        }
        let extent = result.image.extent
        cacheLogger.info("RAW decoded \(url.lastPathComponent) draft=\(draftMode) profile=\(profile.rawValue) decoder=\(rawFilter.decoderVersion.rawValue) scale=\(rawFilter.scaleFactor, format: .fixed(precision: 3)) \(Int(extent.width))x\(Int(extent.height)) asShot=\(Int(result.neutralTemperature))K tint=\(Int(result.neutralTint))")
        return RAWDecodeResult(image: result.image, neutralTemperature: result.neutralTemperature,
            neutralTint: result.neutralTint)
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
        from url: URL,
        worker: FullScreenImageDecodeWorker = FullScreenImageDecodeWorker()
    ) async -> (image: CIImage, orientation: Int)? {
        await worker.loadHDR(from: url, maxPixelSize: nil)
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
        let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        let image = isRawFile(url)
            ? rawPreviewFallback(candidate: candidate, from: url, requiredSize: maxDimension)
            : candidate
        guard let image else { return nil }
        return (image, orientation)
    }

    nonisolated static func loadFullResolutionOffPool(from url: URL) async -> CGImage? {
        await loadFullResolutionOffPoolWithOrientation(from: url)?.image
    }

    nonisolated static func loadFullResolutionOffPoolWithOrientation(
        from url: URL,
        worker: FullScreenImageDecodeWorker = FullScreenImageDecodeWorker()
    ) async -> (image: CGImage, orientation: Int)? {
        await worker.loadRaster(from: url, maxPixelSize: nil)
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
        from url: URL,
        worker: EmbeddedRAWPreviewDecodeWorker = EmbeddedRAWPreviewDecodeWorker()
    ) async -> (image: CGImage, orientation: Int)? {
        await worker.load(from: url)
    }

    /// Synchronous ImageIO implementation, reachable only through the default-QoS async
    /// boundary above so foreground Tasks never perform this blocking call directly.
    nonisolated fileprivate static func extractEmbeddedPreviewWithOrientation(
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

/// Runs the original Swift task on a Dispatch thread matching the decoder's internal workers:
/// utility for general Core Image/raster loads, default for embedded RAW extraction. Enforced
/// work-item QoS prevents GCD from inferring a foreground caller's higher priority while
/// preserving the Swift task's priority, local values and cancellation. Each request has a serial
/// executor targeting the shared concurrent decode queue, preserving both actor isolation
/// and independent foreground/prefetch decode concurrency.
nonisolated final class FullScreenImageDecodeExecutor: SerialExecutor {
    enum Profile: Sendable {
        case generalImage
        case embeddedRAWPreview

        var qos: DispatchQoS {
            switch self {
            case .generalImage: .utility
            case .embeddedRAWPreview: .default
            }
        }
    }

    private static let decodeQueue = DispatchQueue(
        label: "com.aagedal.photo-agent.preview-decode", qos: .utility, attributes: .concurrent
    )
    private static let embeddedPreviewQueue = DispatchQueue(
        label: "com.aagedal.photo-agent.embedded-preview-decode", qos: .default,
        attributes: .concurrent
    )
    private let queue: DispatchSerialQueue
    private let qos: DispatchQoS
    private let didEnqueue: @Sendable () -> Void

    init(
        label: String = "com.aagedal.photo-agent.preview-decode.request",
        profile: Profile = .generalImage,
        didEnqueue: @escaping @Sendable () -> Void = {}
    ) {
        qos = profile.qos
        let target = switch profile {
        case .generalImage: Self.decodeQueue
        case .embeddedRAWPreview: Self.embeddedPreviewQueue
        }
        queue = DispatchSerialQueue(label: label, qos: profile.qos, target: target)
        self.didEnqueue = didEnqueue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async(execute: DispatchWorkItem(qos: qos, flags: .enforceQoS) {
            unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
        })
        didEnqueue()
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    func isIsolatingCurrentContext() -> Bool? {
        queue.isIsolatingCurrentContext()
    }
}

/// Embedded preview requests retain caller context while enforcing ImageIO's default thread
/// QoS. Every request gets an independent serial executor; a cancelled request waiting on an
/// occupied executor never touches the provider, and completed pixels are discarded if the
/// caller cancels during a non-preemptible ImageIO call.
actor EmbeddedRAWPreviewDecodeWorker {
    typealias Decoder = @Sendable (URL) -> (image: CGImage, orientation: Int)?

    nonisolated let executor: FullScreenImageDecodeExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    private let decoder: Decoder

    init(
        decoder: @escaping Decoder = {
            FullScreenImageCache.extractEmbeddedPreviewWithOrientation(from: $0)
        },
        executor: FullScreenImageDecodeExecutor = FullScreenImageDecodeExecutor(
            label: "com.aagedal.photo-agent.embedded-preview-decode.request",
            profile: .embeddedRAWPreview
        )
    ) {
        self.decoder = decoder
        self.executor = executor
    }

    func load(from url: URL) -> (image: CGImage, orientation: Int)? {
        guard !Task.isCancelled else { return nil }
        let result = decoder(url)
        return Task.isCancelled ? nil : result
    }
}

/// A nil maximum size selects the original full-resolution loader. Each loader returns the
/// orientation read adjacent to its pixels so callers keep their existing correction frame.
nonisolated struct FullScreenImageDecodeAccess: Sendable {
    let hdr: @Sendable (URL, CGFloat?) -> (image: CIImage, orientation: Int)?
    let raster: @Sendable (URL, CGFloat?) -> (image: CGImage, orientation: Int)?

    static let system = Self(
        hdr: { url, maxPixelSize in
            if let maxPixelSize {
                FullScreenImageCache.loadHDRPreviewWithOrientation(from: url, maxPixelSize: maxPixelSize)
            } else {
                FullScreenImageCache.loadHDRFullResolutionWithOrientation(from: url)
            }
        },
        raster: { url, maxPixelSize in
            if let maxPixelSize {
                FullScreenImageCache.loadDownsampledWithOrientation(from: url, maxPixelSize: maxPixelSize)
            } else {
                FullScreenImageCache.loadFullResolutionWithOrientation(from: url)
            }
        }
    )
}

/// Retains task-local values and cancellation across the blocking decode boundary. A queued
/// cancelled request never opens the file; cancellation during non-preemptible ImageIO work
/// discards the completed pixels before they can enter a cache or presentation owner.
actor FullScreenImageDecodeWorker {
    nonisolated let executor: FullScreenImageDecodeExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    private let access: FullScreenImageDecodeAccess

    init(
        access: FullScreenImageDecodeAccess = .system,
        executor: FullScreenImageDecodeExecutor = FullScreenImageDecodeExecutor()
    ) {
        self.access = access
        self.executor = executor
    }

    func loadHDR(from url: URL, maxPixelSize: CGFloat?) -> (image: CIImage, orientation: Int)? {
        guard !Task.isCancelled else { return nil }
        let result = access.hdr(url, maxPixelSize)
        return Task.isCancelled ? nil : result
    }

    func loadRaster(from url: URL, maxPixelSize: CGFloat?) -> (image: CGImage, orientation: Int)? {
        guard !Task.isCancelled else { return nil }
        let result = access.raster(url, maxPixelSize)
        return Task.isCancelled ? nil : result
    }
}

/// Shared execution boundary for edited browser, comparison and prefetch previews.
/// Serial synchronous segments keep expensive RAW decodes off the cooperative pool.
actor EditedPreviewRenderWorker {
    static let shared = EditedPreviewRenderWorker()
    nonisolated let renderQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        renderQueue.asUnownedSerialExecutor()
    }

    private let orientationReader: @Sendable (URL) -> Int

    init(
        orientationReader: @escaping @Sendable (URL) -> Int = {
            FullScreenImageCache.fileEXIFOrientation(at: $0)
        },
        renderQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.edited-preview-render", qos: .userInitiated
        )
    ) {
        self.orientationReader = orientationReader
        self.renderQueue = renderQueue
    }

    func fileOrientation(at url: URL) -> Int {
        orientationReader(url)
    }
}
