import Foundation

struct TemplateStorageService: Sendable {
    func loadAll() throws -> [MetadataTemplate] {
        let (directory, release) = AppPaths.templatesDirectory()
        defer { release() }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "json" }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MetadataTemplate.self, from: data)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ template: MetadataTemplate) throws {
        let (directory, release) = AppPaths.templatesDirectory()
        defer { release() }
        let data = try JSONEncoder().encode(template)
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try data.write(to: url, options: .atomic)
    }

    func delete(_ template: MetadataTemplate) throws {
        let (directory, release) = AppPaths.templatesDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try FileManager.default.removeItem(at: url)
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
}
