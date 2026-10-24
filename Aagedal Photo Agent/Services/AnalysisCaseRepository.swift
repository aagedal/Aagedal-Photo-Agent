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

/// Everything the workspace needs when a photo opens, derived from one pass over the
/// repository's in-memory case index.
nonisolated struct AnalysisWorkspaceSnapshot: Sendable {
    let caseLoad: AnalysisCaseLoad
    let folderCases: [AnalysisCase]
    let folderMap: AnalysisFolderMapLoad
    /// Where a not-yet-saved case is expected to land, for the portability warning.
    let newDocumentStorage: AnalysisCaseStorage
}

/// Cheap change evidence for a file or directory. It only decides whether a cached decode may
/// be reused; it is never source identity.
nonisolated struct AnalysisFileStamp: Equatable, Sendable {
    let modificationDate: Date
    let byteCount: Int64
    let resourceIdentifier: SourceImageRevision.FileResourceIdentifier?

    static let resourceKeys: [URLResourceKey] = [
        .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey
    ]

    /// Reads the stamp from `url`'s resource values. URLs returned by a directory listing that
    /// prefetched `resourceKeys` answer from that listing without another round trip.
    static func read(_ url: URL) -> AnalysisFileStamp? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
              let modificationDate = values.contentModificationDate else { return nil }
        return AnalysisFileStamp(
            modificationDate: modificationDate,
            byteCount: Int64(values.fileSize ?? 0),
            resourceIdentifier: SourceImageRevision.FileResourceIdentifier(
                foundationValue: values.fileResourceIdentifier
            )
        )
    }
}

/// Synchronous provider access kept inside the repository's retained filesystem executor.
nonisolated struct AnalysisCaseRepositoryFileIO: Sendable {
    let directoryContents: @Sendable (URL) throws -> [URL]
    let isKnownReadOnly: @Sendable (URL) -> Bool
    let canonicalSourceFolder: @Sendable (URL) -> URL
    let defaultApplicationSupportURL: @Sendable () -> URL
    let fileStamp: @Sendable (URL) -> AnalysisFileStamp?
    let now: @Sendable () -> Date

    init(
        directoryContents: @escaping @Sendable (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: AnalysisFileStamp.resourceKeys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        },
        isKnownReadOnly: @escaping @Sendable (URL) -> Bool = {
            guard let values = try? $0.resourceValues(forKeys: [
                .isWritableKey, .volumeIsReadOnlyKey
            ]) else { return false }
            return values.isWritable == false || values.volumeIsReadOnly == true
        },
        canonicalSourceFolder: @escaping @Sendable (URL) -> URL = {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        },
        defaultApplicationSupportURL: @escaping @Sendable () -> URL = {
            if AppPaths.isTestProcess {
                return FileManager.default.temporaryDirectory.appendingPathComponent(
                    "apa-analysis-case-tests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            }
            return AppPaths.applicationSupport
        },
        fileStamp: @escaping @Sendable (URL) -> AnalysisFileStamp? = AnalysisFileStamp.read,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directoryContents = directoryContents
        self.isKnownReadOnly = isKnownReadOnly
        self.canonicalSourceFolder = canonicalSourceFolder
        self.defaultApplicationSupportURL = defaultApplicationSupportURL
        self.fileStamp = fileStamp
        self.now = now
    }

    static let system = AnalysisCaseRepositoryFileIO()
}

/// Source-bound analysis persistence that prefers the portable `.photo_analysis` store and falls
/// back to Application Support only when the photo folder cannot be written.
///
/// Both stores contain app-private JSON. Neither path writes the source image, its metadata, or its
/// XMP sidecar. The fallback index retains the original source/folder identity and is deliberately
/// local-only so sensitive investigation data is not added to portable settings sync.
actor AnalysisCaseRepository {
    // Directory enumeration, provider resource values and path identity comparisons may block.
    // Retain this worker for every actor-isolated operation while preserving task context.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    private let fileIO: AnalysisCaseRepositoryFileIO
    private let sourceFolderURL: URL
    private let casesDirectoryURL: URL
    private let folderMapDocumentURL: URL
    private let fallbackCasesDirectoryURL: URL
    private let fallbackFolderMapsDirectoryURL: URL
    private let fallbackIndexURL: URL
    private let sourceFolderIsWritableOverride: Bool?
    private let didLoadFallbackIndexForWriting: @Sendable () async throws -> Void

    // MARK: In-memory index
    //
    // Opening a photo used to decode every case file in the folder (and every Application
    // Support fallback case) twice. The repository now keeps the decoded cases and reuses a
    // decode while the file's stamp is unchanged; the cases directory is re-listed only when its
    // own stamp changes. This repository's saves update the index in place. A stamp observed
    // within `stampSettleInterval` of its modification time is not trusted on the next pass,
    // because coarse-timestamp volumes (HFS+, SMB, FAT) can hide a same-tick rewrite.
    private static let stampSettleInterval: TimeInterval = 2.5
    private var localCaseFiles: [String: IndexedCaseFile] = [:]
    private var localDirectoryObservation: StampObservation?
    private var fallbackIndexObservation: StampObservation?
    private var cachedFallbackIndex: AnalysisCaseFallbackIndex?
    private var fallbackCaseFiles: [String: IndexedCaseFile] = [:]
    private var localFolderMapCache: CachedFolderMap?
    private var fallbackFolderMapCache: CachedFolderMap?
    private var cachedLookup: CaseLookup?
    /// Bumped by every change to the indexed records, so the lookup tables and a refresh that
    /// raced one of this repository's own saves can tell their snapshot is stale.
    private var indexMutationSequence = 0
    /// Number of case documents decoded from disk. Tests use it to prove navigation stays O(N).
    private(set) var caseDecodeCount = 0

    /// Capture the source root before publishing the repository. The captured URL stays stable
    /// if a presented symlink is later retargeted, while provider access never blocks the caller.
    nonisolated static func open(
        sourceFolderURL: URL,
        applicationSupportURL: URL? = nil,
        sourceFolderIsWritable: Bool? = nil,
        fileIO: AnalysisCaseRepositoryFileIO = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.analysis-case-repository", qos: .utility
        ),
        didLoadFallbackIndexForWriting: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> AnalysisCaseRepository {
        try Task.checkCancellation()
        let preparation = AnalysisCaseRepositoryPreparation(filesystemQueue: filesystemQueue)
        let roots = try await preparation.prepare(
            sourceFolderURL: sourceFolderURL,
            applicationSupportURL: applicationSupportURL,
            fileIO: fileIO
        )
        try Task.checkCancellation()
        return AnalysisCaseRepository(
            canonicalSourceFolderURL: roots.sourceFolderURL,
            applicationSupportURL: roots.applicationSupportURL,
            sourceFolderIsWritable: sourceFolderIsWritable,
            fileIO: fileIO,
            filesystemQueue: filesystemQueue,
            didLoadFallbackIndexForWriting: didLoadFallbackIndexForWriting
        )
    }

    private init(
        canonicalSourceFolderURL: URL,
        applicationSupportURL: URL,
        sourceFolderIsWritable: Bool?,
        fileIO: AnalysisCaseRepositoryFileIO,
        filesystemQueue: DispatchSerialQueue,
        didLoadFallbackIndexForWriting: @escaping @Sendable () async throws -> Void
    ) {
        self.didLoadFallbackIndexForWriting = didLoadFallbackIndexForWriting
        self.fileIO = fileIO
        self.filesystemQueue = filesystemQueue
        sourceFolderURL = canonicalSourceFolderURL
        sourceFolderIsWritableOverride = sourceFolderIsWritable

        let analysisDirectoryURL = canonicalSourceFolderURL
            .appendingPathComponent(".photo_analysis", isDirectory: true)
        casesDirectoryURL = analysisDirectoryURL
            .appendingPathComponent("cases", isDirectory: true)
        folderMapDocumentURL = analysisDirectoryURL
            .appendingPathComponent("folder-map.analysis.json")

        let fallbackRoot = applicationSupportURL
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
        let lookup = await currentLookup()
        return bestMatch(for: revision, in: lookup)
    }

    func loadAllCases() async -> [AnalysisCase] {
        folderCases(in: await currentLookup())
    }

    /// The best case for `revision`, every case of this folder and the folder map, from one pass
    /// over the index. Unchanged case files are not decoded again.
    func loadWorkspaceSnapshot(for revision: SourceImageRevision) async -> AnalysisWorkspaceSnapshot {
        let lookup = await currentLookup()
        let caseLoad = bestMatch(for: revision, in: lookup)
        let cases = folderCases(in: lookup)
        let folderMap = await loadFolderMapDocumentWithStorage()
        return AnalysisWorkspaceSnapshot(
            caseLoad: caseLoad,
            folderCases: cases,
            folderMap: folderMap,
            newDocumentStorage: folderIsKnownReadOnly ? .applicationSupport : .folderLocal
        )
    }

    private func bestMatch(
        for revision: SourceImageRevision,
        in lookup: CaseLookup
    ) -> AnalysisCaseLoad {
        // Only records sharing the hash, the file identity or the path can relate to the
        // revision; visiting them in index order keeps the original tie-breaking.
        var candidateIndices = Set(lookup.bySHA256[revision.sha256] ?? [])
        if let fileID = revision.fileResourceIdentifier {
            candidateIndices.formUnion(lookup.byFileID[fileID] ?? [])
        }
        candidateIndices.formUnion(lookup.byPath[revision.canonicalURL] ?? [])

        var exactMatches: [CaseRecord] = []
        var changedMatches: [CaseRecord] = []
        for index in candidateIndices.sorted() {
            let record = lookup.records[index]
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

    private func folderCases(in lookup: CaseLookup) -> [AnalysisCase] {
        var bestByID: [UUID: CaseRecord] = [:]
        for index in lookup.folderRecordIndices {
            let record = lookup.records[index]
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
            let documentURL = caseURL(for: analysisCase.id, in: casesDirectoryURL)
            let store = AtomicJSONDocumentStore<AnalysisCase>(documentURL: documentURL)
            do {
                try await store.save(analysisCase)
                recordOwnCaseWrite(analysisCase, at: documentURL, storage: .folderLocal)
                return .folderLocal
            } catch {
                guard Self.shouldUseFallback(for: error) else { throw error }
            }
        }

        // Canonicalization runs on this repository's filesystem executor, never on admission's
        // cooperative executor. All repositories and symlink aliases share the same index key.
        let indexKey = fallbackIndexURL.standardizedFileURL.resolvingSymlinksInPath()
        return try await AnalysisCaseFallbackWriteAdmission.shared.withAccess(to: indexKey) {
            try await self.saveCaseInFallback(analysisCase)
        }
    }

    private func saveCaseInFallback(_ analysisCase: AnalysisCase) async throws -> AnalysisCaseStorage {
        let priorIndexWasCurrent = fallbackIndexIsCurrent
        var fallbackIndex = try await loadFallbackIndex()
        try await didLoadFallbackIndexForWriting()
        fallbackIndex.record(analysisCase)
        let documentURL = caseURL(for: analysisCase.id, in: fallbackCasesDirectoryURL)
        let fallbackStore = AtomicJSONDocumentStore<AnalysisCase>(documentURL: documentURL)
        try await fallbackStore.save(analysisCase)
        recordOwnCaseWrite(analysisCase, at: documentURL, storage: .applicationSupport)
        try await saveFallbackIndex(fallbackIndex)
        recordOwnFallbackIndexWrite(
            fallbackIndex,
            priorIndexWasCurrent: priorIndexWasCurrent
        )
        return .applicationSupport
    }

    func loadFolderMapDocument() async -> AnalysisFolderMapDocument {
        await loadFolderMapDocumentWithStorage().document
    }

    func loadFolderMapDocumentWithStorage() async -> AnalysisFolderMapLoad {
        var candidates: [(AnalysisFolderMapDocument, AnalysisCaseStorage)] = []
        if let document = await cachedFolderMap(at: folderMapDocumentURL, storage: .folderLocal) {
            candidates.append((document, .folderLocal))
        }

        if let index = await currentFallbackIndex(),
           let entry = index.folderMaps.first(where: {
               $0.folderURL.standardizedFileURL.resolvingSymlinksInPath() == sourceFolderURL
           }),
           let document = await cachedFolderMap(
               at: fallbackFolderMapsDirectoryURL.appendingPathComponent(entry.documentFilename),
               storage: .applicationSupport
           ) {
            candidates.append((document, .applicationSupport))
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
                recordOwnFolderMapWrite(document, at: folderMapDocumentURL, storage: .folderLocal)
                return .folderLocal
            } catch {
                guard Self.shouldUseFallback(for: error) else { throw error }
            }
        }

        let indexKey = fallbackIndexURL.standardizedFileURL.resolvingSymlinksInPath()
        return try await AnalysisCaseFallbackWriteAdmission.shared.withAccess(to: indexKey) {
            try await self.saveFolderMapInFallback(document)
        }
    }

    private func saveFolderMapInFallback(
        _ document: AnalysisFolderMapDocument
    ) async throws -> AnalysisCaseStorage {
        let priorIndexWasCurrent = fallbackIndexIsCurrent
        var fallbackIndex = try await loadFallbackIndex()
        try await didLoadFallbackIndexForWriting()
        let filename = fallbackIndex.recordFolderMap(for: sourceFolderURL)
        let documentURL = fallbackFolderMapsDirectoryURL.appendingPathComponent(filename)
        let fallbackStore = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(
            documentURL: documentURL
        )
        try await fallbackStore.save(document)
        recordOwnFolderMapWrite(document, at: documentURL, storage: .applicationSupport)
        try await saveFallbackIndex(fallbackIndex)
        recordOwnFallbackIndexWrite(
            fallbackIndex,
            priorIndexWasCurrent: priorIndexWasCurrent
        )
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

    // MARK: Index maintenance

    /// Lookup tables over every indexed record, rebuilt only after the records change.
    private func currentLookup() async -> CaseLookup {
        await refreshLocalCaseFiles()
        _ = await currentFallbackIndex()
        if let cachedLookup, cachedLookup.sequence == indexMutationSequence {
            return cachedLookup
        }

        var records: [CaseRecord] = []
        var folderRecordIndices: [Int] = []
        for name in localCaseFiles.keys.sorted() {
            guard let record = localCaseFiles[name]?.record else { continue }
            folderRecordIndices.append(records.count)
            records.append(record)
        }
        for entry in cachedFallbackIndex?.cases ?? [] {
            guard let file = fallbackCaseFiles[entry.caseFilename],
                  let record = file.record else { continue }
            if file.recordedFolderURL == sourceFolderURL {
                folderRecordIndices.append(records.count)
            }
            records.append(record)
        }

        var bySHA256: [String: [Int]] = [:]
        var byFileID: [SourceImageRevision.FileResourceIdentifier: [Int]] = [:]
        var byPath: [URL: [Int]] = [:]
        for (index, record) in records.enumerated() {
            let source = record.analysisCase.source
            bySHA256[source.sha256, default: []].append(index)
            if let fileID = source.fileResourceIdentifier {
                byFileID[fileID, default: []].append(index)
            }
            byPath[source.canonicalURL, default: []].append(index)
        }
        let lookup = CaseLookup(
            sequence: indexMutationSequence,
            records: records,
            folderRecordIndices: folderRecordIndices,
            bySHA256: bySHA256,
            byFileID: byFileID,
            byPath: byPath
        )
        cachedLookup = lookup
        return lookup
    }

    private func isTrustworthy(
        _ observation: StampObservation?,
        for stamp: AnalysisFileStamp?
    ) -> Bool {
        guard let observation, let stamp, observation.stamp == stamp else { return false }
        return observation.isOwnWrite
            || stamp.modificationDate
                <= observation.observedAt.addingTimeInterval(-Self.stampSettleInterval)
    }

    private func freshStamp(_ url: URL) -> AnalysisFileStamp? {
        // A new URL instance never answers from Foundation's per-instance resource cache.
        fileIO.fileStamp(URL(fileURLWithPath: url.path))
    }

    private func refreshLocalCaseFiles() async {
        let directoryStamp = freshStamp(casesDirectoryURL)
        if isTrustworthy(localDirectoryObservation, for: directoryStamp) { return }

        let startSequence = indexMutationSequence
        let observedAt = fileIO.now()
        var next: [String: IndexedCaseFile] = [:]
        var changed = false
        for url in caseURLs(in: casesDirectoryURL) {
            let name = url.lastPathComponent
            let stamp = fileIO.fileStamp(url)
            if let existing = localCaseFiles[name],
               isTrustworthy(existing.observation, for: stamp) {
                next[name] = existing
                continue
            }
            changed = true
            let record = await loadCaseRecord(at: url, storage: .folderLocal)
            next[name] = IndexedCaseFile(
                observation: stamp.map { StampObservation(stamp: $0, observedAt: observedAt) },
                record: record,
                recordedFolderURL: sourceFolderURL,
                sequence: startSequence
            )
        }
        if Set(next.keys) != Set(localCaseFiles.keys) { changed = true }
        if indexMutationSequence != startSequence {
            // This repository saved a case while the listing was decoded. Keep that record;
            // the save also changed the directory after `directoryStamp` was read, so leave
            // the directory unobserved and re-list on the next pass.
            for (name, entry) in localCaseFiles where entry.sequence > startSequence {
                next[name] = entry
            }
            localCaseFiles = next
            localDirectoryObservation = nil
            indexMutationSequence += 1
            return
        }
        localCaseFiles = next
        localDirectoryObservation = directoryStamp.map {
            StampObservation(stamp: $0, observedAt: observedAt)
        }
        if changed { indexMutationSequence += 1 }
    }

    /// The fallback index, reloaded only when its stamp changes. Every fallback case save
    /// rewrites the index, so an unchanged index also means unchanged fallback cases.
    private func currentFallbackIndex() async -> AnalysisCaseFallbackIndex? {
        let indexStamp = freshStamp(fallbackIndexURL)
        let indexIsCurrent = cachedFallbackIndex != nil
            && isTrustworthy(fallbackIndexObservation, for: indexStamp)

        let startSequence = indexMutationSequence
        let observedAt = fileIO.now()
        let previousIndex = cachedFallbackIndex
        let index: AnalysisCaseFallbackIndex
        if indexIsCurrent, let previousIndex {
            index = previousIndex
        } else {
            guard let loaded = try? await loadFallbackIndex() else {
                // An unreadable or newer-schema index contributes no records, as before.
                if indexMutationSequence == startSequence {
                    if cachedFallbackIndex != nil || !fallbackCaseFiles.isEmpty {
                        cachedFallbackIndex = nil
                        fallbackCaseFiles = [:]
                        indexMutationSequence += 1
                    }
                    fallbackIndexObservation = nil
                }
                return nil
            }
            index = loaded
        }

        var next: [String: IndexedCaseFile] = [:]
        var changed = previousIndex?.cases.map(\.caseFilename) != index.cases.map(\.caseFilename)
        for entry in index.cases {
            let name = entry.caseFilename
            if indexIsCurrent, let existing = fallbackCaseFiles[name] {
                next[name] = existing
                continue
            }
            let url = fallbackCasesDirectoryURL.appendingPathComponent(name)
            let stamp = freshStamp(url)
            if let existing = fallbackCaseFiles[name],
               isTrustworthy(existing.observation, for: stamp) {
                next[name] = existing
                continue
            }
            changed = true
            let record = await loadCaseRecord(at: url, storage: .applicationSupport)
            next[name] = IndexedCaseFile(
                observation: stamp.map { StampObservation(stamp: $0, observedAt: observedAt) },
                record: record,
                recordedFolderURL: entry.source.canonicalURL.deletingLastPathComponent()
                    .standardizedFileURL.resolvingSymlinksInPath(),
                sequence: startSequence
            )
        }
        if indexMutationSequence != startSequence {
            // One of this repository's fallback saves landed while entries were decoded. Its
            // records and index are newer than this pass; the next pass reconciles the rest.
            for (name, entry) in fallbackCaseFiles where entry.sequence > startSequence {
                next[name] = entry
            }
            fallbackCaseFiles = next
            indexMutationSequence += 1
            return cachedFallbackIndex ?? index
        }
        if Set(next.keys) != Set(fallbackCaseFiles.keys) { changed = true }
        fallbackCaseFiles = next
        if !indexIsCurrent {
            cachedFallbackIndex = index
            fallbackIndexObservation = indexStamp.map {
                StampObservation(stamp: $0, observedAt: observedAt)
            }
        }
        if changed { indexMutationSequence += 1 }
        return index
    }

    /// Whether the fallback index on disk is still the one the last pass decoded. Read before
    /// a fallback write so the write can tell whether other writers changed fallback cases.
    private var fallbackIndexIsCurrent: Bool {
        cachedFallbackIndex != nil
            && isTrustworthy(fallbackIndexObservation, for: freshStamp(fallbackIndexURL))
    }

    private func recordOwnCaseWrite(
        _ analysisCase: AnalysisCase,
        at documentURL: URL,
        storage: AnalysisCaseStorage
    ) {
        indexMutationSequence += 1
        let observation = freshStamp(documentURL).map {
            StampObservation(stamp: $0, observedAt: fileIO.now(), isOwnWrite: true)
        }
        // Index what a reader would decode: the store writes ISO-8601 dates without fractions.
        let record = CaseRecord(analysisCase: Self.asPersisted(analysisCase), storage: storage)
        let name = documentURL.lastPathComponent
        switch storage {
        case .folderLocal:
            localCaseFiles[name] = IndexedCaseFile(
                observation: observation,
                record: record,
                recordedFolderURL: sourceFolderURL,
                sequence: indexMutationSequence
            )
        case .applicationSupport:
            fallbackCaseFiles[name] = IndexedCaseFile(
                observation: observation,
                record: record,
                recordedFolderURL: analysisCase.source.canonicalURL.deletingLastPathComponent()
                    .standardizedFileURL.resolvingSymlinksInPath(),
                sequence: indexMutationSequence
            )
        }
    }

    /// `priorIndexWasCurrent` is false when another writer changed the index since the last
    /// pass; their case files are then re-stamped on the next pass instead of being trusted.
    private func recordOwnFallbackIndexWrite(
        _ index: AnalysisCaseFallbackIndex,
        priorIndexWasCurrent: Bool
    ) {
        indexMutationSequence += 1
        cachedFallbackIndex = index
        fallbackIndexObservation = priorIndexWasCurrent
            ? freshStamp(fallbackIndexURL).map {
                StampObservation(stamp: $0, observedAt: fileIO.now(), isOwnWrite: true)
            }
            : nil
    }

    private func cachedFolderMap(
        at url: URL,
        storage: AnalysisCaseStorage
    ) async -> AnalysisFolderMapDocument? {
        let cache = storage == .folderLocal ? localFolderMapCache : fallbackFolderMapCache
        let stamp = freshStamp(url)
        if let cache, cache.url == url, isTrustworthy(cache.observation, for: stamp) {
            return cache.document
        }
        let observedAt = fileIO.now()
        let store = AtomicJSONDocumentStore<AnalysisFolderMapDocument>(documentURL: url)
        var document: AnalysisFolderMapDocument?
        if let loaded = try? await store.load(), case .document(let loadedDocument, _) = loaded {
            document = loadedDocument
        }
        let current = storage == .folderLocal ? localFolderMapCache : fallbackFolderMapCache
        if let current, current.url == url, current.token != cache?.token {
            // This repository saved the map while it was being read; the save is newer.
            return current.document
        }
        let updated = stamp.map {
            CachedFolderMap(
                url: url,
                observation: StampObservation(stamp: $0, observedAt: observedAt),
                document: document
            )
        }
        if storage == .folderLocal {
            localFolderMapCache = updated
        } else {
            fallbackFolderMapCache = updated
        }
        return document
    }

    private func recordOwnFolderMapWrite(
        _ document: AnalysisFolderMapDocument,
        at url: URL,
        storage: AnalysisCaseStorage
    ) {
        let cache = CachedFolderMap(
            url: url,
            observation: freshStamp(url).map {
                StampObservation(stamp: $0, observedAt: fileIO.now(), isOwnWrite: true)
            },
            document: Self.asPersisted(document)
        )
        if storage == .folderLocal {
            localFolderMapCache = cache
        } else {
            fallbackFolderMapCache = cache
        }
    }

    private func loadCaseRecord(
        at url: URL,
        storage: AnalysisCaseStorage
    ) async -> CaseRecord? {
        caseDecodeCount += 1
        let store = AtomicJSONDocumentStore<AnalysisCase>(documentURL: url)
        guard let loaded = try? await store.load(),
              case .document(let analysisCase, _) = loaded else {
            return nil
        }
        return CaseRecord(analysisCase: analysisCase, storage: storage)
    }

    private func caseURLs(in directory: URL) -> [URL] {
        (try? fileIO.directoryContents(directory))?
            .filter { $0.lastPathComponent.hasSuffix(".analysis.json") } ?? []
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
        return fileIO.isKnownReadOnly(sourceFolderURL)
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

    /// The document as a later load decodes it. `AtomicJSONDocumentStore` encodes dates as
    /// ISO-8601 without fractional seconds, so an indexed copy of a just-saved document must be
    /// round-tripped the same way to compare and sort exactly like one read from disk.
    private static func asPersisted<Document: Codable>(_ document: Document) -> Document {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? encoder.encode(document),
              let decoded = try? decoder.decode(Document.self, from: data) else { return document }
        return decoded
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

/// One owner spans the fallback document and its index update across actor suspension. Different
/// roots and portable folder-local writes remain independent. No task wrappers are needed, so the
/// admitted operation retains caller task locals and returns durable evidence despite cancellation.
actor AnalysisCaseFallbackWriteAdmission {
    static let shared = AnalysisCaseFallbackWriteAdmission()
    private var activeKeys: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func withAccess<Value: Sendable>(
        to canonicalIndexURL: URL,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        if activeKeys.contains(canonicalIndexURL) {
            await withCheckedContinuation {
                waiters[canonicalIndexURL, default: []].append($0)
            }
        } else {
            activeKeys.insert(canonicalIndexURL)
        }
        defer { release(canonicalIndexURL) }
        // A cancelled waiter releases its transferred ownership before doing any storage work.
        try Task.checkCancellation()
        return try await operation()
    }

    func waiterCount(for canonicalIndexURL: URL) -> Int {
        waiters[canonicalIndexURL]?.count ?? 0
    }

    private func release(_ key: URL) {
        guard var pending = waiters[key], !pending.isEmpty else {
            waiters[key] = nil
            activeKeys.remove(key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        next.resume()
    }
}

/// Preparation and later repository operations share the same retained serial executor.
/// This separate actor keeps the repository's initializer entirely free of filesystem access.
private actor AnalysisCaseRepositoryPreparation {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    init(filesystemQueue: DispatchSerialQueue) {
        self.filesystemQueue = filesystemQueue
    }

    func prepare(
        sourceFolderURL: URL,
        applicationSupportURL: URL?,
        fileIO: AnalysisCaseRepositoryFileIO
    ) throws -> (sourceFolderURL: URL, applicationSupportURL: URL) {
        try Task.checkCancellation()
        let canonicalRoot = fileIO.canonicalSourceFolder(sourceFolderURL)
        try Task.checkCancellation()
        let fallbackRoot = applicationSupportURL ?? fileIO.defaultApplicationSupportURL()
        try Task.checkCancellation()
        // Bind storage itself to the same captured root used by fallback admission. A custom
        // Application Support symlink must not reroute a queued transaction to another index.
        let canonicalFallbackRoot = fallbackRoot.standardizedFileURL.resolvingSymlinksInPath()
        try Task.checkCancellation()
        return (canonicalRoot, canonicalFallbackRoot)
    }
}

private nonisolated struct CaseRecord: Sendable {
    let analysisCase: AnalysisCase
    let storage: AnalysisCaseStorage
}

/// A file or directory stamp and when it was read. An observation made by this repository's
/// own write is trusted at once; others only once the stamp has settled.
private nonisolated struct StampObservation: Sendable {
    let stamp: AnalysisFileStamp
    let observedAt: Date
    var isOwnWrite = false
}

private nonisolated struct IndexedCaseFile: Sendable {
    let observation: StampObservation?
    /// Nil when the file could not be decoded; it is retried once its stamp changes.
    let record: CaseRecord?
    /// Canonical folder of the case's source, resolved once when the entry is indexed.
    let recordedFolderURL: URL
    /// Index mutation sequence when the entry was produced.
    let sequence: Int
}

private nonisolated struct CachedFolderMap: Sendable {
    let url: URL
    let observation: StampObservation?
    let document: AnalysisFolderMapDocument?
    let token = UUID()
}

private nonisolated struct CaseLookup: Sendable {
    let sequence: Int
    let records: [CaseRecord]
    /// Local cases plus fallback cases recorded for this folder, in index order.
    let folderRecordIndices: [Int]
    let bySHA256: [String: [Int]]
    let byFileID: [SourceImageRevision.FileResourceIdentifier: [Int]]
    let byPath: [URL: [Int]]
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
