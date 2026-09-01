import Foundation
import Observation

/// Describes whether a Develop settings transition remains transient or must cross one of the
/// workspace's existing durable persistence boundaries.
nonisolated enum DevelopPersistenceIntent: Equatable, Sendable {
    case unchanged
    case previewOnly
    case commitPrimary
    case commitNamedVersion
}

/// The observable result of the most recently requested batch settings write.
///
/// Request identity is part of the value so callers and tests can distinguish an explicit
/// cancellation from a failure without coupling themselves to the coordinator's task storage.
nonisolated enum DevelopBatchPersistenceOutcome: Equatable, Sendable {
    case succeeded(requestID: UUID)
    case cancelled(requestID: UUID)
    case failed(requestID: UUID, message: String)
}

/// Owns the Develop workspace's undo lifetime and the set of image previews invalidated by edits.
///
/// The coordinator deliberately does not write XMP or named-version JSON. Those operations remain
/// injected at `EditWorkspaceView`, where the metadata and version services already reconcile
/// durable state. Undo restorations carry an image-session identity so a stale callback retained
/// by AppKit cannot publish settings into a replacement image.
@MainActor
@Observable
final class DevelopPersistenceSessionCoordinator {
    typealias SettingsPublisher = @MainActor (CameraRawSettings?, Bool) -> Void
    typealias PersistenceAction = @MainActor () -> Void
    typealias BatchPersistenceOperation = @MainActor () async throws -> Void

    private(set) var isWorkspaceActive = false
    private(set) var activeImageURL: URL?
    private(set) var editedURLs: Set<URL> = []
    private(set) var pendingBatchPersistenceCount = 0
    private(set) var latestBatchPersistenceOutcome: DevelopBatchPersistenceOutcome?

    @ObservationIgnored private(set) var undoManager = UndoManager()
    @ObservationIgnored private var imageSessionID = UUID()
    @ObservationIgnored private var workspaceSessionID = UUID()
    @ObservationIgnored private var latestBatchPersistenceRequestID: UUID?
    @ObservationIgnored private var batchPersistenceTasks: [UUID: Task<Void, Never>] = [:]

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var isBatchPersistenceInProgress: Bool { pendingBatchPersistenceCount > 0 }
    var batchPersistenceErrorMessage: String? {
        guard case .failed(_, let message) = latestBatchPersistenceOutcome else { return nil }
        return message
    }

    /// Starts a clean workspace lifetime. Session-local cache refresh evidence never leaks from a
    /// previous presentation of the editor.
    func beginWorkspace() {
        invalidateImageSession()
        workspaceSessionID = UUID()
        latestBatchPersistenceRequestID = nil
        pendingBatchPersistenceCount = 0
        latestBatchPersistenceOutcome = nil
        editedURLs.removeAll(keepingCapacity: true)
        activeImageURL = nil
        isWorkspaceActive = true
    }

    /// Replaces the image-scoped undo lifetime and invalidates every restoration registered for
    /// the previous image, even if an external AppKit owner retained a callback temporarily.
    func beginImageSession(_ imageURL: URL?) {
        // Preview refreshes (for example after paste or an orientation fallback) can restart the
        // rendering session without replacing the selected image. Preserve that image's undo
        // history exactly as the former view-owned UndoManager did.
        guard activeImageURL != imageURL else { return }
        invalidateImageSession()
        activeImageURL = imageURL
    }

    func endImageSession() {
        invalidateImageSession()
        activeImageURL = nil
    }

    /// Ends the workspace and consumes the exact URL set whose edited previews must be rebuilt.
    func endWorkspace() -> Set<URL> {
        let result = editedURLs
        invalidateImageSession()
        // A batch paste may already have crossed into a durable sidecar transaction. Do not
        // cancel that work when the view disappears: finishing it preserves the in-memory edit
        // the user already saw. Rotating the session identity suppresses late UI publication.
        workspaceSessionID = UUID()
        latestBatchPersistenceRequestID = nil
        pendingBatchPersistenceCount = 0
        latestBatchPersistenceOutcome = nil
        activeImageURL = nil
        editedURLs.removeAll(keepingCapacity: false)
        isWorkspaceActive = false
        return result
    }

    /// Starts a batch settings write owned by this workspace coordinator.
    ///
    /// Multiple durable writes are allowed to finish because the injected metadata engine owns
    /// per-file transaction serialization. Only the latest request may publish UI state, while
    /// every request remains explicitly cancellable by identity. Workspace teardown intentionally
    /// lets already-started durable work finish and rejects its late result instead of cancelling
    /// a possibly partially committed batch.
    @discardableResult
    func scheduleBatchPersistence(
        operation: @escaping BatchPersistenceOperation
    ) -> UUID? {
        guard isWorkspaceActive else { return nil }

        let requestID = UUID()
        let sessionID = workspaceSessionID
        latestBatchPersistenceRequestID = requestID
        latestBatchPersistenceOutcome = nil
        pendingBatchPersistenceCount += 1

        let task = Task { @MainActor [weak self] in
            do {
                try await operation()
                try Task.checkCancellation()
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .succeeded(requestID: requestID)
                )
            } catch is CancellationError {
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .cancelled(requestID: requestID)
                )
            } catch {
                self?.finishBatchPersistence(
                    requestID: requestID,
                    sessionID: sessionID,
                    outcome: .failed(
                        requestID: requestID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        batchPersistenceTasks[requestID] = task
        return requestID
    }

    func cancelBatchPersistence(requestID: UUID) {
        batchPersistenceTasks[requestID]?.cancel()
    }

    func dismissBatchPersistenceResult() {
        latestBatchPersistenceOutcome = nil
    }

    /// Records an already-published in-memory settings change for the active image. This is
    /// preview/cache state only; callers still choose when to request a durable commit.
    @discardableResult
    func recordPublishedSettingsChange(for imageURL: URL) -> DevelopPersistenceIntent {
        guard isWorkspaceActive, activeImageURL == imageURL else { return .unchanged }
        editedURLs.insert(imageURL)
        return .previewOnly
    }

    /// Batch paste publishes settings for images outside the active image session. It is still
    /// scoped to the current workspace lifetime and shares the same exit-time refresh inventory.
    @discardableResult
    func recordPublishedSettingsChanges(for imageURLs: some Sequence<URL>) -> DevelopPersistenceIntent {
        guard isWorkspaceActive else { return .unchanged }
        let urls = Set(imageURLs)
        guard !urls.isEmpty else { return .unchanged }
        editedURLs.formUnion(urls)
        return .previewOnly
    }

    /// Returns the durable boundary appropriate for the current edit without performing I/O.
    func persistenceIntent(
        hasChanges: Bool,
        editsNamedVersion: Bool
    ) -> DevelopPersistenceIntent {
        guard isWorkspaceActive else { return .unchanged }
        if editsNamedVersion { return .commitNamedVersion }
        return hasChanges ? .commitPrimary : .unchanged
    }

    /// Routes one persistence request to the durable boundary selected for the active image.
    ///
    /// Concrete XMP and named-version writers stay injected so this coordinator owns policy and
    /// lifecycle without taking a dependency on `MetadataViewModel` or the version store. The
    /// in-memory image snapshot is published exactly once before either durable action, matching
    /// the Develop workspace's established thumbnail/full-screen invalidation order.
    @discardableResult
    func performPersistence(
        hasChanges: Bool,
        editsNamedVersion: Bool,
        publishImageSnapshot: PersistenceAction,
        commitPrimary: PersistenceAction,
        commitNamedVersion: PersistenceAction
    ) -> DevelopPersistenceIntent {
        let intent = persistenceIntent(
            hasChanges: hasChanges,
            editsNamedVersion: editsNamedVersion
        )
        switch intent {
        case .commitPrimary:
            publishImageSnapshot()
            commitPrimary()
        case .commitNamedVersion:
            publishImageSnapshot()
            commitNamedVersion()
        case .unchanged, .previewOnly:
            break
        }
        return intent
    }

    /// Registers one value transition with an image identity. Undo and redo both restore the
    /// original dirty-state policy: Primary edits are marked changed; named versions are not.
    @discardableResult
    func recordMutation(
        before: CameraRawSettings?,
        after: CameraRawSettings?,
        editsNamedVersion: Bool,
        actionName: String? = nil,
        publisher: @escaping SettingsPublisher
    ) -> DevelopPersistenceIntent {
        guard isWorkspaceActive, activeImageURL != nil, before != after else { return .unchanged }
        let sessionID = imageSessionID
        registerRestoration(
            target: before,
            inverse: after,
            editsNamedVersion: editsNamedVersion,
            sessionID: sessionID,
            actionName: actionName,
            publisher: publisher
        )
        return .previewOnly
    }

    func undo() {
        guard isWorkspaceActive else { return }
        undoManager.undo()
    }

    func redo() {
        guard isWorkspaceActive else { return }
        undoManager.redo()
    }

    func removeAllUndoActions() {
        undoManager.removeAllActions()
    }

    private func registerRestoration(
        target: CameraRawSettings?,
        inverse: CameraRawSettings?,
        editsNamedVersion: Bool,
        sessionID: UUID,
        actionName: String?,
        publisher: @escaping SettingsPublisher
    ) {
        undoManager.registerUndo(withTarget: self) { coordinator in
            guard coordinator.isWorkspaceActive,
                  coordinator.imageSessionID == sessionID else { return }
            publisher(target, editsNamedVersion)
            coordinator.registerRestoration(
                target: inverse,
                inverse: target,
                editsNamedVersion: editsNamedVersion,
                sessionID: sessionID,
                actionName: actionName,
                publisher: publisher
            )
        }
        if let actionName {
            undoManager.setActionName(actionName)
        }
    }

    private func invalidateImageSession() {
        imageSessionID = UUID()
        undoManager.removeAllActions()
    }

    private func finishBatchPersistence(
        requestID: UUID,
        sessionID: UUID,
        outcome: DevelopBatchPersistenceOutcome
    ) {
        batchPersistenceTasks[requestID] = nil
        guard isWorkspaceActive, workspaceSessionID == sessionID else { return }
        pendingBatchPersistenceCount = max(0, pendingBatchPersistenceCount - 1)
        guard latestBatchPersistenceRequestID == requestID else { return }
        latestBatchPersistenceOutcome = outcome
    }
}
