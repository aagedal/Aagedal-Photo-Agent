import Foundation

struct TemplateStorageService: Sendable {
    private var directory: URL { AppPaths.templatesDirectory }

    func loadAll() throws -> [MetadataTemplate] {
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
        let data = try JSONEncoder().encode(template)
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try data.write(to: url, options: .atomic)
    }

    func delete(_ template: MetadataTemplate) throws {
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try FileManager.default.removeItem(at: url)
    }
}
