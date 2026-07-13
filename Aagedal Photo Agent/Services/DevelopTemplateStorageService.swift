import Foundation
import os

nonisolated private let developTemplateStorageLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "DevelopTemplateStorageService"
)

struct DevelopTemplateStorageService: Sendable {
    func loadAll() throws -> [DevelopTemplate] {
        let (directory, release) = AppPaths.developTemplatesDirectory()
        defer { release() }
        let files = try CloudCoordinatedIO.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension == "json" }

        return files.compactMap { url in
            do {
                let data = try CloudCoordinatedIO.readData(at: url)
                return try JSONDecoder().decode(DevelopTemplate.self, from: data)
            } catch {
                developTemplateStorageLog.warning(
                    "Skipping develop template at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ template: DevelopTemplate) throws {
        let (directory, release) = AppPaths.developTemplatesDirectory()
        defer { release() }
        let data = try JSONEncoder().encode(template)
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try CloudCoordinatedIO.writeData(data, to: url)
    }

    func delete(_ template: DevelopTemplate) throws {
        let (directory, release) = AppPaths.developTemplatesDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try CloudCoordinatedIO.removeItem(at: url)
    }
}
