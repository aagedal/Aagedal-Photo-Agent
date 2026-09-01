import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Develop persistence session coordinator")
@MainActor
struct DevelopPersistenceSessionCoordinatorTests {
    @Test("workspace and image lifecycle scope dirty preview URLs")
    func dirtyURLLifecycle() {
        let first = URL(fileURLWithPath: "/tmp/develop-persistence-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-persistence-second.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()

        #expect(coordinator.recordPublishedSettingsChange(for: first) == .unchanged)
        coordinator.beginWorkspace()
        coordinator.beginImageSession(first)
        #expect(coordinator.recordPublishedSettingsChange(for: second) == .unchanged)
        #expect(coordinator.recordPublishedSettingsChange(for: first) == .previewOnly)
        #expect(coordinator.recordPublishedSettingsChanges(for: [first, second]) == .previewOnly)
        #expect(coordinator.editedURLs == [first, second])

        coordinator.beginImageSession(second)
        #expect(coordinator.activeImageURL == second)
        #expect(coordinator.editedURLs == [first, second])
        #expect(coordinator.endWorkspace() == [first, second])
        #expect(!coordinator.isWorkspaceActive)
        #expect(coordinator.activeImageURL == nil)
        #expect(coordinator.editedURLs.isEmpty)
    }

    @Test("persistence intent distinguishes previews primary and named versions")
    func persistenceIntent() {
        let coordinator = DevelopPersistenceSessionCoordinator()
        #expect(coordinator.persistenceIntent(hasChanges: true, editsNamedVersion: false) == .unchanged)

        coordinator.beginWorkspace()
        #expect(coordinator.persistenceIntent(hasChanges: false, editsNamedVersion: false) == .unchanged)
        #expect(coordinator.persistenceIntent(hasChanges: true, editsNamedVersion: false) == .commitPrimary)
        #expect(coordinator.persistenceIntent(hasChanges: false, editsNamedVersion: true) == .commitNamedVersion)
    }

    @Test("persistence routing publishes once before the selected durable boundary")
    func persistenceRouting() {
        let coordinator = DevelopPersistenceSessionCoordinator()
        var events: [String] = []

        let inactiveIntent = coordinator.performPersistence(
            hasChanges: true,
            editsNamedVersion: false,
            publishImageSnapshot: { events.append("publish") },
            commitPrimary: { events.append("primary") },
            commitNamedVersion: { events.append("named") }
        )
        #expect(inactiveIntent == .unchanged)
        #expect(events.isEmpty)

        coordinator.beginWorkspace()
        let primaryIntent = coordinator.performPersistence(
            hasChanges: true,
            editsNamedVersion: false,
            publishImageSnapshot: { events.append("publish-primary") },
            commitPrimary: { events.append("primary") },
            commitNamedVersion: { events.append("unexpected-named") }
        )
        #expect(primaryIntent == .commitPrimary)
        #expect(events == ["publish-primary", "primary"])

        events.removeAll()
        let namedIntent = coordinator.performPersistence(
            hasChanges: false,
            editsNamedVersion: true,
            publishImageSnapshot: { events.append("publish-named") },
            commitPrimary: { events.append("unexpected-primary") },
            commitNamedVersion: { events.append("named") }
        )
        #expect(namedIntent == .commitNamedVersion)
        #expect(events == ["publish-named", "named"])
    }

    @Test("undo and redo restore one image-scoped settings transition")
    func undoAndRedo() {
        let imageURL = URL(fileURLWithPath: "/tmp/develop-persistence-undo.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(imageURL)

        var before = CameraRawSettings()
        before.exposure2012 = 10
        var after = before
        after.exposure2012 = 25
        var published: [(CameraRawSettings?, Bool)] = []

        #expect(coordinator.recordMutation(
            before: before,
            after: after,
            editsNamedVersion: false,
            actionName: "Exposure"
        ) { settings, editsNamedVersion in
            published.append((settings, editsNamedVersion))
        } == .previewOnly)
        #expect(coordinator.canUndo)

        coordinator.undo()
        #expect(published.count == 1)
        #expect(published[0].0 == before)
        #expect(!published[0].1)
        #expect(coordinator.canRedo)

        coordinator.redo()
        #expect(published.count == 2)
        #expect(published[1].0 == after)
        #expect(!published[1].1)
        #expect(coordinator.canUndo)
    }

    @Test("same image preview refresh preserves undo history")
    func sameImageRefreshPreservesUndo() {
        let imageURL = URL(fileURLWithPath: "/tmp/develop-persistence-refresh.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(imageURL)

        var before = CameraRawSettings()
        before.exposure2012 = 5
        var after = before
        after.exposure2012 = 15
        var restored: CameraRawSettings?
        _ = coordinator.recordMutation(
            before: before,
            after: after,
            editsNamedVersion: false
        ) { settings, _ in restored = settings }
        #expect(coordinator.canUndo)

        coordinator.beginImageSession(imageURL)

        #expect(coordinator.canUndo)
        coordinator.undo()
        #expect(restored == before)
    }

    @Test("image replacement rejects stale undo restoration")
    func imageReplacementRejectsStaleUndo() {
        let first = URL(fileURLWithPath: "/tmp/develop-persistence-stale-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-persistence-stale-second.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(first)

        var before = CameraRawSettings()
        before.contrast2012 = 5
        var after = before
        after.contrast2012 = 20
        var publicationCount = 0
        _ = coordinator.recordMutation(
            before: before,
            after: after,
            editsNamedVersion: false
        ) { _, _ in publicationCount += 1 }
        let staleManager = coordinator.undoManager

        coordinator.beginImageSession(second)
        staleManager.undo()

        #expect(publicationCount == 0)
        #expect(!coordinator.canUndo)
        #expect(coordinator.activeImageURL == second)
    }

    @Test("primary persistence owns success failure and cancellation publication")
    func primaryPersistenceOutcomes() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/develop-primary-persistence.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(imageURL)

        let successID = try #require(coordinator.schedulePrimaryPersistence { completion in
            completion(.succeeded)
        })
        try await waitForPrimaryPersistence(coordinator)
        #expect(coordinator.latestPrimaryPersistenceOutcome == .succeeded(requestID: successID))

        let failureID = try #require(coordinator.schedulePrimaryPersistence { completion in
            completion(.failed(message: "Simulated XMP failure"))
        })
        try await waitForPrimaryPersistence(coordinator)
        #expect(coordinator.latestPrimaryPersistenceOutcome == .failed(
            requestID: failureID,
            message: "Simulated XMP failure"
        ))
        #expect(coordinator.primaryPersistenceErrorMessage == "Simulated XMP failure")

        let cancelledID = try #require(coordinator.schedulePrimaryPersistence { completion in
            completion(.cancelled(message: "Cancelled after metadata history commit"))
        })
        try await waitForPrimaryPersistence(coordinator)
        #expect(coordinator.latestPrimaryPersistenceOutcome == .cancelled(
            requestID: cancelledID,
            message: "Cancelled after metadata history commit"
        ))

        var finishExplicitlyCancelled: DevelopPersistenceSessionCoordinator.PrimaryPersistenceCompletion?
        let explicitlyCancelledID = try #require(coordinator.schedulePrimaryPersistence { completion in
            finishExplicitlyCancelled = completion
        })
        coordinator.cancelPrimaryPersistence(requestID: explicitlyCancelledID)
        try await waitForPrimaryPersistence(coordinator)
        #expect(coordinator.latestPrimaryPersistenceOutcome == .cancelled(
            requestID: explicitlyCancelledID,
            message: "The Develop save was cancelled before it completed."
        ))
        finishExplicitlyCancelled?(.succeeded)
    }

    @Test("only the latest primary request publishes within an image session")
    func latestPrimaryResultWins() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/develop-primary-latest.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(imageURL)
        var finishFirst: DevelopPersistenceSessionCoordinator.PrimaryPersistenceCompletion?

        _ = coordinator.schedulePrimaryPersistence { completion in
            finishFirst = completion
        }
        let latestID = try #require(coordinator.schedulePrimaryPersistence { completion in
            completion(.succeeded)
        })
        finishFirst?(.failed(message: "Late superseded failure"))

        try await waitForPrimaryPersistence(coordinator)
        #expect(coordinator.latestPrimaryPersistenceOutcome == .succeeded(requestID: latestID))
        #expect(coordinator.primaryPersistenceErrorMessage == nil)
    }

    @Test("image replacement rejects a late primary result")
    func imageReplacementRejectsPrimaryResult() async throws {
        let first = URL(fileURLWithPath: "/tmp/develop-primary-first.raw")
        let second = URL(fileURLWithPath: "/tmp/develop-primary-second.raw")
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        coordinator.beginImageSession(first)
        var finish: DevelopPersistenceSessionCoordinator.PrimaryPersistenceCompletion?

        _ = coordinator.schedulePrimaryPersistence { completion in
            finish = completion
        }
        coordinator.beginImageSession(second)
        finish?(.failed(message: "Late previous-image failure"))
        try await Task.sleep(for: .milliseconds(10))

        #expect(coordinator.activeImageURL == second)
        #expect(coordinator.pendingPrimaryPersistenceCount == 0)
        #expect(coordinator.latestPrimaryPersistenceOutcome == nil)
    }

    @Test("batch persistence owns success failure and explicit cancellation")
    func batchPersistenceOutcomes() async throws {
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()

        let successID = try #require(coordinator.scheduleBatchPersistence {})
        try await waitForBatchPersistence(coordinator)
        #expect(coordinator.latestBatchPersistenceOutcome == .succeeded(requestID: successID))
        #expect(!coordinator.isBatchPersistenceInProgress)

        let failureID = try #require(coordinator.scheduleBatchPersistence {
            throw BatchPersistenceTestError.writeFailed
        })
        try await waitForBatchPersistence(coordinator)
        #expect(coordinator.latestBatchPersistenceOutcome == .failed(
            requestID: failureID,
            message: BatchPersistenceTestError.writeFailed.localizedDescription
        ))
        #expect(coordinator.batchPersistenceErrorMessage == "Simulated batch write failure")

        let cancelledID = try #require(coordinator.scheduleBatchPersistence {
            try await Task.sleep(for: .seconds(10))
        })
        coordinator.cancelBatchPersistence(requestID: cancelledID)
        try await waitForBatchPersistence(coordinator)
        #expect(coordinator.latestBatchPersistenceOutcome == .cancelled(requestID: cancelledID))
    }

    @Test("only the latest overlapping batch request publishes a result")
    func latestBatchResultWins() async throws {
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()

        _ = coordinator.scheduleBatchPersistence {
            try? await Task.sleep(for: .milliseconds(60))
            throw BatchPersistenceTestError.lateFailure
        }
        let latestID = try #require(coordinator.scheduleBatchPersistence {
            try await Task.sleep(for: .milliseconds(10))
        })

        try await waitForBatchPersistence(coordinator)
        #expect(coordinator.latestBatchPersistenceOutcome == .succeeded(requestID: latestID))
        #expect(coordinator.batchPersistenceErrorMessage == nil)
    }

    @Test("workspace teardown preserves durable work and rejects its late UI result")
    func teardownPreservesBatchWrite() async throws {
        let coordinator = DevelopPersistenceSessionCoordinator()
        coordinator.beginWorkspace()
        var didFinishDurableWork = false

        _ = coordinator.scheduleBatchPersistence {
            try await Task.sleep(for: .milliseconds(20))
            didFinishDurableWork = true
        }
        _ = coordinator.endWorkspace()

        for _ in 0..<200 where !didFinishDurableWork {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(didFinishDurableWork)
        #expect(coordinator.latestBatchPersistenceOutcome == nil)
        #expect(coordinator.pendingBatchPersistenceCount == 0)
    }

    @Test("edit workspace delegates undo and dirty URL ownership")
    func editWorkspaceSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Views/Browser/EditWorkspaceView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(
            "@State private var persistenceSession = DevelopPersistenceSessionCoordinator()"
        ))
        #expect(source.contains("persistenceSession.beginWorkspace()"))
        #expect(source.contains("persistenceSession.beginImageSession(selectedImageURL)"))
        #expect(source.contains("persistenceSession.endWorkspace()"))
        #expect(source.contains("persistenceSession.recordMutation("))
        #expect(source.contains("persistenceSession.recordPublishedSettingsChange(for: url)"))
        #expect(source.components(separatedBy: "persistenceSession.schedulePrimaryPersistence").count == 2)
        #expect(source.contains("persistenceSession.primaryPersistenceErrorMessage"))
        #expect(source.contains("metadataViewModel.commitEditsReportingResult(mode: mode)"))
        #expect(!source.contains("localizedCaseInsensitiveContains(\"cancel\")"))
        #expect(source.contains("persistenceSession.scheduleBatchPersistence"))
        #expect(source.contains("persistenceSession.batchPersistenceErrorMessage"))
        #expect(source.components(separatedBy: "persistenceSession.performPersistence(").count == 3)
        #expect(!source.contains("Failed to paste camera raw to multiple images"))
        #expect(!source.contains("@State private var editUndoManager"))
        #expect(!source.contains("@State private var editedURLsThisSession"))
    }

    private func waitForPrimaryPersistence(
        _ coordinator: DevelopPersistenceSessionCoordinator
    ) async throws {
        for _ in 0..<100 where coordinator.isPrimaryPersistenceInProgress {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!coordinator.isPrimaryPersistenceInProgress)
    }

    private func waitForBatchPersistence(
        _ coordinator: DevelopPersistenceSessionCoordinator
    ) async throws {
        for _ in 0..<100 where coordinator.isBatchPersistenceInProgress {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!coordinator.isBatchPersistenceInProgress)
    }
}

private enum BatchPersistenceTestError: LocalizedError {
    case writeFailed
    case lateFailure

    var errorDescription: String? {
        switch self {
        case .writeFailed: "Simulated batch write failure"
        case .lateFailure: "Late batch write failure"
        }
    }
}
