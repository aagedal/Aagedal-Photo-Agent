import Testing
import Foundation
@testable import Aagedal_Photo_Agent

/// `expand` is the only behaviour that diverges between the keyword tree and the
/// Person Shown tree: keywords add their keyword-ancestors, people do not. The
/// payload otherwise (node name + synonyms) is identical. These tests pin that
/// divergence so the two services can't silently converge.
@MainActor
@Suite("StructuredKeywordService expand semantics")
struct StructuredKeywordServiceTests {

    /// Politicians[container] › Norway[keyword] › "Jonas Gahr Støre"{Store}
    private func samplePath() -> StructuredKeywordPath {
        StructuredKeywordPath(
            ancestors: [
                StructuredKeyword(name: "Politicians", kind: .container),
                StructuredKeyword(name: "Norway", kind: .keyword),
            ],
            node: StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store"])
        )
    }

    @Test("Keyword tree includes keyword-ancestors plus node plus synonyms")
    func keywordExpandIncludesAncestors() {
        let expanded = StructuredKeywordService.shared.expand(samplePath())
        // Container ancestor "Politicians" is dropped; keyword ancestor "Norway" stays.
        #expect(expanded == ["Norway", "Jonas Gahr Støre", "Store"])
    }

    @Test("Person Shown tree writes only the name plus its synonyms — never the category")
    func personExpandExcludesAncestors() {
        let expanded = StructuredKeywordService.personShown.expand(samplePath())
        #expect(expanded == ["Jonas Gahr Støre", "Store"])
        #expect(!expanded.contains("Norway"))
        #expect(!expanded.contains("Politicians"))
    }

    @Test("Activation carries ancestor category names separately from expanded values")
    func activationCarriesCategoryKeywords() {
        let activation = StructuredKeywordService.personShown.activation(samplePath())
        #expect(activation.values == ["Jonas Gahr Støre", "Store"])
        #expect(activation.categoryKeywords == ["Politicians", "Norway"])
        #expect(activation.relatedKeywords.isEmpty)
    }

    @Test("expansion(forName:) matches keyword nodes and synonyms case-insensitively")
    func expansionForName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-expansion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structured)
            try await service.saveTree([
                StructuredKeyword(name: "Politicians", kind: .container, children: [
                    StructuredKeyword(name: "Norway", kind: .keyword, children: [
                        StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store"]),
                    ]),
                ]),
            ])

            #expect(service.expansion(forName: "jonas gahr støre") == ["Norway", "Jonas Gahr Støre", "Store"])
            #expect(service.expansion(forName: "store") == ["Norway", "Jonas Gahr Støre", "Store"])
            // Containers are navigation-only and never expand.
            #expect(service.expansion(forName: "Politicians") == nil)
            #expect(service.expansion(forName: "Not In Tree") == nil)
        }
    }

    @Test("activation(forName:) carries related keywords for node and synonym matches")
    func activationForNameIncludesRelatedKeywords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try await service.saveTree([
                StructuredKeyword(name: "People", kind: .container, children: [
                    StructuredKeyword(
                        name: "Ada Lovelace",
                        kind: .keyword,
                        synonyms: ["Countess of Lovelace"],
                        relatedKeywords: ["mathematician", "computing pioneer"]
                    ),
                ]),
            ])

            #expect(service.activation(forName: "Ada Lovelace")?.values == ["Ada Lovelace", "Countess of Lovelace"])
            #expect(service.activation(forName: "countess of lovelace")?.relatedKeywords == ["mathematician", "computing pioneer"])
        }
    }

    @Test("searchable names include synonyms and canonical resolver maps aliases to node names")
    func searchableNamesAndCanonicalResolver() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-searchable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try await service.saveTree([
                StructuredKeyword(name: "People", kind: .container, children: [
                    StructuredKeyword(name: "Jonas Gahr Støre", kind: .keyword, synonyms: ["Store", "Statsministeren"]),
                    StructuredKeyword(name: "Store", kind: .keyword),
                ]),
            ])

            #expect(service.allSearchableNames() == ["Jonas Gahr Støre", "Store", "Statsministeren"])
            #expect(service.canonicalName(forNameOrSynonym: "statsministeren") == "Jonas Gahr Støre")
            #expect(service.canonicalName(forNameOrSynonym: "Store") == "Jonas Gahr Støre")
            #expect(service.canonicalName(forNameOrSynonym: "People") == nil)
        }
    }

    @Test("Settings import reads and commits away from MainActor with balanced source access")
    func settingsImportUsesSerializedBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let text = "[People]\n\tAlice\n"
            let probe = StructuredKeywordSettingsImportProbe(text: text)
            let service = StructuredKeywordService(
                key: .structured,
                textImportService: TextFileImportService(reader: probe.textReader),
                persistenceService: KeywordListEditorPersistenceService(access: probe.fileAccess)
            )

            try await service.importListURL(URL(fileURLWithPath: "/virtual/people.txt"))
            await Task.yield()

            #expect(probe.scopeStartCount == 1)
            #expect(probe.scopeStopCount == 1)
            #expect(probe.writeCount == 1)
            #expect(probe.committedText == text)
            #expect(!probe.ranOnMainThread)
            #expect(service.rootCount == 1)
            #expect(service.keywordCount == 1)
        }
    }

    @Test("a replacement import prevents an older read from committing")
    func replacementRejectsStaleRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let probe = BlockingStructuredKeywordSettingsImportProbe()
            let service = StructuredKeywordService(
                key: .structured,
                textImportService: TextFileImportService(reader: probe.textReader),
                persistenceService: KeywordListEditorPersistenceService(access: probe.fileAccess)
            )
            let first = Task { @MainActor in
                try await service.importListURL(URL(fileURLWithPath: "/virtual/first.txt"))
            }
            try await probe.waitUntilFirstReadStarts()
            let second = Task { @MainActor in
                try await service.importListURL(URL(fileURLWithPath: "/virtual/second.txt"))
            }
            try await Task.sleep(for: .milliseconds(20))
            probe.releaseFirstRead()

            try await first.value
            try await second.value
            await Task.yield()

            #expect(probe.writeCount == 1)
            #expect(probe.committedText == "Second\n")
            #expect(service.roots.map(\.name) == ["Second"])
        }
    }

    @Test("Settings picker source owns cancellable async import tasks")
    func settingsPickerSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )

        let librarySource = try String(contentsOf: workspace.appendingPathComponent(
            "Aagedal Photo Agent/Views/Settings/StructuredKeywordLibrarySettings.swift"), encoding: .utf8)
        #expect(librarySource.contains("try await TextFileImportService.shared.loadText"))
        #expect(librarySource.contains("importTask?.cancel()"))
        #expect(librarySource.contains("guard !Task.isCancelled"))
        #expect(source.contains("try await settingsViewModel.structuredPersonShown.importListURL(url)"))
        #expect(source.contains("structuredPersonShownImportTask?.cancel()"))
        #expect(source.contains("settingsViewModel.structuredPersonShown.cancelImport()"))
    }
}

private nonisolated final class StructuredKeywordSettingsImportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var starts = 0
    private var stops = 0
    private var writes = 0
    private var writtenText: String?
    private var observedMainThread = false

    init(text: String) {
        self.text = text
    }

    var textReader: TextFileImportReader {
        TextFileImportReader(
            read: { [self] _ in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return Data(text.utf8)
            },
            startAccessing: { [self] _ in
                lock.withLock {
                    starts += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return true
            },
            stopAccessing: { [self] _ in
                lock.withLock {
                    stops += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            }
        )
    }

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { _ in false },
            readData: { _ in Data() },
            writeData: { [self] data, _ in
                lock.withLock {
                    writes += 1
                    writtenText = String(decoding: data, as: UTF8.self)
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
            }
        )
    }

    var scopeStartCount: Int { lock.withLock { starts } }
    var scopeStopCount: Int { lock.withLock { stops } }
    var writeCount: Int { lock.withLock { writes } }
    var committedText: String? { lock.withLock { writtenText } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private enum StructuredKeywordSettingsImportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingStructuredKeywordSettingsImportProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var firstReadStarted = false
    private var firstReadReleased = false
    private var writes = 0
    private var writtenText: String?
    private var writtenURL: URL?

    var textReader: TextFileImportReader {
        TextFileImportReader(read: { [self] url in
            condition.lock()
            if url.lastPathComponent == "first.txt" {
                firstReadStarted = true
                condition.broadcast()
                while !firstReadReleased { condition.wait() }
            }
            condition.unlock()
            return Data((url.lastPathComponent == "first.txt" ? "First\n" : "Second\n").utf8)
        })
    }

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { [self] url in condition.withLock { writtenURL == url } },
            readData: { [self] _ in condition.withLock { Data((writtenText ?? "").utf8) } },
            writeData: { [self] data, url in
                condition.withLock {
                    writes += 1
                    writtenURL = url
                    writtenText = String(decoding: data, as: UTF8.self)
                }
            }
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition.withLock({ firstReadStarted }) {
            guard ContinuousClock.now < deadline else {
                throw StructuredKeywordSettingsImportProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.withLock {
            firstReadReleased = true
            condition.broadcast()
        }
    }

    var committedURL: URL? { condition.withLock { writtenURL } }
    var writeCount: Int { condition.withLock { writes } }
    var committedText: String? { condition.withLock { writtenText } }
}

@MainActor
@Suite("Structured keyword persistence")
struct StructuredKeywordPersistenceTests {
    @Test("Structured loads preserve tabs off MainActor and cancellation suppresses publication")
    func structuredLoadBoundary() async throws {
        let text = "[People]\n\tAda\n\t\t{Countess}\n"
        let service = KeywordListEditorPersistenceService(access: .init(
            itemExists: { _ in #expect(!Thread.isMainThread); return true },
            readData: { _ in #expect(!Thread.isMainThread); return Data(text.utf8) },
            writeData: { _, _ in Issue.record("A load must not write") }
        ))
        let source = URL(fileURLWithPath: "/virtual/structured.txt")
        let requestID = UUID()
        #expect(try await service.loadText(from: source, requestID: requestID) == .loaded(
            requestID: requestID, sourceURL: source, text: text
        ))
        let cancelledService = KeywordListEditorPersistenceService(access: .init(
            itemExists: { _ in true },
            readData: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Data(text.utf8)
            },
            writeData: { _, _ in Issue.record("A load must not write") }
        ))
        let result = try await Task {
            try await cancelledService.loadText(from: source, requestID: requestID)
        }.value
        #expect(result == .cancelled(requestID: requestID))
    }

    @Test("A save cancelled during its write still installs the durable tree")
    func saveAfterCommitCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(persistenceService: KeywordListEditorPersistenceService(access: .init(
                itemExists: { _ in false }, readData: { _ in Data() },
                writeData: { _, _ in
                    #expect(!Thread.isMainThread)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )))
            let saved = await Task {
                try? await service.saveTree([StructuredKeyword(name: "Durable", kind: .keyword)])
            }.value
            #expect(saved == true)
            #expect(service.roots.map(\.name) == ["Durable"])
        }
    }

    @Test("Failed deletion retains the visible tree and propagates the error")
    func deletionFailurePreservesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(persistenceService: KeywordListEditorPersistenceService(access: .init(
                itemExists: { _ in true }, readData: { _ in Data("Keep\n".utf8) },
                writeData: { _, _ in },
                removeItem: { _ in #expect(!Thread.isMainThread); throw CocoaError(.fileWriteNoPermission) }
            )))
            await service.reload()
            #expect(service.roots.map(\.name) == ["Keep"])
            await #expect(throws: CocoaError.self) { try await service.clearList() }
            #expect(service.roots.map(\.name) == ["Keep"])
        }
    }

    @Test("Readable empty trees remain editable while failed reads cannot seed an editor")
    func emptyAndUnreadableSnapshots() async {
        let empty = StructuredKeywordService(persistenceService: KeywordListEditorPersistenceService(access: .init(
            itemExists: { _ in true }, readData: { _ in Data() }, writeData: { _, _ in }
        )))
        await empty.reload()
        #expect(empty.roots.isEmpty)
        #expect(!empty.hasReadFailure)
        let unreadable = StructuredKeywordService(persistenceService: KeywordListEditorPersistenceService(access: .init(
            itemExists: { _ in true }, readData: { _ in throw CocoaError(.fileReadNoPermission) },
            writeData: { _, _ in }
        )))
        await unreadable.reload()
        #expect(unreadable.hasReadFailure)
    }

    @Test("Deleting a structured tree clears its cache only after successful removal")
    func successfulDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService()
            try await service.saveTree([StructuredKeyword(name: "Temporary", kind: .keyword)])
            try await service.clearList()
            #expect(service.roots.isEmpty)
            #expect(service.sourcePath == nil)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("structured/keywords.txt").path))
        }
    }
}

@MainActor
@Suite("Structured keyword route publication")
struct StructuredKeywordRoutePublicationTests {
    @Test("A failed route resolution clears stale keywords and prevents editing the failed snapshot")
    func routeResolutionFailureIsExplicit() async throws {
        let source = URL(fileURLWithPath: "/virtual/structured.txt")
        var failResolution = false
        let service = StructuredKeywordService(
            persistenceService: KeywordListEditorPersistenceService(access: .init(
                itemExists: { _ in true }, readData: { _ in Data("Previous\n".utf8) },
                writeData: { _, _ in Issue.record("A failed load must not write") }
            )),
            storageURL: { _ in source },
            resolveStorageURL: { _ in
                if failResolution { throw CocoaError(.fileReadNoPermission) }
                return source
            }
        )
        await service.reload()
        #expect(service.roots.map(\.name) == ["Previous"])
        failResolution = true
        await service.reload()
        #expect(service.roots.isEmpty)
        #expect(service.sourcePath == nil)
        #expect(service.hasReadFailure)
        #expect(service.loadError != nil)
        failResolution = false
        await service.reload()
        #expect(service.roots.map(\.name) == ["Previous"])
        #expect(!service.hasReadFailure)
        #expect(service.loadError == nil)
    }

    @Test("An import resolves the active destination after a suspended source read")
    func importFollowsRouteAfterSourceRead() async throws {
        let previous = URL(fileURLWithPath: "/virtual/previous.txt")
        let current = URL(fileURLWithPath: "/virtual/current.txt")
        var route = previous
        let probe = BlockingStructuredKeywordSettingsImportProbe()
        let service = StructuredKeywordService(
            textImportService: TextFileImportService(reader: probe.textReader),
            persistenceService: KeywordListEditorPersistenceService(access: probe.fileAccess),
            storageURL: { _ in route }
        )
        let task = Task { try await service.importListURL(URL(fileURLWithPath: "/virtual/first.txt")) }
        defer { probe.releaseFirstRead() }
        try await probe.waitUntilFirstReadStarts()
        route = current
        probe.releaseFirstRead()
        try await task.value
        #expect(probe.committedURL == current)
        #expect(probe.writeCount == 1)
        #expect(service.roots.map(\.name) == ["First"])
        #expect(service.sourcePath == current.path)
    }

    @Test("A reload follows a root change before returning to the editor")
    func reloadFollowsRouteChange() async throws {
        let previous = URL(fileURLWithPath: "/virtual/previous.txt")
        let current = URL(fileURLWithPath: "/virtual/current.txt")
        var route = previous
        let probe = StructuredKeywordReplacementReadProbe()
        let service = StructuredKeywordService(
            persistenceService: KeywordListEditorPersistenceService(access: .init(
                itemExists: { _ in true }, readData: { _ in probe.read() }, writeData: { _, _ in }
            )),
            storageURL: { _ in route }
        )
        let task = Task { await service.reload() }
        defer { probe.release(1); probe.release(2) }
        try await probe.waitForRead(1)
        route = current
        probe.release(1)
        try await probe.waitForRead(2)
        probe.release(2)
        await task.value
        #expect(service.roots.map(\.name) == ["Replacement"])
        #expect(service.sourcePath == current.path)
    }

    @Test("A durable save to the previous root reloads the active route without broadcasting stale text")
    func changedRouteRejectsOldCommit() async throws {
        let previous = URL(fileURLWithPath: "/virtual/previous.txt")
        let current = URL(fileURLWithPath: "/virtual/current.txt")
        var route = previous
        let probe = StructuredKeywordBlockedWriteProbe()
        let service = StructuredKeywordService(
            persistenceService: KeywordListEditorPersistenceService(access: .init(
                itemExists: { _ in true },
                readData: { url in Data((url == current ? "Current\n" : "Previous\n").utf8) },
                writeData: { _, _ in probe.write() }
            )),
            storageURL: { _ in route }
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .keywordListChanged, object: KeywordListsStore.shared, queue: .main
        ) { note in
            guard note.userInfo?[KeywordListsStore.changedSourceIDUserInfo] != nil,
                  note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey == .structured else { return }
            // Other suites may publish concurrently; only the stale content under test is forbidden.
            let text = note.userInfo?[KeywordListsStore.changedTextUserInfo] as? String
            #expect(text != "Obsolete\n")
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let save = Task { try await service.saveTree([StructuredKeyword(name: "Obsolete", kind: .keyword)]) }
        defer { probe.release() }
        try await probe.waitForWrite()
        route = current
        probe.release()
        #expect(try await save.value)
        await service.reload()
        #expect(service.roots.map(\.name) == ["Current"])
        #expect(service.sourcePath == current.path)
    }
}

private nonisolated final class StructuredKeywordBlockedWriteProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func write() {
        condition.lock()
        started = true
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }

    func waitForWrite() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition.withLock({ started }) {
            guard ContinuousClock.now < deadline else { throw StructuredKeywordSettingsImportProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite("Structured keyword reload replacement")
struct StructuredKeywordReloadReplacementTests {
    @Test("Editor reload follows a replacement read before returning its snapshot")
    func reloadAwaitsReplacement() async throws {
        let probe = StructuredKeywordReplacementReadProbe()
        let service = StructuredKeywordService(persistenceService: KeywordListEditorPersistenceService(access: .init(
            itemExists: { _ in true }, readData: { _ in probe.read() }, writeData: { _, _ in }
        )))
        var firstFinished = false
        let first = Task {
            await service.reload()
            firstFinished = true
        }
        defer { probe.release(1); probe.release(2) }
        try await probe.waitForRead(1)
        var replacementStarted = false
        let replacement = Task {
            replacementStarted = true
            await service.reload()
        }
        // Both tasks inherit MainActor: observing this flag means reload has synchronously
        // installed its replacement generation before its first suspension.
        while !replacementStarted { await Task.yield() }
        probe.release(1)
        try await probe.waitForRead(2)
        // Give the cancelled first generation's waiter a chance to resume while the
        // replacement is held at a deterministic filesystem gate.
        for _ in 0..<20 { await Task.yield() }
        #expect(!firstFinished)
        probe.release(2)
        await first.value
        await replacement.value
        #expect(firstFinished)
        #expect(service.roots.map(\.name) == ["Replacement"])
    }
}

private nonisolated final class StructuredKeywordReplacementReadProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = 0
    private var released: Set<Int> = []

    func read() -> Data {
        condition.lock()
        started += 1
        let index = started
        while index <= 2 && !released.contains(index) { condition.wait() }
        condition.unlock()
        return Data((index == 1 ? "Obsolete\n" : "Replacement\n").utf8)
    }

    func release(_ index: Int) {
        condition.withLock { _ = released.insert(index); condition.broadcast() }
    }

    func waitForRead(_ index: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition.withLock({ started >= index }) {
            guard ContinuousClock.now < deadline else { throw StructuredKeywordSettingsImportProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite("Structured keyword libraries and IPTC languages")
struct StructuredKeywordLibraryTests {
    @Test("System language uses all IPTC languages, variants, and US English fallback")
    func languageMatching() {
        let examples: [(String, IPTCMediaTopicsLanguage)] = [
            ("ar-SA", .arabic), ("zh-Hans-CN", .chinese), ("da-DK", .danish),
            ("en-GB", .englishUK), ("en-US", .englishUS), ("fr-CA", .french),
            ("de-DE", .german), ("nb-NO", .norwegianBokmal), ("nn-NO", .norwegianNynorsk),
            ("no-NO", .norwegianBokmal), ("pt-PT", .portuguese), ("pt-BR", .portugueseBrazil),
            ("es-MX", .spanish), ("sv-SE", .swedish), ("ja-JP", .englishUS),
            ("se-NO", .englishUS), // Northern Sami is not Swedish.
        ]
        for (locale, expected) in examples {
            #expect(IPTCMediaTopicsLanguage.resolve(override: nil, preferredLanguages: [locale]) == expected)
        }
        #expect(IPTCMediaTopicsLanguage.resolve(override: "fr", preferredLanguages: ["nb-NO"]) == .french)
        #expect(IPTCMediaTopicsLanguage.resolve(override: nil, preferredLanguages: ["ja-JP", "fr-FR"]) == .englishUS)
    }

    @Test("Single selection, multiple selection, and explicit empty selection round-trip")
    func selectionPersistence() throws {
        var document = StructuredKeywordLibraryDocument()
        #expect(document.activeIDs.contains(StructuredKeywordLibraryDocument.iptcID))
        document.setMode(.single)
        #expect(document.activeIDs == [StructuredKeywordLibraryDocument.iptcID])
        document.setActive(StructuredKeywordLibraryDocument.legacyID, active: true)
        #expect(document.activeIDs == [StructuredKeywordLibraryDocument.legacyID])
        document.setActive(StructuredKeywordLibraryDocument.legacyID, active: false)
        document.languageOverride = "no-NN"
        #expect(try StructuredKeywordLibraryDocument.decode(document.encoded()) == document)
        document.setMode(.multiple)
        document.setActive(StructuredKeywordLibraryDocument.iptcID, active: true)
        document.setActive(StructuredKeywordLibraryDocument.legacyID, active: true)
        #expect(document.activeIDs.count == 2)
    }

    @Test("Malformed libraries cannot overwrite valid state")
    func invalidLibrary() throws {
        var document = StructuredKeywordLibraryDocument()
        document.lists = [.init(id: StructuredKeywordLibraryDocument.iptcID, name: "Collision", text: "wrong")]
        let text = try document.encoded()
        #expect(throws: (any Error).self) { try StructuredKeywordLibraryDocument.decode(text) }
        document = StructuredKeywordLibraryDocument()
        document.schemaVersion = 99
        let future = try document.encoded()
        #expect(throws: (any Error).self) { try StructuredKeywordLibraryDocument.decode(future) }
    }

    @Test("Archive append retains conflicting lists and destination selection")
    func appendLibrary() {
        var existing = StructuredKeywordLibraryDocument()
        existing.lists = [.init(id: "one", name: "Original", text: "First")]
        var imported = StructuredKeywordLibraryDocument()
        imported.lists = [.init(id: "one", name: "Other", text: "Second")]
        let merged = existing.appending(imported)
        #expect(merged.lists.count == 2)
        #expect(Set(merged.lists.map(\.id)).count == 2)
        #expect(merged.activeIDs == existing.activeIDs)
        #expect(existing.appending(existing).lists.count == 1)
    }

    @Test("Bundled vocabulary contains all 13 languages and stable topic identities")
    func bundledVocabulary() throws {
        let url = try #require(Bundle.main.url(forResource: "IPTCMediaTopics", withExtension: "json"))
        let vocabulary = try JSONDecoder().decode(IPTCMediaTopics.self, from: Data(contentsOf: url))
        #expect(vocabulary.roots.count == 17)
        #expect(vocabulary.concepts.count > 1000)
        #expect(Set(vocabulary.concepts.values.flatMap { $0.labels.keys }) == Set(IPTCMediaTopicsLanguage.allCases.map(\.rawValue)))
        let english = vocabulary.tree(language: .englishUS)
        for language in IPTCMediaTopicsLanguage.allCases {
            let roots = vocabulary.tree(language: language)
            #expect(roots.count == 17)
            #expect(roots.map(\.id) == english.map(\.id))
        }
        #expect(vocabulary.tree(language: .norwegianBokmal).first?.name != english.first?.name)
        let untranslated = try #require(vocabulary.concepts["20001396"])
        #expect(untranslated.labels["en-GB"] == "physical security")
    }

    @Test("Active lists aggregate without list-name keywords and survive reload")
    func activeLists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let library = StructuredKeywordLibrary()
            await library.reload()
            #expect(!library.hasReadFailure)
            let legacy = StructuredKeywordService()
            _ = try await legacy.saveTree([StructuredKeyword(name: "Legacy Term", kind: .keyword)])
            let service = StructuredKeywordService(library: library)
            await service.reload()
            #expect(service.search("Legacy Term").count == 1)
            let customID = UUID().uuidString
            _ = try await library.update {
                $0.lists.append(.init(id: customID, name: "Client List", text: "Parent\n\tChild\n\t\t{Alias}\n"))
                $0.setMode(.single)
                $0.setActive(customID, active: true)
                $0.languageOverride = "fr"
            }
            #expect(service.search("Legacy Term").isEmpty)
            #expect(service.expansion(forName: "Alias") == ["Parent", "Child", "Alias"])
            #expect(service.allKeywordNames() == ["Parent", "Child", "Alias"])
            #expect(!service.allKeywordNames().contains("Client List"))
            await library.reload()
            #expect(library.document.activeIDs == [customID])
            #expect(library.effectiveLanguage == .french)
            #expect(service.expansion(forName: "Child") == ["Parent", "Child", "Alias"])
            // Changing selection never rewrites the existing user's tree.
            #expect(try String(contentsOf: root.appendingPathComponent("structured/keywords.txt"), encoding: .utf8).contains("Legacy Term"))
            _ = try await library.update { $0.setActive(customID, active: false) }
            #expect(service.roots.isEmpty)
            let candidates = KeywordListsArchive.inventoryCandidates(for: [.structuredLibrary], rootURL: root)
            #expect(candidates.first?.format == .library)
            #expect(KeywordListsArchive.enumerateKeys().contains(.structuredLibrary))
        }
    }
}

@MainActor
@Suite("IPTC vocabulary updates")
struct IPTCMediaTopicsUpdateTests {
    private func official(release: String = "2026-08-01T12:00:00+00:00", childParent: String = "01000000") -> Data {
        Data("""
        {"uri":"http://cv.iptc.org/newscodes/mediatopic/",
         "dateReleased":"\(release)",
         "hasTopConcept":["http://cv.iptc.org/newscodes/mediatopic/01000000"],
         "conceptSet":[
          {"uri":"http://cv.iptc.org/newscodes/mediatopic/01000000","prefLabel":{"en-US":"Arts","fr":"Arts"}},
          {"uri":"http://cv.iptc.org/newscodes/mediatopic/20000002","prefLabel":{"en-US":"Painting","fr":"Peinture"},"broader":["http://cv.iptc.org/newscodes/mediatopic/\(childParent)"]},
          {"uri":"http://cv.iptc.org/newscodes/mediatopic/20000003","prefLabel":{"en-US":"Retired"},"retired":"2020-01-01T00:00:00+00:00"}
         ]}
        """.utf8)
    }

    @Test("Official downloads retain translations and omit retired topics")
    func decodeDownload() throws {
        let vocabulary = try IPTCMediaTopicsUpdateService.decodeOfficial(official())
        #expect(vocabulary.concepts.count == 2)
        #expect(vocabulary.tree(language: .french).first?.children.first?.name == "Peinture")
        let invalid = official(childParent: "99999999")
        #expect(throws: (any Error).self) { try IPTCMediaTopicsUpdateService.decodeOfficial(invalid) }
    }

    @Test("Successful updates persist offline and automatic checks are throttled")
    func cachedUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iptc-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = official()
        let service = IPTCMediaTopicsUpdateService(cacheURL: root.appendingPathComponent("vocabulary.json"), download: { data })
        let current = try IPTCMediaTopicsUpdateService.decodeOfficial(official(release: "2026-07-02T12:00:00+00:00"))
        let now = Date()
        let updated = try #require(try await service.refresh(current: current, force: false, now: now))
        #expect(updated.vocabulary.release == "2026-08-01T12:00:00+00:00")
        #expect(await service.cached()?.vocabulary.release == updated.vocabulary.release)
        #expect(try await service.refresh(current: updated.vocabulary, force: false, now: now.addingTimeInterval(60)) == nil)
        #expect(try await service.refresh(current: updated.vocabulary, force: true, now: now.addingTimeInterval(60)) != nil)
        #expect(try await service.refresh(current: updated.vocabulary, force: false, now: now.addingTimeInterval(8 * 24 * 60 * 60)) != nil)
    }

    @Test("Failed checks preserve the cached vocabulary and older releases cannot downgrade it")
    func failedAndOlderUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iptc-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("vocabulary.json")
        let older = official(release: "2026-07-02T12:00:00+00:00")
        let current = try IPTCMediaTopicsUpdateService.decodeOfficial(official())
        let service = IPTCMediaTopicsUpdateService(cacheURL: url, download: { older })
        _ = try await service.refresh(current: current, force: true)
        #expect(await service.cached()?.vocabulary.release == current.release)
        let failing = IPTCMediaTopicsUpdateService(cacheURL: url, download: { Data("invalid".utf8) })
        await #expect(throws: (any Error).self) { try await failing.refresh(current: current, force: true) }
        #expect(await failing.cached()?.vocabulary.release == current.release)
    }
}
