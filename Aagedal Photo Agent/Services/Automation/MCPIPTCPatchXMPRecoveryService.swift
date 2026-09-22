import Foundation

/// Native-only resolution of abandoned staging. It never restores, installs or removes a
/// live carrier. Partial publication and external changes retain all recovery material.
nonisolated struct MCPIPTCPatchXMPRecoveryService: Sendable {
    enum Failure: Error, LocalizedError {
        case missingPhotoPath, staleReview, unresolvedChanges
        var errorDescription: String? {
            switch self {
            case .missingPhotoPath: "This older recovery record needs its original photo path for inspection."
            case .staleReview: "Recovery or photo authorization changed. Inspect retained recovery again."
            case .unresolvedChanges: "Original carrier identities could not be verified. Recovery remains retained for explicit restoration."
            }
        }
    }

    struct Review: Sendable {
        let photoPath: String
        let materialID: UUID
        let installedCarriers: MCPIPTCPatchXMPRecoveryStore.InstalledCarriers?
        let canResolveUnchanged: Bool
        let message: String
        fileprivate let material: MCPIPTCPatchXMPRecoveryStore.Material
        fileprivate let snapshot: MCPPhotoCarrierSnapshot
    }

    private let recovery: MCPIPTCPatchXMPRecoveryStore
    private let facade: MCPAutomationFacade

    init(recovery: MCPIPTCPatchXMPRecoveryStore, facade: MCPAutomationFacade) {
        self.recovery = recovery; self.facade = facade
    }

    func inspect(photoPath: String? = nil) throws -> Review? {
        guard let state = try recovery.loadRecoveryState() else { return nil }
        let material = state.material
        guard let path = material.sourcePath ?? photoPath else { throw Failure.missingPhotoPath }
        if let photoPath, let saved = material.sourcePath, photoPath != saved { throw Failure.staleReview }
        let snapshot = try facade.withPhotoSnapshot(path: path) { $0 }
        guard snapshot.target.url.deletingPathExtension().appendingPathExtension("xmp").path == material.targetPath,
              let currentState = try recovery.loadRecoveryState(),
              currentState.material == material, currentState.installed == state.installed else { throw Failure.staleReview }
        let unchanged = try matchesOriginal(snapshot, material: material)
        let identityMessage = state.installed.map {
            $0.appRevision == nil ? " Installed XMP identity is retained." : " Installed XMP and app history identities are retained."
        } ?? ""
        return Review(photoPath: snapshot.target.url.path, materialID: material.id,
            installedCarriers: state.installed, canResolveUnchanged: unchanged,
            message: unchanged
                ? "The original photo, XMP and app history are unchanged. Resolve abandoned staging to allow a new publication review."
                : "Publication or external changes may have occurred. Recovery is retained; automatic restoration is unavailable." + identityMessage,
            material: material, snapshot: snapshot)
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func checking<T>(_ body: () throws -> T) throws -> T {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                return try body()
            }
        }
    }

    /// The caller supplies the exact review accepted by the user. Resolution rechecks all
    /// carrier generations, bytes and authority under the photo and journal locks. A receipt
    /// preserves the staged bytes without claiming they were published.
    @MetadataSidecarFilesystemActor
    func resolveUnchanged(_ review: Review) async throws {
        guard review.canResolveUnchanged else { throw Failure.unresolvedChanges }
        try Task.checkCancellation()
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            let photo = URL(fileURLWithPath: review.photoPath)
            let reservation = try MCPProcessReservation.acquirePhoto(photo)
            defer { reservation.release() }
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: photo)) { @MetadataSidecarFilesystemActor in
                try cancellation.checking {
                    try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
                    try recovery.recordUnchanged(review.material) {
                        let current = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                        guard current.target == review.snapshot.target,
                              current.sourceBytes == review.snapshot.sourceBytes,
                              current.sourceRevision == review.snapshot.sourceRevision,
                              current.xmpSidecarRevision == review.snapshot.xmpSidecarRevision,
                              current.appSidecarRevision == review.snapshot.appSidecarRevision,
                              try matchesOriginal(current, material: review.material) else { throw Failure.staleReview }
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func matchesOriginal(_ snapshot: MCPPhotoCarrierSnapshot,
                                 material: MCPIPTCPatchXMPRecoveryStore.Material) throws -> Bool {
        guard let app = material.appSidecarRecovery else { return false }
        let revision = try facade.authorizationStore.load().authorizationRevision
        return snapshot.sourceRevision == material.binding.sourceRevision
            && snapshot.xmpSidecarRevision == material.binding.xmpSidecarRevision
            && snapshot.appSidecarRevision == material.binding.appSidecarRevision
            && snapshot.xmpBytes == material.original
            && snapshot.appSidecarBytes == app.original
            && material.binding.authorizationRevision == revision
    }
}
