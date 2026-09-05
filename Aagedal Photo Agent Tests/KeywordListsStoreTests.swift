import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("KeywordListsStore")
struct KeywordListsStoreTests {

    private func clearAllStoreFiles() {
        let store = KeywordListsStore.shared
        for type in QuickListType.allCases {
            store.delete(.quick(type))
        }
        for field in ApprovedListField.allCases {
            store.delete(.approved(field))
        }
        store.delete(.structured)
    }

    @Test("writeEntries dedupes, trims, and round-trips through readEntries")
    func writeEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.keywords)
        try KeywordListsStore.shared.writeEntries(
            ["  Berlin  ", "Paris", "", "Berlin", "London"],
            to: key
        )
        let entries = KeywordListsStore.shared.readEntries(key)
        #expect(entries == ["Berlin", "Paris", "London"])
    }

    @Test("writeText preserves the exact text including tabs and braces")
    func writeTextPreservesVerbatim() throws {
        clearAllStoreFiles()
        let text = "animals\n\tlivestock\n\t\t{cattle}\n\t[REPTILE]\n\t\talligator\n"
        try KeywordListsStore.shared.writeText(text, to: .structured)
        #expect(KeywordListsStore.shared.readText(.structured) == text)
    }

    @Test("exists reflects writes and deletes")
    func existsContract() throws {
        clearAllStoreFiles()
        let key = KeywordListKey.approved(.keywords)
        #expect(!KeywordListsStore.shared.exists(key))
        try KeywordListsStore.shared.writeEntries(["a"], to: key)
        #expect(KeywordListsStore.shared.exists(key))
        KeywordListsStore.shared.delete(key)
        #expect(!KeywordListsStore.shared.exists(key))
    }

    @Test("readEntries returns empty array when file is missing")
    func readEntriesMissingFile() {
        clearAllStoreFiles()
        #expect(KeywordListsStore.shared.readEntries(.quick(.event)) == [])
    }

    @Test("importEntries from a temp file writes through to the store")
    func importEntriesRoundTrip() throws {
        clearAllStoreFiles()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kl-test-\(UUID().uuidString).txt")
        try "Alice\nBob\nCharlie\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = try KeywordListsStore.shared.importEntries(from: url, into: .quick(.personShown))
        #expect(entries == ["Alice", "Bob", "Charlie"])
        #expect(KeywordListsStore.shared.readEntries(.quick(.personShown)) == ["Alice", "Bob", "Charlie"])
    }

    @Test("Write posts a keywordListChanged notification carrying the key")
    func notificationOnWrite() async throws {
        clearAllStoreFiles()
        let key = KeywordListKey.quick(.credit)

        // Tests run in parallel and the observer listens with `object: nil`, so it
        // can receive `.keywordListChanged` posts triggered by *other* suites. Filter
        // to our own key and resume exactly once — otherwise a second matching post
        // resumes the continuation twice (SWIFT TASK CONTINUATION MISUSE → crash).
        nonisolated final class Box: @unchecked Sendable {
            var token: NSObjectProtocol?
            var resumed = false
        }
        let box = Box()

        // Set up a one-shot wait for the notification before triggering the write.
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<KeywordListKey?, Never>) in
            box.token = NotificationCenter.default.addObserver(
                forName: .keywordListChanged,
                object: nil,
                queue: .main  // callbacks serialize here, so the `resumed` guard is race-free
            ) { note in
                let observed = note.userInfo?[KeywordListsStore.changedKeyUserInfo] as? KeywordListKey
                guard observed == key, !box.resumed else { return }
                box.resumed = true
                if let token = box.token {
                    NotificationCenter.default.removeObserver(token)
                }
                continuation.resume(returning: observed)
            }
            DispatchQueue.main.async {
                try? KeywordListsStore.shared.writeEntries(["Acme"], to: key)
            }
        }
        #expect(observed == key)
    }
}

@Suite("Keyword-list backup preview filesystem boundary")
struct KeywordListBackupPreviewServiceTests {
    @Test("a complete immutable preview is read away from the main actor")
    @MainActor
    func completePreviewRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/backup.txt")
        let bytes = Data("People\n\tAlice\n".utf8)
        let requestID = UUID()
        let probe = KeywordListBackupPreviewReaderProbe(data: bytes)
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .loaded(KeywordListBackupPreviewSnapshot(
            requestID: requestID,
            sourceURL: source,
            text: "People\n\tAlice\n",
            byteCount: bytes.count
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled preview never enters the synchronous reader")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = KeywordListBackupPreviewReaderProbe(data: Data("unused".utf8))
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )
        let task = Task {
            await Task.yield()
            return try await service.loadPreview(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping previews serialize and cancellation stops a queued read")
    func serializedQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.txt")
        let secondURL = URL(fileURLWithPath: "/virtual/second.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingKeywordListBackupPreviewReaderProbe()
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader(read: probe.read)
        )
        let first = Task {
            try await service.loadPreview(from: firstURL, requestID: firstID)
        }
        try await probe.waitUntilFirstReadStarts()
        let second = Task {
            try await service.loadPreview(from: secondURL, requestID: secondID)
        }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(KeywordListBackupPreviewSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            text: "first",
            byteCount: Data("first".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeRead(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("cancellation during a non-preemptible read reports evidence without text")
    func cancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/slow.txt")
        let bytes = Data("complete bytes".utf8)
        let requestID = UUID()
        let service = KeywordListBackupPreviewService(
            reader: KeywordListBackupPreviewReader { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes
            }
        )

        let result = try await Task {
            try await service.loadPreview(from: source, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
    }

    @Test("the backup sheet awaits the boundary and rejects stale completion")
    func backupSheetSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListBackupsSheet.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func loadPreview("))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func cancelPreview()"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "try await KeywordListBackupPreviewService.shared.loadPreview("
        ))
        #expect(functionSource.contains("guard previewRequestID == requestID,"))
        #expect(functionSource.contains("previewedVersion?.id == version.id"))
        #expect(functionSource.contains("case .cancelledBeforeRead, .cancelledAfterRead:"))
        #expect(source.contains(".onDisappear {\n            cancelPreview()"))
        #expect(!source.contains("String(contentsOf: version.url"))
    }
}

@Suite("Keyword-list backup inventory and restore filesystem boundary")
struct KeywordListBackupFileServiceTests {
    @Test("inventory returns an immutable sorted snapshot away from the main actor")
    @MainActor
    func inventoryRunsOffMainActor() async {
        let directory = URL(fileURLWithPath: "/virtual/backups")
        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.txt")
        let requestID = UUID()
        let probe = KeywordListBackupFileIOProbe(files: [older, newer])
        probe.snapshots = [
            older: KeywordListBackupFileSnapshot(
                url: older,
                date: Date(timeIntervalSince1970: 10),
                text: "older",
                byteCount: 5
            ),
            newer: KeywordListBackupFileSnapshot(
                url: newer,
                date: Date(timeIntervalSince1970: 20),
                text: "newer",
                byteCount: 5
            )
        ]
        let service = KeywordListBackupFileService(io: probe.fileIO)

        let result = await Task {
            await service.inventory(
                directories: [KeywordListBackupDirectoryRequest(
                    identifier: "structured/keywords.txt",
                    directoryURL: directory
                )],
                requestID: requestID
            )
        }.value

        #expect(result == .loaded(KeywordListBackupInventorySnapshot(
            requestID: requestID,
            directories: [KeywordListBackupDirectorySnapshot(
                identifier: "structured/keywords.txt",
                versions: [probe.snapshots[newer]!, probe.snapshots[older]!]
            )]
        )))
        #expect(probe.contentsInvocationCount == 1)
        #expect(probe.inspectInvocationCount == 2)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a cancelled queued inventory does not enter filesystem enumeration")
    func queuedInventoryCancellation() async throws {
        let probe = BlockingKeywordListBackupFileIOProbe()
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let firstID = UUID()
        let secondID = UUID()
        let request = [KeywordListBackupDirectoryRequest(
            identifier: "quick/keywords.txt",
            directoryURL: URL(fileURLWithPath: "/virtual/backups")
        )]
        let first = Task { await service.inventory(directories: request, requestID: firstID) }
        try await probe.waitUntilFirstEnumerationStarts()
        let second = Task { await service.inventory(directories: request, requestID: secondID) }
        second.cancel()
        probe.releaseFirstEnumeration()

        _ = await first.value
        let secondResult = await second.value

        #expect(secondResult == .cancelled(
            requestID: secondID,
            completedDirectoryCount: 0,
            discoveredVersionCount: 0
        ))
        #expect(probe.contentsInvocationCount == 1)
        #expect(probe.maximumConcurrentEnumerations == 1)
    }

    @Test("restore reports cancellation after read and does not commit")
    func restoreCancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/source.txt")
        let destination = URL(fileURLWithPath: "/virtual/destination.txt")
        let bytes = Data("restored".utf8)
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = bytes
        probe.cancelDuringRead = true
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let requestID = UUID()

        let result = try await Task {
            try await service.restore(
                from: source,
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
        #expect(probe.writeInvocationCount == 0)
    }

    @Test("restore exposes cancellation observed after its durable commit")
    func restoreDurableAfterCancellation() async throws {
        let source = URL(fileURLWithPath: "/virtual/source.txt")
        let destination = URL(fileURLWithPath: "/virtual/destination.txt")
        let bytes = Data("restored".utf8)
        let probe = KeywordListBackupFileIOProbe(files: [])
        probe.readDataResult = bytes
        probe.cancelDuringWrite = true
        let service = KeywordListBackupFileService(io: probe.fileIO)
        let requestID = UUID()

        let result = try await Task {
            try await service.restore(
                from: source,
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .restored(KeywordListBackupRestoreCommit(
            requestID: requestID,
            sourceURL: source,
            destinationURL: destination,
            byteCount: bytes.count,
            cancellationObservedAfterCommit: true
        )))
        #expect(probe.writtenData == bytes)
        #expect(probe.writtenURL == destination)
    }

    @Test("the backup sheet awaits inventory and restore with stale-result guards")
    func backupSheetAsyncSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListBackupsSheet.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("await KeywordListsBackupService.shared.allVersionsByKey("))
        #expect(source.contains("guard inventoryRequestID == requestID else { return }"))
        #expect(source.contains("try await KeywordListsBackupService.shared.restore("))
        #expect(source.contains("guard restoreRequestID == requestID else { return }"))
        #expect(!source.contains("KeywordListsBackupService.shared.restore(version)"))
    }
}

private nonisolated final class KeywordListBackupPreviewReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var count = 0
    private var observedMainThread = false

    init(data: Data) {
        self.data = data
    }

    func read(_ url: URL) throws -> Data {
        _ = url
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        return data
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private nonisolated final class KeywordListBackupFileIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let files: [URL]
    var snapshots: [URL: KeywordListBackupFileSnapshot] = [:]
    var readDataResult = Data()
    var cancelDuringRead = false
    var cancelDuringWrite = false
    private var contentsCount = 0
    private var inspectCount = 0
    private var writeCount = 0
    private var observedMainThread = false
    private var committedData: Data?
    private var committedURL: URL?

    init(files: [URL]) {
        self.files = files
    }

    var fileIO: KeywordListBackupFileIO {
        KeywordListBackupFileIO(
            contentsOfDirectory: { [self] _ in
                lock.withLock {
                    contentsCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return files
            },
            inspectTextFile: { [self] url in
                lock.withLock {
                    inspectCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                    return snapshots[url]!
                }
            },
            createDirectory: { _ in },
            readData: { [self] _ in
                let (data, shouldCancel) = lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    return (readDataResult, cancelDuringRead)
                }
                if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
                return data
            },
            writeData: { [self] data, url in
                let shouldCancel = lock.withLock {
                    writeCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                    committedData = data
                    committedURL = url
                    return cancelDuringWrite
                }
                if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
            },
            removeItem: { _ in }
        )
    }

    var contentsInvocationCount: Int { lock.withLock { contentsCount } }
    var inspectInvocationCount: Int { lock.withLock { inspectCount } }
    var writeInvocationCount: Int { lock.withLock { writeCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var writtenData: Data? { lock.withLock { committedData } }
    var writtenURL: URL? { lock.withLock { committedURL } }
}

private nonisolated final class BlockingKeywordListBackupFileIOProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var contentsCount = 0
    private var activeEnumerations = 0
    private var maximumActiveEnumerations = 0
    private var firstEnumerationReleased = false

    var fileIO: KeywordListBackupFileIO {
        KeywordListBackupFileIO(
            contentsOfDirectory: { [self] _ in
                condition.lock()
                contentsCount += 1
                activeEnumerations += 1
                maximumActiveEnumerations = max(maximumActiveEnumerations, activeEnumerations)
                condition.broadcast()
                if contentsCount == 1 {
                    while !firstEnumerationReleased { condition.wait() }
                }
                activeEnumerations -= 1
                condition.unlock()
                return []
            },
            inspectTextFile: { url in
                KeywordListBackupFileSnapshot(
                    url: url,
                    date: .distantPast,
                    text: "",
                    byteCount: 0
                )
            },
            createDirectory: { _ in },
            readData: { _ in Data() },
            writeData: { _, _ in },
            removeItem: { _ in }
        )
    }

    func waitUntilFirstEnumerationStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while contentsInvocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListBackupPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstEnumeration() {
        condition.lock()
        firstEnumerationReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var contentsInvocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return contentsCount
    }

    var maximumConcurrentEnumerations: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveEnumerations
    }
}

private enum KeywordListBackupPreviewProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingKeywordListBackupPreviewReaderProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadReleased = false

    func read(_ url: URL) throws -> Data {
        _ = url
        condition.lock()
        readCount += 1
        activeReads += 1
        maximumActiveReads = max(maximumActiveReads, activeReads)
        condition.broadcast()
        if readCount == 1 {
            while !firstReadReleased {
                condition.wait()
            }
        }
        activeReads -= 1
        condition.unlock()
        return Data("first".utf8)
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw KeywordListBackupPreviewProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstRead() {
        condition.lock()
        firstReadReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return readCount
    }

    var maximumConcurrentReads: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveReads
    }
}

@Suite("Keyword list legacy migration filesystem boundary")
struct KeywordListsLegacyMigrationServiceTests {
    private func source(_ id: String, bookmark: Data? = Data([1])) -> KeywordListsLegacyMigrationSource {
        KeywordListsLegacyMigrationSource(
            id: id, bookmarkKey: id, bookmarkData: bookmark, key: .structured,
            destinationURL: URL(fileURLWithPath: "/unused/\(id).txt"), format: .structured
        )
    }

    @Test("Cancellation before execution never resolves or opens legacy files")
    func cancellationBeforeAccess() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in Issue.record("Unexpected source read"); return "" },
            writeTextIfMissing: { _, _ in Issue.record("Unexpected write"); return false },
            readDestination: { _ in Issue.record("Unexpected verification"); return "" }
        ))
        let sources = [source("first")]
        let id = UUID()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.migrate(sources: sources, requestID: id) { _ in
                Issue.record("Unexpected bookmark resolution")
                return nil
            }
        }.value
        #expect(result == KeywordListsLegacyMigrationResult(
            requestID: id, completedIDs: [], writtenIDs: [], failedIDs: [], cancelled: true
        ))
    }

    @Test("Cancellation during source read leaves destination untouched")
    func cancellationDuringRead() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in
                #expect(!Thread.isMainThread)
                withUnsafeCurrentTask { $0?.cancel() }
                return "legacy"
            },
            writeTextIfMissing: { _, _ in Issue.record("Cancelled read must not write"); return false },
            readDestination: { _ in Issue.record("Cancelled read must not verify"); return "" }
        ))
        let sources = [source("first")]
        let result = await Task {
            await service.migrate(sources: sources, requestID: UUID()) { _ in
                URL(fileURLWithPath: "/unused/source.txt")
            }
        }.value
        #expect(result.cancelled)
        #expect(result.completedIDs.isEmpty)
        #expect(result.writtenIDs.isEmpty)
        #expect(result.failedIDs.isEmpty)
    }

    @Test("Cancellation during write preserves verified commit and skips subsequent sources")
    func cancellationDuringWrite() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in "legacy" },
            writeTextIfMissing: { _, url in
                #expect(!Thread.isMainThread)
                #expect(url.lastPathComponent == "first.txt")
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            },
            readDestination: { _ in "legacy" }
        ))
        let sources = [source("first"), source("second")]
        let result = await Task {
            await service.migrate(sources: sources, requestID: UUID()) { _ in
                URL(fileURLWithPath: "/unused/source.txt")
            }
        }.value
        #expect(result.cancelled)
        #expect(result.writtenIDs == ["first"])
        #expect(result.completedIDs == ["first"])
        #expect(result.failedIDs.isEmpty)
    }

    @Test("Read-back failure preserves durable evidence and permits later source migration")
    func verificationFailureContinues() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in "legacy" },
            writeTextIfMissing: { _, _ in true },
            readDestination: { url in url.lastPathComponent == "first.txt" ? "corrupt" : "legacy" }
        ))
        let result = await service.migrate(
            sources: [source("first"), source("second"), source("absent", bookmark: nil)],
            requestID: UUID()
        ) { _ in URL(fileURLWithPath: "/unused/source.txt") }
        #expect(!result.cancelled)
        #expect(result.writtenIDs == ["first", "second"])
        #expect(result.completedIDs == ["second", "absent"])
        #expect(result.failedIDs == ["first"])
    }

    @Test("Managed list created during source read wins over legacy migration")
    func concurrentManagedWriteIsPreserved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacySeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("managed.txt")
        let source = KeywordListsLegacyMigrationSource(
            id: "structured", bookmarkKey: "unused", bookmarkData: Data([1]),
            key: .structured, destinationURL: destination, format: .structured
        )
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in
                try CloudCoordinatedIO.writeText("User's newer list", to: destination)
                return "Legacy list"
            },
            writeTextIfMissing: KeywordListsLegacyMigrationFileAccess.system.writeTextIfMissing,
            readDestination: { _ in Issue.record("Preserved destination needs no verification"); return "" }
        ))
        let result = await service.migrate(sources: [source], requestID: UUID()) { _ in
            root.appendingPathComponent("legacy.txt")
        }
        #expect(result.completedIDs == ["structured"])
        #expect(result.writtenIDs.isEmpty)
        #expect(result.failedIDs.isEmpty)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "User's newer list")
    }

    @Test("An undownloaded cloud placeholder is preserved during migration")
    func placeholderIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyPlaceholder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("managed.txt")
        let placeholder = root.appendingPathComponent(".managed.txt.icloud")
        try Data().write(to: placeholder)
        #expect(try !CloudCoordinatedIO.writeTextIfMissing("Legacy list", to: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: placeholder.path))
    }

    @Test("Unresolvable bookmark remains retryable without touching files")
    func unresolvedBookmark() async {
        let service = KeywordListsLegacyMigrationService(access: .init(
            readSource: { _, _ in Issue.record("Unexpected source read"); return "" },
            writeTextIfMissing: { _, _ in Issue.record("Unexpected write"); return false },
            readDestination: { _ in Issue.record("Unexpected verification"); return "" }
        ))
        let result = await service.migrate(sources: [source("first")], requestID: UUID()) { _ in nil }
        #expect(result.failedIDs == ["first"])
        #expect(result.completedIDs.isEmpty)
        #expect(result.writtenIDs.isEmpty)
        #expect(!result.cancelled)
    }
}
