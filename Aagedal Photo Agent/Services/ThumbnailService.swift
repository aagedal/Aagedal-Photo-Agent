import AppKit
import QuickLookThumbnailing
import CoreImage
import os

private let thumbnailLogger = Logger(subsystem: "com.aagedal.photo-agent", category: "ThumbnailService")

@Observable
final class ThumbnailService {
    nonisolated(unsafe) private let cache = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var inFlightTasks: [URL: Task<NSImage?, Never>] = [:]
    private let thumbnailSize = CGSize(width: 240, height: 240)

    // Background pre-generation state
    var isPreGenerating = false
    var preGenerateCompleted = 0
    var preGenerateTotal = 0
    @ObservationIgnored private var backgroundGenerationTask: Task<Void, Never>?

    init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func loadThumbnail(for url: URL, cameraRawSettings: CameraRawSettings? = nil, exifOrientation: Int = 1) async -> NSImage? {
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

            if let settings = cameraRawSettings, !settings.isEmpty {
                if let processed = applyCameraRaw(to: image, settings: settings, exifOrientation: exifOrientation) {
                    cache.setObject(processed, forKey: url as NSURL)
                    return processed
                }
            }

            cache.setObject(image, forKey: url as NSURL)
            return image
        }

        inFlightTasks[url] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: url)

        return result
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
            thumbnailLogger.debug("QLThumbnail failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
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

    nonisolated private func applyCameraRaw(to nsImage: NSImage, settings: CameraRawSettings, exifOrientation: Int = 1) -> NSImage? {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        let processed = CameraRawApproximation.applyWithCrop(to: ciImage, settings: settings, exifOrientation: exifOrientation)
        let extent = processed.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let isHDR = settings.hdrEditMode == 1
        let format: CIFormat = isHDR ? .RGBAh : .RGBA8
        let colorSpace = isHDR ? CameraRawApproximation.workingColorSpace : CGColorSpaceCreateDeviceRGB()

        guard let outputCG = CameraRawApproximation.ciContext.createCGImage(
            processed,
            from: extent,
            format: format,
            colorSpace: colorSpace
        ) else {
            return nil
        }
        return NSImage(cgImage: outputCG, size: NSSize(width: outputCG.width, height: outputCG.height))
    }

    func invalidateThumbnail(for url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    /// Rotates the cached thumbnail in-place for instant visual feedback during rotation.
    /// Falls back to invalidation if no cached thumbnail exists.
    func rotateThumbnailInCache(for url: URL, clockwise: Bool) {
        guard let existing = cache.object(forKey: url as NSURL),
              let rotated = rotateImage90(existing, clockwise: clockwise) else {
            cache.removeObject(forKey: url as NSURL)
            return
        }
        cache.setObject(rotated, forKey: url as NSURL)
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
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    // MARK: - Background Pre-generation

    func startBackgroundGeneration(for images: [ImageFile]) {
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
                            _ = await self.loadThumbnail(for: image.url, cameraRawSettings: image.cameraRawSettings, exifOrientation: image.exifOrientation)
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
