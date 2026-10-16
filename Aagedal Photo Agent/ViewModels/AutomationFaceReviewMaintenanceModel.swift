import Foundation
import Observation

nonisolated protocol AutomationFaceReviewMaintenanceServing: Sendable {
    func inspect() async throws -> MCPFaceScanReviewRequestStore.MaintenanceSnapshot
    func cleanup(_ review: MCPFaceScanReviewRequestStore.MaintenanceSnapshot) async throws -> UUID
}

/// A retained filesystem executor keeps bounded archive I/O off MainActor.
actor AutomationFaceReviewMaintenanceService: AutomationFaceReviewMaintenanceServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.face-review-maintenance", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private let requests: MCPFaceScanReviewRequestStore

    init(requests: MCPFaceScanReviewRequestStore) { self.requests = requests }

    func inspect() throws -> MCPFaceScanReviewRequestStore.MaintenanceSnapshot {
        try Task.checkCancellation()
        let review = try requests.maintenanceSnapshot()
        try Task.checkCancellation()
        return review
    }

    func cleanup(_ review: MCPFaceScanReviewRequestStore.MaintenanceSnapshot) throws -> UUID {
        try Task.checkCancellation()
        guard let epoch = review.epoch, !review.cancelledRecords.isEmpty else {
            throw MCPFaceScanReviewRequestStore.Failure.invalidTransition
        }
        return try requests.recoverCancelledCapacity(expectedEpoch: epoch,
            reviewedCancelledRecords: review.cancelledRecords)
    }
}

@MainActor @Observable
final class AutomationFaceReviewMaintenanceModel {
    struct CleanupConfirmation: Identifiable {
        let id: UUID
        let review: MCPFaceScanReviewRequestStore.MaintenanceSnapshot
    }
    private(set) var review: MCPFaceScanReviewRequestStore.MaintenanceSnapshot?
    private(set) var cleanupConfirmation: CleanupConfirmation?
    private(set) var isLoading = false
    private(set) var message: String?
    private let service: any AutomationFaceReviewMaintenanceServing
    private var generation = UUID()
    private var inspection: Task<MCPFaceScanReviewRequestStore.MaintenanceSnapshot, Error>?
    private var cleanup: Task<UUID, Error>?

    init(service: any AutomationFaceReviewMaintenanceServing) { self.service = service }

    isolated deinit { inspection?.cancel(); cleanup?.cancel() }

    func inspect() async {
        guard !isLoading else { return }
        isLoading = true; review = nil; cleanupConfirmation = nil; message = nil
        let request = generation, service = service
        let task = Task { try await service.inspect() }
        inspection = task
        // Busy ownership belongs to the worker, even after clear/dismissal.
        defer { inspection = nil; isLoading = false }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            review = value
            if value.epoch == nil { message = "No face review request archive is retained." }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            message = "Face review capacity could not be verified. Retained evidence is unchanged."
        }
    }

    func requestCleanup() {
        guard !isLoading, let review, review.epoch != nil, !review.cancelledRecords.isEmpty else { return }
        cleanupConfirmation = .init(id: UUID(), review: review)
    }

    func cancelCleanup() { cleanupConfirmation = nil }

    func confirmCleanup(_ confirmationID: UUID) async {
        guard !isLoading, let confirmation = cleanupConfirmation,
              confirmation.id == confirmationID, review == confirmation.review else { return }
        cleanupConfirmation = nil; isLoading = true; message = nil
        let request = generation, service = service
        let task = Task { try await service.cleanup(confirmation.review) }
        cleanup = task
        defer { cleanup = nil; isLoading = false }
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard request == generation else { return }
            review = nil
            message = "Cancelled face review requests removed. The request epoch rotated; awaiting review evidence is retained. Inspect capacity again before another cleanup."
        } catch {
            guard request == generation else { return }
            review = nil
            message = "Cleanup was not confirmed. Inspect capacity again; changed, stale, or unverifiable evidence is retained."
        }
    }

    func clear() {
        generation = UUID()
        inspection?.cancel(); cleanup?.cancel()
        cleanupConfirmation = nil; review = nil; message = nil
    }
}
