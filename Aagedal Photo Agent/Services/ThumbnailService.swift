import AppKit
import QuickLookThumbnailing
import CoreImage

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
            } else if let cg = loadCGImageSourceThumbnail(for: url) {
                image = cg
            }

            guard let image else { return nil as NSImage? }

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
            return nil
        }
    }

    nonisolated private func loadCGImageSourceThumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize.width, thumbnailSize.height) * 2,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

    func clearCache() {
        cancelBackgroundGeneration()
        cache.removeAllObjects()
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    // MARK: - Background Pre-generation

    func startBackgroundGeneration(for urls: [URL]) {
        cancelBackgroundGeneration()
        let uncached = urls.filter { cache.object(forKey: $0 as NSURL) == nil }
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
                    for url in batch {
                        group.addTask {
                            _ = await self.loadThumbnail(for: url)
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
