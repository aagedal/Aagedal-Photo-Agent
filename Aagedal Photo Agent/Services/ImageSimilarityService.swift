import Foundation
import ImageIO
import Vision

/// Serial background analysis, with bounded, content-sensitive feature-print caching.
/// Uses original image pixels; develop edits and metadata do not affect similarity.
actor ImageSimilarityService {
    nonisolated struct Progress: Equatable, Sendable {
        let completed: Int
        let total: Int
    }

    nonisolated enum AnalysisError: LocalizedError {
        case referenceUnavailable

        var errorDescription: String? {
            "The reference photo could not be analyzed. Select a local photo and choose Similarity again."
        }
    }
    nonisolated struct Input: Equatable, Sendable {
        let url: URL
        let size: Int64
        let modified: Date
        let canAnalyze: Bool

        @MainActor init(_ image: ImageFile) {
            url = image.url
            size = image.fileSize
            modified = image.dateModified
            canAnalyze = image.isImageFile && !image.isICloudDownloadPending
        }

        var cacheKey: NSString {
            "\(url.absoluteString)|\(size)|\(modified.timeIntervalSince1970)" as NSString
        }
    }

    private let cache = NSCache<NSString, VNFeaturePrintObservation>()

    init() {
        cache.countLimit = 2_000
    }

    func order(
        _ inputs: [Input], reference: URL,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> [URL] {
        try Task.checkCancellation()
        let total = inputs.filter(\.canAnalyze).count
        await progress(Progress(completed: 0, total: total))
        guard let anchor = inputs.first(where: { $0.url == reference }),
              let referencePrint = try featurePrint(anchor) else {
            throw AnalysisError.referenceUnavailable
        }
        var completed = 1
        await progress(Progress(completed: completed, total: total))
        let clock = ContinuousClock()
        var lastReport = clock.now
        var distances: [URL: Float] = [reference: 0]
        for input in inputs where input.url != reference {
            try Task.checkCancellation()
            if let print = try featurePrint(input) {
                var distance: Float = 0
                if (try? referencePrint.computeDistance(&distance, to: print)) != nil,
                   distance.isFinite {
                    distances[input.url] = distance
                }
            }
            if input.canAnalyze {
                completed += 1
                // Bound UI updates even when thousands of cached prints are scanned.
                if completed == total || lastReport.duration(to: clock.now) >= .milliseconds(100) {
                    await progress(Progress(completed: completed, total: total))
                    lastReport = clock.now
                }
            }
        }
        try Task.checkCancellation()
        // The input's name order breaks ties and keeps unreadable/non-image files last.
        return inputs.enumerated().sorted { lhs, rhs in
            if lhs.element.url == reference { return rhs.element.url != reference }
            if rhs.element.url == reference { return false }
            let left = distances[lhs.element.url] ?? .infinity
            let right = distances[rhs.element.url] ?? .infinity
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map { $0.element.url }
    }

    private func featurePrint(_ input: Input) throws -> VNFeaturePrintObservation? {
        try Task.checkCancellation()
        guard input.canAnalyze else { return nil }
        if let cached = cache.object(forKey: input.cacheKey) { return cached }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            guard !Task.isCancelled else { return nil }
            let request = VNGenerateImageFeaturePrintRequest()
            request.imageCropAndScaleOption = .scaleFit
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
                  let observation = request.results?.first else { return nil }
            cache.setObject(observation, forKey: input.cacheKey)
            return observation
        }
    }
}
