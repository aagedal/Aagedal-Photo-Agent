import Foundation

nonisolated enum DevelopVersionCatalogStorage: String, Equatable, Sendable {
    case folderLocal
    case applicationSupport

    /// A fallback catalog remains fully editable, but it will not travel with the photo folder.
    var portabilityWarning: String? {
        switch self {
        case .folderLocal:
            nil
        case .applicationSupport:
            "Named versions are stored in Application Support because Photo Agent cannot write to this photo folder. They will not automatically travel with the folder."
        }
    }
}

nonisolated enum DevelopVersionCatalogMatch: Equatable, Sendable {
    case exact(
        DevelopVersionCatalog,
        source: AtomicJSONDocumentSource,
        storage: DevelopVersionCatalogStorage
    )
    case sourceChanged(
        DevelopVersionCatalog,
        source: AtomicJSONDocumentSource,
        storage: DevelopVersionCatalogStorage
    )
    case newerSchema(
        schemaVersion: Int,
        data: Data,
        source: AtomicJSONDocumentSource,
        storage: DevelopVersionCatalogStorage
    )
    case none
}

/// Folder-local persistence for app-private named Develop versions, with an Application Support
/// fallback when the photo folder cannot be written.
///
/// Catalog filenames use the authoritative source hash, so renaming or moving a source never
/// rewrites identity. The catalog payload retains discovery hints for changed-source recovery.
actor DevelopVersionCatalogRepository {
    private let catalogsDirectoryURL: URL
    private let fallbackCatalogsDirectoryURL: URL
    private let fallbackIndexURL: URL
    private let sourceFolderURL: URL

    init(
        sourceFolderURL: URL,
        applicationSupportURL: URL? = nil
    ) {
        self.sourceFolderURL = sourceFolderURL
        catalogsDirectoryURL = sourceFolderURL
            .appendingPathComponent(".photo_versions", isDirectory: true)
            .appendingPathComponent("catalogs", isDirectory: true)
        let fallbackRoot = (applicationSupportURL ?? Self.defaultApplicationSupportURL)
            .appendingPathComponent("DevelopVersions", isDirectory: true)
        fallbackCatalogsDirectoryURL = fallbackRoot
            .appendingPathComponent("catalogs", isDirectory: true)
        fallbackIndexURL = fallbackRoot.appendingPathComponent("index.versions.json")
    }

    func loadMostRelevantCatalog(
        for revision: SourceImageRevision
    ) async -> DevelopVersionCatalogMatch {
        let records = await loadAllRecords()
        var exact: [CatalogCandidate] = []
        var changed: [CatalogCandidate] = []

        for record in records {
            switch record.load {
            case .document(let catalog, let source):
                switch catalog.source.relationship(to: revision) {
                case .exactRevision:
                    exact.append(CatalogCandidate(
                        catalog: catalog,
                        source: source,
                        storage: record.storage
                    ))
                case .sameFileChanged, .samePathChanged:
                    changed.append(CatalogCandidate(
                        catalog: catalog,
                        source: source,
                        storage: record.storage
                    ))
                case .unrelated:
                    break
                }
            case .newerSchema(let schemaVersion, let data, let source):
                // The source fields cannot safely be interpreted without its schema. Surface the
                // read-only bytes when their hash-derived filename is the requested revision.
                if catalogURL(
                    forSHA256: revision.sha256,
                    in: catalogsDirectoryURL
                ).lastPathComponent
                    == record.url.lastPathComponent {
                    return .newerSchema(
                        schemaVersion: schemaVersion,
                        data: data,
                        source: source,
                        storage: record.storage
                    )
                }
            }
        }

        if let match = bestCandidate(in: exact) {
            return .exact(match.catalog, source: match.source, storage: match.storage)
        }
        if let match = bestCandidate(in: changed) {
            return .sourceChanged(
                match.catalog,
                source: match.source,
                storage: match.storage
            )
        }
        return .none
    }

    @discardableResult
    func save(_ catalog: DevelopVersionCatalog) async throws -> DevelopVersionCatalogStorage {
        if !folderIsKnownReadOnly {
            let store = AtomicJSONDocumentStore<DevelopVersionCatalog>(
                documentURL: catalogURL(
                    forSHA256: catalog.source.sha256,
                    in: catalogsDirectoryURL
                )
            )
            do {
                try await store.save(catalog)
                return .folderLocal
            } catch {
                guard Self.shouldUseFallback(for: error) else { throw error }
            }
        }

        // Check the index schema before installing the catalog. This prevents an older app from
        // silently creating fallback state beside a newer, read-only index schema.
        var fallbackIndex = try await loadFallbackIndex()
        fallbackIndex.record(catalog.source)
        let fallbackStore = AtomicJSONDocumentStore<DevelopVersionCatalog>(
            documentURL: catalogURL(
                forSHA256: catalog.source.sha256,
                in: fallbackCatalogsDirectoryURL
            )
        )
        try await fallbackStore.save(catalog)
        try await saveFallbackIndex(fallbackIndex)
        return .applicationSupport
    }

    func loadAllCatalogs() async -> [DevelopVersionCatalog] {
        await loadAllRecords().compactMap { record in
            guard case .document(let catalog, _) = record.load else { return nil }
            return catalog
        }
    }

    private func loadAllRecords() async -> [CatalogRecord] {
        var records: [CatalogRecord] = []
        for (directory, storage) in [
            (catalogsDirectoryURL, DevelopVersionCatalogStorage.folderLocal),
            (fallbackCatalogsDirectoryURL, DevelopVersionCatalogStorage.applicationSupport)
        ] {
            let urls = catalogURLs(in: directory)
            for url in urls {
                let store = AtomicJSONDocumentStore<DevelopVersionCatalog>(documentURL: url)
                guard let loaded = try? await store.load() else { continue }
                records.append(CatalogRecord(url: url, load: loaded, storage: storage))
            }
        }
        return records
    }

    private func catalogURLs(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { $0.lastPathComponent.hasSuffix(".versions.json") } ?? []
    }

    private func catalogURL(forSHA256 sha256: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(sha256).versions.json")
    }

    private var folderIsKnownReadOnly: Bool {
        guard let values = try? sourceFolderURL.resourceValues(forKeys: [
            .isWritableKey,
            .volumeIsReadOnlyKey
        ]) else {
            return false
        }
        return values.isWritable == false || values.volumeIsReadOnly == true
    }

    private func bestCandidate(in candidates: [CatalogCandidate]) -> CatalogCandidate? {
        candidates.max { lhs, rhs in
            if lhs.catalog.updatedAt != rhs.catalog.updatedAt {
                return lhs.catalog.updatedAt < rhs.catalog.updatedAt
            }
            // At equal revisions prefer the portable folder-local copy.
            return lhs.storage == .applicationSupport && rhs.storage == .folderLocal
        }
    }

    private func loadFallbackIndex() async throws -> DevelopVersionFallbackIndex {
        let store = AtomicJSONDocumentStore<DevelopVersionFallbackIndex>(
            documentURL: fallbackIndexURL
        )
        do {
            switch try await store.load() {
            case .document(let document, _):
                return document
            case .newerSchema(let schemaVersion, _, _):
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: schemaVersion,
                    supported: DevelopVersionFallbackIndex.currentSchemaVersion
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DevelopVersionFallbackIndex.create()
        }
    }

    private func saveFallbackIndex(_ index: DevelopVersionFallbackIndex) async throws {
        let store = AtomicJSONDocumentStore<DevelopVersionFallbackIndex>(
            documentURL: fallbackIndexURL
        )
        try await store.save(index)
    }

    private nonisolated static var defaultApplicationSupportURL: URL {
        if AppPaths.isTestProcess {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "apa-version-catalog-tests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        }
        return AppPaths.applicationSupport
    }

    private static func shouldUseFallback(for error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [
               CocoaError.Code.fileWriteNoPermission.rawValue,
               CocoaError.Code.fileWriteVolumeReadOnly.rawValue,
               CocoaError.Code.fileWriteFileExists.rawValue
           ].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return shouldUseFallback(for: underlying)
        }
        return false
    }
}

private nonisolated struct CatalogRecord: Sendable {
    let url: URL
    let load: AtomicJSONDocumentLoad<DevelopVersionCatalog>
    let storage: DevelopVersionCatalogStorage
}

private nonisolated struct CatalogCandidate: Sendable {
    let catalog: DevelopVersionCatalog
    let source: AtomicJSONDocumentSource
    let storage: DevelopVersionCatalogStorage
}

/// A small portability index for catalogs that could not be stored beside their source folder.
private nonisolated struct DevelopVersionFallbackIndex: VersionedJSONDocument, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let source: SourceImageRevision
        let catalogFilename: String
    }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var entries: [Entry]

    static func create() -> DevelopVersionFallbackIndex {
        DevelopVersionFallbackIndex(schemaVersion: currentSchemaVersion, entries: [])
    }

    mutating func record(_ source: SourceImageRevision) {
        let entry = Entry(
            source: source,
            catalogFilename: "\(source.sha256).versions.json"
        )
        if let index = entries.firstIndex(where: { $0.source.sha256 == source.sha256 }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { $0.source.sha256 < $1.source.sha256 }
    }

    func validateForPersistence() throws {
        let hashes = entries.map(\.source.sha256)
        guard Set(hashes).count == hashes.count,
              entries.allSatisfy({
                  $0.source.sha256.count == 64
                      && $0.catalogFilename == "\($0.source.sha256).versions.json"
              }) else {
            throw DevelopVersionCatalogValidationError.invalidSourceHash
        }
    }
}
