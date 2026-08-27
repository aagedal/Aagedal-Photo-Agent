import AppKit
import QuickLookThumbnailing
import CoreImage
import os

nonisolated private let thumbnailLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ThumbnailService")

@Observable
final class ThumbnailService {
    typealias OriginalThumbnailLoader = @Sendable (URL) async -> NSImage?

    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private let editedCache = NSCache<NSURL, NSImage>()
    private struct InFlightRequest {
        let id: UUID
        let task: Task<NSImage?, Never>
        var consumers: Set<UUID>
    }
    @ObservationIgnored private var inFlightTasks: [URL: InFlightRequest] = [:]
    @ObservationIgnored private var editedInFlightTasks: [URL: InFlightRequest] = [:]
    private let thumbnailSize = CGSize(width: 240, height: 240)
    @ObservationIgnored private let memoryCoordinator: ImageMemoryCoordinator
    @ObservationIgnored private let originalThumbnailLoader: OriginalThumbnailLoader?
    @ObservationIgnored private var memoryRegistration: ImageMemoryCoordinator.Registration? = nil

    /// Caps how many thumbnail decodes run concurrently across the whole app — visible cell loads
    /// and collection-view prefetch both funnel through it. Without a cap a fast scroll or a
    /// held arrow key spawns hundreds of QuickLook/ImageIO decodes at once, saturating `thumbnailsd`
    /// and the cooperative pool so the thumbnails actually on screen queue behind off-screen ones.
    private let decodeGate = ThumbnailDecodeGate(limit: 6)

    init(
        memoryCoordinator: ImageMemoryCoordinator = .shared,
        originalThumbnailLoader: OriginalThumbnailLoader? = nil
    ) {
        self.memoryCoordinator = memoryCoordinator
        self.originalThumbnailLoader = originalThumbnailLoader
        cache.countLimit = 500
        editedCache.countLimit = 500
        applyMemoryLimit(memoryCoordinator.policy().thumbnailLimit)
        memoryRegistration = memoryCoordinator.register(
            kind: .thumbnail,
            cancelSpeculativeWork: { [weak self] in
                Task { @MainActor [weak self] in self?.cancelInFlightWork() }
            },
            applyLimit: { [weak self] limit in
                Task { @MainActor [weak self] in self?.applyMemoryLimit(limit) }
            },
            evict: { [weak self] in
                Task { @MainActor [weak self] in self?.clearCache() }
            }
        )
    }

    private func applyMemoryLimit(_ totalLimit: Int) {
        let perVariant = max(0, totalLimit / 2)
        cache.totalCostLimit = perVariant
        editedCache.totalCostLimit = perVariant
    }

    /// Returns the best available thumbnail. Checks editedCache first unless preferOriginal is true.
    func thumbnail(for url: URL, preferOriginal: Bool = false) -> NSImage? {
        if !preferOriginal, let edited = editedCache.object(forKey: url as NSURL) {
            return edited
        }
        return cache.object(forKey: url as NSURL)
    }

    /// Checks whether an edited thumbnail exists in cache for the given URL.
    func hasEditedThumbnail(for url: URL) -> Bool {
        editedCache.object(forKey: url as NSURL) != nil
    }

    /// Loads or generates the original (unedited) thumbnail for a URL.
    ///
    /// QuickLook/CGImageSource bake the FILE's embedded orientation into the bitmap. When the
    /// authoritative display orientation lives in an XMP sidecar instead — a RAW (always) or a
    /// C2PA file rotated without touching the original — the file tag is unchanged, so the grid
    /// (and the full-screen instant preview, which reuses this cached thumbnail) would show the
    /// wrong orientation. `orientedToTarget` rotates the bitmap to the sidecar orientation when it
    /// differs. Reading the sidecar at generation time keeps this correct regardless of when the
    /// in-memory orientation is populated, and is a no-op for files with no sidecar (normal JPEG).
    func loadThumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        let consumerID = UUID()
        let request: InFlightRequest
        if var existing = inFlightTasks[url] {
            existing.consumers.insert(consumerID)
            inFlightTasks[url] = existing
            request = existing
        } else {
            let requestID = UUID()
            let originalThumbnailLoader = originalThumbnailLoader
            let task = Task<NSImage?, Never> {
                guard !Task.isCancelled else { return nil }
                if let originalThumbnailLoader {
                    guard let loaded = await originalThumbnailLoader(url),
                          !Task.isCancelled else { return nil }
                    cache.setObject(
                        loaded,
                        forKey: url as NSURL,
                        cost: Self.decodedCost(of: loaded)
                    )
                    return loaded
                }
                if let oriented = await self.generateOrientedThumbnail(for: url) {
                    guard !Task.isCancelled else { return nil }
                    cache.setObject(oriented, forKey: url as NSURL, cost: Self.decodedCost(of: oriented))
                    return oriented
                }

                guard !Task.isCancelled else { return nil }
                // For non-image files, use system file icon.
                if !SupportedImageFormats.isSupported(url: url) {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: thumbnailSize.width, height: thumbnailSize.height)
                    cache.setObject(icon, forKey: url as NSURL, cost: Self.decodedCost(of: icon))
                    return icon
                }
                return nil
            }
            request = InFlightRequest(id: requestID, task: task, consumers: [consumerID])
            inFlightTasks[url] = request
        }

        return await awaitRequest(
            request,
            url: url,
            consumerID: consumerID,
            isEdited: false
        )
    }

    /// Decodes the thumbnail and applies sidecar-orientation correction entirely off the main
    /// actor, behind the shared `decodeGate` concurrency cap. The decode (`generateQLThumbnail` /
    /// `loadCGImageSourceThumbnail`) was already off-main, but `loadThumbnail`'s enclosing `Task`
    /// is MainActor-isolated, so the orientation finalize used to run on the main thread — for a
    /// RAW folder, where every file carries a sidecar, that meant a sidecar read plus a full
    /// `CIImage` rotation on the main thread per thumbnail, hitching grid scrolling. `nonisolated
    /// async` keeps the whole finalize on the cooperative pool. `XMPReader` (SwiftExif) is a
    /// pure-Swift parser, so the sidecar read is safe off-main.
    nonisolated private func generateOrientedThumbnail(for url: URL) async -> NSImage? {
        guard Self.isLocallyAvailableForThumbnail(url) else { return nil }
        guard await decodeGate.acquire() else { return nil }
        if Task.isCancelled {
            await decodeGate.release()
            return nil
        }
        var oriented: NSImage?
        if let ql = await generateQLThumbnail(for: url) {
            oriented = Self.orientedToSidecar(ql, fileURL: url)
        } else if !Task.isCancelled,
                  let cg = await loadCGImageSourceThumbnail(for: url) {
            oriented = Self.orientedToSidecar(cg, fileURL: url)
        }
        await decodeGate.release()
        return Task.isCancelled ? nil : oriented
    }

    /// Rotate a freshly generated (file-oriented) thumbnail to the orientation recorded
    /// in the image's XMP sidecar, when that differs from the file's embedded tag (which
    /// QuickLook already baked in). No-op when there's no sidecar orientation or it matches
    /// the file — so normal JPEGs (orientation in the file) are untouched, while sidecar-only
    /// rotations (RAW, C2PA) are corrected. Authoritative at generation time, so it doesn't
    /// depend on when `ImageFile.exifOrientation` gets populated during folder load.
    nonisolated private static func orientedToSidecar(_ image: NSImage, fileURL: URL) -> NSImage {
        guard let sidecarOrientation = XMPSidecarService().sidecarOrientation(for: fileURL) else {
            return image
        }
        let fileOrientation = FullScreenImageCache.fileEXIFOrientation(at: fileURL)
        let correction = ImageFile.orientationCorrection(from: fileOrientation, to: sidecarOrientation)
        guard correction != .up,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let rotated = CIImage(cgImage: cg).oriented(correction)
        guard let out = CameraRawApproximation.ciContext.createCGImage(rotated, from: rotated.extent) else {
            return image
        }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    /// Renders an edited thumbnail by applying CameraRaw settings to the original thumbnail.
    /// Stores the result in the edited cache. Runs the heavy work at utility priority.
    func renderEditedThumbnail(for url: URL, settings: CameraRawSettings, exifOrientation: Int) async -> NSImage? {
        if let cached = editedCache.object(forKey: url as NSURL) {
            return cached
        }

        let consumerID = UUID()
        if var existing = editedInFlightTasks[url] {
            existing.consumers.insert(consumerID)
            editedInFlightTasks[url] = existing
            return await awaitRequest(
                existing,
                url: url,
                consumerID: consumerID,
                isEdited: true
            )
        }

        let requestID = UUID()
        let maxPixelSize = max(thumbnailSize.width, thumbnailSize.height) * 2
        let task = Task<NSImage?, Never> {
            guard !Task.isCancelled, !settings.isEmpty else { return nil }

            // RAW edits must start from a real CIRAWFilter decode rather than QuickLook's
            // already tone-mapped camera JPEG. Cropped edits of every format also need this
            // source-decode path: cropping a fixed 480 px QuickLook thumbnail can leave only
            // a few dozen pixels for a tight crop, which the grid then enlarges into a blur.
            // `decodedEditedPreview` increases the pre-crop decode size just enough for the
            // cropped result itself to retain thumbnail resolution.
            let needsSourceDecode = SupportedImageFormats.isRaw(url: url)
                || settings.crop?.isEffectiveCrop == true
            if needsSourceDecode {
                guard Self.isLocallyAvailableForThumbnail(url) else { return nil }
                guard await decodeGate.acquire() else { return nil }
                if Task.isCancelled {
                    await decodeGate.release()
                    return nil
                }
                let outputCG = await FullScreenImageCache.decodedEditedPreview(
                    for: url, settings: settings, orientation: exifOrientation, screenMaxPx: maxPixelSize)
                await decodeGate.release()
                guard let outputCG else { return nil }
                // Drop the result if a rotation (or other invalidation) cancelled us mid-decode,
                // so a render for the old orientation can't clobber the rotated cache entry.
                guard !Task.isCancelled else { return nil }
                let edited = NSImage(cgImage: outputCG, size: NSSize(width: outputCG.width, height: outputCG.height))
                editedCache.setObject(edited, forKey: url as NSURL, cost: Self.decodedCost(of: edited))
                return edited
            }

            // Non-RAW: composite edits onto the decoded thumbnail. The thumbnail base and the
            // edit-view base are the same SDR decode here, so there's no source divergence and
            // the cheap QL-preview path stays accurate.
            // `loadThumbnail` already brings the base to the sidecar orientation, so the
            // crop and mask geometry below (applied in the display frame) line up on a
            // sidecar-rotated file.
            let original: NSImage
            if let cached = cache.object(forKey: url as NSURL) {
                original = cached
            } else if let loaded = await loadThumbnail(for: url) {
                original = loaded
            } else {
                return nil
            }

            // Unwrap the CGImage on the current actor (cheap — the thumbnail is
            // already a bitmap rep), then render the edits off-main. The CoreImage
            // render must not run on the MainActor or it hitches grid scrolling.
            guard let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            guard let outputCG = await Self.renderEditedThumbnail(
                cgImage: cgImage, settings: settings, exifOrientation: exifOrientation) else {
                return nil
            }
            // Drop the result if a rotation (or other invalidation) cancelled us mid-render,
            // so a render for the old orientation can't clobber the rotated cache entry.
            guard !Task.isCancelled else { return nil }
            let edited = NSImage(cgImage: outputCG, size: NSSize(width: outputCG.width, height: outputCG.height))
            editedCache.setObject(edited, forKey: url as NSURL, cost: Self.decodedCost(of: edited))
            return edited
        }

        let request = InFlightRequest(id: requestID, task: task, consumers: [consumerID])
        editedInFlightTasks[url] = request
        return await awaitRequest(
            request,
            url: url,
            consumerID: consumerID,
            isEdited: true
        )
    }

    /// Await a shared decode without letting one canceled consumer kill work that a
    /// visible cell still needs. The underlying task is canceled only when its final
    /// consumer leaves; this makes collection-view prefetch cancellation effective
    /// while preserving request coalescing for duplicate visible/prefetch loads.
    private func awaitRequest(
        _ request: InFlightRequest,
        url: URL,
        consumerID: UUID,
        isEdited: Bool
    ) async -> NSImage? {
        await withTaskCancellationHandler {
            let result = await request.task.value
            removeConsumer(
                for: url,
                requestID: request.id,
                consumerID: consumerID,
                isEdited: isEdited,
                cancelWhenUnused: false
            )
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeConsumer(
                    for: url,
                    requestID: request.id,
                    consumerID: consumerID,
                    isEdited: isEdited,
                    cancelWhenUnused: true
                )
            }
        }
    }

    private func removeConsumer(
        for url: URL,
        requestID: UUID,
        consumerID: UUID,
        isEdited: Bool,
        cancelWhenUnused: Bool
    ) {
        if isEdited {
            guard var current = editedInFlightTasks[url], current.id == requestID else { return }
            current.consumers.remove(consumerID)
            if current.consumers.isEmpty {
                editedInFlightTasks.removeValue(forKey: url)
                if cancelWhenUnused { current.task.cancel() }
            } else {
                editedInFlightTasks[url] = current
            }
        } else {
            guard var current = inFlightTasks[url], current.id == requestID else { return }
            current.consumers.remove(consumerID)
            if current.consumers.isEmpty {
                inFlightTasks.removeValue(forKey: url)
                if cancelWhenUnused { current.task.cancel() }
            } else {
                inFlightTasks[url] = current
            }
        }
    }

    nonisolated private func generateQLThumbnail(for url: URL) async -> NSImage? {
        // QL talks to thumbnailsd; that daemon can wedge after a flood of failed
        // requests (e.g. iCloud-evicted or moved files). Race the call against a
        // bounded deadline so background pre-generation can't get held hostage —
        // on timeout we fall through to the CGImageSource fallback.
        let size = thumbnailSize
        return await withTaskGroup(of: NSImage?.self) { group in
            group.addTask {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: size,
                    scale: 2.0,
                    representationTypes: .thumbnail
                )
                do {
                    let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                    return thumbnail.nsImage
                } catch {
                    thumbnailLogger.debug("QLThumbnail failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                    return nil
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return nil
                }
                guard !Task.isCancelled else { return nil }
                thumbnailLogger.warning("QLThumbnail timed out for \(url.lastPathComponent, privacy: .private(mask: .hash))")
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated private func loadCGImageSourceThumbnail(for url: URL) async -> NSImage? {
        let maxPixelSize = max(thumbnailSize.width, thumbnailSize.height) * 2
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }
    }

    /// Applies the full develop pipeline (tonal + masks + crop/rotation) to a
    /// decoded thumbnail so grid thumbs reflect edits, Bridge-style. Used for
    /// non-RAW files, whose thumbnail base matches the edit-view SDR decode.
    /// (RAW files render their edited thumbnail from a real CIRAWFilter decode via
    /// `FullScreenImageCache.decodedEditedPreview` in `renderEditedThumbnail(for:…)`,
    /// because their QL preview is the camera-baked JPEG and diverges from the RAW
    /// decode the edit/export renders use.)
    ///
    /// `nonisolated static async` so the CoreImage render runs on the cooperative
    /// pool, off the MainActor. Takes/returns `CGImage` (Sendable) to cross the
    /// isolation boundary cleanly.
    nonisolated private static func renderEditedThumbnail(
        cgImage: CGImage, settings: CameraRawSettings, exifOrientation: Int
    ) async -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        // Async: suspends on the dedicated render queue instead of blocking this thumbnail
        // task's cooperative-pool thread — grid scrolling can spawn many of these at once.
        let edited = await CameraRawApproximation.applyWithCropAsync(
            to: ciImage, settings: settings, exifOrientation: exifOrientation)
        let editedExtent = edited.extent
        guard editedExtent.width > 0, editedExtent.height > 0 else { return nil }

        return CameraRawApproximation.ciContext.createCGImage(
            edited, from: editedExtent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    /// Invalidates only the edited thumbnail for a URL (original remains cached).
    func invalidateEditedThumbnail(for url: URL) {
        editedCache.removeObject(forKey: url as NSURL)
    }

    /// Invalidates both original and edited thumbnails for a URL.
    /// Also cancels any in-flight load tasks so a stuck loader on a moved/deleted file
    /// can't keep the URL's slot in the coalesce map forever.
    func invalidateThumbnail(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
        editedCache.removeObject(forKey: url as NSURL)
        inFlightTasks.removeValue(forKey: url)?.task.cancel()
        editedInFlightTasks.removeValue(forKey: url)?.task.cancel()
    }

    /// Rotates the cached thumbnail in-place for instant visual feedback during rotation.
    /// Falls back to invalidation if no cached thumbnail exists.
    func rotateThumbnailInCache(for url: URL, clockwise: Bool) {
        // Cancel any in-flight edited render: it captured the pre-rotation orientation and,
        // for a slow gated RAW decode, would finish *after* this rotation and overwrite the
        // freshly-rotated cache entry with a stale-orientation image — leaving the grid
        // thumbnail disagreeing with the edit view. (RAW edited renders are the only ones
        // slow enough to lose this race, which is why uncropped/non-RAW files are unaffected.)
        editedInFlightTasks.removeValue(forKey: url)?.task.cancel()
        if let existing = cache.object(forKey: url as NSURL),
           let rotated = rotateImage90(existing, clockwise: clockwise) {
            cache.setObject(rotated, forKey: url as NSURL, cost: Self.decodedCost(of: rotated))
        } else {
            cache.removeObject(forKey: url as NSURL)
        }
        if let existing = editedCache.object(forKey: url as NSURL),
           let rotated = rotateImage90(existing, clockwise: clockwise) {
            editedCache.setObject(rotated, forKey: url as NSURL, cost: Self.decodedCost(of: rotated))
        } else {
            editedCache.removeObject(forKey: url as NSURL)
        }
    }

    private func rotateImage90(_ image: NSImage, clockwise: Bool) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: height,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rotatedCG = context.makeImage() else { return nil }
        return NSImage(cgImage: rotatedCG, size: NSSize(width: height, height: width))
    }

    func clearCache() {
        cache.removeAllObjects()
        editedCache.removeAllObjects()
        cancelInFlightWork()
    }

    /// Cancels producers without discarding completed thumbnails. Warning pressure uses this
    /// lighter operation; critical pressure follows it with `clearCache` in eviction order.
    private func cancelInFlightWork() {
        for request in inFlightTasks.values {
            request.task.cancel()
        }
        inFlightTasks.removeAll()
        for request in editedInFlightTasks.values {
            request.task.cancel()
        }
        editedInFlightTasks.removeAll()
    }

    /// Approximate the decoded backing-store cost. Quick Look usually supplies a
    /// bitmap representation at 2x; using representation pixel dimensions avoids
    /// undercounting it as the image's point-sized `NSImage.size`.
    private static func decodedCost(of image: NSImage) -> Int {
        var largest = 0
        for representation in image.representations {
            if let bitmap = representation as? NSBitmapImageRep, bitmap.bytesPerRow > 0 {
                largest = max(largest, bitmap.bytesPerRow * bitmap.pixelsHigh)
            } else if representation.pixelsWide > 0, representation.pixelsHigh > 0 {
                largest = max(largest, representation.pixelsWide * representation.pixelsHigh * 4)
            }
        }
        if largest > 0 { return largest }
        let fallbackWidth = max(Int((image.size.width * 2).rounded(.up)), 1)
        let fallbackHeight = max(Int((image.size.height * 2).rounded(.up)), 1)
        return fallbackWidth * fallbackHeight * 4
    }

    /// Avoid handing not-yet-downloaded iCloud placeholders to QuickLook/ImageIO.
    /// Those APIs may block until the download completes; if enough placeholders
    /// enter the shared decode gate, thumbnails for unrelated local folders stall.
    /// Kick the download and let a later visible or prefetch request retry
    /// after iCloud has materialized the file.
    nonisolated private static func isLocallyAvailableForThumbnail(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: url) else { return true }

        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard values?.ubiquitousItemDownloadingStatus == .notDownloaded else { return true }

        try? fileManager.startDownloadingUbiquitousItem(at: url)
        thumbnailLogger.info("Deferred thumbnail for not-downloaded iCloud item: \(url.lastPathComponent, privacy: .private(mask: .hash))")
        return false
    }
}

/// A small async semaphore bounding how many thumbnail decodes run at once. Plain FIFO: callers
/// that can't get a permit immediately suspend until one is released, so a burst of requests is
/// throttled to `limit` concurrent decodes instead of all firing at once.
actor ThumbnailDecodeGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var waiterOrder: [UUID] = []
    private var waiterHead = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Returns false when the caller is canceled before it receives a permit.
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if inUse < limit {
            inUse += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[id] = continuation
                    waiterOrder.append(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        while waiterHead < waiterOrder.count {
            let id = waiterOrder[waiterHead]
            waiterHead += 1
            if let continuation = waiters.removeValue(forKey: id) {
                compactWaiterOrderIfNeeded()
                // Hand the permit directly to the next live waiter (`inUse` stays the same).
                continuation.resume(returning: true)
                return
            }
        }
        compactWaiterOrderIfNeeded(force: true)
        inUse = max(0, inUse - 1)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(returning: false)
    }

    private func compactWaiterOrderIfNeeded(force: Bool = false) {
        guard waiterHead > 0,
              force || (waiterHead >= 64 && waiterHead * 2 >= waiterOrder.count) else { return }
        waiterOrder.removeFirst(waiterHead)
        waiterHead = 0
    }
}
