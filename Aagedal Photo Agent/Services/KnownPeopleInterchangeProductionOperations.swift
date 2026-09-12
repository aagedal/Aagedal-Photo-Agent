import Darwin
import Foundation

@MainActor
struct KnownPeopleInterchangeBundleExporterFactory {
    enum Failure: Error, Equatable, LocalizedError {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key): "The app bundle is missing required export metadata: \(key)."
            case .invalid(let key): "The app bundle contains invalid export metadata: \(key)."
            }
        }
    }

    private let bundle: Bundle

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func make() throws -> KnownPeoplePackageManifest.Exporter {
        let app = try requiredString("CFBundleDisplayName")
        let shortVersion = try requiredString("CFBundleShortVersionString")
        let build = try requiredString("CFBundleVersion")
        let sourceRevision = try requiredString("AagedalSourceRevision")
        guard sourceRevision.utf8.count == 40, sourceRevision.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }) else {
            throw Failure.invalid("AagedalSourceRevision")
        }
        let version = "\(shortVersion) (build \(build))"
        guard Self.isManifestText(version) else {
            throw Failure.invalid("CFBundleShortVersionString/CFBundleVersion")
        }
        return try .init(app: app, version: version, sourceRevision: sourceRevision)
    }

    private func requiredString(_ key: String) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            throw Failure.missing(key)
        }
        guard Self.isManifestText(value),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("$("), !value.contains("${") else {
            throw Failure.invalid(key)
        }
        return value
    }

    private static func isManifestText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 128
            && !value.contains("\0")
    }
}

@MainActor
struct KnownPeopleInterchangeSecurityScope {
    var start: (URL) -> Bool
    var stop: (URL) -> Void
    static var system: Self {
        .init(start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() })
    }
}

/// Injectable at operation boundaries; production closures only use schema-2 services.
@MainActor
struct KnownPeopleInterchangeOperationsAccess {
    var availability: () -> KnownPeopleInterchangeAvailability
    var scope: KnownPeopleInterchangeSecurityScope
    var admit: (URL) async -> KnownPeoplePackageAdmissionResult
    var planImport: (KnownPeopleManagedImportAdmission) async throws -> KnownPeopleManagedStoreReplacementPlan
    var commitImport: (KnownPeopleManagedStoreReplacementPlan) async -> KnownPeopleManagedStoreReplacementResult
    var prepareExport: () async -> KnownPeopleLocalInterchangePreparationResult
    var validateDestination: (URL, KnownPeopleInterchangeFormat, Bool) async throws -> Void
    var writeDirectory: (KnownPeoplePackageSnapshot, URL, Bool) async -> KnownPeoplePackageWriteResult
    var writeZIP: (KnownPeoplePackageSnapshot, URL, Bool) async throws -> KnownPeoplePackageArchiveResult
    var currentCounts: (KnownPeopleManagedStoreReplacementPlan) async -> KnownPeopleInterchangeCurrentCounts = { _ in .unknown }

    static func system(owner: KnownPeopleService, coordinator: ICloudSyncCoordinator,
                       exporter: @escaping () throws -> KnownPeoplePackageManifest.Exporter,
                       scope: KnownPeopleInterchangeSecurityScope) -> Self {
        .init(availability: {
            if coordinator.isKnownPeopleRouting { return .unavailable(.routing) }
            if coordinator.knownPeopleEnabled { return .unavailable(.iCloudEnabled) }
            return .available
        }, scope: scope, admit: { await KnownPeoplePackageAdmissionService().admit(at: $0) },
        planImport: { try await $0.planReplacement(owner: owner, routingActive: coordinator.isKnownPeopleRouting) },
        commitImport: { await owner.replaceManagedStore(plan: $0, decision: $0.requiredDecision,
                                                         routingActive: coordinator.isKnownPeopleRouting) },
        prepareExport: {
            do {
                let descriptor = try exporter()
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return await owner.prepareLocalInterchangeSnapshot(exportedAt: formatter.string(from: Date()),
                    exporter: descriptor, routingActive: coordinator.isKnownPeopleRouting)
            } catch {
                return .init(capture: nil, identityAssignment: nil,
                    failure: error is CancellationError ? nil : error.localizedDescription, wasCancelled: error is CancellationError)
            }
        }, validateDestination: { try await KnownPeopleInterchangeExportDestination().validate($0, format: $1, overwrite: $2) },
        writeDirectory: { snapshot, destination, overwrite in
            var access = KnownPeoplePackageWriteAccess()
            if !overwrite {
                access.install = { plan, committed in
                    guard plan.destinationIdentity == nil else { throw KnownPeoplePackageArchiveError.destinationExists }
                    try KnownPeoplePackageWriterFilesystem.install(plan, onCommitted: committed)
                }
            }
            return await KnownPeoplePackageDirectoryWriter(access: access).write(snapshot: snapshot, destinationURL: destination)
        }, writeZIP: { try await KnownPeoplePackageArchive().export(snapshot: $0, to: $1, overwrite: $2) },
        currentCounts: { await KnownPeopleInterchangeCurrentCountsReader().read(plan: $0) })
    }
}

@MainActor
final class KnownPeopleInterchangeProductionOperations: KnownPeopleInterchangeOperating {
    private let access: KnownPeopleInterchangeOperationsAccess
    private var plans: [KnownPeopleInterchangeImportToken: KnownPeopleManagedStoreReplacementPlan] = [:]
    var availability: KnownPeopleInterchangeAvailability { access.availability() }
    var retainedImportCount: Int { plans.count }

    init(exporter: @escaping () throws -> KnownPeoplePackageManifest.Exporter = {
            try KnownPeopleInterchangeBundleExporterFactory().make()
         },
         owner: KnownPeopleService = .shared, coordinator: ICloudSyncCoordinator = .shared,
         scope: KnownPeopleInterchangeSecurityScope = .system) {
        access = .system(owner: owner, coordinator: coordinator, exporter: exporter, scope: scope)
    }
    init(access: KnownPeopleInterchangeOperationsAccess) { self.access = access }

    func prepareImport(at sourceURL: URL) async -> KnownPeopleInterchangeImportPreparation {
        if let problem = unavailable() { return .failed(problem) }
        if Task.isCancelled { return .cancelled(.init(.cancelled)) }
        // Source access ends after all admission/extraction cleanup, before waiting on a
        // local-store plan and before any user confirmation can be presented.
        let admitted = await withScope(sourceURL) { await access.admit(sourceURL) }
        guard admitted.completed, let admission = admitted.admission else {
            let problem = KnownPeopleInterchangeProblem(admitted.wasCancelled ? .cancelled : .admissionFailed,
                detail: admitted.failure, recoveryURLs: admitted.recoveryDirectories)
            return admitted.wasCancelled ? .cancelled(problem) : .failed(problem)
        }
        do {
            try Task.checkCancellation()
            let plan = try await access.planImport(admission)
            let counts = await access.currentCounts(plan)
            try Task.checkCancellation()
            let token = KnownPeopleInterchangeImportToken()
            plans[token] = plan
            let relationship: KnownPeopleInterchangeImportPrompt.Relationship
            switch plan.requiredDecision {
            case .replaceSameLibrary: relationship = .sameLibrary
            case .replaceDifferentLibrary: relationship = .differentLibrary
            case .replaceUntracked: relationship = .untracked
            }
            return .ready(.init(token: token, sourceURL: admission.provenance.sourceURL,
                libraryID: plan.snapshot.manifest.libraryID, relationship: relationship,
                peopleCount: plan.snapshot.manifest.peopleCount, embeddingCount: plan.snapshot.manifest.embeddingCount,
                currentLibraryID: plan.priorState?.libraryID, currentPeopleCount: counts.people,
                currentEmbeddingCount: counts.embeddings, missingEditorMetadata: plan.snapshot.editor == nil))
        } catch {
            let problem = KnownPeopleInterchangeProblem(error is CancellationError ? .cancelled : .importPreparationFailed,
                                                       detail: error is CancellationError ? nil : error.localizedDescription)
            return error is CancellationError ? .cancelled(problem) : .failed(problem)
        }
    }

    func discardImport(_ token: KnownPeopleInterchangeImportToken) { plans.removeValue(forKey: token) }

    func commitImport(_ token: KnownPeopleInterchangeImportToken) async -> KnownPeopleInterchangeImportCommitOutcome {
        guard let plan = plans.removeValue(forKey: token) else { return .failed(.init(.invalidToken)) }
        if let problem = unavailable() { return .failed(problem) }
        if Task.isCancelled { return .cancelled(.init(.cancelled)) }
        let result = await access.commitImport(plan)
        if result.committed { return .committed(Self.evidence(result)) }
        let problem = KnownPeopleInterchangeProblem(result.wasCancelled ? .cancelled : .importCommitFailed,
            detail: result.failure, recoveryURLs: result.recoveryDirectory.map { [$0] } ?? [])
        return result.wasCancelled ? .cancelled(problem) : .failed(problem)
    }

    func export(to destinationURL: URL, format: KnownPeopleInterchangeFormat,
                overwrite: Bool) async -> KnownPeopleInterchangeExportOutcome {
        if let problem = unavailable() { return .failed(problem) }
        if Task.isCancelled { return .cancelled(.init(.cancelled)) }
        return await withScope(destinationURL) {
            do {
                // A concrete destination is validated before preparation can assign identity.
                try await access.validateDestination(destinationURL, format, overwrite)
                try Task.checkCancellation()
            } catch {
                if error is CancellationError { return .cancelled(.init(.cancelled)) }
                let category: KnownPeopleInterchangeProblem.Category =
                    error as? KnownPeopleInterchangeExportDestination.Failure == .exists ? .overwriteRequired : .invalidDestination
                return .failed(.init(category, detail: error.localizedDescription))
            }
            let prepared = await access.prepareExport()
            let identity = prepared.identityAssignment.map(Self.evidence)
            guard prepared.isReady, let captured = prepared.capture else {
                let problem = KnownPeopleInterchangeProblem(prepared.wasCancelled ? .cancelled : .exportPreparationFailed,
                    detail: prepared.failure, identityAssignment: identity)
                return prepared.wasCancelled ? .cancelled(problem) : .failed(problem)
            }
            if Task.isCancelled { return .cancelled(.init(.cancelled, identityAssignment: identity)) }
            do {
                if format == .zip, try await !KnownPeopleInterchangeZIPCapacity().fits(captured.snapshot.files) {
                    return .requiresDirectory(.init(.zipRequiresDirectory,
                        detail: "ZIP32 supports at most 65,534 entries and 512 MiB. Export this library as an .aagedalpeople directory package.",
                        identityAssignment: identity))
                }
                let write: KnownPeopleInterchangeCommitEvidence
                let actualDestination: URL
                switch format {
                case .directory:
                    let result = await access.writeDirectory(captured.snapshot, destinationURL, overwrite)
                    write = .init(committed: result.receipt != nil,
                        verified: result.receipt?.installedSnapshotVerified == true && result.receipt?.parentDirectorySynced == true,
                        wasCancelled: result.wasCancelled, detail: result.failure, recoveryURLs: result.recoveryDirectories)
                    actualDestination = result.receipt?.destinationURL ?? destinationURL
                case .zip:
                    let result = try await access.writeZIP(captured.snapshot, destinationURL, overwrite)
                    write = .init(committed: result.receipt != nil,
                        verified: result.receipt?.installedBytesVerified == true && result.receipt?.parentDirectorySynced == true,
                        wasCancelled: result.wasCancelled, detail: result.failure, recoveryURLs: result.recoveryURLs)
                    actualDestination = result.receipt?.destinationURL ?? destinationURL
                }
                if write.committed { return .written(.init(destinationURL: actualDestination, write: write, identityAssignment: identity)) }
                let problem = KnownPeopleInterchangeProblem(write.wasCancelled ? .cancelled : .exportWriteFailed,
                    detail: write.detail, recoveryURLs: write.recoveryURLs, identityAssignment: identity)
                return write.wasCancelled ? .cancelled(problem) : .failed(problem)
            } catch {
                let problem = KnownPeopleInterchangeProblem(error is CancellationError ? .cancelled : .exportWriteFailed,
                    detail: error is CancellationError ? nil : error.localizedDescription, identityAssignment: identity)
                return error is CancellationError ? .cancelled(problem) : .failed(problem)
            }
        }
    }

    private func unavailable() -> KnownPeopleInterchangeProblem? {
        if case .unavailable(let reason) = availability { return .init(.unavailable(reason)) }
        return nil
    }
    private func withScope<Value>(_ url: URL, body: () async -> Value) async -> Value {
        let started = access.scope.start(url)
        defer { if started { access.scope.stop(url) } }
        // False also occurs for ordinary non-scoped local URLs. Actual filesystem admission
        // determines access; a false start must never be balanced with a stop call.
        return await body()
    }
    private static func evidence(_ value: KnownPeopleManagedStoreReplacementResult) -> KnownPeopleInterchangeCommitEvidence {
        let verified = value.installedState != nil && value.failure == nil && !value.wasCancelled
        return .init(committed: value.committed, verified: verified,
              wasCancelled: value.wasCancelled, detail: value.failure,
              recoveryURLs: value.recoveryDirectory.map { [$0] } ?? [],
              recoveryMeaning: value.committed && verified ? .rollbackBackup : .unresolved)
    }
}

actor KnownPeopleInterchangeZIPCapacity {
    func fits(_ files: [String: Data]) throws -> Bool {
        try Task.checkCancellation()
        guard files.count <= KnownPeoplePackageArchiveCodec.maximumEntries else { return false }
        var bytes = 22
        let maximum = KnownPeoplePackageArchiveCodec.maximumArchiveBytes
        for (path, data) in files {
            try Task.checkCancellation()
            let nameBytes = path.utf8.count
            guard nameBytes <= (maximum - 76) / 2 else { return false }
            let overhead = 76 + nameBytes * 2
            guard overhead <= maximum - bytes else { return false }
            bytes += overhead
            guard data.count <= maximum - bytes else { return false }
            bytes += data.count
        }
        return true
    }
}

nonisolated struct KnownPeopleInterchangeCurrentCounts: Sendable {
    let people: Int?
    let embeddings: Int?
    static let unknown = Self(people: nil, embeddings: nil)
}

actor KnownPeopleInterchangeCurrentCountsReader {
    func read(plan: KnownPeopleManagedStoreReplacementPlan) async -> KnownPeopleInterchangeCurrentCounts {
        do {
            let builder = KnownPeopleLocalStoreSnapshotBuilder()
            let captured: KnownPeopleLocalStoreSnapshotCapture
            if plan.priorState == nil {
                captured = try await builder.captureUntracked(rootURL: plan.route.rootURL,
                    libraryID: plan.snapshot.manifest.libraryID, exportedAt: plan.snapshot.manifest.exportedAt,
                    exporter: plan.snapshot.manifest.exporter)
            } else {
                captured = try await builder.capture(rootURL: plan.route.rootURL,
                    exportedAt: plan.snapshot.manifest.exportedAt, exporter: plan.snapshot.manifest.exporter)
            }
            guard captured.managedInventorySHA256 == plan.inventory.inventorySHA256,
                  captured.inventory.device == plan.inventory.rootIdentity.device,
                  captured.inventory.inode == plan.inventory.rootIdentity.inode else { return .unknown }
            return .init(people: captured.snapshot.manifest.peopleCount, embeddings: captured.snapshot.manifest.embeddingCount)
        } catch { return .unknown }
    }
}

actor KnownPeopleInterchangeExportDestination {
    enum Failure: Error { case invalid, exists }
    func validate(_ url: URL, format: KnownPeopleInterchangeFormat, overwrite: Bool) throws {
        try Task.checkCancellation()
        let suffix = format == .directory ? ".aagedalpeople" : ".aagedalpeople.zip"
        guard url.isFileURL, url.lastPathComponent.hasSuffix(suffix), url.lastPathComponent.count > suffix.count,
              !url.path.contains("\0") else { throw Failure.invalid }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            let valid = format == .directory ? info.st_mode & S_IFMT == S_IFDIR
                : info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
            guard valid, try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile != true else { throw Failure.invalid }
            guard overwrite else { throw Failure.exists }
        } else if errno != ENOENT { throw Failure.invalid }
    }
}
