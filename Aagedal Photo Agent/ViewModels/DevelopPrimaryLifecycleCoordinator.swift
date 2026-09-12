import Foundation

/// Retains the immutable Primary writer independently of a Develop view, selection, or alert.
/// The metadata owner owns request payloads and retries; this registry only coordinates capture,
/// accepted-work completion and the Close/Quit boundary.
@MainActor
final class DevelopPrimaryLifecycleCoordinator {
    static let shared = DevelopPrimaryLifecycleCoordinator()

    private struct Owner {
        let waitForAccepted: @MainActor () async -> Void
        let requirePersisted: @MainActor () throws -> Void
    }
    private struct Editor {
        let hasPendingWork: @MainActor () -> Bool
        let capture: @MainActor () throws -> Void
    }
    private var owners: [UUID: Owner] = [:]
    private var editors: [UUID: Editor] = [:]
    private var generation: UInt64 = 0

    var hasPendingWork: Bool {
        !owners.isEmpty || editors.values.contains { $0.hasPendingWork() }
    }

    /// The owner intentionally remains strongly retained until all captured intent is durable
    /// or an exact verified export authorizes its explicit discard.
    func register(ownerID: UUID,
                  waitForAccepted: @escaping @MainActor () async -> Void,
                  requirePersisted: @escaping @MainActor () throws -> Void) {
        owners[ownerID] = .init(waitForAccepted: waitForAccepted, requirePersisted: requirePersisted)
        generation &+= 1
    }

    func unregister(ownerID: UUID) {
        if owners.removeValue(forKey: ownerID) != nil { generation &+= 1 }
    }

    /// Capture must finish transient controls and synchronously admit immutable Primary intent.
    /// Named-version capture remains owned by the existing named-version coordinator.
    func registerEditor(ownerID: UUID,
                        hasPendingWork: @escaping @MainActor () -> Bool = { true },
                        capture: @escaping @MainActor () throws -> Void) {
        editors[ownerID] = .init(hasPendingWork: hasPendingWork, capture: capture)
    }

    func unregisterEditor(ownerID: UUID) {
        editors.removeValue(forKey: ownerID)
    }

    /// A synchronous caller cannot wait for an asynchronous writer. It still captures first,
    /// then fails closed while the owner reports incomplete work. Async transitions use flush().
    func requirePersisted() throws {
        let captureFailure = captureEditorFailure()
        try checkOwnersAndEditors(captureFailure: captureFailure)
    }

    /// Wait for every accepted generation, including work admitted while an earlier owner was
    /// finishing. Failures are retained by their owner and are never automatically retried here.
    func flush() async throws {
        let captureFailure = captureEditorFailure()
        while true {
            let observed = generation
            let accepted = Array(owners.values)
            for owner in accepted { await owner.waitForAccepted() }
            if generation == observed { break }
        }
        // A failing capture must not make another already accepted write disappear or skip its
        // completion. Report failures only after the accepted queue has settled.
        try checkOwnersAndEditors(captureFailure: captureFailure)
        try Task.checkCancellation()
    }

    /// Recovery can snapshot live controls without crossing the failing persistence barrier.
    func captureEditors() throws {
        if let failure = captureEditorFailure() { throw failure }
    }

    private func captureEditorFailure() -> (any Error)? {
        var firstFailure: (any Error)?
        for editor in Array(editors.values) where editor.hasPendingWork() {
            do { try editor.capture() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        return firstFailure
    }

    private func checkOwnersAndEditors(captureFailure: (any Error)?) throws {
        for owner in Array(owners.values) { try owner.requirePersisted() }
        if let captureFailure { throw captureFailure }
        guard !editors.values.contains(where: { $0.hasPendingWork() }) else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Primary Develop edits still need to be captured or saved. Finish the active adjustment and retry before leaving.")
        }
    }
}
