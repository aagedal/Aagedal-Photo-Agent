import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Keyword-list editor filesystem boundary")
struct KeywordListEditorPersistenceServiceTests {
    @Test("load returns a complete normalized snapshot away from MainActor")
    @MainActor
    func loadRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/quick-list.txt")
        let bytes = Data(" Berlin \n# ignored\nParis\nBerlin\n\n".utf8)
        let probe = KeywordListEditorFileAccessProbe(readData: bytes)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.loadEntries(from: source, requestID: requestID)

        #expect(result == .loaded(KeywordListEditorLoadSnapshot(
            requestID: requestID,
            sourceURL: source,
            entries: ["Berlin", "Paris"],
            byteCount: bytes.count
        )))
        #expect(probe.existsInvocationCount == 1)
        #expect(probe.readInvocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("missing file returns immutable evidence without entering the reader")
    func missingFile() async throws {
        let source = URL(fileURLWithPath: "/virtual/missing.txt")
        let probe = KeywordListEditorFileAccessProbe(itemExists: false)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await service.loadEntries(from: source, requestID: requestID)

        #expect(result == .missing(requestID: requestID, sourceURL: source))
        #expect(probe.existsInvocationCount == 1)
        #expect(probe.readInvocationCount == 0)
    }

    @Test("a pre-cancelled load performs no filesystem access")
    func preCancelledLoad() async throws {
        let probe = KeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()
        let task = Task {
            await Task.yield()
            return try await service.loadEntries(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeAccess(requestID: requestID))
        #expect(probe.existsInvocationCount == 0)
        #expect(probe.readInvocationCount == 0)
    }

    @Test("queued editor operations serialize and cancellation prevents the queued read")
    func serializationAndQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.txt")
        let secondURL = URL(fileURLWithPath: "/virtual/second.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingKeywordListEditorFileAccessProbe()
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)

        let first = Task { try await service.loadEntries(from: firstURL, requestID: firstID) }
        try await probe.waitUntilFirstReadStarts()
        let second = Task { try await service.loadEntries(from: secondURL, requestID: secondID) }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(KeywordListEditorLoadSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            entries: ["first"],
            byteCount: Data("first\n".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeAccess(requestID: secondID))
        #expect(probe.readInvocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("save returns exact normalized durable-commit evidence")
    func saveCommitEvidence() async throws {
        let destination = URL(fileURLWithPath: "/virtual/event.txt")
        let probe = KeywordListEditorFileAccessProbe(cancelDuringWrite: true)
        let service = KeywordListEditorPersistenceService(access: probe.fileAccess)
        let requestID = UUID()

        let result = try await Task {
            try await service.saveEntries(
                [" Oslo ", "Bergen", "", "Oslo"],
                to: destination,
                requestID: requestID
            )
        }.value

        #expect(result == .committed(KeywordListEditorSaveCommit(
            requestID: requestID,
            destinationURL: destination,
            entries: ["Oslo", "Bergen"],
            byteCount: Data("Oslo\nBergen\n".utf8).count,
            cancellationRequestedAfterCommit: true
        )))
        #expect(probe.writtenData == Data("Oslo\nBergen\n".utf8))
        #expect(probe.writtenURL == destination)
    }

    @Test("SwiftUI editor awaits the owner and rejects stale load and save publication")
    func editorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/KeywordListEditor.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "try await KeywordListEditorPersistenceService.shared.loadEntries("
        ))
        #expect(source.contains(
            "try await KeywordListEditorPersistenceService.shared.saveEntries("
        ))
        #expect(source.contains("guard loadRequestID == requestID, !Task.isCancelled"))
        #expect(source.contains("guard persistenceRequestID == requestID else { return }"))
        #expect(source.contains("entries: commit.entries"))
        #expect(source.contains("persistenceRequestID = nil\n            persistenceTask = nil"))

        let persistStart = try #require(source.range(of: "private func persist()"))
        let persistSource = source[persistStart.lowerBound...]
        let durablePublication = try #require(persistSource.range(of:
            "KeywordListsStore.shared.recordExternalWrite("
        ))
        let uiRequestGate = try #require(persistSource.range(of:
            "guard persistenceRequestID == requestID else { return }"
        ))
        #expect(durablePublication.lowerBound < uiRequestGate.lowerBound)

        #expect(!source.contains("KeywordListsStore.shared.readEntries(storeKey)"))
        #expect(!source.contains("KeywordListsStore.shared.writeEntries(entries, to: storeKey)"))
        #expect(!source.contains("ApprovedListService.shared.saveEntries(entries"))
    }
}

private nonisolated final class KeywordListEditorFileAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let storedItemExists: Bool
    private let storedReadData: Data
    private let cancelDuringWrite: Bool
    private var existsCount = 0
    private var readCount = 0
    private var observedMainThread = false
    private var committedData: Data?
    private var committedURL: URL?

    init(
        itemExists: Bool = true,
        readData: Data = Data(),
        cancelDuringWrite: Bool = false
    ) {
        storedItemExists = itemExists
        storedReadData = readData
        self.cancelDuringWrite = cancelDuringWrite
    }

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { [self] _ in
                lock.withLock {
                    existsCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return storedItemExists
            },
            readData: { [self] _ in
                lock.withLock {
                    readCount += 1
                    observedMainThread = observedMainThread || Thread.isMainThread
                }
                return storedReadData
            },
            writeData: { [self] data, url in
                lock.withLock {
                    observedMainThread = observedMainThread || Thread.isMainThread
                    committedData = data
                    committedURL = url
                }
                if cancelDuringWrite {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
    }

    var existsInvocationCount: Int { lock.withLock { existsCount } }
    var readInvocationCount: Int { lock.withLock { readCount } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var writtenData: Data? { lock.withLock { committedData } }
    var writtenURL: URL? { lock.withLock { committedURL } }
}

private enum KeywordListEditorFileAccessProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingKeywordListEditorFileAccessProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var readCount = 0
    private var activeReads = 0
    private var maximumActiveReads = 0
    private var firstReadStarted = false
    private var firstReadReleased = false

    var fileAccess: KeywordListEditorFileAccess {
        KeywordListEditorFileAccess(
            itemExists: { _ in true },
            readData: { [self] _ in
                condition.lock()
                readCount += 1
                activeReads += 1
                maximumActiveReads = max(maximumActiveReads, activeReads)
                if readCount == 1 {
                    firstReadStarted = true
                    condition.broadcast()
                    while !firstReadReleased { condition.wait() }
                }
                activeReads -= 1
                condition.unlock()
                return Data("first\n".utf8)
            },
            writeData: { _, _ in }
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition.withLock({ firstReadStarted }) {
            guard ContinuousClock.now < deadline else {
                throw KeywordListEditorFileAccessProbeError.timedOut
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

    var readInvocationCount: Int { condition.withLock { readCount } }
    var maximumConcurrentReads: Int { condition.withLock { maximumActiveReads } }
}
