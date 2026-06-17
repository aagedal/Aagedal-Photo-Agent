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

    // Background pre-generation state
    var isPreGenerating = false
    var preGenerateCompleted = 0
    var preGenerateTotal = 0
    @ObservationIgnored private var backgroundGenerationTask: Task<Void, Never>?
    /// When true, the speculative background sweep is suspended. Set while the develop editor is
    /// active: background thumbnail decodes call ImageIO's XMP parsing, which races the editor's
    /// concurrent NSXML sidecar write on libxml2's process-global state. On-demand `loadThumbnail`
    /// is left ungated (the filmstrip is user-visible).
    @ObservationIgnored private var backgroundGenerationSuppressed = false

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
            var image: NSImage?
            if let ql = await generateQLThumbnail(for: url) {
                image = ql
            } else if let cg = await loadCGImageSourceThumbnail(for: url) {
                image = cg
            }

            guard let image else {
            // For non-image files, use system file icon
            if !SupportedImageFormats.isSupported(url: url) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: thumbnailSize.width, height: thumbnailSize.height)
                cache.setObject(icon, forKey: url as NSURL)
                return icon
            }
            return nil as NSImage?
        }

            let oriented = Self.orientedToSidecar(image, fileURL: url)
            cache.setObject(oriented, forKey: url as NSURL)
            return oriented
        }

        inFlightTasks[url] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: url)

        return result
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

        let task = Task<NSImage?, Never> {
            // Get or load the original thumbnail
            // `loadThumbnail` already brings the base to the sidecar orientation, so the
            // crop and mask geometry below (applied in the display frame) line up on a
            // sidecar-rotated RAW.
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
            guard !settings.isEmpty,
                  let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            guard let outputCG = await Self.renderEditedThumbnail(
                cgImage: cgImage, settings: settings, exifOrientation: exifOrientation) else {
                return nil
            }
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
    /// thumbnail so grid thumbs reflect edits, Bridge-style. For RAW files the QL
    /// thumbnail is the camera-rendered preview (camera processing baked in), so
    /// tonal/WB results are approximate there — an accepted trade-off: an
    /// approximate edited thumb beats an untouched one, and the full-screen and
    /// export renders stay exact.
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
        cancelBackgroundGeneration()
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

    // MARK: - Background Pre-generation

    /// Suspend (and cancel) the speculative background sweep while the develop editor is active so
    /// its ImageIO XMP parsing can't race the editor's NSXML sidecar write — see
    /// `backgroundGenerationSuppressed`.
    func suppressBackgroundGeneration(_ suppressed: Bool) {
        backgroundGenerationSuppressed = suppressed
        if suppressed { cancelBackgroundGeneration() }
    }

    func startBackgroundGeneration(for images: [ImageFile]) {
        guard !backgroundGenerationSuppressed else { return }
        cancelBackgroundGeneration()
        let uncached = images.filter { cache.object(forKey: $0.url as NSURL) == nil }
        guard !uncached.isEmpty else { return }

        preGenerateTotal = uncached.count
        preGenerateCompleted = 0
        isPreGenerating = true

        backgroundGenerationTask = Task {
            let batchSize = 6
            for batchStart in stride(from: 0, to: uncached.count, by: batchSize) {
                guard !Task.isCancelled else { break }
                let batchEnd = min(batchStart + batchSize, uncached.count)
                let batch = Array(uncached[batchStart..<batchEnd])

                await withTaskGroup(of: Void.self) { group in
                    for image in batch {
                        group.addTask {
                            _ = await self.loadThumbnail(for: image.url)
                        }
                    }
                }

                guard !Task.isCancelled else { break }
                self.preGenerateCompleted = batchEnd
            }
            self.isPreGenerating = false
        }
    }

    func cancelBackgroundGeneration() {
        backgroundGenerationTask?.cancel()
        backgroundGenerationTask = nil
        isPreGenerating = false
        preGenerateCompleted = 0
        preGenerateTotal = 0
    }
}
