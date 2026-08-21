import Foundation

/// Every mutable input family that can change a preflight result owns a separate revision.
/// A caller must advance the relevant component before requesting a cached evaluation.
nonisolated struct DeadlinePreflightRevisionToken: Codable, Hashable, Sendable {
    let selectionSourceRevision: UInt64
    let metadataRevision: UInt64
    let profileRevision: UInt64
    let resourceRevision: UInt64
    let renameEnvironmentRevision: UInt64
    let exportCapabilityRevision: UInt64
    let deliverySnapshotRevision: UInt64

    init(
        selectionSourceRevision: UInt64,
        metadataRevision: UInt64,
        profileRevision: UInt64,
        resourceRevision: UInt64,
        renameEnvironmentRevision: UInt64,
        exportCapabilityRevision: UInt64,
        deliverySnapshotRevision: UInt64
    ) {
        self.selectionSourceRevision = selectionSourceRevision
        self.metadataRevision = metadataRevision
        self.profileRevision = profileRevision
        self.resourceRevision = resourceRevision
        self.renameEnvironmentRevision = renameEnvironmentRevision
        self.exportCapabilityRevision = exportCapabilityRevision
        self.deliverySnapshotRevision = deliverySnapshotRevision
    }
}

nonisolated struct DeadlinePreflightPublication: Equatable, Sendable {
    let token: DeadlinePreflightRevisionToken
    let report: DeadlinePreflightReport
    let wasCached: Bool
}

nonisolated struct DeadlinePreflightProgressPublication: Equatable, Sendable {
    let token: DeadlinePreflightRevisionToken
    let progress: DeadlinePreflightProgress
}

nonisolated enum DeadlinePreflightCachePolicy: Equatable, Sendable {
    case useCompositeRevisionToken
    case bypass
}

/// Serializes preflight publication while the pure service remains freely callable in tests and
/// background work. Superseded tasks are cancelled, and a generation gate also suppresses an
/// evaluator that ignores cooperative cancellation.
actor DeadlinePreflightCoordinator {
    typealias Evaluator = @Sendable (DeadlinePreflightRequest) async throws -> DeadlinePreflightReport
    typealias ProgressiveEvaluator = @Sendable (
        DeadlinePreflightRequest,
        @escaping DeadlinePreflightService.ProgressHandler
    ) async throws -> DeadlinePreflightReport
    typealias ProgressHandler = @Sendable (DeadlinePreflightProgressPublication) async -> Void

    private let evaluator: ProgressiveEvaluator
    private let maximumCacheEntries: Int
    private var cache: [DeadlinePreflightRevisionToken: DeadlinePreflightReport] = [:]
    private var cacheOrder: [DeadlinePreflightRevisionToken] = []
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var activeTask: Task<DeadlinePreflightReport, Error>?

    init(
        service: DeadlinePreflightService = DeadlinePreflightService(),
        maximumCacheEntries: Int = 8
    ) {
        evaluator = { request, progress in
            try await service.evaluate(request, onProgress: progress)
        }
        self.maximumCacheEntries = max(1, maximumCacheEntries)
    }

    init(maximumCacheEntries: Int = 8, evaluator: @escaping Evaluator) {
        self.evaluator = { request, _ in try await evaluator(request) }
        self.maximumCacheEntries = max(1, maximumCacheEntries)
    }

    init(maximumCacheEntries: Int = 8, progressiveEvaluator: @escaping ProgressiveEvaluator) {
        evaluator = progressiveEvaluator
        self.maximumCacheEntries = max(1, maximumCacheEntries)
    }

    /// Returns `nil` only when this invocation was superseded while its evaluator was suspended.
    func evaluate(
        request: DeadlinePreflightRequest,
        token: DeadlinePreflightRevisionToken,
        cachePolicy: DeadlinePreflightCachePolicy = .useCompositeRevisionToken,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> DeadlinePreflightPublication? {
        generation &+= 1
        let invocationGeneration = generation
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = invocationGeneration

        if cachePolicy == .useCompositeRevisionToken, let report = cache[token] {
            touch(token)
            guard generation == invocationGeneration else { return nil }
            activeGeneration = nil
            return DeadlinePreflightPublication(token: token, report: report, wasCached: true)
        }

        let task = Task {
            try await evaluator(request) { progress in
                await self.forwardProgress(
                    progress,
                    token: token,
                    generation: invocationGeneration,
                    to: onProgress
                )
            }
        }
        activeTask = task

        let report: DeadlinePreflightReport
        do {
            report = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            guard generation == invocationGeneration else { return nil }
            activeTask = nil
            activeGeneration = nil
            throw error
        }

        guard generation == invocationGeneration, activeGeneration == invocationGeneration else {
            return nil
        }
        activeTask = nil
        activeGeneration = nil
        if cachePolicy == .useCompositeRevisionToken {
            insert(report, for: token)
        }
        return DeadlinePreflightPublication(token: token, report: report, wasCached: false)
    }

    func invalidateAll() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        activeGeneration = nil
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    func cachedReport(for token: DeadlinePreflightRevisionToken) -> DeadlinePreflightReport? {
        cache[token]
    }

    private func forwardProgress(
        _ progress: DeadlinePreflightProgress,
        token: DeadlinePreflightRevisionToken,
        generation invocationGeneration: UInt64,
        to handler: ProgressHandler
    ) async {
        guard generation == invocationGeneration,
              activeGeneration == invocationGeneration,
              !Task.isCancelled else { return }
        await handler(DeadlinePreflightProgressPublication(token: token, progress: progress))
    }

    private func touch(_ token: DeadlinePreflightRevisionToken) {
        cacheOrder.removeAll { $0 == token }
        cacheOrder.append(token)
    }

    private func insert(
        _ report: DeadlinePreflightReport,
        for token: DeadlinePreflightRevisionToken
    ) {
        cache[token] = report
        touch(token)
        while cacheOrder.count > maximumCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
