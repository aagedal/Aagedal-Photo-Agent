import Foundation
import os

nonisolated private let templateStorageLog = Logger(subsystem: "com.aagedal.photo-agent", category: "TemplateStorageService")

struct TemplateStorageService: Sendable {
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
                templateStorageLog.warning("Skipping template at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
