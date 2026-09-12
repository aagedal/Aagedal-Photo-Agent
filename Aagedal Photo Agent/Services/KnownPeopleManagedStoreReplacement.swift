import CryptoKit
import Darwin
import Foundation

/// Process-wide ownership shared by Known People route publication and managed-root commits.
/// Planning deliberately does not acquire this lease: a user decision can remain open without
/// blocking iCloud routing. Waiters are FIFO and cancellation removes them before admission.
nonisolated final class KnownPeopleRouteMutationGate: @unchecked Sendable {
    static let shared = KnownPeopleRouteMutationGate()

    nonisolated final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private let gate: KnownPeopleRouteMutationGate
        private let id: UUID
        private var released = false

        fileprivate init(gate: KnownPeopleRouteMutationGate, id: UUID) {
            self.gate = gate
            self.id = id
        }

        func release() {
            let shouldRelease = lock.withLock {
                guard !released else { return false }
                released = true
                return true
            }
            if shouldRelease { gate.release(id: id) }
        }

        deinit { release() }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private let lock = NSLock()
    private var owner: UUID?
    private var waiters: [Waiter] = []
    private var cancelledBeforeEnqueue: Set<UUID> = []

    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        let id = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            self.cancel(id: id)
        }
        do {
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    var waitingCount: Int { lock.withLock { waiters.count } }
    var isHeld: Bool { lock.withLock { owner != nil } }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Lease, any Error>) {
        let outcome: Result<Lease, any Error>? = lock.withLock {
            if cancelledBeforeEnqueue.remove(id) != nil {
                return .failure(CancellationError())
            }
            if owner == nil {
                owner = id
                return .success(Lease(gate: self, id: id))
            }
            waiters.append(Waiter(id: id, continuation: continuation))
            return nil
        }
        if let outcome { continuation.resume(with: outcome) }
    }

    private func cancel(id: UUID) {
        let continuation: CheckedContinuation<Lease, any Error>? = lock.withLock {
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                return waiters.remove(at: index).continuation
            }
            if owner != id { cancelledBeforeEnqueue.insert(id) }
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release(id: UUID) {
        let next: Waiter? = lock.withLock {
            guard owner == id else { return nil }
            guard !waiters.isEmpty else {
                owner = nil
                return nil
            }
            let next = waiters.removeFirst()
            owner = next.id
            return next
        }
        if let next {
            next.continuation.resume(returning: Lease(gate: self, id: next.id))
        }
    }
}

/// The route observed by the caller while presenting a destructive replacement decision.
/// `generation` must change whenever route resolution or iCloud ownership changes.
nonisolated struct KnownPeopleManagedStoreRoute: Equatable, Sendable {
    let rootURL: URL
    let generation: UInt64
    let iCloudSyncActive: Bool
    let routingActive: Bool
}

nonisolated enum KnownPeopleManagedStoreDecision: Equatable, Sendable {
    case replaceSameLibrary
    case replaceDifferentLibrary
    case replaceUntracked
}

nonisolated struct KnownPeopleManagedStoreInventoryToken: Equatable, Sendable {
    let rootURL: URL
    let rootIdentity: KnownPeoplePackageDirectoryIdentity
    let inventorySHA256: String

    /// Directory entries use a trailing slash and the literal bytes `directory`.
    static func hash(entries: [String: Data]) -> String {
        var hasher = SHA256()
        for path in entries.keys.sorted() {
            hasher.update(data: Data(path.utf8)); hasher.update(data: Data([0]))
            hasher.update(data: entries[path]!); hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct KnownPeopleManagedStoreReplacementPlan: Sendable {
    let snapshot: KnownPeoplePackageSnapshot
    let route: KnownPeopleManagedStoreRoute
    let inventory: KnownPeopleManagedStoreInventoryToken
    let requiredDecision: KnownPeopleManagedStoreDecision
    let priorState: KnownPeopleManagedStoreState?
    /// A first-identity plan retains this UUID across precommit retries.
    let initialInstallationID: UUID?
}

/// Strict root-local authority. This record, rather than a process-global preference,
/// binds the managed projection to the admitted interchange contract and revision.
nonisolated struct KnownPeopleManagedStoreState: Codable, Equatable, Sendable {
    static let fileName = ".aagedal-known-people-state.json"
    static let format = "aagedal-known-people-managed-store"
    static let schemaVersion = 1

    let libraryID: UUID
    let installationID: UUID
    let currentRevision: String
    let currentCoreRevision: String
    let importedRevisions: [String]
    let contract: KnownPeoplePackageManifest.EmbeddingContract
    let managedProjectionSHA256: String
    let admittedPackageSHA256: String
    let admittedPackageDirectory: String
    let needsCloudReconciliation: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, libraryID, installationID, currentRevision, currentCoreRevision
        case importedRevisions, contract, managedProjectionSHA256, admittedPackageSHA256
        case admittedPackageDirectory
        case needsCloudReconciliation
    }

    init(libraryID: UUID, installationID: UUID, currentRevision: String,
         currentCoreRevision: String, importedRevisions: [String],
         contract: KnownPeoplePackageManifest.EmbeddingContract,
         managedProjectionSHA256: String, admittedPackageSHA256: String,
         needsCloudReconciliation: Bool = true) throws {
        self.libraryID = libraryID
        self.installationID = installationID
        self.currentRevision = currentRevision
        self.currentCoreRevision = currentCoreRevision
        self.importedRevisions = Array(Set(importedRevisions)).sorted()
        self.contract = contract
        self.managedProjectionSHA256 = managedProjectionSHA256
        self.admittedPackageSHA256 = admittedPackageSHA256
        admittedPackageDirectory = ".admitted-package"
        self.needsCloudReconciliation = needsCloudReconciliation
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys) == Set(CodingKeys.allCases) else {
            throw KnownPeopleManagedStoreFailure.malformedState
        }
        guard try container.decode(String.self, forKey: .format) == Self.format,
              try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw KnownPeopleManagedStoreFailure.malformedState
        }
        let libraryText = try container.decode(String.self, forKey: .libraryID)
        let installationText = try container.decode(String.self, forKey: .installationID)
        guard libraryText == libraryText.lowercased(), installationText == installationText.lowercased(),
              let library = UUID(uuidString: libraryText), library.uuidString.lowercased() == libraryText,
              let installation = UUID(uuidString: installationText),
              installation.uuidString.lowercased() == installationText else {
            throw KnownPeopleManagedStoreFailure.malformedState
        }
        libraryID = library
        installationID = installation
        currentRevision = try container.decode(String.self, forKey: .currentRevision)
        currentCoreRevision = try container.decode(String.self, forKey: .currentCoreRevision)
        importedRevisions = try container.decode([String].self, forKey: .importedRevisions)
        contract = try container.decode(KnownPeoplePackageManifest.EmbeddingContract.self, forKey: .contract)
        managedProjectionSHA256 = try container.decode(String.self, forKey: .managedProjectionSHA256)
        admittedPackageSHA256 = try container.decode(String.self, forKey: .admittedPackageSHA256)
        admittedPackageDirectory = try container.decode(String.self, forKey: .admittedPackageDirectory)
        needsCloudReconciliation = try container.decode(Bool.self, forKey: .needsCloudReconciliation)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(libraryID.uuidString.lowercased(), forKey: .libraryID)
        try container.encode(installationID.uuidString.lowercased(), forKey: .installationID)
        try container.encode(currentRevision, forKey: .currentRevision)
        try container.encode(currentCoreRevision, forKey: .currentCoreRevision)
        try container.encode(importedRevisions, forKey: .importedRevisions)
        try container.encode(contract, forKey: .contract)
        try container.encode(managedProjectionSHA256, forKey: .managedProjectionSHA256)
        try container.encode(admittedPackageSHA256, forKey: .admittedPackageSHA256)
        try container.encode(admittedPackageDirectory, forKey: .admittedPackageDirectory)
        try container.encode(needsCloudReconciliation, forKey: .needsCloudReconciliation)
    }

    private func validate() throws {
        guard libraryID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              installationID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              Self.isHash(currentRevision), Self.isHash(currentCoreRevision),
              Self.isHash(managedProjectionSHA256), Self.isHash(admittedPackageSHA256),
              !importedRevisions.isEmpty,
              importedRevisions == Array(Set(importedRevisions)).sorted(),
              importedRevisions.allSatisfy(Self.isHash), importedRevisions.contains(currentRevision),
              admittedPackageDirectory == ".admitted-package",
              contract == .auraFaceV1 else { throw KnownPeopleManagedStoreFailure.malformedState }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw KnownPeopleManagedStoreFailure.malformedState }
        do {
            try KnownPeoplePackageManifest.validateJSONStructure(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw KnownPeopleManagedStoreFailure.malformedState
            }
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw KnownPeopleManagedStoreFailure.malformedState
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func admittedPackageHash(_ files: [String: Data]) -> String {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: files[path]!)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the same root-local authority with only its cloud publication gate changed.
    /// The revision, projection and admitted-package bindings remain immutable.
    func requiringCloudReconciliation(_ required: Bool) throws -> Self {
        try Self(libraryID: libraryID, installationID: installationID,
                 currentRevision: currentRevision, currentCoreRevision: currentCoreRevision,
                 importedRevisions: importedRevisions, contract: contract,
                 managedProjectionSHA256: managedProjectionSHA256,
                 admittedPackageSHA256: admittedPackageSHA256,
                 needsCloudReconciliation: required)
    }

    /// A valid record protects an admitted v3 store from the legacy global-version reset
    /// only while the managed person and thumbnail bytes still match its bound digest.
    static func protectsCurrentEmbeddingStore(at root: URL) -> Bool {
        do {
            let data = try KnownPeopleManagedProjection.readRegularFile(
                at: root.appendingPathComponent(fileName), maximum: 65_536)
            let state = try decode(data)
            let projection = try KnownPeopleManagedProjection.hash(root: root)
            return state.contract == .auraFaceV1 && projection == state.managedProjectionSHA256
        } catch { return false }
    }

    /// A valid locally admitted replacement must not enter preserve-newer iCloud routing:
    /// doing so could resurrect records deliberately removed by its authoritative snapshot.
    static func requiresCloudReconciliation(at root: URL) throws -> Bool {
        let stateURL = root.appendingPathComponent(fileName)
        var info = stat()
        guard lstat(stateURL.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw KnownPeopleManagedStoreFailure.malformedState
        }
        do {
            let data = try KnownPeopleManagedProjection.readRegularFile(at: stateURL, maximum: 65_536)
            return try decode(data).needsCloudReconciliation
        } catch {
            throw KnownPeopleManagedStoreFailure.malformedState
        }
    }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated enum KnownPeopleManagedStoreFailure: Error, Equatable, LocalizedError {
    case invalidRoot, malformedState, activeICloudOrRouting, staleRoute, staleInventory
    case wrongDecision, invalidSnapshot, unsafeEntry, io, stagedValidationFailed
    case readbackFailed, durabilityFailed, cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "The selected Known People root is not a regular local directory."
        case .malformedState: "The Known People root-local identity record is malformed."
        case .activeICloudOrRouting: "Disable Known People iCloud sync and wait for routing to finish before replacing the library."
        case .staleRoute: "The Known People storage route changed after the replacement decision."
        case .staleInventory: "The Known People library changed after the replacement decision."
        case .wrongDecision: "The replacement confirmation does not match the current library identity."
        case .invalidSnapshot: "The admitted Known People snapshot is no longer valid."
        case .unsafeEntry: "The Known People store contains an unsupported file or symbolic link."
        case .io: "The Known People managed-store transaction failed."
        case .stagedValidationFailed: "The staged Known People replacement failed validation. The current library was not changed."
        case .readbackFailed: "The replacement committed, but installed-store readback failed."
        case .durabilityFailed: "The replacement committed, but syncing its parent directory failed. Recovery evidence was retained."
        case .cleanupFailed: "The replacement did not commit, and its staged recovery evidence could not be removed."
        }
    }
}

nonisolated struct KnownPeopleManagedStoreReplacementResult: Sendable {
    let committed: Bool
    let revision: String?
    let recoveryDirectory: URL?
    let installedState: KnownPeopleManagedStoreState?
    let failure: String?
    let wasCancelled: Bool
}

nonisolated struct KnownPeopleManagedStoreReplacementAccess: Sendable {
    var beforeStageReadback: @Sendable () throws -> Void = {}
    var beforeCommit: @Sendable () throws -> Void = {}
    var syncStageBeforeCommit: @Sendable (Int32) throws -> Void = {
        try KnownPeopleManagedStageFilesystem.syncTree($0)
    }
    var syncParentAfterCommit: @Sendable (KnownPeoplePackageParentTransaction) throws -> Void = {
        try KnownPeoplePackageWriterFilesystem.syncDirectory($0)
    }
    var afterCommit: @Sendable () throws -> Void = {}
    var liveRouteBeforeCommit: @MainActor @Sendable () -> KnownPeopleManagedStoreRoute? = { nil }
    var invalidateAfterCommit: @Sendable (URL) async -> Void = { _ in }
}

/// Replaces one already-resolved local managed root. Planning is read-only and never calls
/// `KnownPeopleService.loadDatabase()`, whose compatibility path may migrate or garbage collect.
actor KnownPeopleManagedStoreReplacement {
    private let access: KnownPeopleManagedStoreReplacementAccess
    private let fileManager = FileManager.default

    init(access: KnownPeopleManagedStoreReplacementAccess = .init()) { self.access = access }

    /// Production entry point. The swap callback advances every KnownPeopleService
    /// generation for this resolved root before installed-store readback returns.
    @MainActor
    static func integratedWithKnownPeopleService(
        _ service: KnownPeopleService,
        routingActive: Bool,
        baseAccess: KnownPeopleManagedStoreReplacementAccess = .init()
    ) -> KnownPeopleManagedStoreReplacement {
        var access = baseAccess
        access.liveRouteBeforeCommit = { [weak service] in
            service?.managedStoreRoute(routingActive: routingActive)
        }
        access.invalidateAfterCommit = { root in
            await MainActor.run {
                KnownPeopleService.invalidateAfterManagedStoreReplacement(at: root)
            }
        }
        return KnownPeopleManagedStoreReplacement(access: access)
    }

    func plan(snapshot: KnownPeoplePackageSnapshot,
              route: KnownPeopleManagedStoreRoute,
              initialInstallationID: UUID? = nil) throws -> KnownPeopleManagedStoreReplacementPlan {
        try admit(snapshot)
        try validateLocal(route)
        if let initialInstallationID,
           initialInstallationID == UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) {
            throw KnownPeopleManagedStoreFailure.wrongDecision
        }
        let inventory = try inventoryToken(root: route.rootURL)
        let state = try readState(root: route.rootURL)
        guard initialInstallationID == nil || state == nil else {
            throw KnownPeopleManagedStoreFailure.wrongDecision
        }
        let decision: KnownPeopleManagedStoreDecision
        if let state {
            decision = state.libraryID == snapshot.manifest.libraryID
                ? .replaceSameLibrary : .replaceDifferentLibrary
        } else {
            decision = .replaceUntracked
        }
        return KnownPeopleManagedStoreReplacementPlan(snapshot: snapshot, route: route,
            inventory: inventory, requiredDecision: decision, priorState: state,
            initialInstallationID: initialInstallationID)
    }

    /// Read-only transaction evidence, also used to bind first-identity construction to
    /// the exact root that the replacement transaction will later revalidate.
    func inventory(route: KnownPeopleManagedStoreRoute) throws -> KnownPeopleManagedStoreInventoryToken {
        try validateLocal(route)
        try Task.checkCancellation()
        return try inventoryToken(root: route.rootURL)
    }

    func replace(plan: KnownPeopleManagedStoreReplacementPlan,
                 decision: KnownPeopleManagedStoreDecision,
                 currentRoute: KnownPeopleManagedStoreRoute) async -> KnownPeopleManagedStoreReplacementResult {
        let commit = KnownPeopleManagedStoreCommitFlag()
        var recovery: URL?
        var installedState: KnownPeopleManagedStoreState?
        do {
            guard decision == plan.requiredDecision else { throw KnownPeopleManagedStoreFailure.wrongDecision }
            try validateLocal(currentRoute)
            guard normalized(currentRoute.rootURL) == normalized(plan.route.rootURL),
                  currentRoute.generation == plan.route.generation else {
                throw KnownPeopleManagedStoreFailure.staleRoute
            }
            try Task.checkCancellation()
            try admit(plan.snapshot)
            guard try inventoryToken(root: currentRoute.rootURL) == plan.inventory else {
                throw KnownPeopleManagedStoreFailure.staleInventory
            }

            let root = normalized(currentRoute.rootURL)
            let parentURL = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let transaction = try KnownPeoplePackageWriterFilesystem.openParent(parentURL)
            guard let heldRoot = try KnownPeoplePackageWriterFilesystem.openDirectory(transaction, root.lastPathComponent),
                  heldRoot.identity.sameDirectory(as: plan.inventory.rootIdentity) else {
                throw KnownPeopleManagedStoreFailure.staleInventory
            }
            guard try inventoryToken(root: root, descriptor: heldRoot.descriptor) == plan.inventory else {
                throw KnownPeopleManagedStoreFailure.staleInventory
            }

            let stageName = ".KnownPeople-replacement-\(UUID().uuidString)"
            let stage = try KnownPeoplePackageWriterFilesystem.createStage(transaction, stageName)
            do {
                let state = try stageReplacement(plan: plan, stage: stage)
                try access.beforeStageReadback()
                try validateStaged(stage: stage, snapshot: plan.snapshot, expectedState: state)
                try access.beforeCommit()
                try Task.checkCancellation()
                let liveRoute = await access.liveRouteBeforeCommit() ?? currentRoute
                try validateLocal(liveRoute)
                guard normalized(liveRoute.rootURL) == normalized(plan.route.rootURL),
                      liveRoute.generation == plan.route.generation else {
                    throw KnownPeopleManagedStoreFailure.staleRoute
                }
                try access.syncStageBeforeCommit(stage.descriptor)
                try Task.checkCancellation()
                try validateStaged(stage: stage, snapshot: plan.snapshot, expectedState: state)
                let liveDestination = try KnownPeoplePackageWriterFilesystem.entryURL(
                    transaction, root.lastPathComponent).standardizedFileURL
                guard sameResolvedPath(liveDestination, root),
                      let liveParentIdentity = try KnownPeoplePackageWriterFilesystem.inspect(
                        root.deletingLastPathComponent()),
                      liveParentIdentity.sameDirectory(as: transaction.identity),
                      let liveRootIdentity = try KnownPeoplePackageWriterFilesystem.inspect(root),
                      liveRootIdentity.sameDirectory(as: heldRoot.identity) else {
                    throw KnownPeopleManagedStoreFailure.staleRoute
                }
                guard try inventoryToken(root: root, descriptor: heldRoot.descriptor) == plan.inventory else {
                    throw KnownPeopleManagedStoreFailure.staleInventory
                }
                try KnownPeoplePackageWriterFilesystem.install(
                    KnownPeoplePackageInstallPlan(parent: transaction, stageName: stageName,
                        destinationName: root.lastPathComponent, stageIdentity: stage.identity,
                        destinationIdentity: heldRoot.identity)
                ) { commit.markCommitted() }
                guard commit.isCommitted else { throw KnownPeopleManagedStoreFailure.io }
                recovery = try KnownPeoplePackageWriterFilesystem.directoryURL(heldRoot)
                await access.invalidateAfterCommit(root)
                try access.afterCommit()
                do {
                    guard let installed = try KnownPeoplePackageWriterFilesystem.openDirectory(
                        transaction, root.lastPathComponent),
                          installed.identity.sameDirectory(as: stage.identity) else {
                        throw KnownPeopleManagedStoreFailure.readbackFailed
                    }
                    try verifyStaged(stage: installed, snapshot: plan.snapshot, expectedState: state)
                    installedState = state
                } catch {
                    throw KnownPeopleManagedStoreFailure.readbackFailed
                }
                do {
                    try access.syncParentAfterCommit(transaction)
                } catch {
                    throw KnownPeopleManagedStoreFailure.durabilityFailed
                }
            } catch {
                if !commit.isCommitted {
                    do {
                        try KnownPeoplePackageWriterFilesystem.removeOwned(transaction, stageName, stage.identity)
                    } catch {
                        recovery = try? KnownPeoplePackageWriterFilesystem.directoryURL(stage)
                        throw KnownPeopleManagedStoreFailure.cleanupFailed
                    }
                }
                throw error
            }
            return .init(committed: true, revision: plan.snapshot.manifest.revision,
                recoveryDirectory: recovery, installedState: installedState, failure: nil,
                wasCancelled: false)
        } catch {
            return .init(committed: commit.isCommitted, revision: commit.isCommitted ? plan.snapshot.manifest.revision : nil,
                recoveryDirectory: recovery, installedState: installedState,
                failure: error is CancellationError ? nil : error.localizedDescription,
                wasCancelled: error is CancellationError)
        }
    }

    /// Exact bytes retained under the managed root for byte-for-byte package re-export.
    func admittedPackageFiles(root: URL) throws -> [String: Data] {
        let state = try readState(root: root)
        guard let state else { throw KnownPeopleManagedStoreFailure.malformedState }
        guard try KnownPeopleManagedProjection.hash(root: root) == state.managedProjectionSHA256 else {
            throw KnownPeopleManagedStoreFailure.invalidSnapshot
        }
        let base = normalized(root).appendingPathComponent(state.admittedPackageDirectory, isDirectory: true)
        let files = try readFiles(root: base)
        guard KnownPeopleManagedStoreState.admittedPackageHash(files) == state.admittedPackageSHA256 else {
            throw KnownPeopleManagedStoreFailure.invalidSnapshot
        }
        try validateAdmittedPackageFiles(files, state: state)
        return files
    }

    private func validateAdmittedPackageFiles(_ files: [String: Data],
                                              state: KnownPeopleManagedStoreState) throws {
        guard let manifestBytes = files[KnownPeoplePackageManifest.fileName],
              let payloadBytes = files[KnownPeoplePackageManifest.payloadFileName] else {
            throw KnownPeopleManagedStoreFailure.invalidSnapshot
        }
        do {
            let manifest = try KnownPeoplePackageManifest.decode(manifestBytes)
            let payload = try KnownPeoplePackagePayload.decode(payloadBytes)
            try manifest.validate(payload: payload)
            guard manifest.libraryID == state.libraryID,
                  manifest.revision == state.currentRevision,
                  manifest.coreRevision == state.currentCoreRevision,
                  manifest.contract == state.contract,
                  Set(files.keys) == Set(manifest.files.map(\.path)).union([KnownPeoplePackageManifest.fileName]) else {
                throw KnownPeopleManagedStoreFailure.invalidSnapshot
            }
            for declaration in manifest.files {
                guard let bytes = files[declaration.path], bytes.count == declaration.byteCount,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == declaration.sha256 else {
                    throw KnownPeopleManagedStoreFailure.invalidSnapshot
                }
            }
        } catch let error as KnownPeopleManagedStoreFailure {
            throw error
        } catch {
            throw KnownPeopleManagedStoreFailure.invalidSnapshot
        }
    }

    private func stageReplacement(plan: KnownPeopleManagedStoreReplacementPlan,
                                  stage: KnownPeoplePackageHeldDirectory) throws -> KnownPeopleManagedStoreState {
        for name in ["people", "thumbnails", "embedding_thumbnails", ".admitted-package"] {
            try KnownPeopleManagedStageFilesystem.createDirectory(name, in: stage.descriptor)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for person in plan.snapshot.people {
            try KnownPeopleManagedStageFilesystem.writeFile(encoder.encode(person),
                path: "people/\(person.id.uuidString).json", in: stage.descriptor)
        }
        for person in plan.snapshot.payload.people {
            if let path = person.thumbnailPath, let bytes = plan.snapshot.files[path] {
                try KnownPeopleManagedStageFilesystem.writeFile(bytes,
                    path: "thumbnails/\(person.id.uuidString).jpg", in: stage.descriptor)
            }
            for example in person.examples where example.thumbnailPath != nil {
                guard let path = example.thumbnailPath, let bytes = plan.snapshot.files[path] else {
                    throw KnownPeopleManagedStoreFailure.invalidSnapshot
                }
                try KnownPeopleManagedStageFilesystem.writeFile(bytes,
                    path: "embedding_thumbnails/\(example.id.uuidString).jpg", in: stage.descriptor)
            }
        }
        for (path, bytes) in plan.snapshot.files {
            try KnownPeopleManagedStageFilesystem.writeFile(bytes,
                path: ".admitted-package/\(path)", in: stage.descriptor)
        }
        let projectionHash = try KnownPeopleManagedProjection.hash(descriptor: stage.descriptor)
        let prior = plan.priorState?.importedRevisions ?? []
        let state = try KnownPeopleManagedStoreState(libraryID: plan.snapshot.manifest.libraryID,
            installationID: plan.priorState?.installationID ?? plan.initialInstallationID ?? UUID(),
            currentRevision: plan.snapshot.manifest.revision,
            currentCoreRevision: plan.snapshot.manifest.coreRevision,
            importedRevisions: prior + [plan.snapshot.manifest.revision],
            contract: plan.snapshot.manifest.contract, managedProjectionSHA256: projectionHash,
            admittedPackageSHA256: KnownPeopleManagedStoreState.admittedPackageHash(plan.snapshot.files))
        try KnownPeopleManagedStageFilesystem.writeFile(state.encoded(),
            path: KnownPeopleManagedStoreState.fileName, in: stage.descriptor)
        return state
    }

    private func verifyInstalled(root: URL, snapshot: KnownPeoplePackageSnapshot,
                                 expectedState: KnownPeopleManagedStoreState) throws {
        guard try readState(root: root) == expectedState,
              try KnownPeopleManagedProjection.hash(root: root) == expectedState.managedProjectionSHA256,
              try admittedPackageFiles(root: root) == snapshot.files else {
            throw KnownPeopleManagedStoreFailure.readbackFailed
        }
        let people = try readFiles(root: normalized(root).appendingPathComponent("people", isDirectory: true))
        guard people.count == snapshot.people.count else { throw KnownPeopleManagedStoreFailure.readbackFailed }
        for person in snapshot.people {
            let path = "\(person.id.uuidString).json"
            guard let bytes = people[path], try JSONDecoder().decode(KnownPerson.self, from: bytes).id == person.id else {
                throw KnownPeopleManagedStoreFailure.readbackFailed
            }
        }
    }

    private func verifyStaged(stage: KnownPeoplePackageHeldDirectory,
                              snapshot: KnownPeoplePackageSnapshot,
                              expectedState: KnownPeopleManagedStoreState) throws {
        let stateData = try KnownPeopleManagedProjection.readRegularFile(
            in: stage.descriptor, name: KnownPeopleManagedStoreState.fileName, maximum: 65_536)
        let state = try KnownPeopleManagedStoreState.decode(stateData)
        guard state == expectedState,
              try KnownPeopleManagedProjection.hash(descriptor: stage.descriptor) == state.managedProjectionSHA256 else {
            throw KnownPeopleManagedStoreFailure.readbackFailed
        }
        let raw = try KnownPeopleManagedProjection.openDirectory(
            in: stage.descriptor, name: state.admittedPackageDirectory)
        defer { close(raw) }
        let rawFiles = try KnownPeopleManagedProjection.readFiles(descriptor: raw)
        try validateAdmittedPackageFiles(rawFiles, state: state)
        guard rawFiles == snapshot.files else { throw KnownPeopleManagedStoreFailure.readbackFailed }

        let peopleDirectory = try KnownPeopleManagedProjection.openDirectory(in: stage.descriptor, name: "people")
        defer { close(peopleDirectory) }
        let people = try KnownPeopleManagedProjection.readFiles(descriptor: peopleDirectory)
        guard people.count == snapshot.people.count else { throw KnownPeopleManagedStoreFailure.readbackFailed }
        for person in snapshot.people {
            let path = "\(person.id.uuidString).json"
            guard let bytes = people[path], try JSONDecoder().decode(KnownPerson.self, from: bytes).id == person.id else {
                throw KnownPeopleManagedStoreFailure.readbackFailed
            }
        }
    }

    private func validateStaged(stage: KnownPeoplePackageHeldDirectory,
                                snapshot: KnownPeoplePackageSnapshot,
                                expectedState: KnownPeopleManagedStoreState) throws {
        do {
            try verifyStaged(stage: stage, snapshot: snapshot, expectedState: expectedState)
        } catch {
            throw KnownPeopleManagedStoreFailure.stagedValidationFailed
        }
    }

    private func readState(root: URL) throws -> KnownPeopleManagedStoreState? {
        let url = normalized(root).appendingPathComponent(KnownPeopleManagedStoreState.fileName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { throw KnownPeopleManagedStoreFailure.malformedState }
        return try KnownPeopleManagedStoreState.decode(
            KnownPeopleManagedProjection.readRegularFile(at: url, maximum: 65_536))
    }

    private func admit(_ snapshot: KnownPeoplePackageSnapshot) throws {
        do { try KnownPeoplePackageSnapshotValidation.validate(snapshot) }
        catch is CancellationError { throw CancellationError() }
        catch { throw KnownPeopleManagedStoreFailure.invalidSnapshot }
    }

    private func validateLocal(_ route: KnownPeopleManagedStoreRoute) throws {
        guard !route.iCloudSyncActive, !route.routingActive else {
            throw KnownPeopleManagedStoreFailure.activeICloudOrRouting
        }
        guard route.rootURL.isFileURL else { throw KnownPeopleManagedStoreFailure.invalidRoot }
    }

    private func inventoryToken(root: URL) throws -> KnownPeopleManagedStoreInventoryToken {
        let root = normalized(root)
        guard let identity = try KnownPeoplePackageWriterFilesystem.inspect(root) else {
            throw KnownPeopleManagedStoreFailure.invalidRoot
        }
        let files = try readFiles(root: root, includeDirectories: true, limits: .wholeManagedRoot)
        return inventoryToken(root: root, identity: identity, files: files)
    }

    private func inventoryToken(root: URL, descriptor: Int32) throws -> KnownPeopleManagedStoreInventoryToken {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw KnownPeopleManagedStoreFailure.invalidRoot
        }
        let identity = KnownPeoplePackageDirectoryIdentity(device: info.st_dev, inode: info.st_ino,
            modificationSeconds: info.st_mtimespec.tv_sec,
            modificationNanoseconds: info.st_mtimespec.tv_nsec,
            changeSeconds: info.st_ctimespec.tv_sec,
            changeNanoseconds: info.st_ctimespec.tv_nsec)
        let files = try KnownPeopleManagedProjection.readFiles(
            descriptor: descriptor, includeDirectories: true,
            limits: .wholeManagedRoot)
        return inventoryToken(root: normalized(root), identity: identity, files: files)
    }

    private func inventoryToken(root: URL, identity: KnownPeoplePackageDirectoryIdentity,
                                files: [String: Data]) -> KnownPeopleManagedStoreInventoryToken {
        return .init(rootURL: root, rootIdentity: identity,
                     inventorySHA256: KnownPeopleManagedStoreInventoryToken.hash(entries: files))
    }

    private func readFiles(root: URL, includeDirectories: Bool = false,
                           limits: KnownPeopleManagedEnumerationBudget = .projection) throws -> [String: Data] {
        try KnownPeopleManagedProjection.readFiles(root: root, includeDirectories: includeDirectories,
            limits: limits)
    }

    private func normalized(_ url: URL) -> URL { url.standardizedFileURL }

    /// URL directory hints are presentation metadata. Route identity uses the actual resolved
    /// filesystem path so equivalent `file:///root` and `file:///root/` values compare equal.
    private func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

nonisolated private final class KnownPeopleManagedStoreCommitFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCommitted: Bool { lock.withLock { value } }
    func markCommitted() { lock.withLock { value = true } }
}

/// Writes only beneath the held staging descriptor. Every intermediate component is opened
/// no-follow, each file is synchronized before close, and directory entries are synchronized
/// through the stage root before publication.
nonisolated private enum KnownPeopleManagedStageFilesystem {
    static func createDirectory(_ path: String, in root: Int32) throws {
        let components = try components(path)
        let descriptors = try openDirectories(components, in: root)
        defer { descriptors.reversed().forEach { close($0) } }
        for descriptor in descriptors.reversed() where fsync(descriptor) != 0 {
            throw KnownPeopleManagedStoreFailure.io
        }
        guard fsync(root) == 0 else { throw KnownPeopleManagedStoreFailure.io }
    }

    static func writeFile(_ data: Data, path: String, in root: Int32) throws {
        let parts = try components(path)
        guard let name = parts.last else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        let descriptors = try openDirectories(Array(parts.dropLast()), in: root)
        defer { descriptors.reversed().forEach { close($0) } }
        let parent = descriptors.last ?? root
        let file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard file >= 0 else { throw KnownPeopleManagedStoreFailure.io }
        defer { close(file) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw KnownPeopleManagedStoreFailure.io }
                offset += amount
            }
        }
        guard fsync(file) == 0 else { throw KnownPeopleManagedStoreFailure.io }
        for descriptor in descriptors.reversed() where fsync(descriptor) != 0 {
            throw KnownPeopleManagedStoreFailure.io
        }
        guard fsync(root) == 0 else { throw KnownPeopleManagedStoreFailure.io }
    }

    static func syncTree(_ descriptor: Int32) throws {
        let root = dup(descriptor)
        guard root >= 0 else { throw KnownPeopleManagedStoreFailure.io }
        defer { close(root) }
        try syncDirectory(root)
    }

    private static func components(_ path: String) throws -> [String] {
        let values = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, values.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        }) else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        return values
    }

    /// Returned descriptors are owned by the caller. The passed root is never returned.
    private static func openDirectories(_ components: [String], in root: Int32) throws -> [Int32] {
        var opened: [Int32] = []
        var parent = root
        do {
            for component in components {
                if mkdirat(parent, component, S_IRWXU) != 0, errno != EEXIST {
                    throw KnownPeopleManagedStoreFailure.io
                }
                let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                var info = stat()
                guard fstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    close(child)
                    throw KnownPeopleManagedStoreFailure.unsafeEntry
                }
                opened.append(child)
                parent = child
            }
            return opened
        } catch {
            opened.reversed().forEach { close($0) }
            throw error
        }
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw KnownPeopleManagedStoreFailure.io
        }
        defer { closedir(stream) }
        while let entry = try KnownPeopleManagedDirectoryReader.next { readdir(stream) } {
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(validatingCString: $0)
                }
            }) else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
            if name == "." || name == ".." { continue }
            guard !name.contains("/") && !name.contains("\0") else {
                throw KnownPeopleManagedStoreFailure.unsafeEntry
            }
            var expected = stat()
            guard fstatat(descriptor, name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw KnownPeopleManagedStoreFailure.io
            }
            switch expected.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, sameEntry(expected, opened) else {
                    throw KnownPeopleManagedStoreFailure.unsafeEntry
                }
                try syncDirectory(child)
            case S_IFREG:
                guard expected.st_nlink == 1 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard file >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                defer { close(file) }
                var opened = stat()
                guard fstat(file, &opened) == 0, sameEntry(expected, opened), fsync(file) == 0 else {
                    throw KnownPeopleManagedStoreFailure.unsafeEntry
                }
            default:
                throw KnownPeopleManagedStoreFailure.unsafeEntry
            }
        }
        guard fsync(descriptor) == 0 else { throw KnownPeopleManagedStoreFailure.io }
    }

    private static func sameEntry(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode && lhs.st_nlink == rhs.st_nlink
    }
}

/// Clears and checks `errno` around `readdir`, whose nil result means either EOF or failure.
/// The injected read operation keeps the otherwise rare error path deterministic in tests.
nonisolated enum KnownPeopleManagedDirectoryReader {
    static func next(_ readEntry: () -> UnsafeMutablePointer<dirent>?) throws
        -> UnsafeMutablePointer<dirent>? {
        errno = 0
        let entry = readEntry()
        guard entry != nil || errno == 0 else { throw KnownPeopleManagedStoreFailure.io }
        return entry
    }
}

nonisolated struct KnownPeopleManagedEnumerationBudget {
    static let projection = KnownPeopleManagedEnumerationBudget(
        maximumEntries: 200_100, maximumBytes: 600_000_000)
    static let wholeManagedRoot = KnownPeopleManagedEnumerationBudget(
        maximumEntries: 410_010, maximumBytes: 1_500_000_000)

    let maximumEntries: Int
    let maximumBytes: Int
    private(set) var entryCount = 0
    private(set) var byteCount = 0

    mutating func accountEntry(byteCount addedBytes: Int) throws {
        guard addedBytes >= 0, entryCount < maximumEntries,
              addedBytes <= maximumBytes - byteCount else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        entryCount += 1
        byteCount += addedBytes
    }
}

nonisolated private enum KnownPeopleManagedProjection {
    static func hash(root: URL) throws -> String {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        defer { close(descriptor) }
        return try hash(descriptor: descriptor)
    }

    static func hash(descriptor: Int32) throws -> String {
        var hasher = SHA256()
        for name in ["people", "thumbnails", "embedding_thumbnails"] {
            let directory = try openDirectory(in: descriptor, name: name)
            defer { close(directory) }
            let files = try readFiles(descriptor: directory, includeDirectories: true)
            hasher.update(data: Data((name + "/\0").utf8))
            for path in files.keys.sorted() {
                hasher.update(data: Data(path.utf8)); hasher.update(data: Data([0]))
                hasher.update(data: files[path]!); hasher.update(data: Data([0]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func readFiles(root: URL, includeDirectories: Bool = false,
                          limits: KnownPeopleManagedEnumerationBudget = .projection) throws -> [String: Data] {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        defer { close(descriptor) }
        return try readFiles(descriptor: descriptor, includeDirectories: includeDirectories, limits: limits)
    }

    static func readFiles(descriptor: Int32, includeDirectories: Bool = false,
                          limits: KnownPeopleManagedEnumerationBudget = .projection) throws -> [String: Data] {
        let held = dup(descriptor)
        guard held >= 0 else { throw KnownPeopleManagedStoreFailure.io }
        defer { close(held) }
        var result: [String: Data] = [:]
        var budget = limits
        try enumerate(held, prefix: "", includeDirectories: includeDirectories,
                      result: &result, budget: &budget)
        return result
    }

    static func openDirectory(in descriptor: Int32, name: String) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        var info = stat()
        guard fstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(child)
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        return child
    }

    static func readRegularFile(at url: URL, maximum: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        defer { close(descriptor) }
        return try readRegularFile(descriptor, maximum: maximum)
    }

    static func readRegularFile(in directory: Int32, name: String, maximum: Int) throws -> Data {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
        defer { close(descriptor) }
        return try readRegularFile(descriptor, maximum: maximum)
    }

    private static func enumerate(_ descriptor: Int32, prefix: String, includeDirectories: Bool,
                                  result: inout [String: Data],
                                  budget: inout KnownPeopleManagedEnumerationBudget) throws {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFDIR else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw KnownPeopleManagedStoreFailure.io
        }
        defer { closedir(stream) }
        rewinddir(stream)
        while let entry = try KnownPeopleManagedDirectoryReader.next({ readdir(stream) }) {
            guard let name = withUnsafePointer(to: &entry.pointee.d_name, { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(validatingCString: $0)
                }
            }) else {
                throw KnownPeopleManagedStoreFailure.unsafeEntry
            }
            if name == "." || name == ".." { continue }
            guard !name.contains("/") && !name.contains("\0") else {
                throw KnownPeopleManagedStoreFailure.unsafeEntry
            }
            let path = prefix + name
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw KnownPeopleManagedStoreFailure.io
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try budget.accountEntry(byteCount: 0)
                do {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard child >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                    defer { close(child) }
                    if includeDirectories { result[path + "/"] = Data("directory".utf8) }
                    try enumerate(child, prefix: path + "/", includeDirectories: includeDirectories,
                                  result: &result, budget: &budget)
                }
            case S_IFREG:
                guard info.st_nlink == 1, info.st_size >= 0,
                      info.st_size <= off_t(Int.max) else {
                    throw KnownPeopleManagedStoreFailure.unsafeEntry
                }
                let expectedBytes = Int(info.st_size)
                try budget.accountEntry(byteCount: expectedBytes)
                let data: Data
                do {
                    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard file >= 0 else { throw KnownPeopleManagedStoreFailure.unsafeEntry }
                    defer { close(file) }
                    data = try readRegularFile(file, maximum: expectedBytes)
                }
                result[path] = data
            default:
                throw KnownPeopleManagedStoreFailure.unsafeEntry
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, same(before, after) else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
    }

    private static func readRegularFile(_ descriptor: Int32, maximum: Int) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximum else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        var result = Data(count: Int(before.st_size))
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset),
                                         buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw KnownPeopleManagedStoreFailure.io }
                offset += amount
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, same(before, after) else {
            throw KnownPeopleManagedStoreFailure.unsafeEntry
        }
        return result
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

}
