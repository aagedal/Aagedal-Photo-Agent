import Foundation
import Observation

/// Immutable evidence returned after the Develop export persistence operation finishes.
///
/// The renderer owns the file transaction and reports the installed URL here. Metadata copying
/// is a second persistence leg: a rendered file may be durable even when that leg fails, so the
/// coordinator must surface a warning instead of misreporting the complete export as a failure.
nonisolated struct DevelopExportPersistenceResult: Equatable, Sendable {
    let outputURL: URL
    let metadataWasCopied: Bool
}

/// Owns the one-at-a-time export lifecycle for a Develop workspace.
///
/// Rendering and metadata policy stay behind the injected persistence operation. The coordinator
/// owns request identity, cancellation, busy/error publication, and workspace teardown. Request
/// identity is checked in addition to cooperative task cancellation because a renderer may finish
/// an atomic file install after cancellation; that durable output is retained, but a late result
/// cannot mutate presentation state belonging to a closed workspace.
@MainActor
@Observable
final class DevelopExportSessionCoordinator {
    typealias PersistenceOperation = @MainActor () async throws -> DevelopExportPersistenceResult

    private(set) var isExporting = false
    private(set) var isWorkspaceActive = false
    private(set) var errorMessage: String?
    private(set) var lastPersistedOutputURL: URL?

    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    /// Starts a persistence request only when no export is already active. This preserves the
    /// existing single-export interaction contract enforced by the disabled toolbar button.
    @discardableResult
    func requestExport(
        operation: @escaping PersistenceOperation
    ) -> Bool {
        guard isWorkspaceActive, !isExporting else { return false }

        invalidateExport()
        let currentRequestID = requestID
        isExporting = true
        errorMessage = nil

        exportTask = Task { [weak self] in
            do {
                let result = try await operation()
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID else { return }

                lastPersistedOutputURL = result.outputURL
                if !result.metadataWasCopied {
                    errorMessage = "Image saved but metadata copy failed — IPTC data may be missing"
                }
                finishExport(requestID: currentRequestID)
            } catch is CancellationError {
                self?.finishExport(requestID: currentRequestID)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID else { return }
                errorMessage = "Failed to save image: \(error.localizedDescription)"
                finishExport(requestID: currentRequestID)
            }
        }
        return true
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Begins a fresh presentation lifetime. SwiftUI may reuse the coordinator after a prior
    /// disappearance, so no result or error from that lifetime is carried into the new one.
    func beginWorkspaceSession() {
        invalidateExport()
        isWorkspaceActive = true
        errorMessage = nil
        lastPersistedOutputURL = nil
    }

    /// Cancels presentation ownership without attempting to roll back an already-committed file.
    func cancelExport() {
        invalidateExport()
    }

    /// Ends the workspace lifetime and rejects every late success or failure publication.
    func endWorkspaceSession() {
        invalidateExport()
        isWorkspaceActive = false
        errorMessage = nil
        lastPersistedOutputURL = nil
    }

    private func invalidateExport() {
        exportTask?.cancel()
        exportTask = nil
        requestID = UUID()
        isExporting = false
    }

    private func finishExport(requestID completedRequestID: UUID) {
        guard requestID == completedRequestID else { return }
        exportTask = nil
        isExporting = false
    }
}
