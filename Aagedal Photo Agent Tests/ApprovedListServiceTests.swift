import Testing
import Foundation
@testable import Aagedal_Photo_Agent

private func makeApprovedListTestDefaults() -> UserDefaults {
    let suiteName = "com.aagedal.photo-agent.tests.approved.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
}

private func makeIsolatedApprovedListService(
    importService: ApprovedListImportService = .shared,
    persistence: KeywordListEditorPersistenceService = .shared
) -> ApprovedListService {
    ApprovedListService(
        importService: importService,
        persistence: persistence,
        defaults: makeApprovedListTestDefaults(),
        startInitialLoad: false,
        observeChanges: false
    )
}

// MARK: - Parser

@Suite("ApprovedListParser")
struct ApprovedListParserTests {

    @Test("Simple TXT, one keyword per line")
    func simpleTxt() {
        let input = "Berlin\nParis\nLondon\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("CRLF line endings are handled")
    func crlfLineEndings() {
        let input = "Berlin\r\nParis\r\nLondon\r\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("Empty lines and # comments are skipped")
    func emptyAndComments() {
        let input = "# Cities of Europe\nBerlin\n\nParis\n  # mid-file comment\nLondon\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("Duplicates preserve first occurrence")
    func duplicatesFirstWins() {
        let input = "Berlin\nBerlin\nberlin\nParis\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        // The parser dedupes by exact string. NFC/case folding is the service's job, not the parser's.
        #expect(result == ["Berlin", "berlin", "Paris"])
    }

    @Test("CSV takes first column only, ignoring extra columns")
    func csvFirstColumn() {
        let input = "Berlin,DE,1\nParis,FR,2\nLondon,UK,3\n"
        let result = ApprovedListParser.parseString(input, csv: true)
        #expect(result == ["Berlin", "Paris", "London"])
    }

    @Test("CSV strips surrounding double quotes on first column")
    func csvStripsQuotes() {
        let input = "\"Berlin\",DE\n\"Saint-Tropez\",FR\nLondon,UK\n"
        let result = ApprovedListParser.parseString(input, csv: true)
        #expect(result == ["Berlin", "Saint-Tropez", "London"])
    }

    @Test("BOM and NBSP are cleaned out")
    func bomAndNbsp() {
        let input = "\u{FEFF}Berlin\nParis\u{00A0}Mitte\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris Mitte"])
    }

    @Test("Empty file produces empty result")
    func emptyFile() {
        let result = ApprovedListParser.parseString("", csv: false)
        #expect(result.isEmpty)
    }

    @Test("Whitespace-only lines are skipped")
    func whitespaceOnlyLines() {
        let input = "Berlin\n   \n\t\nParis\n"
        let result = ApprovedListParser.parseString(input, csv: false)
        #expect(result == ["Berlin", "Paris"])
    }
}

// MARK: - Import filesystem boundary

@Suite("Approved-list import filesystem boundary")
struct ApprovedListImportServiceTests {
    @Test("a complete import runs off MainActor and returns immutable commit evidence")
    @MainActor
    func completeImportRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/approved.csv")
        let destination = URL(fileURLWithPath: "/virtual/store/keywords.txt")
        let sourceData = Data("Berlin,DE\nParis,FR\nBerlin,duplicate\n".utf8)
        let requestID = UUID()
        let probe = ApprovedListImportAccessProbe(sourceData: sourceData)
        let service = ApprovedListImportService(access: probe.fileAccess)

        let result = try await service.importEntries(
            from: source,
            to: destination,
            requestID: requestID
        )

        #expect(result == .committed(ApprovedListImportCommit(
            requestID: requestID,
            sourceURL: source,
            destinationURL: destination,
            entries: ["Berlin", "Paris"],
            sourceByteCount: sourceData.count,
            committedByteCount: Data("Berlin\nParis\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(probe.writtenData == Data("Berlin\nParis\n".utf8))
        #expect(probe.writeDestination == destination)
        #expect(probe.startAccessCount == 1)
        #expect(probe.stopAccessCount == 1)
        #expect(!probe.ranFilesystemCallOnMainThread)
    }

    @Test("a pre-cancelled import performs no filesystem access")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = ApprovedListImportAccessProbe(sourceData: Data("unused".utf8))
        let service = ApprovedListImportService(access: probe.fileAccess)
        let task = Task {
            await Task.yield()
            return try await service.importEntries(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                to: URL(fileURLWithPath: "/virtual/store.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeAccess(requestID: requestID))
        #expect(probe.filesystemCallCount == 0)
    }

    @Test("cancellation during the atomic write still reports a committed destination")
    func cancellationDuringWriteIsCommitted() async throws {
        let source = URL(fileURLWithPath: "/virtual/approved.txt")
        let destination = URL(fileURLWithPath: "/virtual/store/keywords.txt")
        let sourceData = Data("Berlin\nParis\n".utf8)
        let requestID = UUID()
        let probe = BlockingApprovedListImportWriteProbe(sourceData: sourceData)
        let service = ApprovedListImportService(access: probe.fileAccess)
        let task = Task {
            try await service.importEntries(
                from: source,
                to: destination,
                requestID: requestID
            )
        }
        try await probe.waitUntilWriteStarts()
        task.cancel()
        probe.releaseWrite()
        let result = try await task.value

        guard case let .committed(commit) = result else {
            Issue.record("Expected durable commit evidence after the write returned")
            return
        }
        #expect(commit.requestID == requestID)
        #expect(commit.destinationURL == destination)
        #expect(commit.entries == ["Berlin", "Paris"])
        #expect(commit.cancellationRequestedAfterCommit)
        #expect(probe.writtenData == sourceData)
    }

    @Test("overlapping imports serialize and cancellation prevents a queued read or write")
    func serializedQueuedCancellation() async throws {
        let firstSource = URL(fileURLWithPath: "/virtual/first.txt")
        let secondSource = URL(fileURLWithPath: "/virtual/second.txt")
        let destination = URL(fileURLWithPath: "/virtual/store/keywords.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingApprovedListImportAccessProbe()
        let service = ApprovedListImportService(access: probe.fileAccess)
        let first = Task {
            try await service.importEntries(
                from: firstSource,
                to: destination,
                requestID: firstID
            )
        }
        try await probe.waitUntilFirstReadStarts()
        let second = Task {
            try await service.importEntries(
                from: secondSource,
                to: destination,
                requestID: secondID
            )
        }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .committed(ApprovedListImportCommit(
            requestID: firstID,
            sourceURL: firstSource,
            destinationURL: destination,
            entries: ["first"],
            sourceByteCount: Data("first\n".utf8).count,
            committedByteCount: Data("first\n".utf8).count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(secondResult == .cancelledBeforeAccess(requestID: secondID))
        #expect(probe.readCount == 1)
        #expect(probe.writeCount == 1)
    }

    @Test("a newer service import prevents an older completion from publishing stale cache")
    @MainActor
    func serviceRejectsStaleCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovedListStale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await KeywordListsStoreStorageOverride.$current.withValue(root) {
            let probe = BlockingApprovedListImportAccessProbe(persistWrites: true)
            let filesystem = ApprovedListImportService(access: probe.fileAccess)
            let service = makeIsolatedApprovedListService(importService: filesystem)
            let first = Task { @MainActor in
                try await service.importListURL(
                    URL(fileURLWithPath: "/virtual/first.txt"),
                    for: .keywords
                )
            }
            try await probe.waitUntilFirstReadStarts()
            let second = Task { @MainActor in
                try await service.importListURL(
                    URL(fileURLWithPath: "/virtual/second.txt"),
                    for: .keywords
                )
            }
            // Let the second MainActor call establish its request identity while the first actor
            // operation remains blocked inside its non-preemptible read.
            try await Task.sleep(for: .milliseconds(20))
            probe.releaseFirstRead()

            try await first.value
            try await second.value

            #expect(service.orderedEntries(for: .keywords) == ["second"])
            #expect(KeywordListsStore.shared.readEntries(.approved(.keywords)) == ["second"])
        }
    }

    @Test("approved-list notifications carry immutable entries instead of re-reading on MainActor")
    func notificationPayloadSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let storeSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/KeywordListsStore.swift"
            ),
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/ApprovedListService.swift"
            ),
            encoding: .utf8
        )

        #expect(storeSource.contains("changedEntriesUserInfo"))
        #expect(storeSource.contains("func recordExternalWrite("))
        #expect(storeSource.contains("entries: [String]? = nil"))
        #expect(serviceSource.contains("entries: commit.entries"))
        #expect(serviceSource.contains("sourceID: notificationSourceID"))
        #expect(serviceSource.contains("if let committedEntries"))
        #expect(serviceSource.contains("self.installParsed("))
    }
}

private nonisolated final class ApprovedListImportAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceData: Data
    private var storedWrittenData: Data?
    private var storedWriteDestination: URL?
    private var storedStartAccessCount = 0
    private var storedStopAccessCount = 0
    private var storedFilesystemCallCount = 0
    private var storedRanFilesystemCallOnMainThread = false

    init(sourceData: Data) {
        self.sourceData = sourceData
    }

    var fileAccess: ApprovedListImportFileAccess {
        ApprovedListImportFileAccess(
            startAccessing: { [self] _ in
                recordFilesystemCall()
                lock.withLock { storedStartAccessCount += 1 }
                return true
            },
            stopAccessing: { [self] _ in
                recordFilesystemCall()
                lock.withLock { storedStopAccessCount += 1 }
            },
            fileSize: { [self] _ in
                recordFilesystemCall()
                return Int64(sourceData.count)
            },
            readData: { [self] _ in
                recordFilesystemCall()
                return sourceData
            },
            writeData: { [self] data, destination in
                recordFilesystemCall()
                lock.withLock {
                    storedWrittenData = data
                    storedWriteDestination = destination
                }
            }
        )
    }

    var writtenData: Data? { lock.withLock { storedWrittenData } }
    var writeDestination: URL? { lock.withLock { storedWriteDestination } }
    var startAccessCount: Int { lock.withLock { storedStartAccessCount } }
    var stopAccessCount: Int { lock.withLock { storedStopAccessCount } }
    var filesystemCallCount: Int { lock.withLock { storedFilesystemCallCount } }
    var ranFilesystemCallOnMainThread: Bool {
        lock.withLock { storedRanFilesystemCallOnMainThread }
    }

    private func recordFilesystemCall() {
        let isMainThread = Thread.isMainThread
        lock.withLock {
            storedFilesystemCallCount += 1
            storedRanFilesystemCallOnMainThread =
                storedRanFilesystemCallOnMainThread || isMainThread
        }
    }
}

private nonisolated final class BlockingApprovedListImportWriteProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let sourceData: Data
    private var writeStarted = false
    private var shouldReleaseWrite = false
    private var storedWrittenData: Data?

    init(sourceData: Data) {
        self.sourceData = sourceData
    }

    var fileAccess: ApprovedListImportFileAccess {
        ApprovedListImportFileAccess(
            startAccessing: { _ in false },
            stopAccessing: { _ in },
            fileSize: { [sourceData] _ in Int64(sourceData.count) },
            readData: { [sourceData] _ in sourceData },
            writeData: { [self] data, _ in
                condition.withLock {
                    storedWrittenData = data
                    writeStarted = true
                    condition.broadcast()
                    while !shouldReleaseWrite {
                        condition.wait()
                    }
                }
            }
        )
    }

    var writtenData: Data? { condition.withLock { storedWrittenData } }

    func waitUntilWriteStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition.withLock({ writeStarted }) {
            guard ContinuousClock.now < deadline else {
                throw ApprovedListImportProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseWrite() {
        condition.withLock {
            shouldReleaseWrite = true
            condition.broadcast()
        }
    }
}

private nonisolated enum ApprovedListImportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingApprovedListImportAccessProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let persistWrites: Bool
    private var firstReadStarted = false
    private var shouldReleaseFirstRead = false
    private var storedReadCount = 0
    private var storedWriteCount = 0

    init(persistWrites: Bool = false) {
        self.persistWrites = persistWrites
    }

    var fileAccess: ApprovedListImportFileAccess {
        ApprovedListImportFileAccess(
            startAccessing: { _ in false },
            stopAccessing: { _ in },
            fileSize: { _ in Int64(Data("first\n".utf8).count) },
            readData: { [self] url in
                condition.lock()
                storedReadCount += 1
                if storedReadCount == 1 {
                    firstReadStarted = true
                    condition.broadcast()
                    while !shouldReleaseFirstRead {
                        condition.wait()
                    }
                }
                condition.unlock()
                return Data("\(url.deletingPathExtension().lastPathComponent)\n".utf8)
            },
            writeData: { [self] data, destination in
                condition.withLock { storedWriteCount += 1 }
                if persistWrites {
                    try CloudCoordinatedIO.writeData(data, to: destination)
                }
            }
        )
    }

    var readCount: Int { condition.withLock { storedReadCount } }
    var writeCount: Int { condition.withLock { storedWriteCount } }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition.withLock({ firstReadStarted }) {
            guard ContinuousClock.now < deadline else {
                throw ApprovedListImportProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.withLock {
            shouldReleaseFirstRead = true
            condition.broadcast()
        }
    }
}

// MARK: - Service suggestions/matching

@Suite("ApprovedListService.suggestions (static)")
struct ApprovedListSuggestionTests {

    private let cities = ["Berlin", "Bergen", "Paris", "London", "Saint-Petersburg", "Heidelberg"]

    @Test("Empty prefix returns no suggestions")
    func emptyPrefix() {
        let result = ApprovedListService.suggestions(prefix: "", in: cities)
        #expect(result.isEmpty)
    }

    @Test("Prefix matches come before substring matches")
    func prefixBeforeSubstring() {
        let result = ApprovedListService.suggestions(prefix: "ber", in: cities)
        // Berlin and Bergen are prefix matches; Heidelberg is a substring match.
        let canonicals = result.map(\.canonical)
        #expect(canonicals.firstIndex(of: "Berlin")! < canonicals.firstIndex(of: "Heidelberg")!)
        #expect(canonicals.firstIndex(of: "Bergen")! < canonicals.firstIndex(of: "Heidelberg")!)
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let result = ApprovedListService.suggestions(prefix: "PARIS", in: cities)
        #expect(result.first?.canonical == "Paris")
    }

    @Test("Limit is respected")
    func limitRespected() {
        let many = (0..<100).map { "Item \($0)" }
        let result = ApprovedListService.suggestions(prefix: "Item", in: many, limit: 5)
        #expect(result.count == 5)
    }

    @Test("Match kind correctly labels prefix vs substring")
    func matchKindLabels() {
        let result = ApprovedListService.suggestions(prefix: "berg", in: cities)
        let bergen = result.first(where: { $0.canonical == "Bergen" })
        let heidelberg = result.first(where: { $0.canonical == "Heidelberg" })
        #expect(bergen?.matchKind == .prefix)
        #expect(heidelberg?.matchKind == .substring)
    }
}

// MARK: - Service end-to-end

@Suite("ApprovedListService end-to-end")
struct ApprovedListServiceTests {

    private func tempCSV(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approved-test-\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("contains uses NFC + case-insensitive normalization")
    func containsCaseAndUnicode() async throws {
        let url = try tempCSV("Berlin,DE\nMünchen,DE\nParis,FR\n")
        let service = makeIsolatedApprovedListService()
        try await service.importListURL(url, for: .keywords)

        #expect(service.contains("berlin", in: .keywords))
        #expect(service.contains("BERLIN", in: .keywords))
        #expect(service.contains("München", in: .keywords))
        // NFD-decomposed Munchen should still match NFC-normalized "München".
        let nfd = "Mu\u{0308}nchen"
        #expect(service.contains(nfd, in: .keywords))
        #expect(!service.contains("Tokyo", in: .keywords))

        try? FileManager.default.removeItem(at: url)
    }

    @Test("canonicalCasing returns file-original casing")
    func canonicalCasing() async throws {
        let url = try tempCSV("Berlin\nParis\nNew York\n")
        let service = makeIsolatedApprovedListService()
        try await service.importListURL(url, for: .keywords)

        #expect(service.canonicalCasing(of: "berlin", in: .keywords) == "Berlin")
        #expect(service.canonicalCasing(of: "NEW YORK", in: .keywords) == "New York")
        #expect(service.canonicalCasing(of: "tokyo", in: .keywords) == nil)

        try? FileManager.default.removeItem(at: url)
    }

    @Test("isActive requires both enabled toggle and a populated list")
    func isActiveContract() async throws {
        let url = try tempCSV("Berlin\nParis\n")
        let service = makeIsolatedApprovedListService()
        try await service.importListURL(url, for: .keywords)

        #expect(service.hasListConfigured(for: .keywords))
        #expect(!service.isActive(for: .keywords))

        service.setEnabled(true, for: .keywords)
        #expect(service.isActive(for: .keywords))

        await service.clearList(for: .keywords)
        #expect(!service.isActive(for: .keywords))

        try? FileManager.default.removeItem(at: url)
    }

    @Test("managed cache reload publishes only the actor-loaded snapshot")
    @MainActor
    func managedCacheReloadUsesSerializedBoundary() async {
        let probe = ApprovedListCacheLoadAccessProbe(
            data: Data(" Oslo \n# ignored\nBergen\nOslo\n".utf8)
        )
        let persistence = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let service = ApprovedListService(
            persistence: persistence,
            defaults: makeApprovedListTestDefaults(),
            startInitialLoad: false,
            observeChanges: false
        )

        await service.reloadFromStore(for: .keywords)

        #expect(service.orderedEntries(for: .keywords) == ["Oslo", "Bergen"])
        #expect(service.hasListConfigured(for: .keywords))
        #expect(probe.readInvocationCount >= 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("approved-list cache source never reads or removes through the MainActor store")
    func managedCacheSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/ApprovedListService.swift"
            ),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/SettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("try await persistence.loadEntries("))
        #expect(source.contains("try await persistence.saveEntries("))
        #expect(source.contains("try await persistence.deleteQuickList("))
        #expect(source.contains("guard cacheLoadRequestIDs[field] == requestID"))
        #expect(!source.contains("private func loadFromStore"))
        #expect(!source.contains("store.exists(key)"))
        #expect(!source.contains("store.readEntries(key)"))
        #expect(!source.contains("KeywordListsStore.shared.writeEntries("))
        #expect(!source.contains("KeywordListsStore.shared.delete("))
        #expect(settingsSource.contains("await service.clearList(for: field)"))
    }

    @Test("mode defaults to .warn when unset")
    func modeDefaultsToWarn() {
        let service = makeIsolatedApprovedListService()
        #expect(service.mode(for: .keywords) == .warn)
    }

    @Test("entryCount reflects parsed list size")
    func entryCount() async throws {
        let url = try tempCSV("Berlin\nParis\nLondon\n")
        let service = makeIsolatedApprovedListService()
        try await service.importListURL(url, for: .keywords)
        #expect(service.entryCount(for: .keywords) == 3)
        try? FileManager.default.removeItem(at: url)
    }
}

private nonisolated final class ApprovedListCacheLoadAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var storedReadInvocationCount = 0
    private var storedRanOnMainThread = false

    init(data: Data) {
        self.data = data
    }

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { [self] _ in
                recordAccess()
                return true
            },
            readData: { [self] _ in
                recordAccess()
                lock.withLock { storedReadInvocationCount += 1 }
                return data
            },
            writeData: { _, _ in },
            removeItem: { _ in }
        )
    }

    var readInvocationCount: Int { lock.withLock { storedReadInvocationCount } }
    var ranOnMainThread: Bool { lock.withLock { storedRanOnMainThread } }

    private func recordAccess() {
        let isMainThread = Thread.isMainThread
        lock.withLock {
            storedRanOnMainThread = storedRanOnMainThread || isMainThread
        }
    }
}

// MARK: - Service validation surface

@Suite("ApprovedListService.validate / validateBulk")
struct ApprovedListValidationTests {

    private func tempList(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("approved-validate-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeService(mode: ApprovedListMode, enabled: Bool = true) async throws -> (ApprovedListService, URL) {
        let url = try tempList("Berlin\nMunich\nParis\n")
        let service = makeIsolatedApprovedListService()
        try await service.importListURL(url, for: .keywords)
        service.setMode(mode, for: .keywords)
        service.setEnabled(enabled, for: .keywords)
        return (service, url)
    }

    @Test("validate returns .accept when list is inactive (no enforcement)")
    func validateInactive() async throws {
        let (service, url) = try await makeService(mode: .strict, enabled: false)
        defer { try? FileManager.default.removeItem(at: url) }

        if case .accept = service.validate("anything", in: .keywords) {} else {
            Issue.record("Expected .accept when list is disabled")
        }
    }

    @Test("validate canonicalises approved values regardless of mode")
    func validateCanonicalAllModes() async throws {
        for mode in [ApprovedListMode.suggest, .warn, .strict] {
            let (service, url) = try await makeService(mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            if case .acceptCanonical(let canonical) = service.validate("berlin", in: .keywords) {
                #expect(canonical == "Berlin")
            } else {
                Issue.record("Expected .acceptCanonical(\"Berlin\") in mode \(mode)")
            }
        }
    }

    @Test("validate accepts non-approved values in Suggest and Warn modes")
    func validateNonApprovedSuggestWarn() async throws {
        for mode in [ApprovedListMode.suggest, .warn] {
            let (service, url) = try await makeService(mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            if case .accept = service.validate("Tokyo", in: .keywords) {} else {
                Issue.record("Expected .accept for non-approved in mode \(mode)")
            }
        }
    }

    @Test("validate rejects non-approved values in Strict mode")
    func validateNonApprovedStrict() async throws {
        let (service, url) = try await makeService(mode: .strict)
        defer { try? FileManager.default.removeItem(at: url) }
        if case .reject = service.validate("Tokyo", in: .keywords) {} else {
            Issue.record("Expected .reject for non-approved in Strict mode")
        }
    }

    @Test("validateBulk canonicalises accepted entries and preserves input order")
    func validateBulkCanonicalAndOrder() async throws {
        let (service, url) = try await makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["paris", "BERLIN", "Munich"], in: .keywords)
        #expect(result.accepted == ["Paris", "Berlin", "Munich"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk dedupes case-insensitively across accepted entries")
    func validateBulkDedupe() async throws {
        let (service, url) = try await makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "BERLIN", "Berlin"], in: .keywords)
        #expect(result.accepted == ["Berlin"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk splits accepted vs rejected in Strict mode, preserves input casing of rejects")
    func validateBulkStrictSplit() async throws {
        let (service, url) = try await makeService(mode: .strict)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "Belin", "munich", "tokyo"], in: .keywords)
        #expect(result.accepted == ["Berlin", "Munich"])
        #expect(result.rejected == ["Belin", "tokyo"])
    }

    @Test("validateBulk in Warn mode accepts non-approved without canonicalising")
    func validateBulkWarnPassthrough() async throws {
        let (service, url) = try await makeService(mode: .warn)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["berlin", "Belin"], in: .keywords)
        // "berlin" canonicalises to "Berlin"; "Belin" is non-approved but accepted in Warn.
        #expect(result.accepted == ["Berlin", "Belin"])
        #expect(result.rejected.isEmpty)
    }

    @Test("validateBulk on inactive list accepts everything verbatim")
    func validateBulkInactive() async throws {
        let (service, url) = try await makeService(mode: .strict, enabled: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = service.validateBulk(["foo", "Bar", "baz"], in: .keywords)
        #expect(result.accepted == ["foo", "Bar", "baz"])
        #expect(result.rejected.isEmpty)
    }
}

@Suite("Keyword list legacy migration", .serialized)
@MainActor
struct KeywordListLegacyMigrationTests {
    @Test("Completed sources stay complete while a failed source retries and bookmarks remain")
    func migrationRetriesPerSourceAfterReadBackVerifiedImports() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeywordMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let approvedSource = root.appendingPathComponent("legacy-approved.txt")
        let quickSource = root.appendingPathComponent("legacy-quick.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Berlin\nParis\n".write(to: approvedSource, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let approvedBookmark = Data("approved".utf8)
        let quickBookmark = Data("quick".utf8)
        let defaults = UserDefaults.standard
        let approvedKey = ApprovedListField.keywords.bookmarkKey
        let quickKey = QuickListType.keywords.bookmarkKey
        let legacyBookmarkKeys =
            ApprovedListField.allCases.map(\.bookmarkKey)
            + QuickListType.allCases.map(\.bookmarkKey)
            + [UserDefaultsKeys.structuredKeywordsBookmark]
        let migrationKeys = [
            UserDefaultsKeys.keywordListsMigratedVersion,
            UserDefaultsKeys.keywordListsMigrationCompletedKeys,
        ] + legacyBookmarkKeys
        let previous = Dictionary(uniqueKeysWithValues: migrationKeys.map { ($0, defaults.object(forKey: $0)) })
        let migrationNotices = MigrationRecoveryNoticeCenter()
        KeywordListsStore.migrationRecoveryNotices = migrationNotices
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            KeywordListsStore.legacyBookmarkResolver = { data in
                var isStale = false
                return try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            KeywordListsStore.migrationRecoveryNotices = .shared
        }

        for key in migrationKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(approvedBookmark, forKey: approvedKey)
        defaults.set(quickBookmark, forKey: quickKey)
        KeywordListsStore.legacyBookmarkResolver = { data in
            switch data {
            case approvedBookmark: approvedSource
            case quickBookmark: quickSource
            default: nil
            }
        }

        try KeywordListsStoreStorageOverride.$current.withValue(root.appendingPathComponent("store")) {
            let store = KeywordListsStore.shared
            store.migrateLegacyBookmarksIfNeeded()

            #expect(defaults.integer(forKey: UserDefaultsKeys.keywordListsMigratedVersion) == 0)
            #expect(store.readEntries(.approved(.keywords)) == ["Berlin", "Paris"])
            #expect(
                defaults.stringArray(forKey: UserDefaultsKeys.keywordListsMigrationCompletedKeys)?
                    .contains("approved:keywords") == true
            )
            #expect(migrationNotices.notice?.affectedCategories == [.keywordLists])
            #expect(migrationNotices.notice?.message.contains("Keyword Lists") == true)
            #expect(migrationNotices.notice?.message.contains(quickSource.path) == false)

            // A completed source must not be re-imported while the failed source retries.
            try "Changed\n".write(to: approvedSource, atomically: true, encoding: .utf8)
            try "Fast One\nFast Two\n".write(to: quickSource, atomically: true, encoding: .utf8)
            store.migrateLegacyBookmarksIfNeeded()

            #expect(store.readEntries(.approved(.keywords)) == ["Berlin", "Paris"])
            #expect(store.readEntries(.quick(.keywords)) == ["Fast One", "Fast Two"])
            #expect(defaults.integer(forKey: UserDefaultsKeys.keywordListsMigratedVersion) == 1)
            #expect(defaults.data(forKey: approvedKey) == approvedBookmark)
            #expect(defaults.data(forKey: quickKey) == quickBookmark)
            #expect(migrationNotices.notice == nil)
        }
    }
}
