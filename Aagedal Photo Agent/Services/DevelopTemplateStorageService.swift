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
    /// Set on a transaction scope captured while Templates sync is on but iCloud is unreachable:
    /// the scope reads the local fallback, but must never write to it.
    private let refusesWrites: Bool

    init(directoryURL: URL? = nil, trashAccess: TemplateTrashAccess = .system, refusesWrites: Bool = false) {
        directoryOverride = directoryURL
        self.trashAccess = trashAccess
        self.refusesWrites = refusesWrites
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
        let (directory, release) = try writableDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        var data = try JSONEncoder().encode(template)
        if CloudCoordinatedIO.itemExists(at: url) {
            // Preserve newer or unreadable documents, including members this
            // build cannot understand, rather than silently replacing them.
            let existingData = try CloudCoordinatedIO.readData(at: url)
            let existing = try JSONDecoder().decode(DevelopTemplate.self, from: existingData)
            guard existing.id == template.id else {
                throw TemplateJSONPreservation.PreservationError.mismatchedIdentity
            }
            data = try TemplateJSONPreservation.develop(
                replacement: data, existing: existingData,
                decodedExisting: JSONEncoder().encode(existing)
            )
        }
        try CloudCoordinatedIO.writeData(data, to: url)
    }

    func delete(_ template: DevelopTemplate) throws {
        let (directory, release) = try writableDirectory()
        defer { release() }
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try trashAccess.moveToTrash(at: url)
    }

    func resolvedForTransaction() -> TemplateStorageScope<Self> {
        let (directory, release, unavailable) = resolvedDirectoryReportingAvailability()
        let canonical = SafePathComponent.resolvingExistingSymlinks(in: directory)
        return TemplateStorageScope(
            access: Self(directoryURL: canonical, trashAccess: trashAccess,
                         refusesWrites: refusesWrites || unavailable),
            directoryURL: canonical,
            release: release
        )
    }

    /// The directory for a write, refusing while Templates sync is on but iCloud is unreachable.
    private func writableDirectory() throws -> (url: URL, release: @Sendable () -> Void) {
        let (directory, release, unavailable) = resolvedDirectoryReportingAvailability()
        guard !refusesWrites, !unavailable else {
            release()
            throw ICloudStorageUnavailableError()
        }
        return (directory, release)
    }

    private func resolvedDirectoryReportingAvailability() -> (
        url: URL, release: @Sendable () -> Void, cloudUnavailable: Bool
    ) {
        if let directoryOverride {
            return (directoryOverride, {}, false)
        }
        return AppPaths.developTemplatesDirectoryResolution()
    }

    private func resolvedDirectory() -> (url: URL, release: @Sendable () -> Void) {
        if let directoryOverride {
            return (directoryOverride, {})
        }
        return AppPaths.developTemplatesDirectory()
    }
}
