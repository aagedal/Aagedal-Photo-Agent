import CryptoKit
import Foundation

/// Stable, deliberately non-diagnostic registry failures. Paths, filenames, plan fingerprints,
/// profiles, and editorial values are never interpolated into errors that may reach a log or UI.
nonisolated enum DeliveryWorkflowRegistryError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot
    case workflowAlreadyExists
    case workflowNotFound
    case unsafeStoredPath
    case incompleteWorkflow
    case invalidStoredPlan
    case invalidStoredManifest
    case invalidStagingEvidence
    case retainedStagingUnavailable
    case duplicateWorkflowIdentity
    case newerSchema
    case persistenceFailed
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "The private delivery-workflow store is unavailable."
        case .workflowAlreadyExists: "A delivery workflow with that identity already exists."
        case .workflowNotFound: "The delivery workflow was not found."
        case .unsafeStoredPath: "The delivery workflow contains an unsafe stored path."
        case .incompleteWorkflow: "The delivery workflow is only partially stored."
        case .invalidStoredPlan: "The stored frozen delivery plan is invalid."
        case .invalidStoredManifest: "The stored delivery workflow state is invalid."
        case .invalidStagingEvidence: "The stored delivery staging evidence is invalid."
        case .retainedStagingUnavailable: "Verified retained staging bytes are unavailable."
        case .duplicateWorkflowIdentity: "The delivery store contains a duplicate workflow identity."
        case .newerSchema: "A delivery workflow was created by a newer app version."
        case .persistenceFailed: "The private delivery workflow could not be stored safely."
        case .cleanupFailed: "The delivery workflow could not be removed safely."
        }
    }
}

/// Public discovery is intentionally limited to identity plus state/count facts. In particular it
/// cannot represent source paths, output names, hashes, destination details, or editorial values.
nonisolated struct DeliveryWorkflowRegistrySummary: Codable, Equatable, Sendable {
    let workflowIdentifier: UUID
    let stage: DeliveryWorkflowStage
    let completedItemCount: Int
    let itemCount: Int
    let hasRetainedStaging: Bool
    let failureCode: DeliveryWorkflowFailureCode?
}

nonisolated struct DeliveryWorkflowRegistryCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let workflowCount: Int
    let workflows: [DeliveryWorkflowRegistrySummary]

    init(workflows: [DeliveryWorkflowRegistrySummary]) {
        schemaVersion = Self.currentSchemaVersion
        workflowCount = workflows.count
        self.workflows = workflows
    }
}

/// Every URL is derived from a canonical lower-case UUID component below the registry root.
nonisolated struct DeliveryWorkflowRegistryLocations: Equatable, Sendable {
    let workflowRootURL: URL
    let planDocumentURL: URL
    let manifestDocumentURL: URL
    let stagingEvidenceDocumentURL: URL
    let stagingRootURL: URL

    var manifestPersistence: DeliveryWorkflowManifestPersistence {
        Self.secureManifestPersistence(documentURL: manifestDocumentURL)
    }

    var stagingEvidencePersistence: DeliveryWorkflowStagingEvidencePersistence {
        Self.secureStagingEvidencePersistence(documentURL: stagingEvidenceDocumentURL)
    }

    private static func secureManifestPersistence(
        documentURL: URL
    ) -> DeliveryWorkflowManifestPersistence {
        let persistence = DeliveryWorkflowManifestPersistence.atomic(documentURL: documentURL)
        return DeliveryWorkflowManifestPersistence(
            load: persistence.load,
            save: { manifest in
                try await persistence.save(manifest)
                try DeliveryWorkflowRegistry.secureDocumentAndBackup(at: documentURL)
            }
        )
    }

    private static func secureStagingEvidencePersistence(
        documentURL: URL
    ) -> DeliveryWorkflowStagingEvidencePersistence {
        let persistence = DeliveryWorkflowStagingEvidencePersistence.atomic(documentURL: documentURL)
        return DeliveryWorkflowStagingEvidencePersistence(
            load: persistence.load,
            save: { evidence in
                try await persistence.save(evidence)
                try DeliveryWorkflowRegistry.secureDocumentAndBackup(at: documentURL)
            }
        )
    }
}

/// Exact private state needed to rebuild a coordinator request after relaunch. This value must not
/// be encoded for Activity, analytics, logs, or synchronization because `plan` contains resolved
/// editorial metadata and source paths.
nonisolated struct DeliveryWorkflowResumeRecord: Sendable {
    let workflowIdentifier: UUID
    let plan: DeliveryPlan
    let currentProfile: DeadlineProfile
    let stagingRootURL: URL
    let stagingResult: DeliveryStagingBatchResult
    let remoteStatPolicy: DeliveryRemoteStatPolicy
    let locations: DeliveryWorkflowRegistryLocations

    var request: DeliveryWorkflowRequest {
        DeliveryWorkflowRequest(
            workflowIdentifier: workflowIdentifier,
            plan: plan,
            currentProfile: currentProfile,
            stagingRootURL: stagingRootURL,
            remoteStatPolicy: remoteStatPolicy
        )
    }
}

/// Age-based removal applies only to terminal workflows. A `nil` duration explicitly means keep
/// that terminal class until a manual cleanup request.
nonisolated struct DeliveryWorkflowRetentionPolicy: Equatable, Sendable {
    let sentLifetime: TimeInterval?
    let failedOrCancelledLifetime: TimeInterval?

    static let manualOnly = Self(sentLifetime: nil, failedOrCancelledLifetime: nil)

    init(sentLifetime: TimeInterval?, failedOrCancelledLifetime: TimeInterval?) {
        self.sentLifetime = sentLifetime.map { max(0, $0) }
        self.failedOrCancelledLifetime = failedOrCancelledLifetime.map { max(0, $0) }
    }
}

nonisolated struct DeliveryWorkflowCleanupResult: Equatable, Sendable {
    let removedCount: Int
    let retainedCount: Int
}

/// Application-owned, backup-excluded persistence for frozen delivery workflows.
///
/// Each workflow is an independently recoverable unit:
/// `<root>/<lowercase UUID>/{plan.json,manifest.json,staging-evidence.json,staging/}`.
/// Workflow directory creation is the cross-process no-overwrite claim; document writes inside it
/// are atomic, and plan.json is immutable for the lifetime of the directory.
actor DeliveryWorkflowRegistry {
    private static let planFilename = "plan.json"
    private static let manifestFilename = "manifest.json"
    private static let evidenceFilename = "staging-evidence.json"
    private static let stagingDirectoryName = "staging"

    private let configuredRootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        configuredRootURL = rootURL
        self.fileManager = fileManager
    }

    /// Recommended non-ubiquitous location. The registry additionally excludes the root and every
    /// workflow directory from backup when it creates them.
    nonisolated static func applicationSupportRoot(
        applicationIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !applicationIdentifier.isEmpty,
              !applicationIdentifier.contains("/"),
              applicationIdentifier != ".",
              applicationIdentifier != ".." else {
            throw DeliveryWorkflowRegistryError.invalidRoot
        }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(applicationIdentifier, isDirectory: true)
        .appendingPathComponent("Delivery Workflows", isDirectory: true)
    }

    /// Claims a new workflow ID, stores the exact frozen plan without overwrite, and installs the
    /// initial atomic manifest. On success the returned locations can be injected directly into a
    /// `DeliveryWorkflowCoordinator`.
    func createWorkflow(
        plan: DeliveryPlan,
        workflowIdentifier: UUID = UUID(),
        remoteStatPolicy: DeliveryRemoteStatPolicy = .notRequested,
        createdAt: Date = Date()
    ) async throws -> DeliveryWorkflowRegistryLocations {
        do {
            try DeliveryPlanningService.validateFrozenPlan(plan)
        } catch {
            throw DeliveryWorkflowRegistryError.invalidStoredPlan
        }

        let root = try prepareRoot()
        let locations = Self.locations(root: root, identifier: workflowIdentifier)
        guard !fileManager.fileExists(atPath: locations.workflowRootURL.path) else {
            throw DeliveryWorkflowRegistryError.workflowAlreadyExists
        }

        do {
            // `withIntermediateDirectories: false` is the filesystem-level exclusive claim used
            // by concurrent registry actors and processes.
            try fileManager.createDirectory(
                at: locations.workflowRootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            if fileManager.fileExists(atPath: locations.workflowRootURL.path) {
                throw DeliveryWorkflowRegistryError.workflowAlreadyExists
            }
            throw DeliveryWorkflowRegistryError.persistenceFailed
        }

        do {
            try Self.excludeFromBackup(locations.workflowRootURL)
            try fileManager.createDirectory(
                at: locations.stagingRootURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try writeImmutablePlan(plan, to: locations.planDocumentURL)

            let manifest = DeliveryWorkflowManifest(
                workflowIdentifier: workflowIdentifier,
                planFingerprint: plan.fingerprint,
                profileIdentifier: plan.profile.id,
                itemCount: plan.items.count,
                startedAt: createdAt,
                remoteStatPolicy: remoteStatPolicy
            )
            try await locations.manifestPersistence.save(manifest)
            return locations
        } catch {
            // This actor exclusively created the exact UUID directory above, so rollback cannot
            // target pre-existing user state. A failed rollback remains discoverable as corrupt
            // partial state rather than being reused or overwritten.
            try? fileManager.removeItem(at: locations.workflowRootURL)
            if let registryError = error as? DeliveryWorkflowRegistryError {
                throw registryError
            }
            throw DeliveryWorkflowRegistryError.persistenceFailed
        }
    }

    func locations(for workflowIdentifier: UUID) throws -> DeliveryWorkflowRegistryLocations {
        let root = try prepareRoot()
        return Self.locations(root: root, identifier: workflowIdentifier)
    }

    /// Rebuilds an exact request only after validating every cross-document identity and hashing
    /// every retained staged file. Missing or substituted staging bytes can never reach resume.
    func resumeRecord(for workflowIdentifier: UUID) async throws -> DeliveryWorkflowResumeRecord {
        let stored = try await loadStoredWorkflow(identifier: workflowIdentifier)
        guard let stagingResult = stored.stagingResult else {
            throw DeliveryWorkflowRegistryError.retainedStagingUnavailable
        }
        return DeliveryWorkflowResumeRecord(
            workflowIdentifier: workflowIdentifier,
            plan: stored.plan,
            currentProfile: stored.plan.profile,
            stagingRootURL: stored.locations.stagingRootURL,
            stagingResult: stagingResult,
            remoteStatPolicy: stored.manifest.remoteStatPolicy,
            locations: stored.locations
        )
    }

    /// Fails the complete discovery operation if any visible workflow is unsafe, duplicated, or
    /// only partially valid. Callers never receive a misleading partial catalog.
    func catalog() async throws -> DeliveryWorkflowRegistryCatalog {
        let root = try prepareRoot()
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw DeliveryWorkflowRegistryError.invalidRoot
        }

        var seen = Set<UUID>()
        var summaries: [DeliveryWorkflowRegistrySummary] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Finder metadata does not represent a workflow. All other unexpected root entries
            // fail closed, including abandoned attacker-chosen aliases.
            if entry.lastPathComponent == ".DS_Store" { continue }
            guard let identifier = Self.canonicalIdentifier(for: entry.lastPathComponent) else {
                throw DeliveryWorkflowRegistryError.unsafeStoredPath
            }
            guard seen.insert(identifier).inserted else {
                throw DeliveryWorkflowRegistryError.duplicateWorkflowIdentity
            }
            let stored = try await loadStoredWorkflow(identifier: identifier)
            guard stored.locations.workflowRootURL.lastPathComponent == entry.lastPathComponent else {
                throw DeliveryWorkflowRegistryError.duplicateWorkflowIdentity
            }
            summaries.append(Self.summary(stored))
        }
        return DeliveryWorkflowRegistryCatalog(workflows: summaries)
    }

    /// Removes only expired terminal workflows. Active and non-terminal crash states are retained.
    func applyRetention(
        _ policy: DeliveryWorkflowRetentionPolicy,
        now: Date = Date()
    ) async throws -> DeliveryWorkflowCleanupResult {
        let catalog = try await catalog()
        var removed = 0
        for summary in catalog.workflows {
            let stored = try await loadStoredWorkflow(identifier: summary.workflowIdentifier)
            let lifetime: TimeInterval?
            switch stored.manifest.stage {
            case .sent:
                lifetime = policy.sentLifetime
            case .failed, .cancelled:
                lifetime = policy.failedOrCancelledLifetime
            default:
                lifetime = nil
            }
            guard let lifetime,
                  stored.manifest.updatedAt.addingTimeInterval(lifetime) <= now else {
                continue
            }
            try removeValidatedWorkflow(stored.locations)
            removed += 1
        }
        return DeliveryWorkflowCleanupResult(
            removedCount: removed,
            retainedCount: catalog.workflowCount - removed
        )
    }

    /// Explicit cleanup is allowed for any stage, but only for the exact canonical UUID directory.
    func removeWorkflow(_ workflowIdentifier: UUID) throws {
        let root = try prepareRoot()
        let locations = Self.locations(root: root, identifier: workflowIdentifier)
        guard fileManager.fileExists(atPath: locations.workflowRootURL.path) else {
            throw DeliveryWorkflowRegistryError.workflowNotFound
        }
        try removeValidatedWorkflow(locations)
    }

    // MARK: - Validation

    private struct StoredWorkflow {
        let locations: DeliveryWorkflowRegistryLocations
        let plan: DeliveryPlan
        let manifest: DeliveryWorkflowManifest
        let stagingResult: DeliveryStagingBatchResult?
    }

    private func loadStoredWorkflow(identifier: UUID) async throws -> StoredWorkflow {
        let root = try prepareRoot()
        let locations = Self.locations(root: root, identifier: identifier)
        try requireDirectory(locations.workflowRootURL, expectedParent: root)
        try requireDirectory(
            locations.stagingRootURL,
            expectedParent: locations.workflowRootURL
        )
        try requireRegularDocument(locations.planDocumentURL)

        let plan: DeliveryPlan
        do {
            plan = try DeliveryPlanIO().importPlan(from: locations.planDocumentURL)
        } catch let error as EditorialJSONSchemaError {
            if case .newerSchemaRequiresReadOnly = error {
                throw DeliveryWorkflowRegistryError.newerSchema
            }
            throw DeliveryWorkflowRegistryError.invalidStoredPlan
        } catch {
            throw DeliveryWorkflowRegistryError.invalidStoredPlan
        }

        let manifest: DeliveryWorkflowManifest
        do {
            guard let loaded = try await locations.manifestPersistence.load() else {
                throw DeliveryWorkflowRegistryError.incompleteWorkflow
            }
            manifest = loaded
            try manifest.validateForPersistence()
        } catch let error as AtomicJSONDocumentStoreError {
            if case .newerSchemaRequiresReadOnly = error {
                throw DeliveryWorkflowRegistryError.newerSchema
            }
            throw DeliveryWorkflowRegistryError.invalidStoredManifest
        } catch let error as DeliveryWorkflowRegistryError {
            throw error
        } catch {
            throw DeliveryWorkflowRegistryError.invalidStoredManifest
        }
        guard manifest.workflowIdentifier == identifier else {
            throw DeliveryWorkflowRegistryError.duplicateWorkflowIdentity
        }
        guard manifest.planFingerprint == plan.fingerprint,
              manifest.profileIdentifier == plan.profile.id,
              manifest.itemCount == plan.items.count else {
            throw DeliveryWorkflowRegistryError.invalidStoredManifest
        }

        let evidenceExists = try documentOrBackupExists(locations.stagingEvidenceDocumentURL)
        guard evidenceExists || manifest.stagingEvidence == nil else {
            throw DeliveryWorkflowRegistryError.retainedStagingUnavailable
        }
        guard evidenceExists else {
            return StoredWorkflow(
                locations: locations,
                plan: plan,
                manifest: manifest,
                stagingResult: nil
            )
        }

        let evidence: DeliveryWorkflowStagingEvidenceDocument
        do {
            guard let loaded = try await locations.stagingEvidencePersistence.load() else {
                throw DeliveryWorkflowRegistryError.invalidStagingEvidence
            }
            evidence = loaded
            try evidence.validateForPersistence()
        } catch let error as AtomicJSONDocumentStoreError {
            if case .newerSchemaRequiresReadOnly = error {
                throw DeliveryWorkflowRegistryError.newerSchema
            }
            throw DeliveryWorkflowRegistryError.invalidStagingEvidence
        } catch let error as DeliveryWorkflowRegistryError {
            throw error
        } catch {
            throw DeliveryWorkflowRegistryError.invalidStagingEvidence
        }

        guard evidence.workflowIdentifier == identifier,
              evidence.planFingerprint == plan.fingerprint else {
            throw DeliveryWorkflowRegistryError.invalidStagingEvidence
        }
        if let referenced = manifest.stagingEvidence {
            guard referenced.batchIdentifier == evidence.stagingResult.batchID,
                  referenced.verifiedItemCount == evidence.stagingResult.items.count,
                  referenced.evidenceFingerprint == (try Self.evidenceFingerprint(
                    plan: plan,
                    result: evidence.stagingResult
                  )) else {
                throw DeliveryWorkflowRegistryError.invalidStagingEvidence
            }
        } else {
            // The coordinator intentionally permits repair only in this pre-upload atomic window.
            guard [.staging, .writing, .verifying, .preservationVerifying]
                .contains(manifest.stage),
                  manifest.uploadCheckpoint == nil,
                  manifest.pendingReceiptIdentifier == nil else {
                throw DeliveryWorkflowRegistryError.invalidStagingEvidence
            }
        }
        try validateRetainedStaging(
            evidence.stagingResult,
            plan: plan,
            locations: locations
        )
        return StoredWorkflow(
            locations: locations,
            plan: plan,
            manifest: manifest,
            stagingResult: evidence.stagingResult
        )
    }

    private func validateRetainedStaging(
        _ result: DeliveryStagingBatchResult,
        plan: DeliveryPlan,
        locations: DeliveryWorkflowRegistryLocations
    ) throws {
        let expectedBatch = locations.stagingRootURL.appendingPathComponent(
            "deadline-\(result.batchID.uuidString.lowercased())",
            isDirectory: true
        )
        try requireDirectory(expectedBatch, expectedParent: locations.stagingRootURL)
        guard try Self.sameResolvedURL(result.stagingDirectoryURL, expectedBatch),
              try Self.sameResolvedURL(result.cleanupToken.stagingRootURL, locations.stagingRootURL),
              try Self.sameResolvedURL(result.cleanupToken.stagingDirectoryURL, expectedBatch),
              result.cleanupToken.batchID == result.batchID,
              result.cleanupToken.planFingerprint == plan.fingerprint,
              result.items.count == plan.items.count else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }

        for (index, item) in result.items.enumerated() {
            let planned = plan.items[index]
            guard item.itemIndex == index,
                  item.stageInputFingerprint == planned.stageInputFingerprint,
                  item.stagedRelativePath == planned.stagedRelativePath,
                  let byteCount = item.stagedByteCount,
                  let sha256 = item.stagedSHA256,
                  byteCount >= 0 else {
                throw DeliveryWorkflowRegistryError.invalidStagingEvidence
            }
            let fileURL = try safeDescendant(
                relativePath: item.stagedRelativePath,
                root: expectedBatch
            )
            try requireRegularDocument(fileURL)
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == byteCount,
                  try Self.sha256(of: fileURL) == sha256 else {
                throw DeliveryWorkflowRegistryError.retainedStagingUnavailable
            }
        }
        do {
            _ = try DeliveryVerifiedStagedBatch.validated(plan: plan, stagingResult: result)
        } catch {
            throw DeliveryWorkflowRegistryError.invalidStagingEvidence
        }
    }

    private func prepareRoot() throws -> URL {
        guard configuredRootURL.isFileURL,
              configuredRootURL.path.isEmpty == false else {
            throw DeliveryWorkflowRegistryError.invalidRoot
        }
        let standardized = configuredRootURL.standardizedFileURL
        do {
            if fileManager.fileExists(atPath: standardized.path) {
                let values = try standardized.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw DeliveryWorkflowRegistryError.invalidRoot
                }
            } else {
                try fileManager.createDirectory(
                    at: standardized,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: standardized.path
            )
            try Self.excludeFromBackup(standardized)
            return standardized.resolvingSymlinksInPath()
        } catch let error as DeliveryWorkflowRegistryError {
            throw error
        } catch {
            throw DeliveryWorkflowRegistryError.invalidRoot
        }
    }

    private nonisolated static func locations(
        root: URL,
        identifier: UUID
    ) -> DeliveryWorkflowRegistryLocations {
        let workflowRoot = root.appendingPathComponent(
            identifier.uuidString.lowercased(),
            isDirectory: true
        )
        return DeliveryWorkflowRegistryLocations(
            workflowRootURL: workflowRoot,
            planDocumentURL: workflowRoot.appendingPathComponent(planFilename),
            manifestDocumentURL: workflowRoot.appendingPathComponent(manifestFilename),
            stagingEvidenceDocumentURL: workflowRoot.appendingPathComponent(evidenceFilename),
            stagingRootURL: workflowRoot.appendingPathComponent(
                stagingDirectoryName,
                isDirectory: true
            )
        )
    }

    private func writeImmutablePlan(_ plan: DeliveryPlan, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw DeliveryWorkflowRegistryError.workflowAlreadyExists
        }
        let data = try DeliveryPlanIO().encode(plan)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".plan-staging-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DeliveryWorkflowRegistryError.persistenceFailed
        }
        try fileManager.moveItem(at: temporary, to: url)
        try Self.secureDocument(at: url)
    }

    private func requireDirectory(_ url: URL, expectedParent: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == expectedParent.standardizedFileURL,
              fileManager.fileExists(atPath: url.path) else {
            throw DeliveryWorkflowRegistryError.incompleteWorkflow
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try Self.sameResolvedURL(url.deletingLastPathComponent(), expectedParent) else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }
    }

    private func requireRegularDocument(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw DeliveryWorkflowRegistryError.incompleteWorkflow
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }
    }

    private func documentOrBackupExists(_ url: URL) throws -> Bool {
        for candidate in [url, url.appendingPathExtension("backup")] {
            if fileManager.fileExists(atPath: candidate.path) {
                try requireRegularDocument(candidate)
                return true
            }
        }
        return false
    }

    private func safeDescendant(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~") else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }
        var current = root
        for component in components.dropLast() {
            current.appendPathComponent(String(component), isDirectory: true)
            let values = try current.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DeliveryWorkflowRegistryError.unsafeStoredPath
            }
        }
        current.appendPathComponent(String(components.last!))
        guard current.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw DeliveryWorkflowRegistryError.unsafeStoredPath
        }
        return current
    }

    private func removeValidatedWorkflow(_ locations: DeliveryWorkflowRegistryLocations) throws {
        let root = locations.workflowRootURL.deletingLastPathComponent()
        do {
            try requireDirectory(locations.workflowRootURL, expectedParent: root)
            try fileManager.removeItem(at: locations.workflowRootURL)
        } catch let error as DeliveryWorkflowRegistryError {
            throw error
        } catch {
            throw DeliveryWorkflowRegistryError.cleanupFailed
        }
    }

    private nonisolated static func summary(
        _ stored: StoredWorkflow
    ) -> DeliveryWorkflowRegistrySummary {
        let completed: Int
        if stored.manifest.stage == .sent {
            completed = stored.manifest.itemCount
        } else {
            completed = stored.manifest.uploadCheckpoint?.items.count ?? 0
        }
        return DeliveryWorkflowRegistrySummary(
            workflowIdentifier: stored.manifest.workflowIdentifier,
            stage: stored.manifest.stage,
            completedItemCount: completed,
            itemCount: stored.manifest.itemCount,
            hasRetainedStaging: stored.stagingResult != nil,
            failureCode: stored.manifest.failureCode
        )
    }

    private nonisolated static func canonicalIdentifier(for component: String) -> UUID? {
        guard component == component.lowercased(),
              let identifier = UUID(uuidString: component),
              identifier.uuidString.lowercased() == component else {
            return nil
        }
        return identifier
    }

    private nonisolated static func sameResolvedURL(_ lhs: URL, _ rhs: URL) throws -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath()
            == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    private nonisolated static func evidenceFingerprint(
        plan: DeliveryPlan,
        result: DeliveryStagingBatchResult
    ) throws -> String {
        let payload = RegistryStagingFingerprintPayload(
            batchIdentifier: result.batchID,
            planFingerprint: result.planFingerprint,
            requiredBytes: result.requiredBytes,
            items: result.items.map {
                RegistryStagingItemFingerprintPayload(
                    itemIndex: $0.itemIndex,
                    stageInputFingerprint: $0.stageInputFingerprint,
                    stagedByteCount: $0.stagedByteCount,
                    stagedSHA256: $0.stagedSHA256,
                    renderSettings: $0.renderSettings,
                    metadataPreservation: $0.metadataPreservation,
                    checkedFields: $0.checkedFields
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate nonisolated static func secureDocumentAndBackup(at url: URL) throws {
        try secureDocument(at: url)
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            try secureDocument(at: backup)
        }
    }

    private nonisolated static func secureDocument(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        try excludeFromBackup(url)
    }

    private nonisolated static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

private nonisolated struct RegistryStagingFingerprintPayload: Codable, Sendable {
    let batchIdentifier: UUID
    let planFingerprint: String
    let requiredBytes: Int64
    let items: [RegistryStagingItemFingerprintPayload]
}

private nonisolated struct RegistryStagingItemFingerprintPayload: Codable, Sendable {
    let itemIndex: Int
    let stageInputFingerprint: String
    let stagedByteCount: Int?
    let stagedSHA256: String?
    let renderSettings: DeliveryRenderSettings?
    let metadataPreservation: MetadataPreservationVerificationReport?
    let checkedFields: [IPTCMetadataVerificationField]
}
