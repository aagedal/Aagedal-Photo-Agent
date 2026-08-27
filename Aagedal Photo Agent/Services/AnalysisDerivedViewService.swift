import CoreGraphics

/// Exact identity for one bounded Pixel Analysis visualization.
///
/// The source identifier includes the file, representation, orientation, and Develop render
/// token. Pixel geometry is included independently so a decoder-policy change cannot reuse a
/// raster produced at a different preview size.
nonisolated struct AnalysisDerivedViewCacheKey: Hashable, Sendable {
    let sourceIdentifier: String
    let mode: AnalysisPixelViewMode
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        sourceIdentifier: String,
        mode: AnalysisPixelViewMode,
        source: CGImage
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.mode = mode
        pixelWidth = source.width
        pixelHeight = source.height
    }
}

/// Deterministic, byte-cost-bounded LRU storage for Pixel Analysis derived rasters.
///
/// A custom actor-backed cache is used instead of an unbounded view-owned dictionary so the five
/// full-resolution derived modes cannot accumulate across a long review session. The default
/// 64 MiB budget holds roughly four 2,048-square RGBA8 views and accounts for actual row stride
/// and padding.
actor AnalysisDerivedViewCache {
    nonisolated static let defaultMaximumCost = 64 * 1_024 * 1_024
    nonisolated static let defaultMaximumEntryCount = 8

    struct Metrics: Equatable, Sendable {
        let entryCount: Int
        let totalCost: Int
        let maximumCost: Int
    }

    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: UInt64
    }

    private var maximumCost: Int
    private let maximumEntryCount: Int
    private var entries: [AnalysisDerivedViewCacheKey: Entry] = [:]
    private var totalCost = 0
    private var accessClock: UInt64 = 0

    init(
        maximumCost: Int = AnalysisDerivedViewCache.defaultMaximumCost,
        maximumEntryCount: Int = AnalysisDerivedViewCache.defaultMaximumEntryCount
    ) {
        self.maximumCost = max(0, maximumCost)
        self.maximumEntryCount = max(0, maximumEntryCount)
    }

    func image(for key: AnalysisDerivedViewCacheKey) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = nextAccess()
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: CGImage, for key: AnalysisDerivedViewCacheKey) {
        let cost = Self.cost(of: image)
        guard maximumCost > 0,
              maximumEntryCount > 0,
              cost <= maximumCost else {
            return
        }

        if let replaced = entries.removeValue(forKey: key) {
            totalCost -= replaced.cost
        }
        makeRoom(forCost: cost)
        entries[key] = Entry(
            image: image,
            cost: cost,
            lastAccess: nextAccess()
        )
        totalCost += cost
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        accessClock = 0
    }

    func setMaximumCost(_ newMaximumCost: Int) {
        maximumCost = max(0, newMaximumCost)
        trimToLimits()
    }

    func metrics() -> Metrics {
        Metrics(
            entryCount: entries.count,
            totalCost: totalCost,
            maximumCost: maximumCost
        )
    }

    private func nextAccess() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func makeRoom(forCost cost: Int) {
        while totalCost > maximumCost - cost || entries.count >= maximumEntryCount {
            guard let leastRecent = entries.min(
                by: { $0.value.lastAccess < $1.value.lastAccess }
            ) else {
                break
            }
            entries.removeValue(forKey: leastRecent.key)
            totalCost -= leastRecent.value.cost
        }
    }

    private func trimToLimits() {
        while totalCost > maximumCost || entries.count > maximumEntryCount {
            guard let leastRecent = entries.min(
                by: { $0.value.lastAccess < $1.value.lastAccess }
            ) else { break }
            entries.removeValue(forKey: leastRecent.key)
            totalCost -= leastRecent.value.cost
        }
    }

    nonisolated private static func cost(of image: CGImage) -> Int {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return overflow ? Int.max : cost
    }
}

/// Renders and caches spatially aligned Pixel Analysis views.
///
/// SwiftUI cancels its preview task whenever the source or mode changes. That cancellation is
/// explicitly forwarded into the detached utility task here; a superseded result is neither
/// published nor inserted into the cache.
nonisolated final class AnalysisDerivedViewService: Sendable {
    typealias Renderer = @Sendable (CGImage, AnalysisPixelViewMode) -> CGImage?

    static let shared = AnalysisDerivedViewService(memoryCoordinator: .shared)

    private let cache: AnalysisDerivedViewCache
    private let renderer: Renderer
    private let memoryCoordinator: ImageMemoryCoordinator?
    private let memoryRegistration: ImageMemoryCoordinator.Registration?

    init(
        maximumCost: Int = AnalysisDerivedViewCache.defaultMaximumCost,
        maximumEntryCount: Int = AnalysisDerivedViewCache.defaultMaximumEntryCount,
        memoryCoordinator: ImageMemoryCoordinator? = nil,
        renderer: @escaping Renderer = AnalysisPixelViewRenderer.render
    ) {
        cache = AnalysisDerivedViewCache(
            maximumCost: maximumCost,
            maximumEntryCount: maximumEntryCount
        )
        self.renderer = renderer
        self.memoryCoordinator = memoryCoordinator
        if let memoryCoordinator {
            memoryRegistration = memoryCoordinator.register(
                kind: .scope,
                applyLimit: { [cache] limit in
                    Task { await cache.setMaximumCost(limit) }
                },
                evict: { [cache] in
                    Task { await cache.removeAll() }
                }
            )
        } else {
            memoryRegistration = nil
        }
    }

    func image(
        for key: AnalysisDerivedViewCacheKey,
        source: CGImage
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard key.mode != .normal else { return source }
        if let memoryCoordinator {
            let adaptiveLimit = memoryCoordinator.adaptiveLimit(
                for: .scope,
                sourcePixelSize: CGSize(width: source.width, height: source.height),
                bytesPerPixel: max(source.bitsPerPixel / 8, 4)
            )
            await cache.setMaximumCost(adaptiveLimit)
        }
        if let cached = await cache.image(for: key) {
            return Task.isCancelled ? nil : cached
        }

        let mode = key.mode
        let renderer = renderer
        let renderTask = Task.detached(priority: .utility) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            let rendered = renderer(source, mode)
            return Task.isCancelled ? nil : rendered
        }
        let rendered = await withTaskCancellationHandler {
            await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }

        guard !Task.isCancelled, let rendered else { return nil }
        await cache.insert(rendered, for: key)
        return rendered
    }

    func cachedImage(for key: AnalysisDerivedViewCacheKey) async -> CGImage? {
        await cache.image(for: key)
    }

    func cacheMetrics() async -> AnalysisDerivedViewCache.Metrics {
        await cache.metrics()
    }

    func removeAllCachedImages() async {
        await cache.removeAll()
    }
}
