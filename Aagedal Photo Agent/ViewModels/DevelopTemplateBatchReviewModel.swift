import Foundation
import Observation

/// Owns only a native review and its retirement. This model has no writer or Start capability.
@MainActor @Observable
final class DevelopTemplateBatchReviewModel {
    typealias Review = DevelopTemplateBatchAdmissionService.Review
    typealias Preparation = @Sendable () async throws -> Review
    typealias Cancellation = @Sendable (Review) async throws -> Void

    private(set) var review: Review?
    private(set) var isBusy = false
    private(set) var message: String?
    var cleanupRequiredID: UUID? { pendingCleanup?.id ?? preparationCleanupID }

    @ObservationIgnored private let cancelReview: Cancellation
    @ObservationIgnored private let retryPreparationCleanup: @Sendable () async throws -> Void
    @ObservationIgnored private var pendingCleanup: Review?
    @ObservationIgnored private var preparationCleanupID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(cancel: @escaping Cancellation,
         retryPreparationCleanup: @escaping @Sendable () async throws -> Void) {
        cancelReview = cancel
        self.retryPreparationCleanup = retryPreparationCleanup
    }

    /// The retained task outlives a dismissed view and drains any late review retirement.
    func prepare(_ preparation: @escaping Preparation) async {
        guard !isBusy, review == nil, cleanupRequiredID == nil else { return }
        generation = UUID()
        let current = generation
        isBusy = true; message = nil
        let task = Task { @MainActor in
            defer { isBusy = false; operation = nil }
            do {
                let prepared = try await preparation()
                if generation != current || Task.isCancelled {
                    await retire(prepared)
                } else {
                    review = prepared
                }
            } catch {
                if case DevelopTemplateBatchAdmissionFailure.cancellationCleanupRequired(let id) = error {
                    preparationCleanupID = id
                    message = "Develop preparation cleanup failed. Retry cleanup before preparing another review."
                } else if generation == current { message = error.localizedDescription }
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Mark the exact preparation immediately; a queued main-actor dismissal
            // alone could lose a race with a late preparation returning its review.
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.dismiss()
            }
        }
    }

    /// Visibility and consent disappear synchronously; filesystem cleanup remains owned.
    func dismiss() {
        generation = UUID()
        operation?.cancel()
        guard let retained = review else { return }
        review = nil
        beginRetirement(retained)
    }

    func retryCleanup() async {
        guard !isBusy else { return }
        if let retained = pendingCleanup {
            beginRetirement(retained)
        } else if preparationCleanupID != nil {
            isBusy = true
            operation = Task { @MainActor in
                defer { isBusy = false; operation = nil }
                let retry = retryPreparationCleanup
                let cleanup = Task { try await retry() }
                do {
                    try await cleanup.value
                    preparationCleanupID = nil; message = nil
                } catch {
                    message = "Develop preparation cleanup failed. Retry cleanup before preparing another review. \(error.localizedDescription)"
                }
            }
        }
        await waitForIdle()
    }

    func waitForIdle() async { await operation?.value }

    private func beginRetirement(_ retained: Review) {
        isBusy = true
        operation = Task { @MainActor in
            defer { isBusy = false; operation = nil }
            await retire(retained)
        }
    }

    private func retire(_ retained: Review) async {
        pendingCleanup = retained
        let cancel = cancelReview
        // A dismissed preparation is cancelled. Retirement must run in an uncancelled
        // task so cancellation cannot silently abandon its exact durable journal.
        let cleanup = Task { try await cancel(retained) }
        do {
            try await cleanup.value
            pendingCleanup = nil
            message = nil
        } catch {
            message = "Develop review cleanup failed. Retry cleanup before preparing another review. \(error.localizedDescription)"
        }
    }
}
