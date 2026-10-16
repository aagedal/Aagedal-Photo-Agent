import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native face review capacity maintenance")
struct AutomationFaceReviewMaintenanceTests {
    private func snapshot() -> MCPFaceScanReviewRequestStore.MaintenanceSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000), epoch = UUID()
        let intent = MCPFaceScanReviewRequestStore.Intent(canonicalPath: "/private/tmp/review", rootID: UUID().uuidString.lowercased(),
            folderIdentity: .init(device: 1, inode: 1), forceFullScan: false, includeJerseyNumbers: false,
            snapshotRevision: "sha256:" + String(repeating: "a", count: 64), photoCount: 1,
            preparedAt: date, expiresAt: date.addingTimeInterval(300),
            monotonicWitness: .init(bootSessionID: UUID().uuidString.lowercased(), uptime: 10))
        let record = MCPFaceScanReviewRequestStore.Record(requestID: UUID().uuidString.lowercased(),
            requestEpoch: epoch.uuidString.lowercased(), intent: intent, intentSHA256: String(repeating: "b", count: 64),
            createdAt: date, updatedAt: date, state: .cancelled, cancellationRequestedAt: date)
        return .init(epoch: epoch, retainedCount: 2, maximumRecords: 64, cancelledRecords: [record])
    }

    private actor ControlledService: AutomationFaceReviewMaintenanceServing {
        let value: MCPFaceScanReviewRequestStore.MaintenanceSnapshot
        var inspectionCalls = 0
        var cleanupCalls = 0
        var heldInspection: CheckedContinuation<Void, Never>?
        var heldCleanup: CheckedContinuation<Void, Never>?
        var holdInspection = false
        var holdCleanup = false
        init(_ value: MCPFaceScanReviewRequestStore.MaintenanceSnapshot) { self.value = value }
        func setHoldInspection() { holdInspection = true }
        func setHoldCleanup() { holdCleanup = true }
        func inspectionPending() -> Bool { heldInspection != nil }
        func cleanupPending() -> Bool { heldCleanup != nil }
        func releaseInspection() { heldInspection?.resume(); heldInspection = nil }
        func releaseCleanup() { heldCleanup?.resume(); heldCleanup = nil }
        func inspect() async throws -> MCPFaceScanReviewRequestStore.MaintenanceSnapshot {
            inspectionCalls += 1
            if holdInspection { await withCheckedContinuation { heldInspection = $0 } }
            return value
        }
        func cleanup(_ review: MCPFaceScanReviewRequestStore.MaintenanceSnapshot) async throws -> UUID {
            cleanupCalls += 1
            if holdCleanup { await withCheckedContinuation { heldCleanup = $0 } }
            return UUID()
        }
    }

    @MainActor @Test("Confirmation is exact, cancellable and single-use")
    func confirmations() async throws {
        let service = ControlledService(snapshot()), model = AutomationFaceReviewMaintenanceModel(service: service)
        await model.inspect()
        model.requestCleanup()
        let old = try #require(model.cleanupConfirmation?.id)
        model.cancelCleanup()
        await model.confirmCleanup(old)
        #expect(await service.cleanupCalls == 0)
        model.requestCleanup()
        let current = try #require(model.cleanupConfirmation?.id)
        await model.confirmCleanup(old)
        #expect(await service.cleanupCalls == 0)
        await model.confirmCleanup(current)
        await model.confirmCleanup(current)
        #expect(await service.cleanupCalls == 1)
        #expect(model.review == nil)
        #expect(model.message?.contains("epoch rotated") == true)
    }

    @MainActor @Test("Clear suppresses a late inspection and retains busy ownership until worker drains")
    func inspectionGeneration() async {
        let service = ControlledService(snapshot()), model = AutomationFaceReviewMaintenanceModel(service: service)
        await service.setHoldInspection()
        let task = Task { await model.inspect() }
        while !(await service.inspectionPending()) { await Task.yield() }
        model.clear()
        #expect(model.isLoading)
        await model.inspect()
        #expect(await service.inspectionCalls == 1)
        await service.releaseInspection()
        await task.value
        #expect(!model.isLoading)
        #expect(model.review == nil)
        #expect(model.message == nil)
    }

    @MainActor @Test("Dismissed cleanup cannot publish or admit duplicate work while draining")
    func cleanupGeneration() async throws {
        let service = ControlledService(snapshot()), model = AutomationFaceReviewMaintenanceModel(service: service)
        await model.inspect(); model.requestCleanup()
        let id = try #require(model.cleanupConfirmation?.id)
        await service.setHoldCleanup()
        let task = Task { await model.confirmCleanup(id) }
        while !(await service.cleanupPending()) { await Task.yield() }
        model.clear()
        #expect(model.isLoading)
        await model.inspect(); await model.confirmCleanup(id)
        #expect(await service.inspectionCalls == 1)
        #expect(await service.cleanupCalls == 1)
        await service.releaseCleanup(); await task.value
        #expect(!model.isLoading)
        #expect(model.review == nil)
        #expect(model.message == nil)
    }

    @Test("Cancelled worker refuses inspection before creating any storage")
    func cancelledWorker() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/face-review-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = AutomationFaceReviewMaintenanceService(requests: .init(storageDirectory: root))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.inspect()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
