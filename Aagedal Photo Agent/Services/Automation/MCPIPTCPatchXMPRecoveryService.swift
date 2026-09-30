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
        fileprivate let preparedXMP: MCPPreparedXMPIdentity?
        fileprivate let preparedMutation: MCPIPTCPatchXMPRecoveryStore.PreparedMutation?
        let canRestorePartialPublication: Bool
        let canResolveUnchanged: Bool
        fileprivate let restored: MCPIPTCPatchXMPRecoveryStore.RestoredCarriers?
        let message: String
        fileprivate let material: MCPIPTCPatchXMPRecoveryStore.Material
        fileprivate let snapshot: MCPPhotoCarrierSnapshot
    }

    struct Hooks: Sendable {
        var beforeXMPReceipt: @Sendable () throws -> Void = {}
        var beforeAppReceipt: @Sendable () throws -> Void = {}
    }

    private let hooks: Hooks
    private let recovery: MCPIPTCPatchXMPRecoveryStore
    private let facade: MCPAutomationFacade

    init(recovery: MCPIPTCPatchXMPRecoveryStore, facade: MCPAutomationFacade, hooks: Hooks = .init()) {
        self.recovery = recovery; self.facade = facade; self.hooks = hooks
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
              currentState.restored == state.restored,
              currentState.preparedXMP == state.preparedXMP,
              currentState.preparedMutation == state.preparedMutation else { throw Failure.staleReview }
        let unchanged = try state.installed == nil && matchesOriginal(snapshot, material: material)
        let preparedMatches = state.installed == nil && state.preparedXMP != nil
            && state.preparedXMP == snapshot.preparedXMPIdentity
            && snapshot.xmpBytes == material.candidate
            && snapshot.xmpSidecarRevision != material.binding.xmpSidecarRevision
        let effectiveInstalled = state.installed ?? (preparedMatches
            ? .init(xmpRevision: snapshot.xmpSidecarRevision, appRevision: nil) : nil)
        let progress = mutationProgress(snapshot, installed: effectiveInstalled,
            restored: state.restored, prepared: state.preparedMutation)
        let restorable = try matchesRestorable(snapshot, material: material,
            installed: progress.installed, restored: progress.restored)
        let identityMessage = state.installed.map {
            $0.appRevision == nil ? " Installed XMP identity is retained." : " Installed XMP and app history identities are retained."
        } ?? ""
        return Review(photoPath: snapshot.target.url.path, materialID: material.id,
            installedCarriers: state.installed, preparedXMP: state.preparedXMP, preparedMutation: state.preparedMutation,
            canRestorePartialPublication: restorable,
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
    /// Receipt-complete steps can resume after reopening. A pre-receipt rename can resume
    /// only when its prepared inode generation matches the rooted live carrier. Interrupted
    /// removals remain unresolved because absence cannot authenticate who removed a file.
    @MetadataSidecarFilesystemActor
    func restorePartialPublication(_ review: Review) async throws {
        guard review.canRestorePartialPublication,
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
                    guard let retained = try recovery.loadRecoveryState(), retained.material == review.material,
                          retained.installed == review.installedCarriers,
                          retained.preparedXMP == review.preparedXMP,
                          retained.preparedMutation == review.preparedMutation,
                          retained.restored == review.restored else { throw Failure.staleReview }
                    var state = retained
                    var current = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                    guard current.target == review.snapshot.target,
                          current.sourceRevision == review.snapshot.sourceRevision,
                          current.xmpSidecarRevision == review.snapshot.xmpSidecarRevision,
                          current.appSidecarRevision == review.snapshot.appSidecarRevision else { throw Failure.staleReview }
                    if let mutation = state.preparedMutation {
                        let progress = mutationProgress(current, installed: state.installed,
                            restored: state.restored, prepared: mutation)
                        guard try matchesRestorable(current, material: retained.material,
                            installed: progress.installed, restored: progress.restored) else { throw Failure.staleReview }
                        let captured = current
                        let verify = {
                            try requireAuthority(retained.material)
                            let fresh = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                            guard fresh.target == captured.target,
                                  fresh.sourceRevision == captured.sourceRevision,
                                  fresh.sourceBytes == captured.sourceBytes,
                                  fresh.xmpSidecarRevision == captured.xmpSidecarRevision,
                                  fresh.appSidecarRevision == captured.appSidecarRevision,
                                  fresh.xmpBytes == captured.xmpBytes,
                                  fresh.appSidecarBytes == captured.appSidecarBytes else { throw Failure.staleReview }
                        }
                        if progress.installed == state.installed, progress.restored == state.restored {
                            try recovery.discardUnrenamedMutation(retained.material, verify: verify)
                        } else {
                            switch mutation.purpose {
                            case .appPublication:
                                guard let installed = progress.installed else { throw Failure.staleReview }
                                try recovery.recordInstalled(retained.material, installed: installed, verify: verify)
                            case .xmpRestoration:
                                guard let restored = progress.restored else { throw Failure.staleReview }
                                try recovery.recordRestored(retained.material, restored: restored, verify: verify)
                            case .appRestoration:
                                guard let restored = progress.restored else { throw Failure.staleReview }
                                try recovery.recordRestored(retained.material, restored: restored, complete: true, verify: verify)
                                return
                            }
                        }
                        guard let updated = try recovery.loadRecoveryState(), updated.material == retained.material,
                              updated.preparedMutation == nil else { throw Failure.staleReview }
                        state = updated
                    }
                    let installed: MCPIPTCPatchXMPRecoveryStore.InstalledCarriers
                    if let receipt = state.installed {
                        installed = receipt
                    } else if let prepared = state.preparedXMP {
                        installed = .init(xmpRevision: current.xmpSidecarRevision, appRevision: nil)
                        guard current.target == review.snapshot.target,
                              current.sourceRevision == retained.material.binding.sourceRevision,
                              current.preparedXMPIdentity == prepared,
                              current.xmpSidecarRevision != retained.material.binding.xmpSidecarRevision,
                              current.xmpBytes == retained.material.candidate,
                              current.appSidecarRevision == retained.material.binding.appSidecarRevision,
                              current.appSidecarBytes == app.original else { throw Failure.staleReview }
                        let preparedSnapshot = current
                        try recovery.recordInstalled(retained.material, installed: installed) {
                            try requireAuthority(retained.material)
                            let fresh = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                            guard fresh.sourceRevision == preparedSnapshot.sourceRevision,
                                  fresh.xmpSidecarRevision == preparedSnapshot.xmpSidecarRevision,
                                  fresh.appSidecarRevision == preparedSnapshot.appSidecarRevision,
                                  fresh.xmpBytes == preparedSnapshot.xmpBytes,
                                  fresh.appSidecarBytes == preparedSnapshot.appSidecarBytes else { throw Failure.staleReview }
                        }
                    } else { throw Failure.staleReview }
                    guard current.target == review.snapshot.target,
                          current.sourceRevision == review.snapshot.sourceRevision,
                          current.xmpSidecarRevision == review.snapshot.xmpSidecarRevision,
                          current.appSidecarRevision == review.snapshot.appSidecarRevision,
                          try matchesRestorable(current, material: retained.material, installed: installed, restored: state.restored)
                    else { throw Failure.staleReview }
                    let original = MCPPhotoCarrierSnapshot(target: current.target, sourceBytes: current.sourceBytes,
                        xmpBytes: retained.material.original, appSidecarBytes: app.original,
                        sourceModificationDate: current.sourceModificationDate, xmpModificationDate: nil,
                        sourceRevision: retained.material.binding.sourceRevision,
                        xmpSidecarRevision: retained.material.binding.xmpSidecarRevision,
                        appSidecarRevision: retained.material.binding.appSidecarRevision)
                    if state.restored == nil {
                        let recordXMP: @Sendable (MCPPhotoCarrierSnapshot) throws -> Void = { after in
                            try hooks.beforeXMPReceipt()
                            try recovery.recordRestored(retained.material, restored: .init(xmpRevision: after.xmpSidecarRevision, appRevision: nil)) {
                                try requireAuthority(retained.material)
                                let fresh = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                                guard fresh.target == after.target,
                                      fresh.sourceRevision == after.sourceRevision,
                                      fresh.xmpSidecarRevision == after.xmpSidecarRevision,
                                      fresh.appSidecarRevision == after.appSidecarRevision,
                                      after.xmpBytes == retained.material.original,
                                      after.sourceRevision == original.sourceRevision else { throw Failure.staleReview }
                            }
                        }
                        if let bytes = retained.material.original {
                            _ = try facade.installXMPSidecar(data: bytes, expected: current, reservation: reservation,
                                restoringEmptyOriginal: bytes.isEmpty,
                                beforeInstall: { try requireAuthority(retained.material) }, beforeMutation: { identity in
                                    try recovery.recordPreparedMutation(retained.material,
                                        mutation: .init(purpose: .xmpRestoration, identity: identity)) {
                                        try requireAuthority(retained.material)
                                    }
                                }, afterInstall: recordXMP)
                        } else {
                            try facade.removeOriginallyAbsentCarrier(.xmp, original: original, candidate: retained.material.candidate,
                                installedRevision: installed.xmpRevision, authorizationRevision: retained.material.binding.authorizationRevision,
                                expected: current, reservation: reservation, afterRemoval: recordXMP)
                        }
                    }
                    current = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                    guard let progress = try recovery.loadRecoveryState(), let restored = progress.restored,
                          progress.material == retained.material, progress.installed == installed,
                          try matchesRestorable(current, material: retained.material, installed: installed, restored: restored)
                    else { throw Failure.staleReview }
                    let recordApp: @Sendable (MCPPhotoCarrierSnapshot) throws -> Void = { after in
                        try hooks.beforeAppReceipt()
                        try recovery.recordRestored(retained.material,
                            restored: .init(xmpRevision: restored.xmpRevision, appRevision: after.appSidecarRevision), complete: true) {
                                try requireAuthority(retained.material)
                                let fresh = try facade.withPhotoSnapshot(path: photo.path, reservation: reservation) { $0 }
                                guard fresh.sourceRevision == after.sourceRevision,
                                      fresh.xmpSidecarRevision == after.xmpSidecarRevision,
                                      fresh.appSidecarRevision == after.appSidecarRevision,
                                      after.sourceRevision == original.sourceRevision,
                                      after.xmpSidecarRevision == restored.xmpRevision,
                                      after.xmpBytes == retained.material.original, after.appSidecarBytes == app.original
                                else { throw Failure.staleReview }
                            }
                    }
                    if installed.appRevision == nil || restored.appRevision != nil {
                        try recordApp(current)
                    } else if let bytes = app.original {
                        _ = try facade.installPendingDraft(data: bytes, expected: current, reservation: reservation,
                            beforeInstall: { try requireAuthority(retained.material) }, beforeMutation: { identity in
                                try recovery.recordPreparedMutation(retained.material,
                                    mutation: .init(purpose: .appRestoration, identity: identity)) {
                                    try requireAuthority(retained.material)
                                }
                            }, afterInstall: recordApp)
                    } else {
                        try facade.removeOriginallyAbsentCarrier(.appHistory, original: original, candidate: app.candidate!,
                            installedRevision: installed.appRevision!, authorizationRevision: retained.material.binding.authorizationRevision,
                            expected: current, reservation: reservation, afterRemoval: recordApp)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Infer only the next exact staged inode; peer carriers and authority are verified by
    /// matchesRestorable before this evidence is promoted into a durable receipt.
    private func mutationProgress(_ snapshot: MCPPhotoCarrierSnapshot,
                                  installed: MCPIPTCPatchXMPRecoveryStore.InstalledCarriers?,
                                  restored: MCPIPTCPatchXMPRecoveryStore.RestoredCarriers?,
                                  prepared: MCPIPTCPatchXMPRecoveryStore.PreparedMutation?)
        -> (installed: MCPIPTCPatchXMPRecoveryStore.InstalledCarriers?,
            restored: MCPIPTCPatchXMPRecoveryStore.RestoredCarriers?) {
        guard let prepared, let installed else { return (installed, restored) }
        switch prepared.purpose {
        case .appPublication:
            guard snapshot.preparedAppIdentity == prepared.identity else { return (installed, restored) }
            return (.init(xmpRevision: installed.xmpRevision, appRevision: snapshot.appSidecarRevision), restored)
        case .xmpRestoration:
            guard snapshot.preparedXMPIdentity == prepared.identity else { return (installed, restored) }
            return (installed, .init(xmpRevision: snapshot.xmpSidecarRevision, appRevision: nil))
        case .appRestoration:
            guard snapshot.preparedAppIdentity == prepared.identity, let restored else { return (installed, restored) }
            return (installed, .init(xmpRevision: restored.xmpRevision, appRevision: snapshot.appSidecarRevision))
        }
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
