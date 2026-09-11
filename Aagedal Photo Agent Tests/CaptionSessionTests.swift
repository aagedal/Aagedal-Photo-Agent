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


@Suite("Metadata Review retained persistence")
struct MetadataReviewPersistenceTests {
    private func folder() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MetadataReviewCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a.JPG", "b.JPG"] { try Data("Source \(name)".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func creation(_ image: URL) async throws -> CaptionDraftPersistence {
        let previous = IPTCMetadata(title: "A")
        let evidence = MetadataSidecarReplayCreationEvidence(sourceRevision: try await SourceImageRevision.capture(at: image),
            xmpData: try XMPSidecarService().fieldMutationData(for: image))
        return try #require(try MetadataReviewDraftCapture.capture(previous: previous, edited: .init(title: "B"),
            baselineSidecar: nil, imageURL: image, folderURL: image.deletingLastPathComponent(), creationEvidence: evidence))
    }

    @Test("Capture retains every pre-trim field change, nil snapshot, orientation intent and opaque saved fields")
    func completeCapture() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let orientation = MetadataOrientationDraft(expectedOrientation: 1, targetOrientation: 6)
        let baseline = MetadataSidecar(sourceFile: "a.JPG", pendingChanges: true,
            metadata: .init(title: "A"), imageMetadataSnapshot: nil, orientationDraft: orientation)
        let service = MetadataSidecarService()
        try service.saveSidecar(baseline, for: image, in: root)
        let jsonURL = root.appendingPathComponent(".photo_metadata/a.JPG.meta.json")
        var graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        graph["futureExtension"] = ["opaque": "preserved"]
        try JSONSerialization.data(withJSONObject: graph).write(to: jsonURL)
        let loaded = try #require(try await MetadataReviewDraftCapture.loadBaseline(for: image, in: root))
        var edited = loaded.metadata
        for field in MetadataFieldID.allCases where !field.isRepeatable {
            field.setHistoryValue("Review \(field.rawValue)", in: &edited)
        }
        let captured = try #require(try MetadataReviewDraftCapture.capture(previous: loaded.metadata, edited: edited,
            baselineSidecar: loaded, imageURL: image, folderURL: root))
        #expect(captured.request.changes.count > MetadataSidecar.historyLimit)
        #expect(captured.sidecar.history.count == MetadataSidecar.historyLimit)
        #expect(captured.sidecar.imageMetadataSnapshot == nil)
        #expect(captured.sidecar.orientationDraft == orientation)
        let result = try captured.persist()
        #expect(result.metadata == edited)
        #expect(result.imageMetadataSnapshot == nil)
        #expect(result.orientationDraft == orientation)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        #expect((saved["futureExtension"] as? [String: String])?["opaque"] == "preserved")
    }

    @Test("First Review creation fails closed if the captured photo or XMP changed", arguments: [false, true])
    func staleCreationBeforeJSON(sourceChanged: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        if sourceChanged { try Data("new source bytes".utf8).write(to: image) }
        else { try XMPSidecarService().saveSidecar(metadata: .init(title: "External"), for: image) }
        let source = try Data(contentsOf: image)
        let xmp = try XMPSidecarService().fieldMutationData(for: image)
        let result = await MetadataSidecarService().replayHistoryAndMirrorXMP(captured.request)
        #expect(result.failure?.kind == .replayConflict)
        #expect(!captured.request.receipt.hasCommitted)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".photo_metadata/a.JPG.meta.json").path))
        #expect(try Data(contentsOf: image) == source)
        #expect(try XMPSidecarService().fieldMutationData(for: image) == xmp)
    }

    @Test("Creation evidence survives JSON success plus pre-mirror failure and rejects a changed retry baseline", arguments: [false, true])
    func staleCreationAfterJSON(sourceChanged: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        let service = MetadataSidecarService()
        let first = await service.replayHistoryAndMirrorXMP(captured.request,
            beforeXMPCommit: { throw CocoaError(.fileWriteNoPermission) })
        #expect(first.installedSidecar?.metadata.title == "B")
        #expect(captured.request.receipt.hasCommitted)
        #expect(!captured.request.receipt.creationMirrorCompleted)
        if sourceChanged { try Data("external source after JSON".utf8).write(to: image) }
        else { try XMPSidecarService().saveSidecar(metadata: .init(title: "External after JSON"), for: image) }
        let source = try Data(contentsOf: image)
        let xmp = try XMPSidecarService().fieldMutationData(for: image)
        let jsonURL = root.appendingPathComponent(".photo_metadata/a.JPG.meta.json")
        let json = try Data(contentsOf: jsonURL)
        let retry = await service.replayHistoryAndMirrorXMP(captured.request)
        #expect(retry.failure?.kind == .replayConflict)
        #expect(captured.request.receipt.creationEvidenceInvalidated)
        #expect(try Data(contentsOf: jsonURL) == json)
        #expect(try Data(contentsOf: image) == source)
        #expect(try XMPSidecarService().fieldMutationData(for: image) == xmp)
    }

    @Test("Creation proof cannot complete if source or XMP changes after the mirror commit", arguments: [false, true])
    func changedAfterMirrorCommit(sourceChanged: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        let service = MetadataSidecarService()
        let result = await service.replayHistoryAndMirrorXMP(captured.request, afterXMPCommit: {
            if sourceChanged { try Data("changed after mirror".utf8).write(to: image) }
            else { try XMPSidecarService().saveSidecar(metadata: .init(title: "External after mirror"), for: image) }
        })
        #expect(result.wroteXMPSidecar)
        #expect(result.failure?.kind == .replayConflict)
        #expect(captured.request.receipt.creationEvidenceInvalidated)
        #expect(!captured.request.receipt.creationMirrorCompleted)
        let source = try Data(contentsOf: image)
        let xmp = try XMPSidecarService().fieldMutationData(for: image)
        let retry = await service.replayHistoryAndMirrorXMP(captured.request)
        #expect(retry.failure?.kind == .replayConflict)
        #expect(try Data(contentsOf: image) == source)
        #expect(try XMPSidecarService().fieldMutationData(for: image) == xmp)
    }

    @Test("A known own XMP install remains retryable after the response fails")
    func ownInstalledMirrorReceipt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        let service = MetadataSidecarService()
        let first = await service.replayHistoryAndMirrorXMP(captured.request,
            afterXMPCommit: { throw CocoaError(.fileReadUnknown) })
        #expect(!first.completed)
        #expect(first.wroteXMPSidecar)
        #expect(!captured.request.receipt.creationMirrorCompleted)
        #expect(captured.request.receipt.creationInstalledXMPData == (try XMPSidecarService().fieldMutationData(for: image)))
        let retry = await service.replayHistoryAndMirrorXMP(captured.request)
        #expect(retry.completed)
        #expect(captured.request.receipt.creationMirrorCompleted)
        #expect(retry.installedSidecar?.metadata.title == "B")
    }

    @Test("Success callbacks carry the exact transaction record and applied retries return newer authoritative fields")
    @MainActor
    func exactSuccessReceipt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        let callbacks = DeferredCaptionFailureCallbacks()
        let queue = CaptionDraftPersistenceQueue(label: "review.receipts", failureDelivery: .init(schedule: callbacks.schedule))
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        var received: [UUID: MetadataSidecar] = [:]
        let firstID = try coordinator.enqueueCapturedDraft(captured, onSuccess: { received[$0] = $1 })
        try coordinator.flushQueuedPersistence() // No mounted Caption handler is required.
        _ = try await MetadataSidecarService().updateMetadataSerialized(for: image, in: root,
            fallback: .init(), pendingChanges: true) { $0.credit = "Independent later credit" }
        callbacks.deliver()
        #expect(received[firstID]?.metadata.title == "B")
        #expect(received[firstID]?.metadata.credit == nil) // No unrelated fresh load masquerades as this receipt.
        let retryID = try coordinator.enqueueCapturedDraft(captured, onSuccess: { received[$0] = $1 })
        try coordinator.flushQueuedPersistence()
        callbacks.deliver()
        #expect(received[retryID]?.metadata.credit == "Independent later credit")
        #expect(!coordinator.hasPendingPersistence)
    }

    @Test("Shared Review conflict export retains creation evidence, freezes admission and resumes unrelated actual writes")
    @MainActor
    func sharedScopedRecovery() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        let captured = try await creation(image)
        _ = await MetadataSidecarService().replayHistoryAndMirrorXMP(captured.request,
            beforeXMPCommit: { throw CocoaError(.fileWriteNoPermission) })
        try Data("external changed source".utf8).write(to: image)
        let b = try await creation(root.appendingPathComponent("b.JPG"))
        let queue = CaptionDraftPersistenceQueue(label: "review.shared-recovery")
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        let failedID = try coordinator.enqueueCapturedDraft(captured)
        _ = try coordinator.enqueueCapturedDraft(b)
        #expect(coordinator.hasPendingPersistence)
        #expect(queue.pendingCount == 2)
        let failure = try #require(queue.currentFailure)
        #expect(failure.id == failedID)
        #expect(failure.kind == .replayConflict)
        let review = try await coordinator.beginConflictReview(failure)
        #expect(throws: CaptionConflictRecoveryError.self) { _ = try coordinator.enqueueCapturedDraft(captured) }
        #expect(throws: CaptionConflictRecoveryError.self) { try coordinator.flushQueuedPersistence() }
        let exportURL = root.appendingPathComponent("review-recovery.json")
        let receipt = try await coordinator.exportConflict(review, to: exportURL)
        let graph = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any])
        let requests = try #require(graph["requests"] as? [[String: Any]])
        #expect(requests.count == 1)
        #expect(requests[0]["creationEvidence"] is [String: Any])
        #expect(requests[0]["creationEvidenceInvalidated"] as? Bool == true)
        #expect(requests[0]["jsonWasCommitted"] as? Bool == true)
        let discard = try await coordinator.discardExportedConflict(review, receipt: receipt)
        #expect(discard.discardedCount == 1)
        #expect(discard.remainingFailure == nil)
        #expect(MetadataSidecarService().loadSidecar(for: b.imageURL, in: root)?.metadata.title == "B")
        #expect(try Data(contentsOf: image) == Data("external changed source".utf8))
        #expect(!coordinator.hasPendingPersistence)
    }

    @Test("Lifecycle pending state includes admitted in-flight work without waiting for its I/O")
    @MainActor
    func inFlightPendingPublication() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = CaptionDraftPersistenceQueue(label: "review.in-flight")
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        queue.enqueue(operation: { started.signal(); release.wait() })
        defer { release.signal() }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
            }
        }
        try #require(didStart)
        #expect(coordinator.hasPendingPersistence)
        release.signal()
        try await coordinator.retryQueuedPersistence()
        #expect(!coordinator.hasPendingPersistence)
    }

    @Test("Review requires first-source evidence while legacy Caption requests retain their compatible default")
    func explicitProvenanceAndCompatibility() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("a.JPG")
        #expect(throws: CaptionWorkspaceFlushError.self) {
            _ = try MetadataReviewDraftCapture.capture(previous: .init(title: "A"), edited: .init(title: "B"),
                baselineSidecar: nil, imageURL: image, folderURL: root)
        }
        let captured = try await creation(image)
        let request = captured.request
        let legacy = MetadataSidecarReplayRequest(sidecar: request.sidecar, baselineMetadata: request.baselineMetadata,
            baselineHistory: request.baselineHistory, baselineRecordExisted: false, changes: request.changes,
            imageURL: image, folderURL: root)
        #expect(legacy.creationEvidence == nil)
        #expect(await MetadataSidecarService().replayHistoryAndMirrorXMP(legacy).completed)
    }
}
