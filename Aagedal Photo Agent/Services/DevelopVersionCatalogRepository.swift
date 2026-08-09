import Foundation

nonisolated enum DevelopVersionCatalogMatch: Equatable, Sendable {
    case exact(DevelopVersionCatalog, source: AtomicJSONDocumentSource)
    case sourceChanged(DevelopVersionCatalog, source: AtomicJSONDocumentSource)
    case newerSchema(schemaVersion: Int, data: Data, source: AtomicJSONDocumentSource)
    case none
}

/// Folder-local persistence for app-private named Develop versions.
///
/// Catalog filenames use the authoritative source hash, so renaming or moving a source never
/// rewrites identity. The catalog payload retains discovery hints for changed-source recovery.
actor DevelopVersionCatalogRepository {
    private let catalogsDirectoryURL: URL

    init(sourceFolderURL: URL) {
        catalogsDirectoryURL = sourceFolderURL
            .appendingPathComponent(".photo_versions", isDirectory: true)
            .appendingPathComponent("catalogs", isDirectory: true)
    }

    func loadMostRelevantCatalog(
        for revision: SourceImageRevision
    ) async -> DevelopVersionCatalogMatch {
        let records = await loadAllRecords()
        var exact: [(DevelopVersionCatalog, AtomicJSONDocumentSource)] = []
        var changed: [(DevelopVersionCatalog, AtomicJSONDocumentSource)] = []

        for record in records {
            switch record.load {
            case .document(let catalog, let source):
                switch catalog.source.relationship(to: revision) {
                case .exactRevision:
                    exact.append((catalog, source))
                case .sameFileChanged, .samePathChanged:
                    changed.append((catalog, source))
                case .unrelated:
                    break
                }
            case .newerSchema(let schemaVersion, let data, let source):
                // The source fields cannot safely be interpreted without its schema. Surface the
                // read-only bytes when their hash-derived filename is the requested revision.
                if catalogURL(forSHA256: revision.sha256).lastPathComponent
                    == record.url.lastPathComponent {
                    return .newerSchema(
                        schemaVersion: schemaVersion,
                        data: data,
                        source: source
                    )
                }
            }
        }

        if let match = exact.max(by: { $0.0.updatedAt < $1.0.updatedAt }) {
            return .exact(match.0, source: match.1)
        }
        if let match = changed.max(by: { $0.0.updatedAt < $1.0.updatedAt }) {
            return .sourceChanged(match.0, source: match.1)
        }
        return .none
    }

    func save(_ catalog: DevelopVersionCatalog) async throws {
        let store = AtomicJSONDocumentStore<DevelopVersionCatalog>(
            documentURL: catalogURL(forSHA256: catalog.source.sha256)
        )
        try await store.save(catalog)
    }

    func loadAllCatalogs() async -> [DevelopVersionCatalog] {
        await loadAllRecords().compactMap { record in
            guard case .document(let catalog, _) = record.load else { return nil }
            return catalog
        }
    }

    private func loadAllRecords() async -> [CatalogRecord] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: catalogsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ).filter { $0.lastPathComponent.hasSuffix(".versions.json") }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            return []
        }

        var records: [CatalogRecord] = []
        for url in urls {
            let store = AtomicJSONDocumentStore<DevelopVersionCatalog>(documentURL: url)
            guard let loaded = try? await store.load() else { continue }
            records.append(CatalogRecord(url: url, load: loaded))
        }
        return records
    }

    private func catalogURL(forSHA256 sha256: String) -> URL {
        catalogsDirectoryURL.appendingPathComponent("\(sha256).versions.json")
    }
}

private nonisolated struct CatalogRecord: Sendable {
    let url: URL
    let load: AtomicJSONDocumentLoad<DevelopVersionCatalog>
}
