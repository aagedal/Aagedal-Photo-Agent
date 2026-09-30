import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native automation operation history")
struct AutomationOperationHistoryTests {
    private final class Fixture {
        let root: URL
        let registry: AutomationOperationRegistry
        init() throws {
            let path = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(path) }
            root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("operation-history-\(UUID().uuidString)")
            registry = AutomationOperationRegistry(storageDirectory: root)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func removingFinishedRecordFreesCapacityWithoutRemovingRecoveryEvidence() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let completed = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner)
        _ = try fixture.registry.start(completed.id, ownerID: owner)
        _ = try fixture.registry.finish(completed.id, ownerID: owner, outcome: .verified)
        let uncertain = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner)
        _ = try fixture.registry.finish(uncertain.id, ownerID: owner, outcome: .recoveryRequired)
        let active = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner)
        let service = AutomationOperationHistoryService(registry: fixture.registry)
        for id in [uncertain.id, active.id] {
            await #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) {
                try await service.removeFinished(id)
            }
        }
        try await service.removeFinished(completed.id)
        #expect(try fixture.registry.records().map(\.id) == [uncertain.id, active.id])
    }

    @Test func cancellationRequestKeepsUnresolvedWorkAndCompletedOutcome() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let active = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner)
        let service = AutomationOperationHistoryService(registry: fixture.registry)
        try await service.requestCancellation(active.id)
        let requested = try fixture.registry.inspect(active.id)
        #expect(requested.cancellationRequestedAt != nil)
        #expect(!requested.isTerminal)
        #expect(requested.outcome == nil)
        _ = try fixture.registry.acknowledgeCancellation(active.id, ownerID: owner)
        let cancelled = try fixture.registry.inspect(active.id)
        try await service.requestCancellation(active.id)
        #expect(try fixture.registry.inspect(active.id) == cancelled)
    }

    @Test("Transcription history preserves saved drafts across success, failure and cancellation", arguments:
        [AutomationOperationRegistry.Outcome.verified, .failed, .cancelled])
    func transcriptDraftHistoryCopy(outcome: AutomationOperationRegistry.Outcome) throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .voiceTranscription, ownerID: owner)
        _ = try fixture.registry.configureBatch(operation.id, ownerID: owner, itemCount: 2)
        _ = try fixture.registry.start(operation.id, ownerID: owner)
        _ = try fixture.registry.startBatchItem(operation.id, ownerID: owner, index: 0)
        _ = try fixture.registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved)
        _ = try fixture.registry.startBatchItem(operation.id, ownerID: owner, index: 1)
        let record: AutomationOperationRegistry.Record
        if outcome == .cancelled {
            _ = try fixture.registry.requestCancellation(operation.id)
            _ = try fixture.registry.finishBatchItem(operation.id, ownerID: owner, index: 1, outcome: .cancelled)
            record = try fixture.registry.acknowledgeCancellation(operation.id, ownerID: owner)
        } else {
            _ = try fixture.registry.finishBatchItem(operation.id, ownerID: owner, index: 1,
                outcome: outcome == .verified ? .draftSaved : .failed)
            record = try fixture.registry.finish(operation.id, ownerID: owner, outcome: outcome)
        }
        let status = AutomationOperationHistoryView.status(record)
        #expect(status.contains("editable transcript draft") || status.contains("Editable transcript drafts"))
        #expect(status.contains("unapproved"))
        #expect(status.contains("IPTC metadata is unchanged"))
        if outcome != .verified { #expect(status.contains("1 editable transcript draft remains saved")) }
        let progress = try #require(record.batchProgress)
        let text = AutomationOperationHistoryView.batchProgressText(progress)
        #expect(text.contains("2 of 2 photos finished"))
        #expect(text.contains("Photo 1: draft saved"))
        #expect(text.contains("Photo 2: \(outcome == .verified ? "draft saved" : outcome.rawValue)"))
        #expect(!text.contains(fixture.root.path))
        #expect(!text.contains(owner.uuidString))
    }

    @Test("Uncertain transcription history separates a saved prefix from an interrupted item")
    func interruptedTranscriptHistoryCopy() throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .voiceTranscription, ownerID: owner)
        _ = try fixture.registry.configureBatch(operation.id, ownerID: owner, itemCount: 2)
        _ = try fixture.registry.start(operation.id, ownerID: owner)
        _ = try fixture.registry.startBatchItem(operation.id, ownerID: owner, index: 0)
        _ = try fixture.registry.finishBatchItem(operation.id, ownerID: owner, index: 0, outcome: .draftSaved)
        _ = try fixture.registry.startBatchItem(operation.id, ownerID: owner, index: 1)
        let record = try fixture.registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired)
        #expect(AutomationOperationHistoryView.status(record).contains("1 editable transcript draft remains saved"))
        #expect(AutomationOperationHistoryView.status(record).contains("effects are uncertain"))
        let guidance = AutomationOperationHistoryView.recoveryGuidance(record)
        #expect(guidance.contains("Saved transcript drafts are retained"))
        #expect(guidance.contains("unfinished items are not confirmed as saved"))
        #expect(!guidance.contains("cannot establish whether a draft was saved"))
        #expect(AutomationOperationHistoryView.batchProgressText(try #require(record.batchProgress))
            .contains("1 of 2 photos finished"))
    }

    @Test @MainActor func failedRefreshRetainsVisibleEvidenceAndSuccessfulRetryClearsError() async throws {
        let fixture = try Fixture()
        let record = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: UUID())
        let service = ToggleService(records: [record])
        let model = AutomationOperationHistoryModel(service: service)
        await model.refresh()
        #expect(model.records == [record])
        await service.setFailing(true)
        await model.refresh()
        #expect(model.records == [record])
        #expect(model.message != nil)
        #expect(!model.isLoading)
        await service.setFailing(false)
        await model.refresh()
        #expect(model.message == nil)
    }

    @Test func orderingShowsMostRecentlyUpdatedRecordFirst() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let old = Date(timeIntervalSinceReferenceDate: 10)
        let first = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner, now: old)
        let second = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner, now: old.addingTimeInterval(1))
        _ = try fixture.registry.requestCancellation(first.id, now: old.addingTimeInterval(2))
        let service = AutomationOperationHistoryService(registry: fixture.registry)
        #expect(try await service.records().map(\.id) == [first.id, second.id])
    }

    @Test("Exact resolved receipts preserve failed publication outcomes and permit explicit removal", arguments:
        [MCPIPTCPatchXMPRecoveryStore.HistoryResolution.unchanged, .restored])
    func resolvedReceiptReconciliation(disposition: MCPIPTCPatchXMPRecoveryStore.HistoryResolution) async throws {
        let fixture = try Fixture()
        let registry = AutomationOperationRegistry(storageDirectory: fixture.root, maximumRecords: 1)
        let owner = UUID()
        let operation = try registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        let material = try stage(recovery, id: operation.id)
        if disposition == .unchanged { try recovery.recordUnchanged(material) {} }
        else {
            try recovery.recordInstalled(material, installed: .init(xmpRevision: "installed-xmp", appRevision: nil)) {}
            try recovery.recordInstalled(material, installed: .init(xmpRevision: "installed-xmp", appRevision: "installed-app")) {}
            try recovery.recordRestored(material, restored: .init(xmpRevision: "restored-xmp", appRevision: nil)) {}
            try recovery.recordRestored(material, restored: .init(xmpRevision: "restored-xmp", appRevision: "restored-app"), complete: true) {}
        }
        let journal = fixture.root.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let evidence = try Data(contentsOf: journal)
        let service = AutomationOperationHistoryService(registry: registry, recovery: recovery)
        let record = try #require(try await service.records().first)
        #expect(record.outcome == .recoveryRequired)
        #expect(record.state == .completed)
        #expect(record.recoveryResolution?.disposition.rawValue == disposition.rawValue)
        #expect(record.recoveryResolution?.receiptSHA256.count == 64)
        #expect(AutomationOperationHistoryService.canRemove(record))
        #expect(try await service.records() == [record])
        #expect(try AutomationOperationRegistry(storageDirectory: fixture.root).inspect(record.id) == record)
        try await service.removeFinished(record.id)
        #expect(try registry.records().isEmpty)
        _ = try registry.enqueue(kind: .iptcPatch, ownerID: owner)
        #expect(try Data(contentsOf: journal) == evidence)
    }

    @Test("Unresolved, unrelated and nonpublication receipts never enable recovery record removal")
    func unresolvedOrUnrelatedReceiptsRemainBlocked() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let publication = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try fixture.registry.finish(publication.id, ownerID: owner, outcome: .recoveryRequired)
        let draft = try fixture.registry.enqueue(kind: .iptcDraft, ownerID: owner)
        _ = try fixture.registry.finish(draft.id, ownerID: owner, outcome: .partialUncertain)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        let material = try stage(recovery, id: draft.id)
        let service = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        #expect(try await service.records().allSatisfy { $0.recoveryResolution == nil })
        try recovery.recordUnchanged(material) {}
        await #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) { try await service.records() }
        #expect(try fixture.registry.records().allSatisfy { $0.recoveryResolution == nil })
        for id in [publication.id, draft.id] {
            await #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) { try await service.removeFinished(id) }
        }
    }

    @Test("Missing or corrupt recovery evidence cannot fabricate resolution")
    func corruptReceiptFailsClosed() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try fixture.registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        let service = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        #expect(try await service.records().first?.recoveryResolution == nil)
        let material = try stage(recovery, id: operation.id)
        try recovery.recordUnchanged(material) {}
        let url = fixture.root.appendingPathComponent("iptc-xmp-recovery/operations.json")
        try Data("corrupt".utf8).write(to: url)
        await #expect(throws: MCPIPTCPatchXMPRecoveryStore.Failure.corruptJournal) { try await service.records() }
        #expect(try fixture.registry.inspect(operation.id).recoveryResolution == nil)
        await #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) { try await service.removeFinished(operation.id) }
    }

    private func stage(_ recovery: MCPIPTCPatchXMPRecoveryStore, id: UUID) throws -> MCPIPTCPatchXMPRecoveryStore.Material {
        try recovery.stage(id: id, planID: UUID().uuidString, targetPath: "/private/tmp/history-photo.xmp",
            binding: .init(sourceRevision: "source", xmpSidecarRevision: "original-xmp",
                appSidecarRevision: "original-app", authorizationRevision: UUID()),
            original: Data("original".utf8), candidate: Data("candidate".utf8),
            appSidecarRecovery: .init(original: Data("original-app".utf8), candidate: Data("candidate-app".utf8)),
            publicationApprovalID: UUID())
    }

    @Test("Resolved history remains removable after the next operation replaces the recovery journal")
    func durableResolutionSurvivesNextStage() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try fixture.registry.finish(operation.id, ownerID: owner, outcome: .partialUncertain)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        try recovery.recordUnchanged(stage(recovery, id: operation.id)) {}
        let service = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        let settled = try await service.records()
        _ = try stage(recovery, id: UUID())
        let newEvidence = try Data(contentsOf: fixture.root.appendingPathComponent("iptc-xmp-recovery/operations.json"))
        #expect(try await service.records() == settled)
        #expect(settled.first?.outcome == .partialUncertain)
        try await service.removeFinished(operation.id)
        #expect(try fixture.registry.records().isEmpty)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("iptc-xmp-recovery/operations.json")) == newEvidence)
    }

    @Test("A failed durable handoff retains exact recovery evidence for a later successful refresh")
    func constrainedHistoryWriteCanRetry() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner)
        _ = try fixture.registry.finish(operation.id, ownerID: owner, outcome: .recoveryRequired)
        let url = fixture.root.appendingPathComponent("operations.json")
        let originalHistory = try Data(contentsOf: url)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        try recovery.recordUnchanged(stage(recovery, id: operation.id)) {}
        let journal = fixture.root.appendingPathComponent("iptc-xmp-recovery/operations.json")
        let originalJournal = try Data(contentsOf: journal)
        let constrained = AutomationOperationRegistry(storageDirectory: fixture.root, maximumBytes: originalHistory.count)
        let failedService = AutomationOperationHistoryService(registry: constrained, recovery: recovery)
        await #expect(throws: AutomationOperationRegistry.Failure.capacity) { try await failedService.records() }
        #expect(try Data(contentsOf: url) == originalHistory)
        #expect(try Data(contentsOf: journal) == originalJournal)
        let retry = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        #expect(try await retry.records().first?.recoveryResolution != nil)
        #expect(try Data(contentsOf: journal) == originalJournal)
    }

    @Test("Resolving unchanged staging for a refusal or clean cancellation does not block future publication", arguments:
        [AutomationOperationRegistry.Outcome.failed, .cancelled])
    func resolvedCleanOutcomeIsHarmless(outcome: AutomationOperationRegistry.Outcome) async throws {
        let fixture = try Fixture()
        let owner = UUID()
        let operation = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner)
        let finished: AutomationOperationRegistry.Record
        if outcome == .cancelled {
            _ = try fixture.registry.requestCancellation(operation.id)
            finished = try fixture.registry.acknowledgeCancellation(operation.id, ownerID: owner)
        } else { finished = try fixture.registry.finish(operation.id, ownerID: owner, outcome: outcome) }
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        try recovery.recordUnchanged(stage(recovery, id: operation.id)) {}
        let service = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        try await service.reconcileRecovery()
        #expect(try await service.records() == [finished])
        _ = try stage(recovery, id: UUID())
        #expect(try await service.records() == [finished])
        try await service.removeFinished(operation.id)
        #expect(try fixture.registry.records().isEmpty)
    }

    @Test("Direct native reconciliation requires kernel proof of owner abandonment")
    func directReconciliationRequiresStoppedOwner() async throws {
        let fixture = try Fixture()
        let owner = UUID()
        var lease: AutomationOperationPersistence.OwnerLease? = try fixture.registry.acquireOwnerLease(ownerID: owner)
        let operation = try fixture.registry.enqueue(kind: .iptcPatch, ownerID: owner, ownerLease: lease)
        _ = try fixture.registry.start(operation.id, ownerID: owner)
        let recovery = MCPIPTCPatchXMPRecoveryStore(directory: fixture.root)
        try recovery.recordUnchanged(stage(recovery, id: operation.id)) {}
        let service = AutomationOperationHistoryService(registry: fixture.registry, recovery: recovery)
        await #expect(throws: AutomationOperationRegistry.Failure.invalidTransition) { try await service.reconcileRecovery() }
        withExtendedLifetime(lease) {}
        #expect(try fixture.registry.inspect(operation.id).state == .running)
        #expect(try fixture.registry.inspect(operation.id).recoveryResolution == nil)
        lease = nil
        try await service.reconcileRecovery()
        let settled = try fixture.registry.inspect(operation.id)
        #expect(settled.state == .completed)
        #expect(settled.outcome == .recoveryRequired)
        #expect(settled.recoveryResolution?.disposition == .unchanged)
        #expect(settled.canRemove)
    }

    private actor ToggleService: AutomationOperationHistoryServing {
        let values: [AutomationOperationRegistry.Record]
        var failing = false
        init(records: [AutomationOperationRegistry.Record]) { values = records }
        func setFailing(_ value: Bool) { failing = value }
        func records() throws -> [AutomationOperationRegistry.Record] {
            if failing { throw AutomationOperationRegistry.Failure.storageUnavailable }
            return values
        }
        func requestCancellation(_ id: UUID) {}
        func removeFinished(_ id: UUID) {}
    }
}
