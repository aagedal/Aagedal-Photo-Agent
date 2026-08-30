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

    private(set) var isWorkspaceActive = false
    private(set) var activeImageURL: URL?
    private(set) var editedURLs: Set<URL> = []

    @ObservationIgnored private(set) var undoManager = UndoManager()
    @ObservationIgnored private var imageSessionID = UUID()

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    /// Starts a clean workspace lifetime. Session-local cache refresh evidence never leaks from a
    /// previous presentation of the editor.
    func beginWorkspace() {
        invalidateImageSession()
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
        activeImageURL = nil
        editedURLs.removeAll(keepingCapacity: false)
        isWorkspaceActive = false
        return result
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
}
