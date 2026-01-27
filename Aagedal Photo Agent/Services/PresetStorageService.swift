import Foundation

struct PresetStorageService: Sendable {
    private var directory: URL { AppPaths.presetsDirectory }

    func loadAll() throws -> [MetadataPreset] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ).filter { $0.pathExtension == "json" }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(MetadataPreset.self, from: data)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ preset: MetadataPreset) throws {
        let data = try JSONEncoder().encode(preset)
        let url = directory.appendingPathComponent("\(preset.id.uuidString).json")
        try data.write(to: url, options: .atomic)
    }

    func delete(_ preset: MetadataPreset) throws {
        let url = directory.appendingPathComponent("\(preset.id.uuidString).json")
        try FileManager.default.removeItem(at: url)
    }
}
