import CoreGraphics
import Dispatch
import Foundation

/// Coordinates disposable image and GPU caches under one process-wide budget.
///
/// The coordinator deliberately does not own cached objects. Each participant keeps the cache
/// implementation best suited to it (NSCache, actor-backed LRU, or Metal texture cache), while
/// this type supplies one adaptive budget and a deterministic memory-pressure protocol.
///
/// Pressure eviction order is:
/// 1. cancel speculative work;
/// 2. evict speculative Develop textures;
/// 3. evict derived scope/analysis rasters;
/// 4. evict display previews;
/// 5. evict thumbnails;
/// 6. evict full-screen images.
///
/// The current live Develop source is intentionally not evicted: it is foreground state rather
/// than a cache. Its estimated footprint is reserved before speculative-prefetch recommendations
/// are made, so a large RAW can reduce Develop prefetch to zero.
nonisolated final class ImageMemoryCoordinator: @unchecked Sendable {
    static let shared = ImageMemoryCoordinator()

    enum CacheKind: Int, CaseIterable, Sendable {
        case developSpeculative
        case scope
        case fullScreenPreview
        case thumbnail
        case fullScreenPrimary
    }

    enum PressureLevel: Sendable {
        case warning
        case critical
    }

    struct Policy: Equatable, Sendable {
        let totalBudget: Int
        let fullScreenPrimaryLimit: Int
        let fullScreenPreviewLimit: Int
        let thumbnailLimit: Int
        let scopeLimit: Int
        let developSpeculativeLimit: Int

        func limit(for kind: CacheKind) -> Int {
            switch kind {
            case .fullScreenPrimary: fullScreenPrimaryLimit
            case .fullScreenPreview: fullScreenPreviewLimit
            case .thumbnail: thumbnailLimit
            case .scope: scopeLimit
            case .developSpeculative: developSpeculativeLimit
            }
        }
    }

    final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellation: (@Sendable () -> Void)?

        fileprivate init(cancellation: @escaping @Sendable () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            let action = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { cancellation = nil }
                return cancellation
            }
            action?()
        }

        deinit { cancel() }
    }

    /// Upper bound of the process image budget (reached at 32 GB of RAM).
    static let maximumTotalBudget = 4 * 1_024 * 1_024 * 1_024

    private struct Participant: Sendable {
        let kind: CacheKind
        let cancelSpeculativeWork: (@Sendable () -> Void)?
        let applyLimit: @Sendable (Int) -> Void
        let evict: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let availableMemory: @Sendable () -> UInt64
    private var participants: [UUID: Participant] = [:]
    private var pressureHandlers: [UUID: PressureHandler] = [:]

    /// A store outside the proportional budget (fixed-size preview pipelines, loaded models,
    /// Core Image caches) that must still release memory under pressure. It never affects the
    /// per-kind participant split.
    private struct PressureHandler: Sendable {
        let level: PressureLevel
        let evict: @Sendable () -> Void
    }
    private var pressureSource: DispatchSourceMemoryPressure?

    init(
        availableMemory: @escaping @Sendable () -> UInt64 = {
            ProcessInfo.processInfo.physicalMemory
        },
        observesSystemPressure: Bool = true
    ) {
        self.availableMemory = availableMemory
        if observesSystemPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: DispatchQueue(label: "com.aagedal.photo-agent.image-memory-pressure")
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let event = source.data
                self.handleMemoryPressure(event.contains(.critical) ? .critical : .warning)
            }
            source.resume()
            pressureSource = source
        }
    }

    deinit {
        pressureSource?.cancel()
    }

    /// The process image budget is one eighth of physical memory, bounded so small machines
    /// retain OS headroom and large machines do not turn caches into an unbounded sink. The
    /// ceiling scales with RAM up to 4 GiB: a fixed 1 GiB cap left a 5K/6K full-screen cache
    /// room for barely one or two screen-resolution HDR images on 32-64 GB Macs. An 8 GB Mac
    /// (and anything smaller) gets the same budget as before.
    func policy() -> Policy {
        let mebibyte = 1_024 * 1_024
        let available = Int(clamping: availableMemory())
        let total = min(max(available / 8, 256 * mebibyte), Self.maximumTotalBudget)

        // Shares total 100%. Full-screen and Develop receive most of the budget, but neither can
        // independently claim the entire process allowance as they did before coordination.
        let fullScreenPrimary = total * 32 / 100
        let fullScreenPreview = total * 12 / 100
        let thumbnail = total * 16 / 100
        let scope = total * 8 / 100
        return Policy(
            totalBudget: total,
            fullScreenPrimaryLimit: fullScreenPrimary,
            fullScreenPreviewLimit: fullScreenPreview,
            thumbnailLimit: thumbnail,
            scopeLimit: scope,
            developSpeculativeLimit: total
                - fullScreenPrimary
                - fullScreenPreview
                - thumbnail
                - scope
        )
    }

    /// Returns a dimension-aware limit for one cache. Large active sources shrink disposable
    /// stores to preserve room for the source plus a render intermediate.
    func adaptiveLimit(
        for kind: CacheKind,
        sourcePixelSize: CGSize?,
        bytesPerPixel: Int
    ) -> Int {
        let policy = policy()
        let base = policy.limit(for: kind) / participantDivisor(for: kind)
        guard let cost = Self.estimatedImageCost(
            pixelSize: sourcePixelSize,
            bytesPerPixel: bytesPerPixel
        ) else { return base }

        let reserved = min(cost.saturatingMultiply(by: 2), policy.totalBudget)
        if reserved >= policy.totalBudget * 3 / 4 { return base / 4 }
        if reserved >= policy.totalBudget / 2 { return base / 2 }
        return base
    }

    /// Maximum number of speculative images whose decoded/GPU footprint can fit inside the
    /// requested cache share after reserving two active-image footprints. Zero disables prefetch.
    func prefetchItemLimit(
        for kind: CacheKind,
        sourcePixelSize: CGSize?,
        bytesPerPixel: Int,
        maximum: Int
    ) -> Int {
        guard maximum > 0,
              let itemCost = Self.estimatedImageCost(
                pixelSize: sourcePixelSize,
                bytesPerPixel: bytesPerPixel
              ),
              itemCost > 0 else { return 0 }
        let policy = policy()
        let activeReserve = min(itemCost.saturatingMultiply(by: 2), policy.totalBudget)
        let remainingProcessBudget = max(0, policy.totalBudget - activeReserve)
        let cacheAllowance = min(
            policy.limit(for: kind) / participantDivisor(for: kind),
            remainingProcessBudget
        )
        return min(maximum, cacheAllowance / itemCost)
    }

    @discardableResult
    func register(
        kind: CacheKind,
        cancelSpeculativeWork: (@Sendable () -> Void)? = nil,
        applyLimit: @escaping @Sendable (Int) -> Void,
        evict: @escaping @Sendable () -> Void
    ) -> Registration {
        let id = UUID()
        let participant = Participant(
            kind: kind,
            cancelSpeculativeWork: cancelSpeculativeWork,
            applyLimit: applyLimit,
            evict: evict
        )
        lock.withLock { participants[id] = participant }
        applyCurrentLimits(for: kind)
        return Registration { [weak self] in
            self?.removeParticipant(id: id, kind: kind)
        }
    }

    /// Registers an eviction callback that runs on memory pressure without joining the shared
    /// cache budget. `.warning` handlers run on every pressure event (after the warning-tier
    /// caches); `.critical` handlers run only on critical pressure, after every cache tier.
    @discardableResult
    func registerPressureEviction(
        level: PressureLevel,
        evict: @escaping @Sendable () -> Void
    ) -> Registration {
        let id = UUID()
        lock.withLock { pressureHandlers[id] = PressureHandler(level: level, evict: evict) }
        return Registration { [weak self] in
            self?.removePressureHandler(id: id)
        }
    }

    private func removePressureHandler(id: UUID) {
        _ = lock.withLock { pressureHandlers.removeValue(forKey: id) }
    }

    private func participantDivisor(for kind: CacheKind) -> Int {
        lock.withLock {
            max(1, participants.values.lazy.filter { $0.kind == kind }.count)
        }
    }

    private func applyCurrentLimits(for kind: CacheKind) {
        let callbacks = lock.withLock {
            participants.values.filter { $0.kind == kind }.map(\.applyLimit)
        }
        guard !callbacks.isEmpty else { return }
        let perParticipant = policy().limit(for: kind) / callbacks.count
        for callback in callbacks { callback(perParticipant) }
    }

    private func removeParticipant(id: UUID, kind: CacheKind) {
        _ = lock.withLock { participants.removeValue(forKey: id) }
        applyCurrentLimits(for: kind)
    }

    func handleMemoryPressure(_ level: PressureLevel) {
        let (snapshot, handlers) = lock.withLock {
            (Array(participants.values), Array(pressureHandlers.values))
        }

        // Cancellation always precedes eviction so completed speculative work cannot repopulate
        // a cache immediately after it was purged.
        for participant in snapshot {
            participant.cancelSpeculativeWork?()
        }

        let evictionOrder: [CacheKind]
        switch level {
        case .warning:
            evictionOrder = [.developSpeculative, .scope, .fullScreenPreview]
        case .critical:
            evictionOrder = CacheKind.allCases
        }
        for kind in evictionOrder {
            for participant in snapshot where participant.kind == kind {
                participant.evict()
            }
        }
        for handler in handlers where handler.level == .warning {
            handler.evict()
        }
        if level == .critical {
            for handler in handlers where handler.level == .critical {
                handler.evict()
            }
        }
    }

    private static func estimatedImageCost(
        pixelSize: CGSize?,
        bytesPerPixel: Int
    ) -> Int? {
        guard let pixelSize,
              pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0,
              bytesPerPixel > 0 else { return nil }
        let width = Int(pixelSize.width.rounded(.up))
        let height = Int(pixelSize.height.rounded(.up))
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelOverflow, !byteOverflow else { return Int.max }
        // Approximate the complete mip chain used by Metal as 4/3 of level zero. This is a
        // conservative overestimate for non-mipmapped CPU images and keeps one policy simple.
        return bytes.saturatingMultiply(by: 4) / 3
    }
}

nonisolated private extension Int {
    func saturatingMultiply(by other: Int) -> Int {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? Int.max : result
    }
}
