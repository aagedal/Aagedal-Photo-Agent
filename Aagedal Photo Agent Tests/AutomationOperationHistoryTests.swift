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
