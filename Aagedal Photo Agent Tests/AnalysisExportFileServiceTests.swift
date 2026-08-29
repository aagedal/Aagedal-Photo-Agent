import Foundation
import Testing
@testable import Aagedal_Photo_Agent

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
