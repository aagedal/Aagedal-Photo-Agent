import Foundation
import os

nonisolated private let templateStorageLog = Logger(subsystem: "com.aagedal.photo-agent", category: "TemplateStorageService")

/// The accepted preview owns every JSON filename and byte, including malformed documents.
/// Absence is evidence too: a newly occupied UUID must not silently become an overwrite.
nonisolated struct TemplateImportAuthority: Equatable, Sendable {
    let directoryURL: URL
    let directoryIdentity: TemplateDirectoryIdentity
    var files: [String: Data]

    static func read(at directory: URL) throws -> Self {
        let directory = SafePathComponent.resolvingExistingSymlinks(in: directory)
        let identity = try TemplateDirectoryIdentity.read(at: directory)
        var files: [String: Data] = [:]
        for file in try CloudCoordinatedIO.contentsOfDirectory(at: directory)
            where file.pathExtension.lowercased() == "json" {
            files[file.lastPathComponent] = try CloudCoordinatedIO.readData(at: file)
        }
        guard try TemplateDirectoryIdentity.read(at: directory) == identity else {
            throw TemplateImportSnapshotConflict()
        }
        return Self(directoryURL: directory, directoryIdentity: identity, files: files)
    }

    var templates: [MetadataTemplate] {
        files.values.compactMap { try? JSONDecoder().decode(MetadataTemplate.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func validateTargets(_ bundle: TemplateBundle) throws {
        for template in bundle.templates {
            let canonicalName = "\(template.id.uuidString).json"
            let matchingFiles = files.filter { name, bytes in
                UUID(uuidString: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent) == template.id
                    || (try? JSONDecoder().decode(MetadataTemplate.self, from: bytes).id) == template.id
            }
            guard matchingFiles.isEmpty || (matchingFiles.count == 1
                && matchingFiles[canonicalName].flatMap {
                    try? JSONDecoder().decode(MetadataTemplate.self, from: $0).id
                } == template.id) else { throw TemplateImportSnapshotConflict() }
        }
    }
}

nonisolated struct TemplateImportSnapshotConflict: LocalizedError, Sendable {
    var errorDescription: String? {
        "The template folder changed or contains an ambiguous import target. Preview the bundle again before importing."
    }
}

/// Deletion keeps the original file recoverable in Finder's Trash, including fields that
/// a newer app may have written. Never fall back to permanent deletion if Trash fails.
nonisolated struct TemplateTrashAccess: Sendable {
    let moveItem: @Sendable (URL) throws -> Void

    static let system = Self(moveItem: { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    })

    func moveToTrash(at url: URL) throws {
        guard CloudCoordinatedIO.itemExists(at: url) else { return }
        // Materialize cloud placeholders before asking Finder to move the actual file.
        _ = try CloudCoordinatedIO.readData(at: url)
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                // A peer may already have removed the item while coordination was pending.
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                try moveItem(coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
    }
}

/// Captures one security-scoped canonical root for the entire admitted operation.
/// Keeping the release alive prevents a settings change from rerouting an in-flight transaction.
nonisolated struct TemplateStorageScope<Access: Sendable>: Sendable {
    let access: Access
    let directoryURL: URL
    let release: @Sendable () -> Void
}

/// Synchronous compatibility helpers; production callers use the CRUD/import actors below.
/// Their captured-root admission owns complete transactions, including reads and inventory refresh.
nonisolated struct TemplateStorageService: Sendable {
    private let directoryOverride: URL?
    private let trashAccess: TemplateTrashAccess

    init(directoryURL: URL? = nil, trashAccess: TemplateTrashAccess = .system) {
        directoryOverride = directoryURL
        self.trashAccess = trashAccess
    }

    func loadAll() throws -> [MetadataTemplate] {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let files = try CloudCoordinatedIO.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension == "json" }

        return files.compactMap { url in
            do {
                let data = try CloudCoordinatedIO.readData(at: url)
                return try JSONDecoder().decode(MetadataTemplate.self, from: data)
            } catch {
                templateStorageLog.warning("Skipping template at \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ template: MetadataTemplate) throws {
        _ = try saveReturningBytes(template)
    }

    func saveReturningBytes(_ template: MetadataTemplate) throws -> Data {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        var data = try JSONEncoder().encode(template)
        if CloudCoordinatedIO.itemExists(at: url) {
            let existingData = try CloudCoordinatedIO.readData(at: url)
            try EditorialJSONSchema.requireWritableVersion(
                in: existingData,
                supportedVersion: MetadataTemplate.currentSchemaVersion,
                documentName: "metadata template",
                unversionedLegacyVersion: 1
            )
            let existing = try JSONDecoder().decode(MetadataTemplate.self, from: existingData)
            guard existing.id == template.id else {
                throw TemplateJSONPreservation.PreservationError.mismatchedIdentity
            }
            data = try TemplateJSONPreservation.metadata(replacement: data, existing: existingData)
        }
        try CloudCoordinatedIO.writeData(data, to: url)
        return data
    }

    func delete(_ template: MetadataTemplate) throws {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try trashAccess.moveToTrash(at: url)
    }

    // MARK: - Export / Import

    @discardableResult
    func exportAll(to destination: URL) throws -> Int {
        let templates = try loadAll()
        let bundle = TemplateBundle(templates: templates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        try data.write(to: destination, options: .atomic)
        return templates.count
    }

    func loadBundle(from source: URL) throws -> TemplateBundle {
        let data = try Data(contentsOf: source)
        try EditorialJSONSchema.requireWritableVersion(
            in: data,
            supportedVersion: TemplateBundle.currentSchemaVersion,
            documentName: "template bundle",
            legacyKey: "version",
            unversionedLegacyVersion: 1
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TemplateBundle.self, from: data)
    }

    func previewImport(from source: URL) throws -> TemplateImportPreview {
        let bundle = try loadBundle(from: source)
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let authority = try TemplateImportAuthority.read(at: directory)
        var existingIDs = Set(authority.templates.map(\.id))
        var newCount = 0
        var overwriteCount = 0
        for t in bundle.templates {
            if existingIDs.contains(t.id) { overwriteCount += 1 } else { newCount += 1 }
            existingIDs.insert(t.id)
        }
        return TemplateImportPreview(
            source: source,
            bundle: bundle,
            newCount: newCount,
            overwriteCount: overwriteCount,
            authority: authority
        )
    }

    @discardableResult
    func importBundle(_ bundle: TemplateBundle, overwriteByID: Bool = true) throws -> TemplateImportResult {
        var existingIDs = Set(try loadAll().map(\.id))
        var added = 0
        var overwritten = 0
        for template in bundle.templates {
            if existingIDs.contains(template.id) {
                if overwriteByID {
                    try save(template)
                    overwritten += 1
                }
            } else {
                try save(template)
                added += 1
                existingIDs.insert(template.id)
            }
        }
        return TemplateImportResult(added: added, overwritten: overwritten)
    }

    func resolvedForTransaction() -> TemplateStorageScope<Self> {
        let (directory, release) = resolvedDirectory()
        let canonical = SafePathComponent.resolvingExistingSymlinks(in: directory)
        return TemplateStorageScope(
            access: Self(directoryURL: canonical, trashAccess: trashAccess),
            directoryURL: canonical,
            release: release
        )
    }

    private func resolvedDirectory() -> (url: URL, release: @Sendable () -> Void) {
        if let directoryOverride {
            return (directoryOverride, {})
        }
        return AppPaths.templatesDirectory()
    }
}

nonisolated struct TemplateImportPreviewCompletion: Sendable {
    let requestID: UUID
    let sourceURL: URL
    let preview: TemplateImportPreview
    let inspectedBundleTemplateCount: Int
}

nonisolated enum TemplateImportPreviewOperationResult: Sendable {
    case prepared(TemplateImportPreviewCompletion)
    case cancelledBeforeRead(requestID: UUID, sourceURL: URL)
    case cancelledAfterRead(
        requestID: UUID,
        sourceURL: URL,
        inspectedBundleTemplateCount: Int,
        newCount: Int,
        overwriteCount: Int
    )
}

nonisolated struct TemplateImportPreviewAccess: Sendable {
    let readPreview: @Sendable (URL) throws -> TemplateImportPreview

    var prepareTransaction: (@Sendable () -> TemplateStorageScope<Self>)? = nil

    static func storage(_ storage: TemplateStorageService, prepareTransaction: Bool = true) -> Self {
        var access = Self(readPreview: { try storage.previewImport(from: $0) })
        if prepareTransaction {
            access.prepareTransaction = {
                let scope = storage.resolvedForTransaction()
                return TemplateStorageScope(
                    access: .storage(scope.access, prepareTransaction: false),
                    directoryURL: scope.directoryURL, release: scope.release
                )
            }
        }
        return access
    }
}

/// Serializes template-bundle reads and the current-template inventory away from MainActor.
/// Foundation and coordinated filesystem calls cannot be preempted once entered, so cancellation
/// before and after the synchronous operation is returned as distinct immutable evidence.
actor TemplateImportPreviewService {
    private let access: TemplateImportPreviewAccess
    // Retain a dedicated worker for blocking provider calls while preserving task context.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    init(access: TemplateImportPreviewAccess,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.templates.import-preview", qos: .utility
         )) {
        self.access = access
        self.filesystemQueue = filesystemQueue
    }

    init(storage: TemplateStorageService,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.templates.import-preview", qos: .utility
         )) {
        self.access = .storage(storage)
        self.filesystemQueue = filesystemQueue
    }

    func preparePreview(from sourceURL: URL, requestID: UUID) async throws -> TemplateImportPreviewOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }
        guard let prepare = access.prepareTransaction else {
            return try preparePreviewInTransaction(from: sourceURL, requestID: requestID)
        }
        let scope = prepare()
        defer { scope.release() }
        let worker = TemplateImportPreviewService(access: scope.access, filesystemQueue: filesystemQueue)
        return try await StorageTransactionAdmission.shared.withAccess(to: [scope.directoryURL]) {
            let reservation = Task.isCancelled ? nil : try MCPProcessReservation.acquireFolder(scope.directoryURL)
            defer { reservation?.release() }
            return try await worker.preparePreviewInTransaction(from: sourceURL, requestID: requestID)
        }
    }

    private func preparePreviewInTransaction(
        from sourceURL: URL,
        requestID: UUID
    ) throws -> TemplateImportPreviewOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, sourceURL: sourceURL)
        }

        let preview = try access.readPreview(sourceURL)
        let inspectedCount = preview.bundle.templates.count
        guard !Task.isCancelled else {
            return .cancelledAfterRead(
                requestID: requestID,
                sourceURL: sourceURL,
                inspectedBundleTemplateCount: inspectedCount,
                newCount: preview.newCount,
                overwriteCount: preview.overwriteCount
            )
        }

        return .prepared(TemplateImportPreviewCompletion(
            requestID: requestID,
            sourceURL: sourceURL,
            preview: preview,
            inspectedBundleTemplateCount: inspectedCount
        ))
    }
}

nonisolated struct TemplateImportCommit: Sendable {
    let requestID: UUID
    let sourceURL: URL
    let addedCount: Int
    let overwrittenCount: Int
    let committedTemplateIDs: [UUID]
    let refreshedTemplates: [MetadataTemplate]
    let inventoryRefreshFailureReason: String?
    let cancellationObservedAfterCommit: Bool
    var directoryURL: URL? = nil
    var authorities: [UUID: TemplateFileAuthority] = [:]
    var inventoryWasRead: Bool = false
}

nonisolated enum TemplateImportCommitOperationResult: Sendable {
    case committed(TemplateImportCommit)
    case cancelledBeforeCommit(requestID: UUID, sourceURL: URL)
}

nonisolated struct TemplateImportCommitError: LocalizedError, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let reason: String
    let addedCount: Int
    let overwrittenCount: Int
    let committedTemplateIDs: [UUID]
    let refreshedTemplates: [MetadataTemplate]
    var directoryURL: URL? = nil
    var authorities: [UUID: TemplateFileAuthority] = [:]
    var inventoryWasRead: Bool = false

    var errorDescription: String? {
        let committedCount = committedTemplateIDs.count
        guard committedCount > 0 else { return reason }
        let noun = committedCount == 1 ? "template was" : "templates were"
        return "\(reason) \(committedCount) \(noun) already imported."
    }
}

nonisolated struct TemplateImportCommitAccess: Sendable {
    let loadAll: @Sendable () throws -> [MetadataTemplate]
    let save: @Sendable (MetadataTemplate) throws -> Void

    var saveReturningBytes: (@Sendable (MetadataTemplate) throws -> Data)? = nil
    var readInventory: (@Sendable () throws -> TemplateFileInventory<MetadataTemplate>)? = nil
    var prepareTransaction: (@Sendable () -> TemplateStorageScope<Self>)? = nil

    static func storage(_ storage: TemplateStorageService, prepareTransaction: Bool = true) -> Self {
        var access = Self(
            loadAll: { try storage.loadAll() },
            save: { try storage.save($0) }
        )
        access.saveReturningBytes = { try storage.saveReturningBytes($0) }
        if prepareTransaction {
            access.prepareTransaction = {
                let scope = storage.resolvedForTransaction()
                var bound = Self.storage(scope.access, prepareTransaction: false)
                bound.readInventory = {
                    try TemplateFileInventory.read(at: scope.directoryURL, sorted: {
                        $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    })
                }
                return TemplateStorageScope(
                    access: bound,
                    directoryURL: scope.directoryURL, release: scope.release
                )
            }
        }
        return access
    }
}

/// Serializes accepted template imports and their inventory refresh away from MainActor.
/// Each coordinated save is a non-preemptible durable boundary. Cancellation before the first
/// save prevents mutation; cancellation after any save reports the exact durable partial commit.
actor TemplateImportCommitService {
    private let access: TemplateImportCommitAccess
    private let transactionDirectoryURL: URL?
    // Retain a dedicated worker for blocking provider calls while preserving task context.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    init(access: TemplateImportCommitAccess,
         transactionDirectoryURL: URL? = nil,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.templates.import-commit", qos: .utility
         )) {
        self.access = access
        self.transactionDirectoryURL = transactionDirectoryURL
        self.filesystemQueue = filesystemQueue
    }

    init(storage: TemplateStorageService,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.templates.import-commit", qos: .utility
         )) {
        self.access = .storage(storage)
        self.transactionDirectoryURL = nil
        self.filesystemQueue = filesystemQueue
    }

    func commit(_ preview: TemplateImportPreview, requestID: UUID) async throws -> TemplateImportCommitOperationResult {
        // Injected in-memory access has no filesystem root. Production previews must carry evidence.
        guard preview.authority != nil || access.prepareTransaction == nil else {
            throw TemplateImportSnapshotConflict()
        }
        return try await commit(preview.bundle, sourceURL: preview.source, requestID: requestID,
                                expectedAuthority: preview.authority)
    }

    func commit(_ bundle: TemplateBundle, sourceURL: URL, requestID: UUID,
                expectedAuthority: TemplateImportAuthority? = nil) async throws -> TemplateImportCommitOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, sourceURL: sourceURL)
        }
        guard let prepare = access.prepareTransaction else {
            return try commitInTransaction(bundle, sourceURL: sourceURL, requestID: requestID, expectedAuthority: expectedAuthority)
        }
        let scope = prepare()
        defer { scope.release() }
        let worker = TemplateImportCommitService(access: scope.access, transactionDirectoryURL: scope.directoryURL, filesystemQueue: filesystemQueue)
        return try await StorageTransactionAdmission.shared.withAccess(to: [scope.directoryURL]) {
            let reservation = Task.isCancelled ? nil : try MCPProcessReservation.acquireFolder(scope.directoryURL)
            defer { reservation?.release() }
            return try await worker.commitInTransaction(bundle, sourceURL: sourceURL, requestID: requestID, expectedAuthority: expectedAuthority)
        }
    }

    private func commitInTransaction(
        _ bundle: TemplateBundle,
        sourceURL: URL,
        requestID: UUID,
        expectedAuthority: TemplateImportAuthority?
    ) throws -> TemplateImportCommitOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, sourceURL: sourceURL)
        }

        var expectedAuthority = expectedAuthority
        if let expected = expectedAuthority {
            guard access.saveReturningBytes != nil,
                  transactionDirectoryURL == expected.directoryURL,
                  try TemplateImportAuthority.read(at: expected.directoryURL) == expected else {
                throw TemplateImportSnapshotConflict()
            }
            try expected.validateTargets(bundle)
        }
        var refreshedTemplates = try access.loadAll()
        var existingIDs = Set(refreshedTemplates.map(\.id))
        var addedCount = 0
        var overwrittenCount = 0
        var committedTemplateIDs: [UUID] = []

        for template in bundle.templates {
            guard !Task.isCancelled else {
                return cancellationResult(
                    requestID: requestID,
                    sourceURL: sourceURL,
                    addedCount: addedCount,
                    overwrittenCount: overwrittenCount,
                    committedTemplateIDs: committedTemplateIDs,
                    refreshedTemplates: refreshedTemplates
                )
            }

            let isOverwrite = existingIDs.contains(template.id)
            let writtenBytes: Data?
            do {
                if let expected = expectedAuthority {
                    guard try TemplateImportAuthority.read(at: expected.directoryURL) == expected else {
                        throw TemplateImportSnapshotConflict()
                    }
                }
                if let save = access.saveReturningBytes {
                    writtenBytes = try save(template)
                } else {
                    try access.save(template)
                    writtenBytes = nil
                }
            } catch {
                throw TemplateImportCommitError(
                    requestID: requestID,
                    sourceURL: sourceURL,
                    reason: error.localizedDescription,
                    addedCount: addedCount,
                    overwrittenCount: overwrittenCount,
                    committedTemplateIDs: committedTemplateIDs,
                    refreshedTemplates: refreshedTemplates,
                    directoryURL: transactionDirectoryURL
                )
            }
            committedTemplateIDs.append(template.id)
            existingIDs.insert(template.id)
            if let index = refreshedTemplates.firstIndex(where: { $0.id == template.id }) {
                refreshedTemplates[index] = template
            } else {
                refreshedTemplates.append(template)
            }
            refreshedTemplates.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if isOverwrite {
                overwrittenCount += 1
            } else {
                addedCount += 1
            }
            guard !Task.isCancelled else {
                return cancellationResult(
                    requestID: requestID, sourceURL: sourceURL,
                    addedCount: addedCount, overwrittenCount: overwrittenCount,
                    committedTemplateIDs: committedTemplateIDs, refreshedTemplates: refreshedTemplates
                )
            }
            if expectedAuthority != nil, let writtenBytes {
                // Advance only to bytes emitted by our save. A later read must never
                // bless a peer's replacement as authority for a repeated UUID.
                expectedAuthority?.files["\(template.id.uuidString).json"] = writtenBytes
            }
        }

        guard !Task.isCancelled else {
            return cancellationResult(
                requestID: requestID,
                sourceURL: sourceURL,
                addedCount: addedCount,
                overwrittenCount: overwrittenCount,
                committedTemplateIDs: committedTemplateIDs,
                refreshedTemplates: refreshedTemplates
            )
        }

        do {
            let inventory: TemplateFileInventory<MetadataTemplate>
            if let read = access.readInventory {
                inventory = try read()
            } else {
                inventory = TemplateFileInventory(templates: try access.loadAll(), authorities: [:])
            }
            refreshedTemplates = inventory.templates
            return .committed(TemplateImportCommit(
                requestID: requestID,
                sourceURL: sourceURL,
                addedCount: addedCount,
                overwrittenCount: overwrittenCount,
                committedTemplateIDs: committedTemplateIDs,
                refreshedTemplates: refreshedTemplates,
                inventoryRefreshFailureReason: nil,
                cancellationObservedAfterCommit: false,
                directoryURL: transactionDirectoryURL,
                authorities: inventory.authorities, inventoryWasRead: true
            ))
        } catch {
            return .committed(TemplateImportCommit(
                requestID: requestID,
                sourceURL: sourceURL,
                addedCount: addedCount,
                overwrittenCount: overwrittenCount,
                committedTemplateIDs: committedTemplateIDs,
                refreshedTemplates: refreshedTemplates,
                inventoryRefreshFailureReason: error.localizedDescription,
                cancellationObservedAfterCommit: false,
                directoryURL: transactionDirectoryURL
            ))
        }
    }

    private func cancellationResult(
        requestID: UUID,
        sourceURL: URL,
        addedCount: Int,
        overwrittenCount: Int,
        committedTemplateIDs: [UUID],
        refreshedTemplates: [MetadataTemplate]
    ) -> TemplateImportCommitOperationResult {
        guard addedCount > 0 || overwrittenCount > 0 else {
            return .cancelledBeforeCommit(requestID: requestID, sourceURL: sourceURL)
        }
        return .committed(TemplateImportCommit(
            requestID: requestID,
            sourceURL: sourceURL,
            addedCount: addedCount,
            overwrittenCount: overwrittenCount,
            committedTemplateIDs: committedTemplateIDs,
            refreshedTemplates: refreshedTemplates,
            inventoryRefreshFailureReason: nil,
            cancellationObservedAfterCommit: true,
            directoryURL: transactionDirectoryURL
        ))
    }
}
