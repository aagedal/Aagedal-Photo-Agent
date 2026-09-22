import Foundation

/// Native recovery of abandoned staging and explicitly reviewed partial publication.
/// External or unreceipted changes retain all recovery material and fail closed.
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
        let canRestorePartialPublication: Bool
        let canResolveUnchanged: Bool
        fileprivate let restored: MCPIPTCPatchXMPRecoveryStore.RestoredCarriers?
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
              currentState.material == material, currentState.installed == state.installed,
              currentState.restored == state.restored else { throw Failure.staleReview }
        let unchanged = try state.installed == nil && matchesOriginal(snapshot, material: material)
        let restorable = try matchesRestorable(snapshot, material: material, installed: state.installed, restored: state.restored)
        let identityMessage = state.installed.map {
            $0.appRevision == nil ? " Installed XMP identity is retained." : " Installed XMP and app history identities are retained."
        } ?? ""
        return Review(photoPath: snapshot.target.url.path, materialID: material.id,
            installedCarriers: state.installed, canRestorePartialPublication: restorable,
            canResolveUnchanged: unchanged, restored: state.restored,
            message: unchanged
                ? "The original photo, XMP and app history are unchanged. Resolve abandoned staging to allow a new publication review."
                : (restorable ? "The retained original metadata can be restored after explicit confirmation." : "Publication or external changes may have occurred. Recovery is retained; automatic restoration is unavailable.") + identityMessage,
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

    /// Internal native-consent boundary. No MCP tool or automatic retry invokes restoration.
    /// Receipt-complete steps can resume after reopening. A mutation interrupted before its
    /// receipt cannot be distinguished from external replacement and remains blocked.
    @MetadataSidecarFilesystemActor
    func restorePartialPublication(_ review: Review) async throws {
        guard review.canRestorePartialPublication, let installed = review.installedCarriers,
              let app = review.material.appSidecarRecovery else { throw Failure.unresolvedChanges }
        try Task.checkCancellation()
        let cancellation = Cancellation()
        try await withTaskCancellationHandler {
            let photo = URL(fileURLWithPath: review.photoPath)
            let reservation = try MCPProcessReservation.acquirePhoto(photo)
            defer { reservation.release() }
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: photo)) { @MetadataSidecarFilesystemActor in
                try cancellation.checking {
                    try AutomationDraftEditorAdmission.shared.requireUnselected(photo)
                    guard let state = try recovery.loadRecoveryState(), state.material == review.material,
                          state.installed == installed, state.restored == review.restored else { throw Failure.staleReview }
                    var current = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                    guard current.target == review.snapshot.target,
                          current.sourceRevision == review.snapshot.sourceRevision,
                          current.xmpSidecarRevision == review.snapshot.xmpSidecarRevision,
                          current.appSidecarRevision == review.snapshot.appSidecarRevision,
                          try matchesRestorable(current, material: state.material, installed: installed, restored: state.restored)
                    else { throw Failure.staleReview }
                    let original = MCPPhotoCarrierSnapshot(target: current.target, sourceBytes: current.sourceBytes,
                        xmpBytes: state.material.original, appSidecarBytes: app.original,
                        sourceModificationDate: current.sourceModificationDate, xmpModificationDate: nil,
                        sourceRevision: state.material.binding.sourceRevision,
                        xmpSidecarRevision: state.material.binding.xmpSidecarRevision,
                        appSidecarRevision: state.material.binding.appSidecarRevision)
                    if state.restored == nil {
                        let recordXMP: @Sendable (MCPPhotoCarrierSnapshot) throws -> Void = { after in
                            try recovery.recordRestored(state.material, restored: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil)) {
                                guard after.xmpBytes == state.material.original,
                                      after.sourceRevision == original.sourceRevision else { throw Failure.staleReview }
                            }
                        }
                        if let bytes = state.material.original {
                            _ = try facade.installXMPSidecar(data: bytes, expected: current, reservation: reservation,
                                restoringEmptyOriginal: bytes.isEmpty,
                                beforeInstall: { try requireAuthority(state.material) }, afterInstall: recordXMP)
                        } else {
                            try facade.removeOriginallyAbsentCarrier(.xmp, original: original, candidate: state.material.candidate,
                                installedRevision: installed.xmpRevision, authorizationRevision: state.material.binding.authorizationRevision,
                                expected: current, reservation: reservation, afterRemoval: recordXMP)
                        }
                    }
                    current = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                    guard let progress = try recovery.loadRecoveryState(), let restored = progress.restored,
                          progress.material == state.material, progress.installed == installed,
                          try matchesRestorable(current, material: state.material, installed: installed, restored: restored)
                    else { throw Failure.staleReview }
                    let recordApp: @Sendable (MCPPhotoCarrierSnapshot) throws -> Void = { after in
                        try recovery.recordRestored(state.material,
                            restored: .init(xmpRevision: restored.xmpRevision, appRevision: after.appSidecarRevision), complete: true) {
                                try requireAuthority(state.material)
                                let fresh = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                                guard fresh.sourceRevision == after.sourceRevision,
                                      fresh.xmpSidecarRevision == after.xmpSidecarRevision,
                                      fresh.appSidecarRevision == after.appSidecarRevision,
                                      after.sourceRevision == original.sourceRevision,
                                      after.xmpSidecarRevision == restored.xmpRevision,
                                      after.xmpBytes == state.material.original, after.appSidecarBytes == app.original
                                else { throw Failure.staleReview }
                            }
                    }
                    if installed.appRevision == nil || restored.appRevision != nil {
                        try recordApp(current)
                    } else if let bytes = app.original {
                        _ = try facade.installPendingDraft(data: bytes, expected: current, reservation: reservation,
                            beforeInstall: { try requireAuthority(state.material) }, afterInstall: recordApp)
                    } else {
                        try facade.removeOriginallyAbsentCarrier(.appHistory, original: original, candidate: app.candidate!,
                            installedRevision: installed.appRevision!, authorizationRevision: state.material.binding.authorizationRevision,
                            expected: current, reservation: reservation, afterRemoval: recordApp)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func requireAuthority(_ material: MCPIPTCPatchXMPRecoveryStore.Material) throws {
        guard try facade.authorizationStore.load().authorizationRevision == material.binding.authorizationRevision else {
            throw Failure.staleReview
        }
    }

    private func matchesRestorable(_ snapshot: MCPPhotoCarrierSnapshot,
                                   material: MCPIPTCPatchXMPRecoveryStore.Material,
                                   installed: MCPIPTCPatchXMPRecoveryStore.InstalledCarriers?,
                                   restored: MCPIPTCPatchXMPRecoveryStore.RestoredCarriers?) throws -> Bool {
        guard let installed, let app = material.appSidecarRecovery, app.candidate != nil,
              material.sourcePath == snapshot.target.url.path,
              snapshot.sourceRevision == material.binding.sourceRevision,
              (app.original?.isEmpty != true) else { return false }
        try requireAuthority(material)
        let xmpRevision = restored?.xmpRevision ?? installed.xmpRevision
        let xmpBytes = restored == nil ? material.candidate : material.original
        let appRevision = restored?.appRevision ?? installed.appRevision ?? material.binding.appSidecarRevision
        let appBytes = restored?.appRevision != nil || installed.appRevision == nil ? app.original : app.candidate
        return snapshot.xmpSidecarRevision == xmpRevision && snapshot.xmpBytes == xmpBytes
            && snapshot.appSidecarRevision == appRevision && snapshot.appSidecarBytes == appBytes
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
