import Foundation
import os

nonisolated private let developTemplateStorageLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "DevelopTemplateStorageService"
)

/// Synchronous compatibility helpers. Production CRUD callers hold shared captured-root
/// admission through TemplateCRUDService for each complete shortcut/mutation transaction.
nonisolated struct DevelopTemplateStorageService: Sendable {
    private let directoryOverride: URL?
    private let trashAccess: TemplateTrashAccess

    init(directoryURL: URL? = nil, trashAccess: TemplateTrashAccess = .system) {
        directoryOverride = directoryURL
        self.trashAccess = trashAccess
    }

    func loadAll() throws -> [DevelopTemplate] {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let files = try CloudCoordinatedIO.contentsOfDirectory(at: directory)
            .filter { $0.pathExtension == "json" }

        return files.compactMap { url in
            do {
                let data = try CloudCoordinatedIO.readData(at: url)
                return try JSONDecoder().decode(DevelopTemplate.self, from: data)
            } catch {
                developTemplateStorageLog.warning(
                    "Skipping develop template at \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ template: DevelopTemplate) throws {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let data = try JSONEncoder().encode(template)
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try CloudCoordinatedIO.writeData(data, to: url)
    }

    func delete(_ template: DevelopTemplate) throws {
        let (directory, release) = resolvedDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try trashAccess.moveToTrash(at: url)
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
        return AppPaths.developTemplatesDirectory()
    }
}
