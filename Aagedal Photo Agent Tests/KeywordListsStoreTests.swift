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
        #expect(source.contains(".onDisappear { cancelPreview() }"))
        #expect(!source.contains("String(contentsOf: version.url"))
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
        let deadline = ContinuousClock.now + .seconds(5)
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
