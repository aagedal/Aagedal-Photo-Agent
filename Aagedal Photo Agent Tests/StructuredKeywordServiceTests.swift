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

        #expect(source.contains("try await settingsViewModel.structuredKeywords.importListURL(url)"))
        #expect(source.contains("try await settingsViewModel.structuredPersonShown.importListURL(url)"))
        #expect(source.contains("structuredKeywordsImportTask?.cancel()"))
        #expect(source.contains("structuredPersonShownImportTask?.cancel()"))
        #expect(source.contains("settingsViewModel.structuredKeywords.cancelImport()"))
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
            itemExists: { _ in false },
            readData: { _ in Data() },
            writeData: { [self] data, _ in
                condition.withLock {
                    writes += 1
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
