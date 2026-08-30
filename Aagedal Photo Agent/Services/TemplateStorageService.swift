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

    func exportAll(to destination: URL) throws {
        let templates = try loadAll()
        let bundle = TemplateBundle(templates: templates)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        try data.write(to: destination, options: .atomic)
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
