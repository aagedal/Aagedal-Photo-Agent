import Foundation
import Observation

nonisolated protocol AutomationRecoveryServing: Sendable {
    func inspectRecovery(photoPath: String?) async throws -> MCPIPTCPatchXMPRecoveryService.Review?
    func resolveUnchangedRecovery(_ review: MCPIPTCPatchXMPRecoveryService.Review) async throws
}

@MainActor @Observable
final class AutomationRecoveryModel {
    var legacyPhotoPath = "" { didSet { if oldValue != legacyPhotoPath { clear() } } }
    private(set) var review: MCPIPTCPatchXMPRecoveryService.Review?
    private(set) var message: String?
    private(set) var isLoading = false
    private let service: any AutomationRecoveryServing
    private var generation = UUID()
    private var inspection: Task<MCPIPTCPatchXMPRecoveryService.Review?, Error>?
    private var resolution: Task<Void, Error>?

    init(service: any AutomationRecoveryServing) { self.service = service }

    isolated deinit {
        inspection?.cancel()
        resolution?.cancel()
    }

    func inspect() async {
        guard !isLoading else { return }
        isLoading = true
        review = nil
        message = nil
        let request = generation
        let path = legacyPhotoPath.isEmpty ? nil : legacyPhotoPath
        let service = service
        let task = Task { try await service.inspectRecovery(photoPath: path) }
        inspection = task
        defer { if generation == request { isLoading = false; inspection = nil } }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            review = value
            if value == nil { message = "No unresolved XMP publication staging is retained." }
        } catch {
            guard request == generation else { return }
            message = "Recovery inspection failed. Check folder authorization and, for an older record, enter the original photo path. Retained evidence is unchanged."
        }
    }

    func resolveUnchanged() async {
        guard !isLoading, let checked = review, checked.canResolveUnchanged else { return }
        isLoading = true
        message = nil
        let request = generation
        let service = service
        let task = Task { try await service.resolveUnchangedRecovery(checked) }
        resolution = task
        defer { if generation == request { isLoading = false; resolution = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            review = nil
            message = "Unchanged staging resolved. No photo or metadata files were changed. Recovery material remains retained until the next publication is staged."
        } catch {
            guard request == generation else { return }
            review = nil
            message = "Staging could not be resolved. Deselect the photo in all metadata editors and inspect recovery again. Changed or uncertain files require restoration; retained evidence has not been discarded."
        }
    }

    func clear() {
        inspection?.cancel()
        resolution?.cancel()
        inspection = nil
        resolution = nil
        generation = UUID()
        review = nil
        message = nil
        isLoading = false
    }
}
