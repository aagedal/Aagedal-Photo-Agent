import AppKit
import QuickLookThumbnailing
import CoreImage
import os

nonisolated private let thumbnailLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ThumbnailService")

@Observable
final class ThumbnailService {
    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    nonisolated(unsafe) private let editedCache = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var inFlightTasks: [URL: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var editedInFlightTasks: [URL: Task<NSImage?, Never>] = [:]
    private let thumbnailSize = CGSize(width: 240, height: 240)

    /// Caps how many thumbnail decodes run concurrently across the whole app — visible cell loads
    /// and collection-view prefetch both funnel through it. Without a cap a fast scroll or a
    /// held arrow key spawns hundreds of QuickLook/ImageIO decodes at once, saturating `thumbnailsd`
    /// and the cooperative pool so the thumbnails actually on screen queue behind off-screen ones.
    private let decodeGate = ThumbnailDecodeGate(limit: 6)

    init() {
        cache.countLimit = 500
        editedCache.countLimit = 500
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

        // Coalesce with existing in-flight request
        if let existingTask = inFlightTasks[url] {
            return await existingTask.value
        }

        // Create and register a new task
        let task = Task<NSImage?, Never> {
            if let oriented = await self.generateOrientedThumbnail(for: url) {
                cache.setObject(oriented, forKey: url as NSURL)
                return oriented
            }

            // For non-image files, use system file icon
            if !SupportedImageFormats.isSupported(url: url) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: thumbnailSize.width, height: thumbnailSize.height)
                cache.setObject(icon, forKey: url as NSURL)
                return icon
            }
            return nil as NSImage?
        }

        inFlightTasks[url] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: url)

        return result
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
        await decodeGate.acquire()
        var oriented: NSImage?
        if let ql = await generateQLThumbnail(for: url) {
            oriented = Self.orientedToSidecar(ql, fileURL: url)
        } else if let cg = await loadCGImageSourceThumbnail(for: url) {
            oriented = Self.orientedToSidecar(cg, fileURL: url)
        }
        await decodeGate.release()
        return oriented
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

        // Coalesce with existing in-flight edited request
        if let existingTask = editedInFlightTasks[url] {
            return await existingTask.value
        }

        let maxPixelSize = max(thumbnailSize.width, thumbnailSize.height) * 2
        let task = Task<NSImage?, Never> {
            guard !settings.isEmpty else { return nil }

            // RAW: render the edited thumbnail from a real CIRAWFilter decode — the same
            // shared edited-decode path the loupe and prefetch use — instead of compositing
            // edits onto QuickLook's embedded camera-JPEG preview. The QL preview is already
            // tone-mapped and clipped, so exposure/highlight numbers calibrated against the
            // linear HDR RAW decode (extendedDynamicRangeAmount=2.0 + sourceHasHDRHeadroom
            // tonemap) blew out highlights — the grid looked overexposed next to the edit
            // view. Decoding the RAW here makes the thumb match. Gated behind `decodeGate`
            // and downscaled to thumbnail size, and only ever for edited RAWs (unedited RAWs
            // keep the fast QL preview), so a fast scroll can't saturate the RAW engine.
            if SupportedImageFormats.isRaw(url: url) {
                guard Self.isLocallyAvailableForThumbnail(url) else { return nil }
                await decodeGate.acquire()
                let outputCG = await FullScreenImageCache.decodedEditedPreview(
                    for: url, settings: settings, orientation: exifOrientation, screenMaxPx: maxPixelSize)
                await decodeGate.release()
                guard let outputCG else { return nil }
                // Drop the result if a rotation (or other invalidation) cancelled us mid-decode,
                // so a render for the old orientation can't clobber the rotated cache entry.
                guard !Task.isCancelled else { return nil }
                let edited = NSImage(cgImage: outputCG, size: NSSize(width: outputCG.width, height: outputCG.height))
                editedCache.setObject(edited, forKey: url as NSURL)
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
            editedCache.setObject(edited, forKey: url as NSURL)
            return edited
        }

        editedInFlightTasks[url] = task
        let result = await task.value
        editedInFlightTasks.removeValue(forKey: url)

        return result
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
                    thumbnailLogger.debug("QLThumbnail failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                thumbnailLogger.warning("QLThumbnail timed out for \(url.lastPathComponent, privacy: .public)")
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
        inFlightTasks.removeValue(forKey: url)?.cancel()
        editedInFlightTasks.removeValue(forKey: url)?.cancel()
    }

    /// Rotates the cached thumbnail in-place for instant visual feedback during rotation.
    /// Falls back to invalidation if no cached thumbnail exists.
    func rotateThumbnailInCache(for url: URL, clockwise: Bool) {
        // Cancel any in-flight edited render: it captured the pre-rotation orientation and,
        // for a slow gated RAW decode, would finish *after* this rotation and overwrite the
        // freshly-rotated cache entry with a stale-orientation image — leaving the grid
        // thumbnail disagreeing with the edit view. (RAW edited renders are the only ones
        // slow enough to lose this race, which is why uncropped/non-RAW files are unaffected.)
        editedInFlightTasks.removeValue(forKey: url)?.cancel()
        if let existing = cache.object(forKey: url as NSURL),
           let rotated = rotateImage90(existing, clockwise: clockwise) {
            cache.setObject(rotated, forKey: url as NSURL)
        } else {
            cache.removeObject(forKey: url as NSURL)
        }
        if let existing = editedCache.object(forKey: url as NSURL),
           let rotated = rotateImage90(existing, clockwise: clockwise) {
            editedCache.setObject(rotated, forKey: url as NSURL)
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
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        for task in editedInFlightTasks.values {
            task.cancel()
        }
        editedInFlightTasks.removeAll()
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
        thumbnailLogger.info("Deferred thumbnail for not-downloaded iCloud item: \(url.lastPathComponent, privacy: .public)")
        return false
    }
}

/// A small async semaphore bounding how many thumbnail decodes run at once. Plain FIFO: callers
/// that can't get a permit immediately suspend until one is released, so a burst of requests is
/// throttled to `limit` concurrent decodes instead of all firing at once.
actor ThumbnailDecodeGate {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            // Hand the permit directly to the next waiter (inUse stays the same).
            waiters.removeFirst().resume()
        }
    }
}
