import Foundation
import Testing
@testable import Aagedal_Photo_Agent

private nonisolated final class CaptionBaselineRetryGate: @unchecked Sendable {
    private enum Failure: Error { case injected }
    private let lock = NSLock()
    private var maySucceed = false
    private var attempts = 0

    var attemptCount: Int { lock.withLock { attempts } }
    func allowSuccess() { lock.withLock { maySucceed = true } }
    func attempt(_ request: CaptionDraftPersistence) throws {
        let succeeds = lock.withLock {
            attempts += 1
            return maySucceed
        }
        guard succeeds else { throw Failure.injected }
        try request.persist()
    }
}

private nonisolated final class HistoryRestoreFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false
    func failFirst() throws {
        let shouldFail = lock.withLock {
            if hasFailed { return false }
            hasFailed = true
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }
}

private actor HistoryRestoreSuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isPaused: Bool { continuation != nil }
    func pause() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Metadata editor sidecar read boundary", .serialized)
struct MetadataEditorReadServiceTests {
    @Test("Active headline buffer reaches the actual Caption Write before focus loss")
    @MainActor
    func activeHeadlineBufferReachesImmediateCaptionWrite() async throws {
        let writer = MetadataCompletionTestWriter {}
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "E"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let buffers = MetadataEditorBufferRegistry()
        var localText = "E"
        buffers.register(key: "title", owner: UUID(), loadID: fixture.model.editorBufferLoadID,
            read: { localText }, readModel: { fixture.model.editingMetadata.title ?? "" },
            readSynchronizedModel: { "E" })
        // Simulate the field's owned buffer changing while the model still holds E.
        localText = "Final immediate headline F"
        #expect(fixture.model.editingMetadata.title == "E")
        var updated = fixture.model.editingMetadata
        #expect(buffers.capture(key: "title", loadID: fixture.model.editorBufferLoadID,
            hasMarkedText: false, metadata: &updated) == .changed)
        fixture.model.editingMetadata = updated
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try captured.persist() }.value
        fixture.model.writeMetadataAndClearSidecar()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        #expect(fixture.model.saveError == nil)
        #expect(writer.writtenFields[.headline] == "Final immediate headline F")
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Final immediate headline F")
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder) == nil)
        #expect(CaptionWriteAndNextGate.shouldAdvance(pendingURL: fixture.image,
            currentURL: fixture.image, writeSucceeded: fixture.model.saveError == nil,
            hasPendingChanges: fixture.model.hasChanges,
            hasUnpersistedEditorChanges: fixture.model.hasUnpersistedEditorChanges))
    }

    @Test("Owned scalar buffers use their actual editor keys and preserve binding normalization", arguments: [
        "title", "description", "extendedDescription", "copyright", "rightsUsageTerms",
        "webStatementOfRights", "digitalImageGUID", "imageSupplierImageID", "jobId",
        "creatorJobTitle", "descriptionWriter", "credit", "source", "city", "sublocation",
        "provinceState", "country", "event", "instructions"
    ])
    @MainActor
    func bufferedScalarFieldMapping(key: String) throws {
        let buffers = MetadataEditorBufferRegistry()
        let loadID = UUID()
        var text = "  Exact text \n"
        buffers.register(key: key, owner: UUID(), loadID: loadID, read: { text })
        var metadata = IPTCMetadata()
        let field = try #require(MetadataFieldID(rawValue: key))
        #expect(buffers.capture(key: key, loadID: loadID, hasMarkedText: false, metadata: &metadata) == .changed)
        #expect(field.historyValue(in: metadata) == text)
        text = ""
        #expect(buffers.capture(key: key, loadID: loadID, hasMarkedText: false, metadata: &metadata) == .changed)
        #expect(field.historyValue(in: metadata) == nil)
    }

    @Test("A synchronous Quick List model update wins over the not-yet-refreshed local buffer")
    @MainActor
    func bufferedFieldCapturePreservesProgrammaticPick() {
        let buffers = MetadataEditorBufferRegistry()
        let loadID = UUID()
        var metadata = IPTCMetadata(credit: "Old credit")
        var modelText = "Old credit"
        buffers.register(key: "credit", owner: UUID(), loadID: loadID, read: { "Old local credit" },
            readModel: { modelText }, readSynchronizedModel: { "Old credit" })
        modelText = "Picked credit"
        metadata.credit = modelText
        #expect(buffers.capture(key: "credit", loadID: loadID, hasMarkedText: false, metadata: &metadata) == .unchanged)
        #expect(metadata.credit == "Picked credit")
        #expect(!MetadataEditorBufferRegistry.mayPublishBuffer(registeredLoadID: loadID,
            currentLoadID: UUID(), hasMarkedText: false))
        #expect(!MetadataEditorBufferRegistry.mayPublishBuffer(registeredLoadID: loadID,
            currentLoadID: loadID, hasMarkedText: true))
        #expect(MetadataEditorBufferRegistry.mayPublishBuffer(registeredLoadID: loadID,
            currentLoadID: loadID, hasMarkedText: false))
    }

    @Test("Buffer capture rejects IME, stale photo loads, and unsubmitted specialized inputs")
    @MainActor
    func bufferedFieldCapturePreservesOwnershipAndComposition() {
        let buffers = MetadataEditorBufferRegistry()
        let loadID = UUID()
        let oldOwner = UUID()
        let newOwner = UUID()
        var metadata = IPTCMetadata(title: "Saved")
        buffers.register(key: "title", owner: oldOwner, loadID: loadID, read: { "Old buffer" })
        buffers.register(key: "title", owner: newOwner, loadID: loadID, read: { "Current buffer" })
        buffers.unregister(key: "title", owner: oldOwner)
        #expect(buffers.capture(key: "title", loadID: loadID, hasMarkedText: true, metadata: &metadata) == .unavailable)
        #expect(buffers.capture(key: "title", loadID: UUID(), hasMarkedText: false, metadata: &metadata) == .unavailable)
        #expect(metadata.title == "Saved")
        for key in ["keywords", "personShown", "creator", "countryCode", "dateCreated", "genre", "gps", "unknown"] {
            buffers.register(key: key, owner: UUID(), loadID: loadID, read: { "Unsubmitted query" })
            #expect(buffers.capture(key: key, loadID: loadID, hasMarkedText: false, metadata: &metadata) == .unchanged)
        }
        #expect(metadata == IPTCMetadata(title: "Saved"))
        #expect(buffers.capture(key: "title", loadID: loadID, hasMarkedText: false, metadata: &metadata) == .changed)
        #expect(metadata.title == "Current buffer")
        buffers.unregister(key: "title", owner: newOwner)
        #expect(buffers.capture(key: "title", loadID: loadID, hasMarkedText: false, metadata: &metadata) == .unavailable)
    }

    @Test("Caption blur FIFO retry retains newer same-field and independent edits after a mirror failure")
    @MainActor
    func captionFIFOBlurRetryPreservesNewerEdits() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "A"))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let queue = CaptionDraftPersistenceQueue(label: "caption.blur.retry")
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        coordinator.register(owner: UUID(), capturePersistence: {
            try fixture.model.captureCaptionDraftPersistence()
        }, handler: {})
        let xmpURL = XMPSidecarService().sidecarURL(for: fixture.image)
        try FileManager.default.removeItem(at: xmpURL)
        try FileManager.default.createDirectory(at: xmpURL, withIntermediateDirectories: true)
        fixture.model.editingMetadata.title = "B"
        fixture.model.markChanged()
        // This is the same boundary now used by field blur/debounce and Caption navigation.
        try coordinator.enqueueFlush()
        do {
            try await queue.drainAsync()
            Issue.record("The obstructed XMP mirror should fail")
        } catch {}
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        var current = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        let originalHistory = current.history
        let previous = current.metadata
        current.metadata.title = "Newer headline C"
        current.metadata.credit = "Independent credit C"
        current.history.append(contentsOf: MetadataHistoryEntry.changes(from: previous, to: current.metadata, timestamp: Date()))
        try MetadataSidecarService().saveSidecar(current, for: fixture.image, in: fixture.folder)
        try FileManager.default.removeItem(at: xmpURL)
        try XMPSidecarService().saveSidecar(metadata: current.metadata, for: fixture.image)
        let jsonURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let beforeRetry = try Data(contentsOf: jsonURL)
        try coordinator.flush()
        #expect(queue.pendingCount == 0)
        #expect(try Data(contentsOf: jsonURL) == beforeRetry)
        let mirror = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        #expect(mirror.title == "Newer headline C")
        #expect(mirror.credit == "Independent credit C")
        let installed = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(installed.imageMetadataSnapshot?.title == "Original")
        #expect(installed.history.filter { originalHistory.map(\.id).contains($0.id) }.count == originalHistory.count)
    }

    @Test("Caption captures complete template mutations before the visible history limit")
    @MainActor
    func captionCapturesAllTemplateFields() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: IPTCMetadata())
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let fields: [WritableKeyPath<IPTCMetadata, String?>] = [
            \.title, \.description, \.extendedDescription, \.copyright, \.rightsUsageTerms,
            \.webStatementOfRights, \.digitalImageGUID, \.imageSupplierImageID, \.jobId,
            \.creatorJobTitle, \.descriptionWriter, \.credit, \.city, \.sublocation,
            \.provinceState, \.country, \.countryCode, \.event, \.instructions, \.source,
            \.dateCreated
        ]
        for (index, field) in fields.enumerated() {
            fixture.model.editingMetadata[keyPath: field] = field == \.dateCreated ? "2026-01-01"
                : field == \.countryCode ? "NOR" : "Value \(index)"
        }
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(captured.request.changes.count > 20)
        #expect(captured.sidecar.history.count == 20)
        try await Task.detached { try captured.persist() }.value
        let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        for field in fields { #expect(record.metadata[keyPath: field] == captured.sidecar.metadata[keyPath: field]) }
        // Retrying the same operation remains idempotent although its earliest event is trimmed.
        try await Task.detached { try captured.persist() }.value
    }

    @Test("Explicit Write after a durable Caption capture completes the exact captured revision")
    @MainActor
    func explicitWriteAfterCaptionCapture() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: IPTCMetadata(title: "A"))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Captured B"
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try captured.persist() }.value
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        guard case .succeeded = result else { Issue.record("Explicit Write failed: \(result)"); return }
        let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(record.metadata.title == "Captured B")
        #expect(record.imageMetadataSnapshot?.title == "Captured B")
        #expect(!record.pendingChanges)
        #expect(!fixture.model.hasChanges)
    }

    @Test("Actual Caption Write and Next clears the exact draft just persisted by its FIFO")
    @MainActor
    func captionWriteAndClearAfterFreshCapture() async throws {
        let writer = MetadataCompletionTestWriter {}
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: IPTCMetadata(title: "A"),
            writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Fresh captured B"
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try captured.persist() }.value
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.metadata.title == "Fresh captured B")
        // This is the actual Caption Write/Write & Next entry, which intentionally removes JSON.
        fixture.model.writeMetadataAndClearSidecar()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        #expect(writer.writeCount == 1)
        #expect(fixture.model.saveError == nil)
        #expect(!fixture.model.hasChanges)
        #expect(fixture.model.editingMetadata.title == "Fresh captured B")
        #expect(fixture.model.sidecarHistory.isEmpty)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder) == nil)
        #expect(CaptionWriteAndNextGate.shouldAdvance(pendingURL: fixture.image,
            currentURL: fixture.image, writeSucceeded: fixture.model.saveError == nil,
            hasPendingChanges: fixture.model.hasChanges,
            hasUnpersistedEditorChanges: fixture.model.hasUnpersistedEditorChanges))
    }

    @Test("Write and Next retains and can persist a newer same-photo buffer typed during the image write")
    @MainActor
    func captionWriteAndNextPreservesNewerEditorBuffer() async throws {
        let gate = HistoryRestoreSuspensionGate()
        let writer = MetadataCompletionTestWriter { await gate.pause() }
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "A"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Captured B"
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try captured.persist() }.value
        fixture.model.writeMetadataAndClearSidecar()
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < admissionDeadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        fixture.model.editingMetadata.title = "New buffer D"
        fixture.model.markChanged()
        await gate.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.editingMetadata.title == "New buffer D")
        #expect(fixture.model.hasUnpersistedEditorChanges)
        #expect(fixture.model.hasChanges)
        #expect(!CaptionWriteAndNextGate.shouldAdvance(pendingURL: fixture.image,
            currentURL: fixture.image, writeSucceeded: fixture.model.saveError == nil,
            hasPendingChanges: fixture.model.hasChanges,
            hasUnpersistedEditorChanges: fixture.model.hasUnpersistedEditorChanges))
        // The app's own successful cleanup must not look like an external discard to the new draft.
        let newer = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(!newer.request.baselineRecordExisted)
        try await Task.detached { try newer.persist() }.value
        let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(record.metadata.title == "New buffer D")
        #expect(record.imageMetadataSnapshot?.title == "Captured B")
        #expect(record.pendingChanges)
        #expect(!CaptionWriteAndNextGate.shouldAdvance(pendingURL: fixture.image,
            currentURL: fixture.image, writeSucceeded: true,
            hasPendingChanges: fixture.model.hasChanges,
            hasUnpersistedEditorChanges: fixture.model.hasUnpersistedEditorChanges))
    }

    @Test("Caption cleanup retains ancestry for a captured draft whose persistence is delayed", arguments: [false, true])
    @MainActor
    func captionCleanupRetainsDelayedCapturedDraft(changeSelection: Bool) async throws {
        let gate = HistoryRestoreSuspensionGate()
        let writer = MetadataCompletionTestWriter { await gate.pause() }
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "A"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Captured B"
        fixture.model.markChanged()
        let first = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try first.persist() }.value
        fixture.model.writeMetadataAndClearSidecar()
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < admissionDeadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        fixture.model.editingMetadata.title = "Delayed D"
        fixture.model.markChanged()
        let delayed = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(delayed.request.baselineRecordExisted)
        if changeSelection {
            await loadCaptionFixture(fixture.model, image: fixture.folder.appendingPathComponent("other.jpg"), folder: fixture.folder)
        }
        await gate.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        let retained = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(retained.metadata.title == "Captured B")
        #expect(retained.pendingChanges)
        try await Task.detached { try delayed.persist() }.value
        let installed = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(installed.metadata.title == "Delayed D")
        #expect(installed.pendingChanges)
        #expect(installed.imageMetadataSnapshot?.title == "Original")
    }

    @Test("Reloading the same photo before cleanup retains a valid baseline for its next Caption draft")
    @MainActor
    func captionCleanupRetainsBaselineAcrossSamePhotoReload() async throws {
        let gate = HistoryRestoreSuspensionGate()
        let writer = MetadataCompletionTestWriter { await gate.pause() }
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "A"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Captured B"
        fixture.model.markChanged()
        let first = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try first.persist() }.value
        fixture.model.writeMetadataAndClearSidecar()
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < admissionDeadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(fixture.model.editingMetadata.title == "Captured B")
        await gate.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        let retained = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(retained.metadata.title == "Captured B")
        fixture.model.editingMetadata.title = "After reload D"
        fixture.model.markChanged()
        let newer = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(newer.request.baselineRecordExisted)
        try await Task.detached { try newer.persist() }.value
        let installed = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(installed.metadata.title == "After reload D")
        #expect(installed.imageMetadataSnapshot?.title == "Original")
        #expect(installed.pendingChanges)
    }

    @Test("Actual Caption Write retains a newer draft saved while its image writer runs")
    @MainActor
    func captionWriteAndClearRetainsNewerDraft() async throws {
        let gate = HistoryRestoreSuspensionGate()
        let writer = MetadataCompletionTestWriter { await gate.pause() }
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "A"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Captured B"
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        try await Task.detached { try captured.persist() }.value
        fixture.model.writeMetadataAndClearSidecar()
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < admissionDeadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        var newer = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        let previous = newer.metadata
        newer.metadata.title = "Independent C"
        newer.history.append(contentsOf: MetadataHistoryEntry.changes(from: previous, to: newer.metadata, timestamp: Date()))
        try MetadataSidecarService().saveSidecar(newer, for: fixture.image, in: fixture.folder)
        let jsonURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let expected = try Data(contentsOf: jsonURL)
        await gate.resume()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        #expect(writer.writeCount == 1)
        #expect(fixture.model.saveError?.contains("newer pending sidecar changes were retained") == true)
        #expect(fixture.model.hasChanges)
        #expect(try Data(contentsOf: jsonURL) == expected)
        #expect(!CaptionWriteAndNextGate.shouldAdvance(pendingURL: fixture.image,
            currentURL: fixture.image, writeSucceeded: fixture.model.saveError == nil,
            hasPendingChanges: fixture.model.hasChanges,
            hasUnpersistedEditorChanges: fixture.model.hasUnpersistedEditorChanges))
    }

    @Test("Image Write completion cannot clear or mirror over a newer pending draft", arguments: [false, true])
    @MainActor
    func embeddedCompletionPreservesNewerDraft(changeSelection: Bool) async throws {
        let gate = HistoryRestoreSuspensionGate()
        let writer = MetadataCompletionTestWriter { await gate.pause() }
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Written B"), writeEngine: writer)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let commit = Task { @MainActor in
            await withCheckedContinuation { continuation in
                fixture.model.commitEditsReportingResult(mode: .writeToFile) { continuation.resume(returning: $0) }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        var newer = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        let previous = newer.metadata
        newer.metadata.title = "Newer C"
        newer.metadata.credit = "Independent C"
        newer.history.append(contentsOf: MetadataHistoryEntry.changes(from: previous, to: newer.metadata, timestamp: Date()))
        try MetadataSidecarService().saveSidecar(newer, for: fixture.image, in: fixture.folder)
        try XMPSidecarService().saveSidecar(metadata: newer.metadata, for: fixture.image)
        let jsonURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let xmpURL = XMPSidecarService().sidecarURL(for: fixture.image)
        let expectedJSON = try Data(contentsOf: jsonURL)
        let expectedXMP = try Data(contentsOf: xmpURL)
        if changeSelection {
            await loadCaptionFixture(fixture.model, image: fixture.folder.appendingPathComponent("other.jpg"), folder: fixture.folder)
        }
        await gate.resume()
        let result = await commit.value
        guard case .failed = result else { Issue.record("Newer draft must prevent completion: \(result)"); return }
        #expect(writer.writeCount == 1)
        if changeSelection {
            #expect(fixture.model.saveError == nil)
            #expect(fixture.model.editingMetadata.title != "Written B")
        } else {
            #expect(fixture.model.saveError?.contains("image metadata was written") == true)
            #expect(fixture.model.hasChanges)
        }
        #expect(!fixture.model.isSaving)
        #expect(try Data(contentsOf: jsonURL) == expectedJSON)
        #expect(try Data(contentsOf: xmpURL) == expectedXMP)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.imageMetadataSnapshot?.title == "Original")
    }

    @Test("Develop-only explicit XMP writes commit technical state without inventing editorial history")
    @MainActor
    func developOnlyXMPWriteCompletes() async throws {
        var pending = IPTCMetadata(title: "Pending headline")
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        pending.cameraRaw = settings
        pending.exifOrientation = 6
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"), pending: pending)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.cameraRaw?.exposure2012 = 1.25
        fixture.model.markChanged()
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        #expect(fixture.model.hasUnpersistedEditorChanges)
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        guard case .succeeded = result else { Issue.record("Develop Write failed: \(result)"); return }
        let mirror = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        #expect(mirror.cameraRaw?.exposure2012 == 1.25)
        #expect(mirror.exifOrientation == 6)
        #expect(mirror.title == "Pending headline")
        let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(record.history.isEmpty)
        #expect(!record.pendingChanges)
        #expect(record.imageMetadataSnapshot?.title == "Pending headline")
        #expect(!fixture.model.hasUnpersistedEditorChanges)
    }

    @Test("A mixed Caption capture leaves technical edits pending for the next explicit Write")
    @MainActor
    func mixedCaptionCaptureDoesNotAcknowledgeTechnicalEdits() async throws {
        var pending = IPTCMetadata(title: "A")
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        pending.cameraRaw = settings
        pending.exifOrientation = 6
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: pending)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "B"
        fixture.model.editingMetadata.cameraRaw?.exposure2012 = 1.25
        fixture.model.editingMetadata.exifOrientation = 8
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(captured.request.changes.count == 1)
        try await Task.detached { try captured.persist() }.value
        let editorialMirror = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        #expect(editorialMirror.title == "B")
        #expect(editorialMirror.cameraRaw?.exposure2012 == 0.5)
        #expect(editorialMirror.exifOrientation == 6)
        #expect(fixture.model.editingMetadata.cameraRaw?.exposure2012 == 1.25)
        #expect(fixture.model.editingMetadata.exifOrientation == 8)
        #expect(fixture.model.hasUnpersistedEditorChanges)
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        guard case .succeeded = result else { Issue.record("Mixed technical Write failed: \(result)"); return }
        let completed = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        #expect(completed.title == "B")
        #expect(completed.cameraRaw?.exposure2012 == 1.25)
        #expect(completed.exifOrientation == 8)
        #expect(!fixture.model.hasUnpersistedEditorChanges)
        #expect(!fixture.model.hasChanges)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.history.count == 1)
    }

    @Test("A technical edit that arrives before Write admission is not overwritten")
    @MainActor
    func externalTechnicalEditBeforeWriteAdmissionIsPreserved() async throws {
        var pending = IPTCMetadata(title: "Pending")
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        pending.cameraRaw = settings
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: pending)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.cameraRaw?.exposure2012 = 0.75
        fixture.model.markChanged()
        var external = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        external.cameraRaw?.exposure2012 = 1.25
        try XMPSidecarService().saveSidecar(metadata: external, for: fixture.image)
        let jsonURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let xmpURL = XMPSidecarService().sidecarURL(for: fixture.image)
        let jsonBefore = try Data(contentsOf: jsonURL)
        let xmpBefore = try Data(contentsOf: xmpURL)
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        guard case .failed = result else { Issue.record("Changed technical reference must conflict: \(result)"); return }
        #expect(fixture.model.hasUnpersistedEditorChanges)
        #expect(fixture.model.saveError != nil)
        #expect(try Data(contentsOf: jsonURL) == jsonBefore)
        #expect(try Data(contentsOf: xmpURL) == xmpBefore)
    }

    @Test("A technical history-only save retains the pending editorial baseline")
    @MainActor
    func technicalPendingSavePreservesOriginal() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.75
        fixture.model.editingMetadata.cameraRaw = settings
        fixture.model.markChanged()
        fixture.model.saveToSidecar()
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isSaving, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!fixture.model.isSaving)
        #expect(fixture.model.saveError == nil)
        let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(record.pendingChanges)
        #expect(record.history.isEmpty)
        #expect(record.imageMetadataSnapshot?.title == "Original")
        #expect(record.metadata.title == "Pending")
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.cameraRaw?.exposure2012 == 0.75)
        #expect(!fixture.model.hasUnpersistedEditorChanges)
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) { continuation.resume(returning: $0) }
        }
        guard case .succeeded = result else { Issue.record("Normalized technical baseline must permit the next Write: \(result)"); return }
        #expect(!fixture.model.hasChanges)
    }

    @Test("Visible field markers compare pending originals independently of the selected XMP reference")
    @MainActor
    func fieldMarkersUseSavedPendingOriginal() async throws {
        var pending = IPTCMetadata(title: "Pending headline", description: "Pending caption")
        pending.keywords = ["Pending keyword"]
        pending.personShown = ["Pending person"]
        pending.organisationsShownNames = ["Pending organisation"]
        pending.organisationsShownCodes = ["Pending code"]
        pending.sceneCodes = ["010100"]
        pending.subjectCodes = ["01000000"]
        pending.mediaTopics = [.init(termIdentifier: "http://cv.iptc.org/newscodes/mediatopic/20000000")]
        pending.genres = [.init(termIdentifier: "http://cv.iptc.org/newscodes/genre/Feature")]
        pending.urgency = 1
        pending.latitude = 59
        pending.longitude = 10
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: pending)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        for reference in [MetadataReferenceSource.embedded, .xmp] {
            fixture.model.applyReferenceSource(reference)
            #expect(fixture.model.fieldDiffers(\.title))
            #expect(fixture.model.fieldDiffers(\.description))
            #expect(fixture.model.keywordsDiffer())
            #expect(fixture.model.personShownDiffer())
            #expect(fixture.model.organisationShownNamesDiffer())
            #expect(fixture.model.organisationShownCodesDiffer())
            #expect(fixture.model.sceneCodesDiffer())
            #expect(fixture.model.subjectCodesDiffer())
            #expect(fixture.model.mediaTopicsDiffer())
            #expect(fixture.model.genresDiffer())
            #expect(fixture.model.urgencyDiffers())
            #expect(fixture.model.gpsDiffers())
        }
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.hasChanges)
        #expect(!fixture.model.fieldDiffers(\.title))
        #expect(!fixture.model.fieldDiffers(\.description))
        #expect(!fixture.model.keywordsDiffer())
        #expect(!fixture.model.gpsDiffers())
    }

    @Test("Original restores exact pending editorial state while preserving Develop and the immutable baseline", arguments: [false, true])
    @MainActor
    func originalRestoreIsDurableAndRepeatable(clearTitles: Bool) async throws {
        let original = IPTCMetadata(title: "Original headline", description: "Original caption")
        var pending = IPTCMetadata(title: "Pending headline", description: "Pending caption")
        pending.localizedTitles = clearTitles ? [] : [.init(languageTag: "nb", value: "Overskrift")]
        var develop = CameraRawSettings()
        develop.exposure2012 = 0.5
        pending.cameraRaw = develop
        pending.exifOrientation = 6
        let fixture = try makeHistoryRestoreFixture(original: original, pending: pending)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let imageBefore = try Data(contentsOf: fixture.image)
        let referenceBefore = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
        #expect(referenceBefore.cameraRaw?.exposure2012 == 0.5)
        #expect(referenceBefore.exifOrientation == 6)
        for _ in 0..<2 {
            await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
            #expect(fixture.model.editingMetadata.cameraRaw == referenceBefore.cameraRaw)
            #expect(fixture.model.editingMetadata.exifOrientation == referenceBefore.exifOrientation)
            #expect(fixture.model.canRestoreOriginalHistory)
            await fixture.model.restoreToOriginal()?.value
            #expect(fixture.model.saveError == nil)
            #expect(!fixture.model.isSaving)
            let record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
            #expect(record.pendingChanges)
            #expect(record.imageMetadataSnapshot == original)
            #expect(record.metadata.title == original.title)
            #expect(record.metadata.description == original.description)
            // IPTCMetadata deliberately serializes only editorial data in JSON; Develop and
            // orientation remain authoritative in XMP and must survive both editor reloads.
            #expect(record.metadata.cameraRaw == nil)
            #expect(record.metadata.exifOrientation == nil)
            #expect(fixture.model.editingMetadata.cameraRaw == referenceBefore.cameraRaw)
            #expect(fixture.model.editingMetadata.exifOrientation == referenceBefore.exifOrientation)
            let mirror = try #require(XMPSidecarService().loadSidecar(for: fixture.image))
            #expect(mirror.title == original.title)
            #expect(mirror.description == original.description)
            #expect(mirror.localizedTitles == nil)
            #expect(mirror.cameraRaw == referenceBefore.cameraRaw)
            #expect(mirror.exifOrientation == referenceBefore.exifOrientation)
            #expect(fixture.model.hasChanges)
            #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        }
        #expect(try Data(contentsOf: fixture.image) == imageBefore)
    }

    @Test("History reversal retains edits older than the retained log and survives further restores")
    @MainActor
    func historyRestoreRetainsTrimmedEdits() async throws {
        var current = IPTCMetadata(title: "Headline 0", credit: "Older retained credit")
        var history: [MetadataHistoryEntry] = []
        for index in 1...25 {
            history.append(MetadataHistoryEntry(timestamp: Date(timeIntervalSince1970: Double(index)),
                fieldID: .headline, oldValue: "Headline \(index - 1)", newValue: "Headline \(index)"))
        }
        history.trimToHistoryLimit()
        current.title = "Headline 25"
        let original = IPTCMetadata(title: "Original", credit: "Original credit")
        let fixture = try makeHistoryRestoreFixture(original: original, pending: current, history: history)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        await fixture.model.restoreToHistoryPoint(at: 10)?.value
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.editingMetadata.title == history[10].newValue)
        #expect(fixture.model.editingMetadata.credit == "Older retained credit")
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError == nil)
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        // The original end-of-log point remains reachable by reversing explicit restoration deltas.
        let originalEnd = try #require(fixture.model.sidecarHistory.firstIndex { $0.id == history.last?.id })
        await fixture.model.restoreToHistoryPoint(at: originalEnd)?.value
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.editingMetadata.title == "Headline 25")
        #expect(fixture.model.editingMetadata.credit == "Older retained credit")
        fixture.model.editingMetadata.title = "New edit after restore"
        fixture.model.markChanged()
        let draft = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(draft.sidecar.imageMetadataSnapshot == original)
        try await Task.detached { try draft.persist() }.value
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(fixture.model.editingMetadata.title == "New edit after restore")
        #expect(fixture.model.pendingFieldNames.contains("Headline"))
    }

    @Test("A clicked legacy history index remains distinct when event IDs collide")
    @MainActor
    func legacyDuplicateHistoryIDsRestoreClickedIndex() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let history = try decoder.decode([MetadataHistoryEntry].self, from: Data("""
        [
          {"timestamp":"2026-01-01T00:00:00Z","fieldName":"Headline","oldValue":"A","newValue":"B"},
          {"timestamp":"2026-01-01T00:00:00Z","fieldName":"Headline","oldValue":"B","newValue":"C"},
          {"timestamp":"2026-01-01T00:00:00Z","fieldName":"Headline","oldValue":"C","newValue":"D"}
        ]
        """.utf8))
        #expect(Set(history.map(\.id)).count == 1)
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "A"),
            pending: IPTCMetadata(title: "D"), history: history)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        await fixture.model.restoreToHistoryPoint(at: 1)?.value
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.editingMetadata.title == "C")
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "C")
    }

    @Test("Restore rejects changed JSON or XMP before replacing either carrier", arguments: [false, true])
    @MainActor
    func staleRestorePreservesExternalChanges(changeJSON: Bool) async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        if changeJSON {
            var record = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
            record.metadata.title = "External"
            try MetadataSidecarService().saveSidecar(record, for: fixture.image, in: fixture.folder)
        } else {
            try XMPSidecarService().saveSidecar(metadata: IPTCMetadata(title: "External"), for: fixture.image)
        }
        let jsonURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let xmpURL = XMPSidecarService().sidecarURL(for: fixture.image)
        let jsonBefore = try Data(contentsOf: jsonURL)
        let xmpBefore = try Data(contentsOf: xmpURL)
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError?.contains("not restored") == true)
        #expect(fixture.model.editingMetadata.title == "Pending")
        #expect(try Data(contentsOf: jsonURL) == jsonBefore)
        #expect(try Data(contentsOf: xmpURL) == xmpBefore)
    }

    @Test("Cancellation after JSON commit reports its durable pending result")
    @MainActor
    func cancellationAfterJSONCommitIsVisible() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"), persist: { request in
                await MetadataSidecarService().restoreSidecarAndMirrorXMP(request, beforeXMPCommit: {
                    throw CancellationError()
                })
            })
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.editingMetadata.title == "Original")
        #expect(fixture.model.hasChanges)
        #expect(!fixture.model.isSaving)
        #expect(fixture.model.saveError?.contains("cancelled") == true)
        #expect(fixture.model.saveError?.contains("draft was saved") == true)
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Pending")
    }

    @Test("Missing original, invalid history, and unflushed edits fail without changing disk")
    @MainActor
    func unsafeHistoryRestorePreservesBytes() async throws {
        let fixture = try makeHistoryRestoreFixture(original: nil, pending: IPTCMetadata(title: "Pending"))
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let recordURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let before = try Data(contentsOf: recordURL)
        #expect(!fixture.model.canRestoreOriginalHistory)
        #expect(fixture.model.restoreToOriginal() == nil)
        #expect(fixture.model.saveError?.contains("unavailable") == true)
        #expect(fixture.model.restoreToHistoryPoint(at: -1) == nil)
        #expect(fixture.model.restoreToHistoryPoint(at: 100) == nil)
        #expect(try Data(contentsOf: recordURL) == before)

        let editable = try makeHistoryRestoreFixture(original: IPTCMetadata(), pending: IPTCMetadata(title: "Pending"))
        defer { try? FileManager.default.removeItem(at: editable.folder) }
        await loadCaptionFixture(editable.model, image: editable.image, folder: editable.folder)
        editable.model.editingMetadata.title = "Unflushed edit"
        editable.model.markChanged()
        #expect(editable.model.restoreToOriginal() == nil)
        #expect(editable.model.saveError?.contains("Finish saving") == true)
        #expect(MetadataSidecarService().loadSidecar(for: editable.image, in: editable.folder)?.metadata.title == "Pending")
    }

    @Test("Summarized or inconsistent later history is never partially replayed", arguments: [false, true])
    @MainActor
    func unverifiableHistoryFails(inconsistent: Bool) async throws {
        let history = [
            MetadataHistoryEntry(timestamp: Date(timeIntervalSince1970: 1), fieldID: .headline, oldValue: "A", newValue: "B"),
            inconsistent
                ? MetadataHistoryEntry(timestamp: Date(timeIntervalSince1970: 2), fieldID: .headline, oldValue: "B", newValue: "Wrong")
                : MetadataHistoryEntry(timestamp: Date(timeIntervalSince1970: 2), fieldID: .description, oldValue: "A", newValue: "B")
        ]
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(),
            pending: IPTCMetadata(title: "C", description: "B"), history: history)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(fixture.model.restoreToHistoryPoint(at: 0) == nil)
        #expect(fixture.model.saveError != nil)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.metadata.title == "C")
    }

    @Test("A JSON-committed mirror failure remains pending and the same Restore retries its mirror")
    @MainActor
    func partialRestoreCanRetrySameTarget() async throws {
        let gate = HistoryRestoreFailureGate()
        let original = IPTCMetadata(title: "Original")
        let fixture = try makeHistoryRestoreFixture(original: original, pending: IPTCMetadata(title: "Pending"),
            persist: { request in
                await MetadataSidecarService().restoreSidecarAndMirrorXMP(request, beforeXMPCommit: {
                    try gate.failFirst()
                })
            })
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError?.contains("XMP mirror is incomplete") == true)
        #expect(fixture.model.editingMetadata.title == "Original")
        #expect(fixture.model.hasChanges)
        #expect(!fixture.model.isSaving)
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Pending")
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError == nil)
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Original")
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.imageMetadataSnapshot == original)
    }

    @Test("A post-commit verification failure reports its path without publishing unverified state")
    @MainActor
    func unverifiedRestoreReportsCommittedPath() async throws {
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"), persist: { request in
                await MetadataSidecarService().restoreSidecarAndMirrorXMP(request, afterJSONCommit: {
                    throw CocoaError(.fileReadUnknown)
                })
            })
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        await fixture.model.restoreToOriginal()?.value
        #expect(fixture.model.saveError?.contains("could not be verified") == true)
        #expect(fixture.model.saveError?.contains("draft.jpg.meta.json") == true)
        #expect(fixture.model.editingMetadata.title == "Pending")
        #expect(!fixture.model.isSaving)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.metadata.title == "Original")
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Pending")
    }

    @Test("Cancelled Restore clears its own busy state and selection changes reject obsolete completions", arguments: [false, true])
    @MainActor
    func cancelledOrObsoleteRestoreCannotPublish(switchSelection: Bool) async throws {
        let gate = HistoryRestoreSuspensionGate()
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"), persist: { request in
                await gate.pause()
                return await MetadataSidecarService().restoreSidecarAndMirrorXMP(request)
            })
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let task = try #require(fixture.model.restoreToOriginal())
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        if switchSelection {
            await loadCaptionFixture(fixture.model,
                image: fixture.folder.appendingPathComponent("other.jpg"), folder: fixture.folder)
        } else {
            task.cancel()
        }
        await gate.resume()
        await task.value
        #expect(!fixture.model.isSaving)
        if switchSelection {
            #expect(fixture.model.editingMetadata.title != "Original")
            #expect(fixture.model.saveError == nil)
        } else {
            #expect(fixture.model.editingMetadata.title == "Pending")
            #expect(fixture.model.saveError?.contains("cancelled") == true)
        }
    }

    @Test("Cancellation after a completed transaction reports the actual durable restoration")
    @MainActor
    func completedRestoreSurvivesLateCallerCancellation() async throws {
        let gate = HistoryRestoreSuspensionGate()
        let fixture = try makeHistoryRestoreFixture(original: IPTCMetadata(title: "Original"),
            pending: IPTCMetadata(title: "Pending"), persist: { request in
                let result = await MetadataSidecarService().restoreSidecarAndMirrorXMP(request)
                await gate.pause()
                return result
            })
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        let task = try #require(fixture.model.restoreToOriginal())
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await gate.isPaused), ContinuousClock.now < deadline { await Task.yield() }
        let paused = await gate.isPaused
        try #require(paused)
        task.cancel()
        await gate.resume()
        await task.value
        #expect(!fixture.model.isSaving)
        #expect(fixture.model.saveError == nil)
        #expect(fixture.model.editingMetadata.title == "Original")
        #expect(fixture.model.hasChanges)
        #expect(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder)?.metadata.title == "Original")
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.title == "Original")
    }

    @MainActor
    private func makeHistoryRestoreFixture(
        original: IPTCMetadata?, pending: IPTCMetadata, history: [MetadataHistoryEntry] = [],
        writeEngine: any MetadataWriteEngine = MetadataCleanupSuccessfulWriter(),
        persist: @escaping @Sendable (MetadataSidecarRestoreRequest) async -> MetadataSidecarPersistenceResult = {
            await MetadataSidecarService().restoreSidecarAndMirrorXMP($0)
        }
    ) throws -> (folder: URL, image: URL, model: MetadataViewModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("draft.jpg")
        // The injected reader supplies source facts. The image bytes must remain untouched.
        try Data("unchanged image fixture".utf8).write(to: image)
        try MetadataSidecarService().saveSidecar(MetadataSidecar(sourceFile: image.lastPathComponent,
            pendingChanges: true, metadata: pending, imageMetadataSnapshot: original, history: history),
            for: image, in: folder)
        try XMPSidecarService().saveSidecar(metadata: pending, for: image)
        let boundary = MetadataEditorReadService(access: .init(read: { url, folder, _, _ in
            MetadataEditorSourceFacts(imageURL: url, xmpMetadata: XMPSidecarService().loadSidecar(for: url),
                appSidecar: folder.flatMap { MetadataSidecarService().loadSidecar(for: url, in: $0) },
                reconciliationVerdict: nil)
        }))
        return (folder, image, MetadataViewModel(readService: SwiftExifReadService(),
            writeEngine: writeEngine, editorReadService: boundary,
            persistHistoryRestore: persist))
    }

    @Test("Untouched pending Caption drafts never enqueue a write or change their baseline", arguments: [false, true])
    @MainActor
    func untouchedCaptionDraftIsReadOnly(hasMirroredXMP: Bool) async throws {
        let fixture = try makePendingCaptionFixture(hasMirroredXMP: hasMirroredXMP)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let sidecarURL = fixture.folder.appendingPathComponent(".photo_metadata/draft.jpg.meta.json")
        let before = try Data(contentsOf: sidecarURL)
        let xmpURL = XMPSidecarService().sidecarURL(for: fixture.image)
        let xmpBefore = try? Data(contentsOf: xmpURL)
        for _ in 0..<2 {
            await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
            #expect(fixture.model.hasChanges)
            #expect(!fixture.model.hasUnpersistedEditorChanges)
            #expect(fixture.model.pendingFieldNames.contains("Description"))
            #expect(fixture.model.fieldDiffers(\.description))
            #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
            #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        }
        #expect(try Data(contentsOf: sidecarURL) == before)
        #expect((try? Data(contentsOf: xmpURL)) == xmpBefore)
    }

    @Test("A new Caption edit preserves the pending snapshot across source switches and reloads", arguments: [false, true])
    @MainActor
    func changedCaptionDraftPreservesBaseline(legacyMissingSnapshot: Bool) async throws {
        let fixture = try makePendingCaptionFixture(
            hasMirroredXMP: true, legacyMissingSnapshot: legacyMissingSnapshot
        )
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(fixture.model.originalImageMetadata?.description == "Pending caption")
        fixture.model.applyReferenceSource(.embedded)
        fixture.model.applyReferenceSource(.xmp)
        fixture.model.editingMetadata.title = "New headline"
        fixture.model.markChanged()
        #expect(fixture.model.hasUnpersistedEditorChanges)
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        #expect(captured.sidecar.imageMetadataSnapshot?.description == nil)
        #expect((captured.sidecar.imageMetadataSnapshot == nil) == legacyMissingSnapshot)
        #expect(captured.sidecar.metadata.description == "Pending caption")
        #expect(captured.sidecar.history.count == 1)
        #expect(captured.sidecar.history.first?.fieldID == .headline)
        #expect(captured.sidecar.history.first?.newValue == "New headline")
        #expect(!fixture.model.hasUnpersistedEditorChanges)
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        try await Task.detached { try captured.persist() }.value
        let installed = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(installed.pendingChanges)
        #expect(installed.metadata.title == "New headline")
        #expect(installed.imageMetadataSnapshot?.description == nil)
        #expect((installed.imageMetadataSnapshot == nil) == legacyMissingSnapshot)

        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(fixture.model.hasChanges)
        #expect(!fixture.model.hasUnpersistedEditorChanges)
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        if !legacyMissingSnapshot {
            #expect(Set(fixture.model.pendingFieldNames).isSuperset(of: ["Description", "Headline"]))
            #expect(Set(MetadataSidecarService().pendingFieldNames(for: fixture.image, in: fixture.folder))
                .isSuperset(of: ["Description", "Headline"]))
        }
    }

    @Test("An unchanged Caption capture still permits explicit Write")
    @MainActor
    func pendingCaptionStillAllowsExplicitWrite() async throws {
        let fixture = try makePendingCaptionFixture(hasMirroredXMP: false)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        let result = await withCheckedContinuation { continuation in
            fixture.model.commitEditsReportingResult(mode: .writeToXMPSidecar) {
                continuation.resume(returning: $0)
            }
        }
        guard case .succeeded = result else {
            Issue.record("Explicit Write failed: \(result)")
            return
        }
        #expect(XMPSidecarService().loadSidecar(for: fixture.image)?.description == "Pending caption")
        #expect(!fixture.model.hasChanges)
    }

    @Test("An unchanged capture does not suppress a failed queued draft retry")
    @MainActor
    func noOpCaptionCaptureStillDrainsFailedQueue() async throws {
        let fixture = try makePendingCaptionFixture(hasMirroredXMP: false)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        await loadCaptionFixture(fixture.model, image: fixture.image, folder: fixture.folder)
        fixture.model.editingMetadata.title = "Queued headline"
        fixture.model.markChanged()
        let captured = try #require(try fixture.model.captureCaptionDraftPersistence())
        let gate = CaptionBaselineRetryGate()
        let queue = CaptionDraftPersistenceQueue(label: "caption-baseline.failed-retry")
        queue.enqueue(operation: { try gate.attempt(captured) })
        #expect(queue.pendingCount == 1)
        #expect(gate.attemptCount == 1)
        let coordinator = CaptionWorkspaceFlushCoordinator(persistenceQueue: queue)
        coordinator.register(owner: UUID(), capturePersistence: {
            try fixture.model.captureCaptionDraftPersistence()
        }, handler: {})
        #expect(try fixture.model.captureCaptionDraftPersistence() == nil)
        gate.allowSuccess()
        try coordinator.flush()
        #expect(queue.pendingCount == 0)
        #expect(gate.attemptCount == 2)
        let persisted = try #require(MetadataSidecarService().loadSidecar(for: fixture.image, in: fixture.folder))
        #expect(persisted.metadata.title == "Queued headline")
        #expect(persisted.imageMetadataSnapshot?.description == nil)
    }

    @MainActor
    private func makePendingCaptionFixture(
        hasMirroredXMP: Bool,
        legacyMissingSnapshot: Bool = false
    ) throws -> (folder: URL, image: URL, model: MetadataViewModel) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptionBaseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("draft.jpg")
        var pending = IPTCMetadata()
        pending.description = "Pending caption"
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(sourceFile: image.lastPathComponent,
                lastModified: Date(timeIntervalSince1970: 100), pendingChanges: true,
                metadata: pending, imageMetadataSnapshot: legacyMissingSnapshot ? nil : IPTCMetadata()),
            for: image, in: folder
        )
        if hasMirroredXMP {
            try XMPSidecarService().saveSidecar(metadata: pending, for: image)
        }
        let readBoundary = MetadataEditorReadService(access: .init(read: { url, folder, _, _ in
            MetadataEditorSourceFacts(
                imageURL: url,
                xmpMetadata: XMPSidecarService().loadSidecar(for: url),
                appSidecar: folder.flatMap { MetadataSidecarService().loadSidecar(for: url, in: $0) },
                reconciliationVerdict: nil
            )
        }))
        let model = MetadataViewModel(readService: SwiftExifReadService(),
            writeEngine: MetadataCleanupSuccessfulWriter(), editorReadService: readBoundary)
        return (folder, image, model)
    }

    @MainActor
    private func loadCaptionFixture(_ model: MetadataViewModel, image: URL, folder: URL) async {
        model.loadMetadata(for: [ImageFile(url: image)], folderURL: folder)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
    }

    @Test("complete immutable source facts are read serially away from MainActor")
    @MainActor
    func completeFactsRunOffMainActor() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw")
        ]
        let folderURL = URL(fileURLWithPath: "/virtual")
        let requestID = UUID()
        let probe = MetadataEditorReadAccessProbe()
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let request = MetadataEditorReadRequest(
            id: requestID,
            imageURLs: urls,
            folderURL: folderURL,
            embeddedMetadataByImageURL: [
                urls[0]: IPTCMetadata(title: "Embedded one"),
                urls[1]: IPTCMetadata(title: "Embedded two")
            ]
        )

        let result = await Task { await service.load(request) }.value

        guard case .complete(let snapshot) = result else {
            Issue.record("Expected complete Metadata editor facts")
            return
        }
        #expect(snapshot.request.id == requestID)
        #expect(snapshot.request.folderURL == folderURL)
        #expect(snapshot.inspectedImageURLs == urls)
        #expect(snapshot.isComplete)
        #expect(snapshot.factsByImageURL[urls[0]]?.xmpMetadata?.title == "XMP 1")
        #expect(snapshot.factsByImageURL[urls[1]]?.appSidecar?.metadata.title == "Draft 2")
        #expect(snapshot.factsByImageURL[urls[0]]?.reconciliationVerdict == .sidecarMaster)
        #expect(probe.readURLs == urls)
        #expect(!probe.ranOnMainThread)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("pre-cancellation performs no source reads")
    func preCancellation() async {
        let url = URL(fileURLWithPath: "/virtual/cancelled.raw")
        let request = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [url],
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let probe = MetadataEditorReadAccessProbe()
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let task = Task {
            await Task.yield()
            return await service.load(request)
        }
        task.cancel()

        guard case .cancelledBeforeRead(let cancelledRequest) = await task.value else {
            Issue.record("Expected cancellation before the first read")
            return
        }
        #expect(cancelledRequest.id == request.id)
        #expect(probe.readURLs.isEmpty)
    }

    @Test("cancellation preserves the exact completed prefix and final-read state")
    func cancellationEvidence() async {
        let urls = [
            URL(fileURLWithPath: "/virtual/one.raw"),
            URL(fileURLWithPath: "/virtual/two.raw"),
            URL(fileURLWithPath: "/virtual/three.raw")
        ]
        let partialProbe = MetadataEditorReadAccessProbe(cancelAtInvocation: 2)
        let partialService = MetadataEditorReadService(access: .init(read: partialProbe.read))
        let partialRequest = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: urls,
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )

        let partialTask = Task {
            await partialService.load(partialRequest)
        }
        guard case .cancelledAfterPartialRead(let partialSnapshot) = await partialTask.value else {
            Issue.record("Expected cancellation after an exact partial prefix")
            return
        }
        #expect(partialSnapshot.inspectedImageURLs == Array(urls.prefix(2)))
        #expect(!partialSnapshot.isComplete)
        #expect(partialProbe.readURLs == Array(urls.prefix(2)))

        let completeProbe = MetadataEditorReadAccessProbe(cancelAtInvocation: 1)
        let completeService = MetadataEditorReadService(access: .init(read: completeProbe.read))
        let completeRequest = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [urls[0]],
            folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let completeTask = Task {
            await completeService.load(completeRequest)
        }
        guard case .cancelledAfterCompleteRead(let completeSnapshot) = await completeTask.value else {
            Issue.record("Expected cancellation after the final complete read")
            return
        }
        #expect(completeSnapshot.inspectedImageURLs == [urls[0]])
        #expect(completeSnapshot.isComplete)
    }

    @Test("queued requests serialize and can cancel before touching storage")
    @MainActor
    func queuedCancellation() async throws {
        let firstURL = URL(fileURLWithPath: "/virtual/blocked.raw")
        let secondURL = URL(fileURLWithPath: "/virtual/queued.raw")
        let probe = MetadataEditorReadAccessProbe(blocksFirstRead: true)
        defer { probe.releaseFirstRead() }
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let firstRequest = MetadataEditorReadRequest(
            id: UUID(), imageURLs: [firstURL], folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )
        let secondRequest = MetadataEditorReadRequest(
            id: UUID(), imageURLs: [secondURL], folderURL: nil,
            embeddedMetadataByImageURL: [:]
        )

        let first = Task { await service.load(firstRequest) }
        try await probe.waitUntilFirstReadStarts()
        let second = Task { await service.load(secondRequest) }
        second.cancel()
        probe.releaseFirstRead()

        guard case .complete(let firstSnapshot) = await first.value else {
            Issue.record("Expected the first request to complete")
            return
        }
        #expect(firstSnapshot.inspectedImageURLs == [firstURL])
        guard case .cancelledBeforeRead(let cancelledRequest) = await second.value else {
            Issue.record("Expected the queued request to cancel before reading")
            return
        }
        #expect(cancelledRequest.imageURLs == [secondURL])
        #expect(probe.readURLs == [firstURL])
        #expect(!probe.ranOnMainThread)
        #expect(probe.maximumConcurrentReads == 1)
    }

    @Test("production access freezes XMP, JSON history, and timestamp reconciliation")
    func productionAccess() async throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataEditorRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let imageURL = folderURL.appendingPathComponent("sample.jpg")
        try Data("image".utf8).write(to: imageURL)
        let embedded = IPTCMetadata(title: "New embedded")
        try XMPSidecarService().saveSidecar(
            metadata: IPTCMetadata(title: "Old XMP"),
            for: imageURL
        )
        let history = MetadataHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 50),
            fieldName: "Title",
            oldValue: "Before",
            newValue: "Draft"
        )
        try MetadataSidecarService().saveSidecar(
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                pendingChanges: true,
                metadata: IPTCMetadata(title: "Draft"),
                history: [history]
            ),
            for: imageURL,
            in: folderURL
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: XMPSidecarService().sidecarURL(for: imageURL).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: imageURL.path
        )
        let request = MetadataEditorReadRequest(
            id: UUID(),
            imageURLs: [imageURL],
            folderURL: folderURL,
            embeddedMetadataByImageURL: [imageURL: embedded]
        )

        let result = await MetadataEditorReadService().load(request)

        guard case .complete(let snapshot) = result,
              let facts = snapshot.factsByImageURL[imageURL] else {
            Issue.record("Expected production source facts")
            return
        }
        #expect(facts.xmpMetadata?.title == "Old XMP")
        #expect(facts.appSidecar?.metadata.title == "Draft")
        #expect(facts.appSidecar?.history.first?.newValue == "Draft")
        #expect(facts.reconciliationVerdict == .fileNewerConflict)
    }

    @Test("same-image reload publishes only the newest request")
    @MainActor
    func sameImageReloadRejectsStalePublication() async throws {
        let imageURL = URL(fileURLWithPath: "/virtual/reload.jpg")
        let probe = MetadataEditorReadAccessProbe(blocksFirstRead: true)
        defer { probe.releaseFirstRead() }
        let service = MetadataEditorReadService(access: .init(read: probe.read))
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            editorReadService: service
        )
        let image = ImageFile(url: imageURL)

        model.loadMetadata(for: [image], folderURL: imageURL.deletingLastPathComponent())
        try await probe.waitUntilFirstReadStarts()
        model.loadMetadata(for: [image], folderURL: imageURL.deletingLastPathComponent())
        probe.releaseFirstRead()

        let deadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
        #expect(model.editingMetadata.title == "Draft 2")
        #expect(model.metadataLoadGeneration == 1)
        #expect(probe.readURLs == [imageURL, imageURL])
    }

    @Test("write cleanup uses persisted sidecar baseline despite editor source overlays")
    @MainActor
    func writeCleanupUsesPersistedBaseline() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorCleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("draft.jpg")
        let pending = IPTCMetadata(title: "Pending title")
        let service = MetadataSidecarService()
        try service.saveSidecar(
            MetadataSidecar(sourceFile: imageURL.lastPathComponent, pendingChanges: true, metadata: pending),
            for: imageURL, in: folder
        )
        let persisted = try #require(service.loadSidecar(for: imageURL, in: folder))
        var xmp = IPTCMetadata(title: "Reference title")
        var cameraRaw = CameraRawSettings()
        cameraRaw.exposure2012 = 0.5
        xmp.cameraRaw = cameraRaw
        let reference = xmp
        let readBoundary = MetadataEditorReadService(access: .init(read: { url, _, _, _ in
            MetadataEditorSourceFacts(
                imageURL: url, xmpMetadata: reference,
                appSidecar: persisted, reconciliationVerdict: nil
            )
        }))
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: MetadataCleanupSuccessfulWriter(),
            editorReadService: readBoundary
        )
        model.loadMetadata(for: [ImageFile(url: imageURL)], folderURL: folder)
        let loadDeadline = ContinuousClock.now + .seconds(5)
        while model.isLoading, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isLoading)
        #expect(model.editingMetadata.title == "Pending title")
        #expect(model.editingMetadata.cameraRaw?.exposure2012 == 0.5)
        #expect(model.editingMetadata.cameraRaw != persisted.metadata.cameraRaw)

        model.writeMetadataAndClearSidecar()
        let writeDeadline = ContinuousClock.now + .seconds(5)
        while model.isSaving, ContinuousClock.now < writeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isSaving)
        #expect(model.saveError == nil)
        #expect(!model.hasChanges)
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("failed selected discard retains the draft and history")
    @MainActor
    func failedDiscardRetainsEditor() async throws {
        let model = makeDiscardModel { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let draft = model.editingMetadata
        let history = model.sidecarHistory

        let task = try #require(model.discardPendingChanges())
        await task.value

        #expect(model.editingMetadata == draft)
        #expect(model.sidecarHistory.map(\.id) == history.map(\.id))
        #expect(model.hasChanges)
        #expect(model.saveError?.contains("1 image(s)") == true)
    }

    @Test("selected discard completion preserves newer draft, selection, or batch intent", arguments: ["draft", "selection", "batch intent"])
    @MainActor
    func staleDiscardPreservesEditor(change: String) async throws {
        let gate = MetadataDiscardGate()
        let model = makeDiscardModel { _, _ in await gate.enter() }
        if change == "batch intent" {
            model.selectedCount = 2
            model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
            // Clearing an already empty common list changes intent without changing its preview.
            model.batchCommonMetadata = model.editingMetadata
        }
        let task = try #require(model.discardPendingChanges())
        await gate.waitUntilStarted()
        if change == "draft" {
            model.editingMetadata.title = "Newer draft"
        } else if change == "selection" {
            model.selectedURLs = [URL(fileURLWithPath: "/virtual/new-selection.jpg")]
        } else {
            try model.setBatchMutation(.clear, for: .keywords)
        }
        let expectedDraft = model.editingMetadata
        let expectedHistory = model.sidecarHistory
        await gate.release()
        await task.value

        #expect(model.editingMetadata == expectedDraft)
        #expect(model.sidecarHistory.map(\.id) == expectedHistory.map(\.id))
        #expect(model.hasChanges)
        if change == "batch intent" {
            #expect(model.batchFieldMutations[.keywords] == .clear)
        }
    }

    @Test("successful batch discard clears explicit intent and cached common values")
    @MainActor
    func batchDiscardClearsIntent() async throws {
        let model = makeDiscardModel { _, _ in }
        model.selectedCount = 2
        model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
        model.batchCommonMetadata = IPTCMetadata(keywords: ["common"])
        model.batchPartialKeywords = ["partial"]
        model.batchPartialPersonShown = ["Person"]
        model.batchDifferingFields = ["keywords"]
        try model.setBatchMutation(.append(["discarded"]), for: .keywords)
        try model.setBatchLocationsShownMutation(.clear)
        try model.setBatchImageSupplierMutation(.clear)

        let task = try #require(model.discardPendingChanges())
        await task.value

        #expect(!model.hasChanges)
        #expect(model.editingMetadata == IPTCMetadata())
        #expect(model.sidecarHistory.isEmpty)
        #expect(model.batchFieldMutations.isEmpty)
        #expect(model.batchLocationsShownMutation == .untouched)
        #expect(model.batchImageSupplierMutation == .untouched)
        #expect(model.batchCommonMetadata == nil)
        #expect(model.batchPartialKeywords.isEmpty)
        #expect(model.batchPartialPersonShown.isEmpty)
        #expect(model.batchDifferingFields.isEmpty)
        // A subsequent intent must not bring back the discarded keyword append.
        try model.setBatchMutation(.append(["fresh"]), for: .keywords)
        #expect(model.editingMetadata.keywords == ["fresh"])
    }

    @Test("cancelling admitted selected or folder discard allows deletion to finish", arguments: [false, true])
    func admittedDiscardCancellation(folderWide: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("draft.jpg")
        let service = MetadataSidecarService()
        try service.saveSidecar(MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: Date(),
            pendingChanges: true,
            metadata: IPTCMetadata(title: "Draft"),
            imageMetadataSnapshot: IPTCMetadata(title: "Original"),
            history: []
        ), for: imageURL, in: folder)
        let gate = MetadataDiscardAdmissionGate()
        defer { gate.release() }
        let task = Task {
            if folderWide {
                try await service.deleteAllSidecarsSerialized(in: folder) {
                    gate.blockAfterAdmission()
                }
            } else {
                try await service.deleteSidecarSerialized(for: imageURL, in: folder) {
                    gate.blockAfterAdmission()
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.hasEntered)
        task.cancel()
        gate.release()
        try await task.value
        #expect(service.loadSidecar(for: imageURL, in: folder) == nil)
    }

    @Test("folder discard preserves a newer draft, folder, or batch intent", arguments: ["draft", "folder", "batch intent"])
    @MainActor
    func staleFolderDiscard(change: String) async throws {
        let gate = MetadataDiscardGate()
        let model = makeDiscardModel(folderDiscard: { _ in await gate.enter() }, discard: { _, _ in })
        if change == "batch intent" {
            model.selectedCount = 2
            model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
            model.batchCommonMetadata = model.editingMetadata
        }
        let task = try #require(model.discardAllPendingInFolder())
        await gate.waitUntilStarted()
        if change == "draft" {
            model.editingMetadata.title = "New draft"
        } else if change == "folder" {
            model.currentFolderURL = URL(fileURLWithPath: "/other")
        } else {
            try model.setBatchMutation(.clear, for: .keywords)
        }
        let draft = model.editingMetadata
        await gate.release()
        await task.value
        #expect(model.editingMetadata == draft)
        #expect(model.hasChanges)
        #expect(!model.sidecarHistory.isEmpty)
    }

    @Test("folder discard failure retains editor; success clears batch intent")
    @MainActor
    func folderDiscardResult() async throws {
        let failed = makeDiscardModel(folderDiscard: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, discard: { _, _ in })
        await failed.discardAllPendingInFolder()?.value
        #expect(failed.editingMetadata.title == "Draft")
        #expect(failed.hasChanges)
        #expect(failed.saveError != nil)

        let model = makeDiscardModel(folderDiscard: { _ in }, discard: { _, _ in })
        model.selectedURLs.append(URL(fileURLWithPath: "/virtual/second.jpg"))
        model.selectedCount = 2
        model.batchCommonMetadata = model.editingMetadata
        try model.setBatchMutation(.append(["old"]), for: .keywords)
        try model.setBatchImageSupplierMutation(.clear)
        await model.discardAllPendingInFolder()?.value
        #expect(model.editingMetadata == IPTCMetadata())
        #expect(model.batchCommonMetadata == nil)
        #expect(model.batchFieldMutations.isEmpty)
        #expect(model.batchImageSupplierMutation == .untouched)
        #expect(!model.hasChanges)
        #expect(model.sidecarHistory.isEmpty)
    }

    @Test("folder barriers serialize photo operations and later barriers while siblings proceed")
    func folderBarrierOrdering() async throws {
        let coordinator = MetadataIOCoordinator()
        let gate = MetadataDiscardGate()
        let events = FolderDiscardEvents()
        let barrier = Task {
            await coordinator.withFolderLock("/virtual") {
                await events.append("folder-start")
                await gate.enter()
                await events.append("folder-end")
            }
        }
        await gate.waitUntilStarted()
        let photo = Task {
            await coordinator.withLock("/virtual/image") { await events.append("photo") }
        }
        let nextBarrier = Task {
            await coordinator.withFolderLock("/virtual") { await events.append("next-folder") }
        }
        await coordinator.withLock("/virtual-sibling/image") { await events.append("sibling") }
        #expect(await events.values == ["folder-start", "sibling"])
        await gate.release()
        await barrier.value
        await photo.value
        await nextBarrier.value
        let result = await events.values
        #expect(result.firstIndex(of: "folder-end")! < result.firstIndex(of: "photo")!)
        #expect(result.firstIndex(of: "folder-end")! < result.firstIndex(of: "next-folder")!)
    }

    @Test("folder discard waits for admitted photo writes and removes directory off main")
    @MainActor
    func folderDiscardService() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = MetadataDiscardGate()
        let imageURL = folder.appendingPathComponent("image.jpg")
        let write = Task {
            try await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: imageURL)) {
                await gate.enter()
                try Data("saved".utf8).write(to: directory.appendingPathComponent("image.jpg.meta.json"))
            }
        }
        await gate.waitUntilStarted()
        let deletion = Task {
            try await MetadataSidecarService().deleteAllSidecarsSerialized(in: folder) {
                #expect(!Thread.isMainThread)
            }
        }
        await gate.release()
        try await write.value
        try await deletion.value
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MetadataSidecarService().deleteAllSidecarsSerialized(in: folder)
        }
        do {
            try await cancelled.value
            Issue.record("Pre-cancelled folder deletion should fail")
        } catch is CancellationError {} catch { throw error }
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    private func makeDiscardModel(
        folderDiscard: @escaping @Sendable (URL) async throws -> Void = { _ in },
        discard: @escaping @Sendable (URL, URL) async throws -> Void
    ) -> MetadataViewModel {
        let model = MetadataViewModel(
            readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(),
            discardSidecar: discard,
            discardFolderSidecars: folderDiscard
        )
        model.currentFolderURL = URL(fileURLWithPath: "/virtual")
        model.selectedURLs = [URL(fileURLWithPath: "/virtual/draft.jpg")]
        model.selectedCount = 1
        model.originalImageMetadata = IPTCMetadata(title: "Original")
        model.editingMetadata = IPTCMetadata(title: "Draft")
        model.hasChanges = true
        model.sidecarHistory = MetadataHistoryEntry.changes(
            from: IPTCMetadata(title: "Original"),
            to: model.editingMetadata,
            timestamp: Date()
        )
        return model
    }

    @Test("passive Metadata callers await complete request-owned facts")
    func metadataViewModelSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/ViewModels/MetadataViewModel.swift"
            ),
            encoding: .utf8
        )
        let ranges = try [
            sourceSlice(source, from: "func loadCaptionCopyPreviousMetadata(", to: "func loadMetadata("),
            sourceSlice(source, from: "func loadMetadata(", to: "func applyReferenceSource("),
            sourceSlice(source, from: "private func loadBatchMetadata(", to: "private func compareOptionalField"),
            sourceSlice(source, from: "private func processVariablesBatch(", to: "private func refreshMetadataAfterProcessing("),
            sourceSlice(source, from: "private func refreshMetadataAfterProcessing(", to: "private func resolveIfChanged")
        ]
        let passiveSource = ranges.joined(separator: "\n")

        #expect(passiveSource.contains("await editorReadService.load("))
        #expect(passiveSource.contains("case .complete(let"))
        #expect(passiveSource.contains("metadataLoadRequestID == requestID"))
        #expect(passiveSource.contains("currentFolderURL == folderSnapshot"))
        #expect(!passiveSource.contains("sidecarService.loadSidecar("))
        #expect(!passiveSource.contains("xmpSidecarService.loadSidecar("))
        #expect(!passiveSource.contains("SidecarReconciliation.verdict("))
        #expect(!source.contains("refreshPendingSidecarsFlag"))
    }

    private func sourceSlice(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(
            of: end,
            range: startRange.upperBound..<source.endIndex
        ))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }
}

private nonisolated final class MetadataEditorReadAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let firstReadGate = DispatchSemaphore(value: 0)
    private let cancelAtInvocation: Int?
    private let blocksFirstRead: Bool
    private var urls: [URL] = []
    private var observedMainThread = false
    private var activeReads = 0
    private var maximumReads = 0
    private var firstReadReleased = false

    init(cancelAtInvocation: Int? = nil, blocksFirstRead: Bool = false) {
        self.cancelAtInvocation = cancelAtInvocation
        self.blocksFirstRead = blocksFirstRead
    }

    func read(
        imageURL: URL,
        folderURL: URL?,
        embedded: IPTCMetadata?,
        reconciles: Bool
    ) -> MetadataEditorSourceFacts {
        let state = lock.withLock { () -> (Int, Bool, Bool) in
            urls.append(imageURL)
            observedMainThread = observedMainThread || Thread.isMainThread
            activeReads += 1
            maximumReads = max(maximumReads, activeReads)
            let invocation = urls.count
            return (
                invocation,
                invocation == cancelAtInvocation,
                blocksFirstRead && invocation == 1 && !firstReadReleased
            )
        }
        defer { lock.withLock { activeReads -= 1 } }
        if state.2 { firstReadGate.wait() }
        if state.1 { withUnsafeCurrentTask { $0?.cancel() } }

        let xmp = IPTCMetadata(title: "XMP \(state.0)")
        let appSidecar = folderURL.map { _ in
            MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                pendingChanges: state.0 == 2,
                metadata: IPTCMetadata(title: "Draft \(state.0)")
            )
        }
        return MetadataEditorSourceFacts(
            imageURL: imageURL,
            xmpMetadata: xmp,
            appSidecar: appSidecar,
            reconciliationVerdict: reconciles && embedded != nil ? .sidecarMaster : nil
        )
    }

    func waitUntilFirstReadStarts() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while readURLs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!readURLs.isEmpty)
    }

    func releaseFirstRead() {
        let shouldSignal = lock.withLock {
            guard !firstReadReleased else { return false }
            firstReadReleased = true
            return true
        }
        if shouldSignal { firstReadGate.signal() }
    }

    var readURLs: [URL] { lock.withLock { urls } }
    var ranOnMainThread: Bool { lock.withLock { observedMainThread } }
    var maximumConcurrentReads: Int { lock.withLock { maximumReads } }
}

/// Suspends the injected discard without blocking MainActor or relying on scheduling delays.
private actor MetadataDiscardGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        completionWaiters.forEach { $0.resume() }
        completionWaiters.removeAll()
    }
}

private nonisolated final class MetadataDiscardAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var hasEntered: Bool { lock.withLock { entered } }

    func blockAfterAdmission() {
        lock.withLock { entered = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private actor FolderDiscardEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

/// Successful image writer isolates the editor's post-write sidecar transaction.
private nonisolated final class MetadataCleanupSuccessfulWriter: MetadataWriteEngine {
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}

private nonisolated final class MetadataCompletionTestWriter: MetadataWriteEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var fieldsWritten: [MetadataFieldKey: String] = [:]
    var writtenFields: [MetadataFieldKey: String] { lock.withLock { fieldsWritten } }
    private let onWrite: @Sendable () async throws -> Void
    var writeCount: Int { lock.withLock { count } }
    init(onWrite: @escaping @Sendable () async throws -> Void) { self.onWrite = onWrite }
    func writeFields(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {
        lock.withLock { count += 1; fieldsWritten = fields }
        try await onWrite()
    }
    func writeFieldsToRenderedFiles(_ fields: [MetadataFieldKey: String], to urls: [URL], structuredData: StructuredWriteData) async throws {}
    func addRemoveListValues(add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]], to urls: [URL]) async throws {}
    func writeRating(_ rating: StarRating, to urls: [URL]) async throws {}
    func writeLabel(_ label: ColorLabel, to urls: [URL]) async throws {}
    func writeOrientation(_ orientation: Int, to urls: [URL]) async throws {}
    func stripIPTCAndXMP(from urls: [URL]) async throws {}
    func copyMetadataToRenderedFile(from source: URL, to destination: URL, bakedCameraRaw: CameraRawSettings?) async throws {}
}
