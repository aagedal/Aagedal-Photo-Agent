import Foundation
import Darwin
import Testing
@testable import Aagedal_Photo_Agent

@MainActor
@Suite("Caption session")
struct CaptionSessionTests {
    private let urls = [
        URL(fileURLWithPath: "/tmp/caption-a.jpg"),
        URL(fileURLWithPath: "/tmp/caption-b.jpg"),
        URL(fileURLWithPath: "/tmp/caption-c.jpg"),
    ]

    @Test("Session owns a stable ordered, deduplicated image list")
    func initialization() {
        let session = CaptionSession(
            imageURLs: [urls[0], urls[1], urls[0], urls[2]],
            currentURL: urls[1]
        )

        #expect(session.orderedImageURLs == urls)
        #expect(session.currentURL == urls[1])
        #expect(session.position == 2)
        #expect(session.previousURL == urls[0])
        #expect(session.count == 3)
        #expect(session.selectedURLs == [urls[1]])
        #expect(session.canGoPrevious)
        #expect(session.canGoNext)
    }

    @Test("Navigation flushes buffered text before changing focus")
    func navigationFlushesBeforeMutation() async throws {
        let session = CaptionSession(imageURLs: urls)
        var focusedDuringFlush: URL?

        let moved = try await session.goNext {
            focusedDuringFlush = session.currentURL
            session.markCurrentDirty()
        }

        #expect(moved)
        #expect(focusedDuringFlush == urls[0])
        #expect(session.currentURL == urls[1])
        #expect(session.dirtyURLs == [urls[0]])
        #expect(session.selectedURLs == [urls[1]])
    }

    @Test("A failed flush leaves navigation and selection unchanged")
    func failedFlushPreventsTransition() async {
        let session = CaptionSession(imageURLs: urls)
        let originalSelection = session.selectedURLs

        await #expect(throws: FlushFailure.self) {
            try await session.goNext { throw FlushFailure() }
        }

        #expect(session.currentURL == urls[0])
        #expect(session.selectedURLs == originalSelection)
        #expect(!session.isTransitioning)
    }

    @Test("Rapid opposite navigation is serialized without changing focus out of order")
    func rapidOppositeNavigationIsSerialized() async throws {
        let session = CaptionSession(imageURLs: urls, currentURL: urls[1])
        let entered = AsyncSignal()
        let release = AsyncSignal()
        let next = Task { @MainActor in
            try await session.goNext {
                entered.signal()
                await release.wait()
            }
        }

        await entered.wait()
        do {
            _ = try await session.goPrevious {}
            Issue.record("Expected the second navigation to be rejected while flushing")
        } catch {
            #expect(error as? CaptionSessionError == .transitionInProgress)
        }
        #expect(session.currentURL == urls[1])

        release.signal()
        #expect(try await next.value)
        #expect(session.currentURL == urls[2])
        #expect(try await session.goPrevious {})
        #expect(session.currentURL == urls[1])
    }

    @Test("A previous-image load is rejected after navigation")
    func staleLoadSuppression() async throws {
        let session = CaptionSession(imageURLs: urls)
        let stale = try #require(session.beginLoad())
        #expect(session.accepts(load: stale))

        try await session.goNext {}

        #expect(!session.accepts(load: stale))
        let current = try #require(session.beginLoad())
        #expect(current.imageURL == urls[1])
        #expect(session.accepts(load: current))
    }

    @Test("Navigation returns while serialized sidecar persistence is still blocked")
    func navigationDoesNotAwaitPersistence() async throws {
        let session = CaptionSession(imageURLs: urls)
        let queue = CaptionDraftPersistenceQueue(label: "caption-session-test.persistence")
        let firstStarted = AsyncSignal()
        let releaseFirst = BlockingGate()
        let order = LockedStrings()

        let moved = try await session.goNext {
            queue.enqueue {
                order.append("first-start")
                firstStarted.signal()
                releaseFirst.wait()
                order.append("first-end")
            }
            queue.enqueue {
                order.append("second")
            }
        }

        #expect(moved)
        #expect(session.currentURL == urls[1])
        await firstStarted.wait()
        // The first operation is still held at the gate, so a FIFO queue cannot have started the
        // second operation. This is an ordering assertion, not a wall-clock threshold.
        #expect(order.values == ["first-start"])

        releaseFirst.signal()
        try queue.drain()
        #expect(order.values == ["first-start", "first-end", "second"])
        #expect(queue.pendingCount == 0)
    }

    @Test("Navigation invalidates but never awaits an in-flight image decode")
    func navigationDoesNotAwaitDecode() async throws {
        let session = CaptionSession(imageURLs: urls)
        let token = try #require(session.beginLoad())
        let decodeStarted = AsyncSignal()
        let releaseDecode = BlockingGate()
        let decode = Task.detached {
            decodeStarted.signal()
            releaseDecode.wait()
        }
        await decodeStarted.wait()

        let moved = try await session.goNext {}

        #expect(moved)
        #expect(session.currentURL == urls[1])
        #expect(!session.accepts(load: token))
        releaseDecode.signal()
        await decode.value
    }

    @Test("Failed persistence remains queued and durable drain retries in FIFO order")
    func persistenceFailureIsRetainedForRetry() throws {
        let queue = CaptionDraftPersistenceQueue(label: "caption-session-test.retry")
        let gate = PersistenceFailureGate()

        queue.enqueue(
            operation: { try gate.attempt() }
        )

        // Synchronizing through pendingCount proves the first background attempt has finished.
        #expect(queue.pendingCount == 1)
        #expect(throws: PersistenceFailure.self) {
            try queue.drain()
        }
        #expect(queue.pendingCount == 1)
        #expect(gate.attempts == 2)

        gate.shouldFail = false
        try queue.drain()
        #expect(queue.pendingCount == 0)
        #expect(gate.attempts == 3)
    }

    @Test("Selection changes flush first and choose a deterministic focus")
    func selectionTransition() async throws {
        let session = CaptionSession(imageURLs: urls)
        var flushCount = 0

        let changed = try await session.select([urls[2], urls[1]], focusedURL: urls[2]) {
            flushCount += 1
        }

        #expect(changed)
        #expect(flushCount == 1)
        #expect(session.currentURL == urls[2])
        #expect(session.selectedURLs == [urls[1], urls[2]])
    }

    @Test("Replacing images retains focus and prunes per-image state")
    func replaceImagesReconcilesState() {
        let session = CaptionSession(imageURLs: urls, currentURL: urls[1])
        session.markCurrentDirty()
        session.setReadiness(.blocked, for: urls[1])
        session.setReadiness(.warnings, for: urls[2])

        session.replaceImages([urls[2], urls[1]])
        #expect(session.currentURL == urls[1])
        #expect(session.position == 2)
        #expect(session.isCurrentDirty)
        #expect(session.currentReadiness == .blocked)

        session.replaceImages([urls[2]])
        #expect(session.currentURL == urls[2])
        #expect(session.dirtyURLs.isEmpty)
        #expect(session.readinessByURL[urls[1]] == nil)
        #expect(session.currentReadiness == .warnings)
    }

    @Test("Copy, template, write, send, and workspace exit all use the flush barrier")
    func actionFlushBarrier() async throws {
        let session = CaptionSession(imageURLs: urls)
        var actions = 0

        try await session.prepare(for: .copyPrevious) { actions += 1 }
        try await session.prepare(for: .applyTemplate) { actions += 1 }
        try await session.prepare(for: .write) { actions += 1 }
        try await session.prepare(for: .send) { actions += 1 }
        try await session.prepare(for: .workspaceExit) { actions += 1 }

        #expect(actions == 5)
    }

    @Test("Caption readiness follows blocker then warning severity")
    func readinessResolution() {
        let warning = MetadataValidationIssue(
            id: "warning",
            imageURL: urls[0],
            field: .headline,
            severity: .warning,
            message: "Warning",
            technicalDetail: nil
        )
        let blocker = MetadataValidationIssue(
            id: "blocker",
            imageURL: urls[0],
            field: .description,
            severity: .blocker,
            message: "Blocked",
            technicalDetail: nil
        )

        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [])) == .ready)
        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [warning])) == .warnings)
        #expect(CaptionReadinessResolver.readiness(for: MetadataValidationReport(issues: [warning, blocker])) == .blocked)
    }

    @Test("Only the active caption panel can unregister the flush barrier")
    func flushCoordinatorOwnership() throws {
        let coordinator = CaptionWorkspaceFlushCoordinator()
        let firstOwner = UUID()
        let activeOwner = UUID()
        var flushed = 0

        coordinator.register(owner: firstOwner) { flushed = 1 }
        coordinator.register(owner: activeOwner) { flushed = 2 }
        coordinator.unregister(owner: firstOwner)
        try coordinator.flush()
        #expect(flushed == 2)

        coordinator.unregister(owner: activeOwner)
        #expect(!coordinator.hasRegisteredHandler)
        #expect(throws: CaptionWorkspaceFlushError.handlerUnavailable) {
            try coordinator.flush()
        }
    }
}

private struct FlushFailure: Error {}

private struct PersistenceFailure: LocalizedError {
    var errorDescription: String? { "Injected caption persistence failure" }
}

private nonisolated final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }

}

private actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    nonisolated func signal() {
        Task { await publish() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    private func publish() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private nonisolated final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private nonisolated final class PersistenceFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failureEnabled = true
    private var attemptCount = 0

    var shouldFail: Bool {
        get { lock.withLock { failureEnabled } }
        set { lock.withLock { failureEnabled = newValue } }
    }

    var attempts: Int {
        lock.withLock { attemptCount }
    }

    func attempt() throws {
        let fails = lock.withLock {
            attemptCount += 1
            return failureEnabled
        }
        if fails { throw PersistenceFailure() }
    }
}

@Suite("Caption conflict recovery")
struct CaptionConflictRecoveryTests {
    private func folder() throws -> URL {
        // Foundation resolvingSymlinksInPath may return logical /var on macOS. POSIX realpath
        // preserves the physical spelling and makes successful exports exercise /private/var.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { free(physical) }
        let folder = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("CaptionRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.ARW", "a.JPG", "b.JPG", "c.JPG", "a.xmp"] {
            try Data("protected \(name)".utf8).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".photo_metadata"), withIntermediateDirectories: true)
        try Data("protected JSON".utf8).write(to: folder.appendingPathComponent(".photo_metadata/a.ARW.meta.json"))
        return folder
    }

    private func draft(_ image: URL, manyFields: Bool = false) -> CaptionDraftPersistence {
        var baseline = IPTCMetadata(title: "A")
        baseline.exifOrientation = 6
        var edited = baseline
        edited.title = "B"
        if manyFields {
            for field in MetadataFieldID.allCases where !field.isRepeatable {
                field.setHistoryValue("Value \(field.rawValue)", in: &edited)
            }
        }
        var technical = CameraRawSettings()
        technical.exposure2012 = 1.25
        edited.cameraRaw = technical
        let changes = MetadataHistoryEntry.changes(from: baseline, to: edited, timestamp: Date(timeIntervalSince1970: 1234.123456))
        var history = changes
        history.trimToHistoryLimit()
        return .init(request: .init(sidecar: .init(sourceFile: image.lastPathComponent, pendingChanges: true,
            metadata: edited, imageMetadataSnapshot: nil, history: history), baselineMetadata: baseline,
            baselineHistory: [], baselineRecordExisted: true, changes: changes,
            imageURL: image, folderURL: image.deletingLastPathComponent()))
    }

    private func protectedBytes(_ folder: URL) throws -> [String: Data] {
        let names = ["a.ARW", "a.JPG", "b.JPG", "c.JPG", "a.xmp", ".photo_metadata/a.ARW.meta.json"]
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
    }

    @Test("Export and scoped discard retain full dependencies and resume unrelated FIFO in order")
    func scopedRecovery() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try protectedBytes(root)
        let queue = CaptionDraftPersistenceQueue(label: "recovery.scoped")
        let order = LockedStrings()
        let first = draft(root.appendingPathComponent("a.ARW"), manyFields: true)
        first.request.receipt.markCommitted()
        let idA = queue.enqueue(persistence: first, operation: { throw CaptionWorkspaceFlushError.replayConflict("newer A") })
        queue.enqueue(persistence: draft(root.appendingPathComponent("b.JPG")), operation: { order.append("B") })
        let idDependent = queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { order.append("dependent must not run") })
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.JPG")), operation: { order.append("JPEG sibling") })
        queue.enqueue(persistence: draft(root.appendingPathComponent("c.JPG")), operation: { order.append("C") })
        #expect(queue.pendingCount == 5)
        let failure = try #require(queue.currentFailure)
        #expect(failure.kind == .replayConflict)
        #expect(failure.affectedRequestCount == 2)
        let snapshot = try await queue.beginReview(failure)
        #expect(snapshot.requestIDs == [idA, idDependent])
        let receipt = try await queue.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"))
        let graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt.exportURL)) as? [String: Any])
        let requests = try #require(graph["requests"] as? [[String: Any]])
        #expect(requests.count == 2)
        let exportedChanges = try #require(requests[0]["changes"] as? [[String: Any]])
        #expect(exportedChanges.count == first.request.changes.count)
        #expect(exportedChanges.count > 20)
        #expect(requests[0]["jsonWasCommitted"] as? Bool == true)
        #expect(requests[0]["baselineRecordExisted"] as? Bool == true)
        #expect(requests[0]["originalImageSnapshot"] == nil)
        let captured = try #require(requests[0]["capturedMetadata"] as? [String: Any])
        #expect(captured["cameraRaw"] != nil)
        #expect(captured["orientation"] as? Int == 6)
        #expect(exportedChanges[0]["timestamp"] as? Double == first.request.changes[0].timestamp.timeIntervalSince1970)
        let result = try await queue.discardExported(snapshot, receipt: receipt)
        #expect(result.discardedCount == 2)
        #expect(result.remainingFailure == nil)
        #expect(order.values == ["B", "JPEG sibling", "C"])
        #expect(queue.pendingCount == 0)
        #expect(try protectedBytes(root) == before)
        let permissions = try FileManager.default.attributesOfItem(atPath: receipt.exportURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Cancelled review, failed export and failed verification remove no requests", arguments: [0, 1, 2])
    func failedExport(mode: Int) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try protectedBytes(root)
        let queue = CaptionDraftPersistenceQueue(label: "recovery.failure")
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { throw CaptionWorkspaceFlushError.replayConflict("A") })
        #expect(queue.pendingCount == 1)
        let snapshot = try await queue.beginReview(try #require(queue.currentFailure))
        if mode == 0 {
            await queue.endReview(snapshot)
        } else {
            let access = CaptionConflictExportAccess(writeAtomic: { data, url in
                if mode == 1 { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            }, read: { url in mode == 2 ? Data("wrong readback".utf8) : try Data(contentsOf: url) })
            await #expect(throws: (any Error).self) {
                _ = try await queue.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"), access: access)
            }
        }
        #expect(queue.pendingCount == 1)
        #expect(try protectedBytes(root) == before)
    }

    @Test("Tampered or deleted exports cannot authorize discard", arguments: [false, true])
    func exportChanged(deleted: Bool) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CaptionDraftPersistenceQueue(label: "recovery.tamper")
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { throw CaptionWorkspaceFlushError.replayConflict("A") })
        #expect(queue.pendingCount == 1)
        let snapshot = try await queue.beginReview(try #require(queue.currentFailure))
        let receipt = try await queue.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"))
        if deleted { try FileManager.default.removeItem(at: receipt.exportURL) }
        else { try Data("replacement".utf8).write(to: receipt.exportURL) }
        await #expect(throws: (any Error).self) { _ = try await queue.discardExported(snapshot, receipt: receipt) }
        #expect(queue.pendingCount == 1)
    }

    @Test("A late captured dependency invalidates export while unrelated arrivals preserve scope", arguments: [false, true])
    func lateAdmission(samePhoto: Bool) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CaptionDraftPersistenceQueue(label: "recovery.late")
        let order = LockedStrings()
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { throw CaptionWorkspaceFlushError.replayConflict("A") })
        #expect(queue.pendingCount == 1)
        let snapshot = try await queue.beginReview(try #require(queue.currentFailure))
        let receipt = try await queue.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"))
        queue.enqueue(persistence: draft(root.appendingPathComponent(samePhoto ? "a.ARW" : "b.JPG")), operation: { order.append("later") })
        #expect(queue.pendingCount == 2)
        if samePhoto {
            await #expect(throws: CaptionConflictRecoveryError.self) { _ = try await queue.discardExported(snapshot, receipt: receipt) }
            #expect(queue.pendingCount == 2)
            #expect(queue.currentFailure?.affectedRequestCount == 2)
            await queue.endReview(snapshot)
            let refreshed = try await queue.beginReview(try #require(queue.currentFailure))
            #expect(refreshed.requestCount == 2)
        } else {
            let result = try await queue.discardExported(snapshot, receipt: receipt)
            #expect(result.discardedCount == 1)
            #expect(order.values == ["later"])
        }
    }

    @Test("Protected metadata destinations and linked parents cannot receive exports", arguments: [0, 1, 2, 3])
    func unsafeDestination(kind: Int) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try protectedBytes(root)
        let queue = CaptionDraftPersistenceQueue(label: "recovery.paths")
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { throw CaptionWorkspaceFlushError.replayConflict("A") })
        #expect(queue.pendingCount == 1)
        let snapshot = try await queue.beginReview(try #require(queue.currentFailure))
        let destination: URL
        if kind == 0 { destination = root.appendingPathComponent(".photo_metadata/a.ARW.meta.json") }
        else if kind == 1 {
            destination = root.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: root.appendingPathComponent("a.ARW"))
        } else if kind == 2 {
            let link = root.appendingPathComponent("linked-folder")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            destination = link.appendingPathComponent("recovery.json")
        } else {
            let scratch = root.appendingPathComponent("scratch")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            destination = URL(fileURLWithPath: scratch.path + "/../.photo_metadata/a.ARW.meta.json")
        }
        await #expect(throws: CaptionConflictRecoveryError.self) { _ = try await queue.exportConflict(snapshot, to: destination) }
        #expect(queue.pendingCount == 1)
        #expect(try protectedBytes(root) == before)
    }

    @Test("A later transient failure is returned after successful scoped discard and remains retryable")
    func laterTransientFailure() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = CaptionDraftPersistenceQueue(label: "recovery.transient")
        let gate = PersistenceFailureGate()
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")), operation: { throw CaptionWorkspaceFlushError.replayConflict("A") })
        let idB = queue.enqueue(persistence: draft(root.appendingPathComponent("b.JPG")), operation: { try gate.attempt() })
        #expect(queue.pendingCount == 2)
        let snapshot = try await queue.beginReview(try #require(queue.currentFailure))
        let receipt = try await queue.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"))
        let result = try await queue.discardExported(snapshot, receipt: receipt)
        #expect(result.discardedCount == 1)
        #expect(result.remainingFailure?.id == idB)
        #expect(result.remainingFailure?.kind == .transient)
        #expect(queue.pendingCount == 1)
        gate.shouldFail = false
        try await queue.drainAsync()
        #expect(queue.pendingCount == 0)
        #expect(queue.currentFailure == nil)
    }

    @Test("Frozen review prevents retries and rejects editor admission before optimistic capture")
    @MainActor
    func frozenAdmission() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.ARW")
        let queue = CaptionDraftPersistenceQueue(label: "recovery.frozen")
        let attempts = LockedStrings()
        queue.enqueue(persistence: draft(image), operation: { attempts.append("attempt"); throw CaptionWorkspaceFlushError.replayConflict("A") })
        #expect(queue.pendingCount == 1)
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let snapshot = try await coordinator.beginConflictReview(try #require(queue.currentFailure))
        var captures = 0
        var flushes = 0
        coordinator.register(owner: UUID(), currentImageURL: { image }, capturePersistence: {
            captures += 1
            return nil
        }, handler: { flushes += 1 })
        #expect(throws: CaptionConflictRecoveryError.self) { try coordinator.enqueueFlush() }
        await #expect(throws: CaptionConflictRecoveryError.self) { try await queue.drainAsync() }
        #expect(captures == 0)
        #expect(flushes == 0)
        #expect(attempts.values.count == 1)
        await coordinator.endConflictReview(snapshot)
    }
}

private nonisolated final class DeferredCaptionFailureCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@MainActor @Sendable () -> Void] = []
    func schedule(_ callback: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { callbacks.append(callback) }
    }
    @MainActor func deliver() {
        let pending = lock.withLock { let pending = callbacks; callbacks.removeAll(); return pending }
        pending.forEach { $0() }
    }
}

extension CaptionConflictRecoveryTests {
    @Test("Already dispatched failure callbacks cannot re-block resolved state or replace a later failure")
    @MainActor
    func obsoleteFailureCallbacks() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let deferred = DeferredCaptionFailureCallbacks()
        let queue = CaptionDraftPersistenceQueue(label: "recovery.callbacks",
            failureDelivery: .init(schedule: deferred.schedule))
        let gate = PersistenceFailureGate()
        let messages = LockedStrings()
        queue.enqueue(persistence: draft(root.appendingPathComponent("a.ARW")),
            operation: { throw CaptionWorkspaceFlushError.replayConflict("obsolete A") },
            onFailure: { messages.append($0) })
        let idB = queue.enqueue(persistence: draft(root.appendingPathComponent("b.JPG")),
            operation: { try gate.attempt() }, onFailure: { messages.append($0) })
        #expect(queue.pendingCount == 2)
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let snapshot = try await coordinator.beginConflictReview(try #require(queue.currentFailure))
        let receipt = try await coordinator.exportConflict(snapshot, to: root.appendingPathComponent("recovery.json"))
        let result = try await coordinator.discardExportedConflict(snapshot, receipt: receipt)
        #expect(result.remainingFailure?.id == idB)
        deferred.deliver()
        #expect(!messages.values.contains("obsolete A"))
        #expect(coordinator.failure?.id == idB)
        gate.shouldFail = false
        try await coordinator.retryQueuedPersistence()
        deferred.deliver()
        #expect(coordinator.failure == nil)
        #expect(queue.pendingCount == 0)
    }
}

extension CaptionConflictRecoveryTests {
    @Test("A production replay conflict reaches the queue as a typed permanent failure")
    func productionReplayConflictClassification() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("b.JPG")
        let service = MetadataSidecarService()
        let baseline = MetadataSidecar(sourceFile: "b.JPG", pendingChanges: true, metadata: .init(title: "A"))
        try service.saveSidecar(baseline, for: image, in: root)
        let captured = draft(image)
        _ = try await service.updateMetadataSerialized(for: image, in: root, fallback: baseline.metadata,
            pendingChanges: true) { $0.title = "Newer C" }
        do {
            try captured.persist()
            Issue.record("The real replay boundary must reject the stale overlapping draft")
        } catch let error as CaptionWorkspaceFlushError {
            guard case .replayConflict(let message) = error else {
                Issue.record("Expected permanent typed replay conflict, got \(error)")
                return
            }
            #expect(!message.isEmpty)
        }
        let queue = CaptionDraftPersistenceQueue(label: "recovery.real-service")
        queue.enqueue(captured, onFailure: { _ in })
        #expect(queue.pendingCount == 1)
        #expect(queue.currentFailure?.kind == .replayConflict)
        #expect(queue.currentFailure?.photoURL == image.standardizedFileURL.resolvingSymlinksInPath())
        #expect(service.loadSidecar(for: image, in: root)?.metadata.title == "Newer C")
    }
}
