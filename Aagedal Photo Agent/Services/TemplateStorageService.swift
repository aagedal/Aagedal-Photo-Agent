import Foundation
import os

nonisolated private let templateStorageLog = Logger(subsystem: "com.aagedal.photo-agent", category: "TemplateStorageService")

nonisolated struct TemplateStorageService: Sendable {
    private let directoryOverride: URL?

    init(directoryURL: URL? = nil) {
        directoryOverride = directoryURL
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
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        if CloudCoordinatedIO.itemExists(at: url) {
            let existingData = try CloudCoordinatedIO.readData(at: url)
            try EditorialJSONSchema.requireWritableVersion(
                in: existingData,
                supportedVersion: MetadataTemplate.currentSchemaVersion,
                documentName: "metadata template",
                unversionedLegacyVersion: 1
            )
        }
        let data = try JSONEncoder().encode(template)
        try CloudCoordinatedIO.writeData(data, to: url)
    }

    func delete(_ template: MetadataTemplate) throws {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try CloudCoordinatedIO.removeItem(at: url)
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
        let existingIDs = Set(try loadAll().map(\.id))
        var newCount = 0
        var overwriteCount = 0
        for t in bundle.templates {
            if existingIDs.contains(t.id) { overwriteCount += 1 } else { newCount += 1 }
        }
        return TemplateImportPreview(
            source: source,
            bundle: bundle,
            newCount: newCount,
            overwriteCount: overwriteCount
        )
    }

    @discardableResult
    func importBundle(_ bundle: TemplateBundle, overwriteByID: Bool = true) throws -> TemplateImportResult {
        let existingIDs = Set(try loadAll().map(\.id))
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
            }
        }
        return TemplateImportResult(added: added, overwritten: overwritten)
    }

    private func resolvedDirectory() -> (url: URL, release: () -> Void) {
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

    static func storage(_ storage: TemplateStorageService) -> Self {
        Self(readPreview: { try storage.previewImport(from: $0) })
    }
}

/// Serializes template-bundle reads and the current-template inventory away from MainActor.
/// Foundation and coordinated filesystem calls cannot be preempted once entered, so cancellation
/// before and after the synchronous operation is returned as distinct immutable evidence.
actor TemplateImportPreviewService {
    private let access: TemplateImportPreviewAccess

    init(access: TemplateImportPreviewAccess) {
        self.access = access
    }

    init(storage: TemplateStorageService) {
        self.access = .storage(storage)
    }

    func preparePreview(
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

    static func storage(_ storage: TemplateStorageService) -> Self {
        Self(
            loadAll: { try storage.loadAll() },
            save: { try storage.save($0) }
        )
    }
}

/// Serializes accepted template imports and their inventory refresh away from MainActor.
/// Each coordinated save is a non-preemptible durable boundary. Cancellation before the first
/// save prevents mutation; cancellation after any save reports the exact durable partial commit.
actor TemplateImportCommitService {
    private let access: TemplateImportCommitAccess

    init(access: TemplateImportCommitAccess) {
        self.access = access
    }

    init(storage: TemplateStorageService) {
        self.access = .storage(storage)
    }

    func commit(
        _ bundle: TemplateBundle,
        sourceURL: URL,
        requestID: UUID
    ) throws -> TemplateImportCommitOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, sourceURL: sourceURL)
        }

        var refreshedTemplates = try access.loadAll()
        let existingIDs = Set(refreshedTemplates.map(\.id))
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
            do {
                try access.save(template)
            } catch {
                throw TemplateImportCommitError(
                    requestID: requestID,
                    sourceURL: sourceURL,
                    reason: error.localizedDescription,
                    addedCount: addedCount,
                    overwrittenCount: overwrittenCount,
                    committedTemplateIDs: committedTemplateIDs,
                    refreshedTemplates: refreshedTemplates
                )
            }
            committedTemplateIDs.append(template.id)
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
            refreshedTemplates = try access.loadAll()
            return .committed(TemplateImportCommit(
                requestID: requestID,
                sourceURL: sourceURL,
                addedCount: addedCount,
                overwrittenCount: overwrittenCount,
                committedTemplateIDs: committedTemplateIDs,
                refreshedTemplates: refreshedTemplates,
                inventoryRefreshFailureReason: nil,
                cancellationObservedAfterCommit: false
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
                cancellationObservedAfterCommit: false
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
            cancellationObservedAfterCommit: true
        ))
    }
}
