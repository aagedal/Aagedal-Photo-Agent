import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("User-selected text import filesystem boundary")
struct TextFileImportServiceTests {
    @Test("a complete immutable snapshot is read away from the main actor")
    @MainActor
    func completeSnapshotRunsOffMainActor() async throws {
        let source = URL(fileURLWithPath: "/virtual/structured-keywords.txt")
        let bytes = Data("People\n\tAlice\n".utf8)
        let requestID = UUID()
        let probe = TextFileImportReaderProbe(data: bytes)
        let service = TextFileImportService(reader: TextFileImportReader(read: probe.read))

        let result = try await Task {
            try await service.loadText(from: source, requestID: requestID)
        }.value

        #expect(result == .loaded(TextFileImportSnapshot(
            requestID: requestID,
            sourceURL: source,
            text: "People\n\tAlice\n",
            byteCount: bytes.count
        )))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled request never enters the synchronous reader")
    func preCancellation() async throws {
        let requestID = UUID()
        let probe = TextFileImportReaderProbe(data: Data("unused".utf8))
        let service = TextFileImportService(reader: TextFileImportReader(read: probe.read))
        let task = Task {
            await Task.yield()
            return try await service.loadText(
                from: URL(fileURLWithPath: "/virtual/cancelled.txt"),
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeRead(requestID: requestID))
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping imports serialize and cancellation stops a queued read")
    func serializedQueuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first.txt")
        let secondURL = URL(fileURLWithPath: "/virtual/second.txt")
        let firstID = UUID()
        let secondID = UUID()
        let probe = BlockingTextFileImportReaderProbe()
        let service = TextFileImportService(reader: TextFileImportReader(read: probe.read))
        let first = Task {
            try await service.loadText(from: firstURL, requestID: firstID)
        }
        try await probe.waitUntilFirstReadStarts()
        let second = Task {
            try await service.loadText(from: secondURL, requestID: secondID)
        }
        second.cancel()
        probe.releaseFirstRead()

        let firstResult = try await first.value
        let secondResult = try await second.value

        #expect(firstResult == .loaded(TextFileImportSnapshot(
            requestID: firstID,
            sourceURL: firstURL,
            text: "first",
            byteCount: Data("first".utf8).count
        )))
        #expect(secondResult == .cancelledBeforeRead(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("cancellation during a non-preemptible read is explicit and publishes no text")
    func cancellationAfterRead() async throws {
        let source = URL(fileURLWithPath: "/virtual/slow.txt")
        let bytes = Data("complete bytes".utf8)
        let requestID = UUID()
        let service = TextFileImportService(reader: TextFileImportReader { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return bytes
        })

        let result = try await Task {
            try await service.loadText(from: source, requestID: requestID)
        }.value

        #expect(result == .cancelledAfterRead(
            requestID: requestID,
            sourceURL: source,
            byteCount: bytes.count
        ))
    }

    @Test("Structured Keyword import awaits the service and rejects stale completion")
    func structuredKeywordEditorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Settings/StructuredKeywordEditor.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func importFromFile()"))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func exportToFile()"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains("try await TextFileImportService.shared.loadText("))
        #expect(functionSource.contains("guard importRequestID == requestID else { return }"))
        #expect(functionSource.contains("case .cancelledBeforeRead, .cancelledAfterRead:"))
        #expect(!functionSource.contains("Data(contentsOf:"))
    }
}

private nonisolated final class TextFileImportReaderProbe: @unchecked Sendable {
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

private enum TextFileImportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingTextFileImportReaderProbe: @unchecked Sendable {
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
                throw TextFileImportProbeError.timedOut
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

@Suite("Analysis export filesystem boundary")
struct AnalysisExportFileServiceTests {
    @Test("atomic commit preserves overwrite behavior and returns immutable evidence")
    func commitEvidence() async throws {
        let fixture = try AnalysisExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("report.pdf")
        try Data("old".utf8).write(to: destination)
        let bytes = Data("new report bytes".utf8)
        let requestID = UUID()

        let result = try await AnalysisExportFileService().write(
            bytes,
            to: destination,
            requestID: requestID
        )

        #expect(result == .committed(AnalysisExportCommit(
            requestID: requestID,
            destinationURL: destination,
            byteCount: bytes.count,
            cancellationRequestedAfterCommit: false
        )))
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test("a pre-cancelled export leaves the destination untouched")
    func preCancellation() async throws {
        let fixture = try AnalysisExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("annotated.jpg")
        let requestID = UUID()
        let task = Task {
            await Task.yield()
            return try await AnalysisExportFileService().write(
                Data("jpeg".utf8),
                to: destination,
                requestID: requestID
            )
        }
        task.cancel()

        let result = try await task.value

        #expect(result == .cancelledBeforeWrite(requestID: requestID))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("overlapping exports serialize and cancellation stops queued work")
    func serializedQueuedCancellation() async throws {
        let fixture = try AnalysisExportFixture()
        defer { fixture.remove() }
        let probe = BlockingAnalysisExportWriter()
        let service = AnalysisExportFileService(writer: AnalysisExportFileWriter(
            write: { data, destination in
                try probe.write(data, destination)
            }
        ))
        let firstID = UUID()
        let secondID = UUID()
        let first = Task {
            try await service.write(
                Data("first".utf8),
                to: fixture.root.appendingPathComponent("first.pdf"),
                requestID: firstID
            )
        }
        try await probe.waitUntilFirstWriteStarts()
        let second = Task {
            try await service.write(
                Data("second".utf8),
                to: fixture.root.appendingPathComponent("second.pdf"),
                requestID: secondID
            )
        }
        second.cancel()
        probe.releaseFirstWrite()

        let firstResult = try await first.value
        let secondResult = try await second.value

        guard case .committed(let commit) = firstResult else {
            Issue.record("Expected the first export to commit")
            return
        }
        #expect(commit.requestID == firstID)
        #expect(secondResult == .cancelledBeforeWrite(requestID: secondID))
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentWrites == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("cancellation arriving during the synchronous commit reports durable success")
    func cancellationAfterCommit() async throws {
        let fixture = try AnalysisExportFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("map.jpg")
        let bytes = Data("committed map".utf8)
        let requestID = UUID()
        let service = AnalysisExportFileService(writer: AnalysisExportFileWriter(
            write: { data, destination in
                try data.write(to: destination, options: .atomic)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        ))
        let task = Task {
            try await service.write(bytes, to: destination, requestID: requestID)
        }

        let result = try await task.value

        #expect(result == .committed(AnalysisExportCommit(
            requestID: requestID,
            destinationURL: destination,
            byteCount: bytes.count,
            cancellationRequestedAfterCommit: true
        )))
        #expect(try Data(contentsOf: destination) == bytes)
    }
}

private enum AnalysisExportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingAnalysisExportWriter: @unchecked Sendable {
    private let condition = NSCondition()
    private var writeCount = 0
    private var activeWrites = 0
    private var maximumActiveWrites = 0
    private var firstWriteReleased = false
    private var observedMainThread = false

    func write(_ data: Data, _ destination: URL) throws {
        _ = data
        _ = destination
        condition.lock()
        writeCount += 1
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        observedMainThread = observedMainThread || Thread.isMainThread
        condition.broadcast()
        if writeCount == 1 {
            while !firstWriteReleased {
                condition.wait()
            }
        }
        activeWrites -= 1
        condition.unlock()
    }

    func waitUntilFirstWriteStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw AnalysisExportProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstWrite() {
        condition.lock()
        firstWriteReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return writeCount
    }

    var maximumConcurrentWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveWrites
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return observedMainThread
    }
}

private nonisolated struct AnalysisExportFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnalysisExportFileServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Export directory filesystem boundary")
struct ExportDirectoryServiceTests {
    @Test("Develop single-image save uses the serialized directory boundary")
    func developSingleImageSaveSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func saveCurrentRenderedImage()"))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    private func signedIntString"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains(
            "try await ExportDirectoryService.shared.ensureDirectory("
        ))
        #expect(functionSource.contains(
            "guard !directoryCommit.cancellationRequestedAfterCommit else { return }"
        ))
        #expect(functionSource.contains("try Task.checkCancellation()"))
        #expect(functionSource.contains("catch is CancellationError"))
        #expect(!functionSource.contains("FileManager.default.createDirectory"))
    }

    @Test("directory creation returns immutable commit evidence off the main thread")
    @MainActor
    func committedCreationRunsOffMainActor() async throws {
        let fixture = try ExportDirectoryFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("nested/output", isDirectory: true)
        let probe = ExportDirectoryWriterProbe()
        let service = ExportDirectoryService(writer: ExportDirectoryWriter(
            ensureDirectory: { url in try probe.ensureDirectory(at: url) }
        ))

        let task = Task {
            try await service.ensureDirectory(at: destination)
        }

        let result = try await task.value

        #expect(result == ExportDirectoryCommit(
            directoryURL: destination,
            cancellationRequestedAfterCommit: false
        ))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled request performs no filesystem mutation")
    func preCancellation() async throws {
        let fixture = try ExportDirectoryFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("cancelled", isDirectory: true)
        let probe = ExportDirectoryWriterProbe()
        let service = ExportDirectoryService(writer: ExportDirectoryWriter(
            ensureDirectory: { url in try probe.ensureDirectory(at: url) }
        ))
        let task = Task {
            await Task.yield()
            return try await service.ensureDirectory(at: destination)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(probe.invocationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("overlapping requests serialize and cancellation stops queued creation")
    func queuedCancellation() async throws {
        let fixture = try ExportDirectoryFixture()
        defer { fixture.remove() }
        let probe = BlockingExportDirectoryWriterProbe()
        let service = ExportDirectoryService(writer: ExportDirectoryWriter(
            ensureDirectory: { url in try probe.ensureDirectory(at: url) }
        ))
        let firstURL = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondURL = fixture.root.appendingPathComponent("second", isDirectory: true)
        let first = Task { try await service.ensureDirectory(at: firstURL) }
        try await probe.waitUntilFirstCreationStarts()
        let second = Task { try await service.ensureDirectory(at: secondURL) }
        second.cancel()
        probe.releaseFirstCreation()

        _ = try await first.value
        await #expect(throws: CancellationError.self) {
            _ = try await second.value
        }
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentCreations == 1)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test("cancellation during a synchronous creation reports the durable commit")
    func cancellationAfterCommit() async throws {
        let fixture = try ExportDirectoryFixture()
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("committed", isDirectory: true)
        let service = ExportDirectoryService(writer: ExportDirectoryWriter(
            ensureDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
                withUnsafeCurrentTask { $0?.cancel() }
            }
        ))

        let task = Task {
            try await service.ensureDirectory(at: destination)
        }

        let result = try await task.value

        #expect(result == ExportDirectoryCommit(
            directoryURL: destination,
            cancellationRequestedAfterCommit: true
        ))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}

private nonisolated final class ExportDirectoryWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var observedMainThread = false

    func ensureDirectory(at url: URL) throws {
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private enum ExportDirectoryProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingExportDirectoryWriterProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var activeCreations = 0
    private var maximumActiveCreations = 0
    private var firstCreationReleased = false

    func ensureDirectory(at url: URL) throws {
        condition.lock()
        count += 1
        activeCreations += 1
        maximumActiveCreations = max(maximumActiveCreations, activeCreations)
        condition.broadcast()
        if count == 1 {
            while !firstCreationReleased {
                condition.wait()
            }
        }
        activeCreations -= 1
        condition.unlock()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func waitUntilFirstCreationStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw ExportDirectoryProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstCreation() {
        condition.lock()
        firstCreationReleased = true
        condition.broadcast()
        condition.unlock()
    }

    var invocationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }

    var maximumConcurrentCreations: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveCreations
    }
}

private nonisolated struct ExportDirectoryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExportDirectoryServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
