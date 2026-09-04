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
    func expansionForName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-expansion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structured)
            try service.saveTree([
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
    func activationForNameIncludesRelatedKeywords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try service.saveTree([
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
    func searchableNamesAndCanonicalResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("structured-service-searchable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try KeywordListsStoreStorageOverride.$current.withValue(root) {
            let service = StructuredKeywordService(key: .structuredPersonShown, includesAncestors: false)
            try service.saveTree([
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
