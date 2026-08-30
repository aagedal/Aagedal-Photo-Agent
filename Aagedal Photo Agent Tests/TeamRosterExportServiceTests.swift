import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Team roster export filesystem boundary")
struct TeamRosterExportServiceTests {
    @Test("an immutable commit is written away from the main actor")
    @MainActor
    func completeCommitRunsOffMainActor() async {
        let destination = URL(fileURLWithPath: "/virtual/roster.pdf")
        let bytes = Data("roster PDF".utf8)
        let artifactID = UUID()
        let requestID = UUID()
        let probe = TeamRosterExportWriterProbe()
        let service = TeamRosterExportService(writer: TeamRosterExportWriter(write: probe.write))

        let evidence = await Task {
            await service.export(
                [TeamRosterExportArtifact(
                    id: artifactID,
                    data: bytes,
                    destinationURL: destination
                )],
                requestID: requestID
            )
        }.value

        #expect(evidence == TeamRosterExportEvidence(
            requestID: requestID,
            results: [.committed(TeamRosterExportCommit(
                artifactID: artifactID,
                destinationURL: destination,
                byteCount: bytes.count,
                cancellationRequestedAfterCommit: false
            ))]
        ))
        #expect(probe.invocationCount == 1)
        #expect(!probe.ranOnMainThread)
    }

    @Test("a pre-cancelled request records every artifact without entering the writer")
    func preCancellation() async {
        let first = TeamRosterExportArtifact(
            data: Data("first".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/first.txt")
        )
        let second = TeamRosterExportArtifact(
            data: Data("second".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/second.txt")
        )
        let probe = TeamRosterExportWriterProbe()
        let service = TeamRosterExportService(writer: TeamRosterExportWriter(write: probe.write))
        let task = Task {
            await Task.yield()
            return await service.export([first, second], requestID: UUID())
        }
        task.cancel()

        let evidence = await task.value

        #expect(evidence.results == [
            .cancelledBeforeWrite(artifactID: first.id, destinationURL: first.destinationURL),
            .cancelledBeforeWrite(artifactID: second.id, destinationURL: second.destinationURL),
        ])
        #expect(evidence.cancelledCount == 2)
        #expect(probe.invocationCount == 0)
    }

    @Test("overlapping requests serialize and cancellation stops a queued write")
    func serializedQueuedCancellation() async throws {
        let first = TeamRosterExportArtifact(
            data: Data("first".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/first.txt")
        )
        let second = TeamRosterExportArtifact(
            data: Data("second".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/second.txt")
        )
        let probe = BlockingTeamRosterExportWriterProbe()
        let service = TeamRosterExportService(writer: TeamRosterExportWriter(write: probe.write))
        let firstTask = Task { await service.export([first], requestID: UUID()) }
        try await probe.waitUntilFirstWriteStarts()
        let secondTask = Task { await service.export([second], requestID: UUID()) }
        secondTask.cancel()
        probe.releaseFirstWrite()

        let firstEvidence = await firstTask.value
        let secondEvidence = await secondTask.value

        #expect(firstEvidence.committedCount == 1)
        #expect(secondEvidence.results == [
            .cancelledBeforeWrite(artifactID: second.id, destinationURL: second.destinationURL),
        ])
        #expect(probe.invocationCount == 1)
        #expect(probe.maximumConcurrentWrites == 1)
    }

    @Test("a batch keeps immutable partial-success evidence after an artifact fails")
    func partialSuccess() async {
        let first = TeamRosterExportArtifact(
            data: Data("pdf".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/roster.pdf")
        )
        let second = TeamRosterExportArtifact(
            data: Data("text".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/roster.txt")
        )
        let error = CocoaError(.fileWriteNoPermission)
        let service = TeamRosterExportService(writer: TeamRosterExportWriter { _, url, _ in
            if url == second.destinationURL { throw error }
        })

        let evidence = await service.export([first, second], requestID: UUID())

        #expect(evidence.results == [
            .committed(TeamRosterExportCommit(
                artifactID: first.id,
                destinationURL: first.destinationURL,
                byteCount: first.data.count,
                cancellationRequestedAfterCommit: false
            )),
            .failed(TeamRosterExportFailure(
                artifactID: second.id,
                destinationURL: second.destinationURL,
                errorDomain: (error as NSError).domain,
                errorCode: (error as NSError).code,
                message: error.localizedDescription,
                failureReason: (error as NSError).localizedFailureReason,
                recoverySuggestion: (error as NSError).localizedRecoverySuggestion
            )),
        ])
        #expect(evidence.committedCount == 1)
        #expect(evidence.failedCount == 1)
        #expect(evidence.isPartialSuccess)
    }

    @Test("cancellation during a synchronous write preserves the commit and stops the remainder")
    func cancellationAfterCommit() async {
        let first = TeamRosterExportArtifact(
            data: Data("pdf".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/roster.pdf")
        )
        let second = TeamRosterExportArtifact(
            data: Data("text".utf8),
            destinationURL: URL(fileURLWithPath: "/virtual/roster.txt")
        )
        let service = TeamRosterExportService(writer: TeamRosterExportWriter { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })

        let evidence = await Task {
            await service.export([first, second], requestID: UUID())
        }.value

        #expect(evidence.results == [
            .committed(TeamRosterExportCommit(
                artifactID: first.id,
                destinationURL: first.destinationURL,
                byteCount: first.data.count,
                cancellationRequestedAfterCommit: true
            )),
            .cancelledBeforeWrite(artifactID: second.id, destinationURL: second.destinationURL),
        ])
        #expect(evidence.isPartialSuccess)
    }

    @Test("the team editor awaits the service and rejects stale completion")
    func teamEditorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Teams/TeamsLibraryView.swift"
            ),
            encoding: .utf8
        )
        let functionStart = try #require(source.range(of: "private func startExport("))
        let suffix = source[functionStart.lowerBound...]
        let functionEnd = try #require(suffix.range(of: "\n    /// Import a"))
        let functionSource = String(suffix[..<functionEnd.lowerBound])

        #expect(functionSource.contains("await TeamRosterExportService.shared.export("))
        #expect(functionSource.contains("guard exportRequestID == requestID else { return }"))
        #expect(!functionSource.contains("write(to:"))
    }
}

private nonisolated final class TeamRosterExportWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var observedMainThread = false

    func write(_ data: Data, _ url: URL, _ options: Data.WritingOptions) throws {
        _ = (data, url, options)
        lock.withLock {
            count += 1
            observedMainThread = observedMainThread || Thread.isMainThread
        }
    }

    var invocationCount: Int { lock.withLock { count } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
}

private enum TeamRosterExportProbeError: Error {
    case timedOut
}

private nonisolated final class BlockingTeamRosterExportWriterProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var writeCount = 0
    private var activeWrites = 0
    private var maximumActiveWrites = 0
    private var firstWriteReleased = false

    func write(_ data: Data, _ url: URL, _ options: Data.WritingOptions) throws {
        _ = (data, url, options)
        condition.lock()
        writeCount += 1
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
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
        let deadline = ContinuousClock.now + .seconds(5)
        while invocationCount == 0 {
            guard ContinuousClock.now < deadline else {
                throw TeamRosterExportProbeError.timedOut
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
}
