import Foundation

nonisolated enum AnalysisCaseStorage: String, Equatable, Sendable {
    case folderLocal
    case applicationSupport

    var portabilityWarning: String? {
        switch self {
        case .folderLocal:
            nil
        case .applicationSupport:
            "Analysis work is stored in Application Support because Photo Agent cannot write to this photo folder. It will not automatically travel with the folder."
        }
    }
}

enum AnalysisCaseMatch: Equatable, Sendable {
    case exact(AnalysisCase)
    case sourceChanged(AnalysisCase)
    case none
}

nonisolated struct AnalysisCaseLoad: Sendable {
    let match: AnalysisCaseMatch
    let storage: AnalysisCaseStorage?
}

nonisolated struct AnalysisFolderMapLoad: Sendable {
    let document: AnalysisFolderMapDocument
    let storage: AnalysisCaseStorage?
}

/// Source-bound analysis persistence that prefers the portable `.photo_analysis` store and falls
/// back to Application Support only when the photo folder cannot be written.
///
/// Both stores contain app-private JSON. Neither path writes the source image, its metadata, or its
/// XMP sidecar. The fallback index retains the original source/folder identity and is deliberately
/// local-only so sensitive investigation data is not added to portable settings sync.
actor AnalysisCaseRepository {
    private let sourceFolderURL: URL
    private let casesDirectoryURL: URL
    private let folderMapDocumentURL: URL
    private let fallbackCasesDirectoryURL: URL
    private let fallbackFolderMapsDirectoryURL: URL
    private let fallbackIndexURL: URL
    private let sourceFolderIsWritableOverride: Bool?

    init(
        sourceFolderURL: URL,
        applicationSupportURL: URL? = nil,
        sourceFolderIsWritable: Bool? = nil
    ) {
        self.sourceFolderURL = sourceFolderURL.standardizedFileURL.resolvingSymlinksInPath()
        sourceFolderIsWritableOverride = sourceFolderIsWritable

        let analysisDirectoryURL = self.sourceFolderURL
            .appendingPathComponent(".photo_analysis", isDirectory: true)
        casesDirectoryURL = analysisDirectoryURL
            .appendingPathComponent("cases", isDirectory: true)
        folderMapDocumentURL = analysisDirectoryURL
            .appendingPathComponent("folder-map.analysis.json")

        let fallbackRoot = (applicationSupportURL ?? Self.defaultApplicationSupportURL)
            .appendingPathComponent("AnalysisCases", isDirectory: true)
        fallbackCasesDirectoryURL = fallbackRoot
            .appendingPathComponent("cases", isDirectory: true)
        fallbackFolderMapsDirectoryURL = fallbackRoot
            .appendingPathComponent("folder-maps", isDirectory: true)
        fallbackIndexURL = fallbackRoot.appendingPathComponent("index.analysis.json")
    }

    func loadMostRelevantCase(for revision: SourceImageRevision) async -> AnalysisCaseMatch {
        await loadMostRelevantCaseWithStorage(for: revision).match
    }

    func loadMostRelevantCaseWithStorage(
        for revision: SourceImageRevision
    ) async -> AnalysisCaseLoad {
        let records = await loadAllCaseRecords(includeFallbackOutsideCurrentFolder: true)
        var exactMatches: [CaseRecord] = []
        var changedMatches: [CaseRecord] = []

        for record in records {
            switch record.analysisCase.source.relationship(to: revision) {
            case .exactRevision:
                exactMatches.append(record)
            case .sameFileChanged, .samePathChanged:
                changedMatches.append(record)
            case .unrelated:
                break
            }
        }

        if let exact = bestCaseRecord(in: exactMatches) {
            return AnalysisCaseLoad(
                match: .exact(exact.analysisCase),
                storage: exact.storage
            )
        }
        if let changed = bestCaseRecord(in: changedMatches) {
            return AnalysisCaseLoad(
                match: .sourceChanged(changed.analysisCase),
                storage: changed.storage
            )
        }
        return AnalysisCaseLoad(match: .none, storage: nil)
    }

    func loadAllCases() async -> [AnalysisCase] {
        let records = await loadAllCaseRecords(includeFallbackOutsideCurrentFolder: false)
        var bestByID: [UUID: CaseRecord] = [:]
        for record in records {
            guard let existing = bestByID[record.analysisCase.id] else {
                bestByID[record.analysisCase.id] = record
                continue
            }
            if record.analysisCase.updatedAt > existing.analysisCase.updatedAt
                || (record.analysisCase.updatedAt == existing.analysisCase.updatedAt
                    && record.storage == .folderLocal
                    && existing.storage == .applicationSupport) {
                bestByID[record.analysisCase.id] = record
            }
        }
        return bestByID.values
            .map(\.analysisCase)
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    @discardableResult
    func save(_ analysisCase: AnalysisCase) async throws -> AnalysisCaseStorage {
        if !folderIsKnownReadOnly {
            let store = AtomicJSONDocumentStore<AnalysisCase>(
                documentURL: caseURL(for: analysisCase.id, in: casesDirectoryURL)
            )
            do {
                try await store.save(analysisCase)
                return .folderLocal
            } catch {
                guard Self.shouldUseFallback(for: error) else { throw error }
            }
        }

        var fallbackIndex = try await loadFallbackIndex()
        fallbackIndex.record(analysisCase)
        let fallbackStore = AtomicJSONDocumentStore<AnalysisCase>(
            documentURL: caseURL(for: analysisCase.id, in: fallbackCasesDirectoryURL)
        )
        try await fallbackStore.save(analysisCase)
        try await saveFallbackIndex(fallbackIndex)
        return .applicationSupport
    }

    func loadFolderMapDocument() async -> AnalysisFolderMapDocument {
        await loadFolderMapDocumentWithStorage().document
    }

    func loadFolderMapDocumentWithStorage() async -> AnalysisFolderMapLoad {
        var candidates: [(AnalysisFolderMapDocument, AnalysisCaseStorage)] = []
        let localStore = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
            documentURL: folderMapDocumentURL
        )
        if let loaded = try? await localStore.load(),
           case .document(let document, _) = loaded {
            candidates.append((document, .folderLocal))
        }

        if let index = try? await loadFallbackIndex(),
           let entry = index.folderMaps.first(where: {
               $0.folderURL.standardizedFileURL.resolvingSymlinksInPath() == sourceFolderURL
           }) {
            let store = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
                documentURL: fallbackFolderMapsDirectoryURL
                    .appendingPathComponent(entry.documentFilename)
            )
            if let loaded = try? await store.load(),
               case .document(let document, _) = loaded {
                candidates.append((document, .applicationSupport))
            }
        }

        guard let best = candidates.max(by: { lhs, rhs in
            if lhs.0.updatedAt != rhs.0.updatedAt { return lhs.0.updatedAt < rhs.0.updatedAt }
            return lhs.1 == .applicationSupport && rhs.1 == .folderLocal
        }) else {
            return AnalysisFolderMapLoad(document: .create(), storage: nil)
        }
        return AnalysisFolderMapLoad(document: best.0, storage: best.1)
    }

    @discardableResult
    func saveFolderMapDocument(
        _ document: AnalysisFolderMapDocument
    ) async throws -> AnalysisCaseStorage {
        if !folderIsKnownReadOnly {
            let store = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
                documentURL: folderMapDocumentURL
            )
            do {
                try await store.save(document)
                return .folderLocal
            } catch {
                guard Self.shouldUseFallback(for: error) else { throw error }
            }
        }

        var fallbackIndex = try await loadFallbackIndex()
        let filename = fallbackIndex.recordFolderMap(for: sourceFolderURL)
        let fallbackStore = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
            documentURL: fallbackFolderMapsDirectoryURL.appendingPathComponent(filename)
        )
        try await fallbackStore.save(document)
        try await saveFallbackIndex(fallbackIndex)
        return .applicationSupport
    }

    /// Refreshes only path/filename discovery hints for cases whose exact source was renamed.
    /// Case IDs, source hashes, evidence, analyzer output, and timestamps are unchanged.
    @discardableResult
    func relocateSourceHints(
        using mappings: [BatchRenameExecutionPresentation.Mapping]
    ) async throws -> Int {
        let destinations = Dictionary(uniqueKeysWithValues: mappings.map {
            (renameReassociationLookupURL($0.sourceURL), $0.destinationURL.standardizedFileURL)
        })
        guard !destinations.isEmpty else { return 0 }

        var relocatedCount = 0
        for var analysisCase in await loadAllCases() {
            guard let destination = destinations[
                renameReassociationLookupURL(analysisCase.source.canonicalURL)
            ] else { continue }
            analysisCase.relocateSource(to: destination)
            try analysisCase.validateForPersistence()
            try await save(analysisCase)
            relocatedCount += 1
        }
        return relocatedCount
    }

    private func loadAllCaseRecords(
        includeFallbackOutsideCurrentFolder: Bool
    ) async -> [CaseRecord] {
        var records = await caseRecords(in: casesDirectoryURL, storage: .folderLocal)

        guard let fallbackIndex = try? await loadFallbackIndex() else { return records }
        for entry in fallbackIndex.cases {
            let recordedFolder = entry.source.canonicalURL.deletingLastPathComponent()
                .standardizedFileURL.resolvingSymlinksInPath()
            guard includeFallbackOutsideCurrentFolder || recordedFolder == sourceFolderURL else {
                continue
            }
            let url = fallbackCasesDirectoryURL.appendingPathComponent(entry.caseFilename)
            if let record = await loadCaseRecord(at: url, storage: .applicationSupport) {
                records.append(record)
            }
        }
        return records
    }

    private func caseRecords(
        in directory: URL,
        storage: AnalysisCaseStorage
    ) async -> [CaseRecord] {
        var records: [CaseRecord] = []
        for url in caseURLs(in: directory) {
            if let record = await loadCaseRecord(at: url, storage: storage) {
                records.append(record)
            }
        }
        return records
    }

    private func loadCaseRecord(
        at url: URL,
        storage: AnalysisCaseStorage
    ) async -> CaseRecord? {
        let store = AtomicJSONDocumentStore<AnalysisCase>(documentURL: url)
        guard let loaded = try? await store.load(),
              case .document(let analysisCase, _) = loaded else {
            return nil
        }
        return CaseRecord(analysisCase: analysisCase, storage: storage)
    }

    private func caseURLs(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { $0.lastPathComponent.hasSuffix(".analysis.json") } ?? []
    }

    private func caseURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(id.uuidString.lowercased()).analysis.json"
        )
    }

    private func bestCaseRecord(in candidates: [CaseRecord]) -> CaseRecord? {
        candidates.max { lhs, rhs in
            if lhs.analysisCase.updatedAt != rhs.analysisCase.updatedAt {
                return lhs.analysisCase.updatedAt < rhs.analysisCase.updatedAt
            }
            return lhs.storage == .applicationSupport && rhs.storage == .folderLocal
        }
    }

    private var folderIsKnownReadOnly: Bool {
        if let sourceFolderIsWritableOverride { return !sourceFolderIsWritableOverride }
        guard let values = try? sourceFolderURL.resourceValues(forKeys: [
            .isWritableKey,
            .volumeIsReadOnlyKey
        ]) else {
            return false
        }
        return values.isWritable == false || values.volumeIsReadOnly == true
    }

    private func loadFallbackIndex() async throws -> AnalysisCaseFallbackIndex {
        let store = AtomicJSONDocumentStore<AnalysisCaseFallbackIndex>(
            documentURL: fallbackIndexURL
        )
        do {
            switch try await store.load() {
            case .document(let document, _):
                return document
            case .newerSchema(let schemaVersion, _, _):
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: schemaVersion,
                    supported: AnalysisCaseFallbackIndex.currentSchemaVersion
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .create()
        }
    }

    private func saveFallbackIndex(_ index: AnalysisCaseFallbackIndex) async throws {
        let store = AtomicJSONDocumentStore<AnalysisCaseFallbackIndex>(
            documentURL: fallbackIndexURL
        )
        try await store.save(index)
    }

    private nonisolated static var defaultApplicationSupportURL: URL {
        if AppPaths.isTestProcess {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "apa-analysis-case-tests-\(ProcessInfo.processInfo.processIdentifier)",
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
               CocoaError.Code.fileWriteVolumeReadOnly.rawValue
           ].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return shouldUseFallback(for: underlying)
        }
        return false
    }
}

private nonisolated struct CaseRecord: Sendable {
    let analysisCase: AnalysisCase
    let storage: AnalysisCaseStorage
}

private nonisolated struct AnalysisCaseFallbackIndex: VersionedJSONDocument, Sendable {
    struct CaseEntry: Codable, Equatable, Sendable {
        let source: SourceImageRevision
        let caseID: UUID
        let caseFilename: String
    }

    struct FolderMapEntry: Codable, Equatable, Sendable {
        let folderURL: URL
        let documentFilename: String
    }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var cases: [CaseEntry]
    var folderMaps: [FolderMapEntry]

    static func create() -> AnalysisCaseFallbackIndex {
        AnalysisCaseFallbackIndex(
            schemaVersion: currentSchemaVersion,
            cases: [],
            folderMaps: []
        )
    }

    mutating func record(_ analysisCase: AnalysisCase) {
        let entry = CaseEntry(
            source: analysisCase.source,
            caseID: analysisCase.id,
            caseFilename: "\(analysisCase.id.uuidString.lowercased()).analysis.json"
        )
        cases.removeAll { $0.caseID == analysisCase.id }
        cases.append(entry)
    }

    mutating func recordFolderMap(for folderURL: URL) -> String {
        let normalized = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = folderMaps.first(where: {
            $0.folderURL.standardizedFileURL.resolvingSymlinksInPath() == normalized
        }) {
            return existing.documentFilename
        }
        let filename = "\(UUID().uuidString.lowercased()).folder-map.analysis.json"
        folderMaps.append(FolderMapEntry(folderURL: normalized, documentFilename: filename))
        return filename
    }

    func validateForPersistence() throws {
        guard Set(cases.map(\.caseID)).count == cases.count,
              Set(cases.map(\.caseFilename)).count == cases.count,
              Set(folderMaps.map { $0.folderURL.standardizedFileURL }).count == folderMaps.count,
              Set(folderMaps.map(\.documentFilename)).count == folderMaps.count else {
            throw AnalysisCaseFallbackIndexError.duplicateEntry
        }
    }
}

private enum AnalysisCaseFallbackIndexError: Error, Sendable {
    case duplicateEntry
}
