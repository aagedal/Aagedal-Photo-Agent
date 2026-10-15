import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Native face review presentation session")
struct MCPNativeFaceScanReviewModelTests {
    nonisolated private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var model = FaceRecognitionModelAvailability.available
        private var installation = UUID()
        func read() -> Data? { lock.withLock { data } }
        func write(_ data: Data?) { lock.withLock { self.data = data } }
        func readiness() -> FaceRecognitionModelAvailability { lock.withLock { model } }
        func change(_ value: FaceRecognitionModelAvailability) { lock.withLock { model = value } }
        func replaceSameVersion() { lock.withLock { installation = UUID() } }
        func preflight() -> (@Sendable () throws -> Void) {
            let retained = lock.withLock { installation }
            return { [self] in
                try lock.withLock {
                    guard installation == retained else { throw MCPNativeFaceScanReviewModel.Failure.modelChanged }
                }
            }
        }
    }
    private actor Gate {
        private var opened = false
        private var pending: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !opened { await withCheckedContinuation { pending.append($0) } } }
        func open() { opened = true; let p = pending; pending.removeAll(); for continuation in p { continuation.resume() } }
    }
    @MainActor private struct Fixture {
        let root: URL
        let photos: URL
        let state: State
        let model: MCPNativeFaceScanReviewModel
        let receipts: MCPFaceScanReceiptStore
        let intents: MCPFaceScanIntentStore
    }
    @MainActor private func fixture(schedule: @escaping MCPFaceScanOperationService.Scheduler) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/native-face-presentation-\(UUID())", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: photos.appendingPathComponent("photo.jpg"))
        let state = State()
        let authorization = MCPAuthorizationStore(readConfigurationData: { state.read() }, writeConfigurationData: { state.write($0) })
        try authorization.addRoot(photos); try authorization.setEnabled(true)
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authorization))
        let receipts = MCPFaceScanReceiptStore(storageDirectory: root.appendingPathComponent("receipts"))
        let operations = MCPFaceScanOperationService(intents: intents,
            registry: .init(storageDirectory: root.appendingPathComponent("operations")), receipts: receipts, schedule: schedule)
        return .init(root: root, photos: photos, state: state,
            model: .init(intents: intents, operations: operations, receipts: receipts, readiness: { state.readiness() }, modelPreflight: { state.preflight() }), receipts: receipts, intents: intents)
    }
    private func refuse(_: MCPFaceScanIntentStore, _: UUID,
                        _: @escaping @Sendable () throws -> Void) async throws -> FaceFolderScanSubmission {
        Issue.record("Unexpected scheduling without valid native consent/readiness")
        return .init(admission: .refused(.scanAlreadyRunning), task: nil)
    }

    @Test("Retained intent presentation keeps exact identity and does not infer consent") @MainActor
    func retainedIntentPresentation() async throws {
        let f = try fixture(schedule: refuse)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let intent = try f.intents.prepare(arguments: ["path": .string(f.photos.path), "includeJerseyNumbers": .bool(true)])
        await f.model.prepare(intentID: intent.id)
        let review = try #require(f.model.review)
        #expect(review.intent.id == intent.id)
        #expect(review.intent.prepared.snapshotRevision == intent.prepared.snapshotRevision)
        #expect(!f.model.acknowledgesScan && !f.model.acknowledgesReset)
        #expect(!f.model.canStart)
        await f.model.start()
        #expect(try f.receipts.receipts().isEmpty)
        f.model.dismiss()
        await f.model.prepare(intentID: UUID())
        #expect(f.model.review == nil)
        #expect(f.model.message != nil)
    }

    @Test("Jersey review shows exact inventory and requires both native acknowledgements") @MainActor
    func acknowledgements() async throws {
        let f = try fixture(schedule: refuse); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: true)
        let review = try #require(f.model.review)
        #expect(review.intent.prepared.imageURLs.map(\.lastPathComponent) == ["photo.jpg"])
        #expect(review.intent.prepared.forceFullScan)
        #expect(!f.model.canStart)
        f.model.acknowledgesScan = true
        #expect(!f.model.canStart)
        await f.model.start()
        #expect(try f.receipts.receipts().isEmpty)
        f.model.acknowledgesReset = true
        #expect(f.model.canStart)
        f.model.dismiss()
        #expect(!f.model.canStart)
        #expect(f.model.review == nil)
        #expect(!f.model.acknowledgesScan && !f.model.acknowledgesReset)
    }

    @Test("Unavailable model refuses preparation without creating operation storage") @MainActor
    func readinessAtPreparation() async throws {
        let f = try fixture(schedule: refuse); defer { try? FileManager.default.removeItem(at: f.root) }
        f.state.change(.notInstalled)
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        #expect(f.model.review == nil)
        #expect(f.model.message?.contains("readiness changed") == true)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }

    @Test("Model readiness or same-version replacement consumes review without scheduling", arguments: [true, false]) @MainActor
    func readinessAtStart(sameVersion: Bool) async throws {
        let f = try fixture(schedule: refuse); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        f.model.acknowledgesScan = true
        if sameVersion { f.state.replaceSameVersion() }
        else { f.state.change(.ready(version: "replacement")) }
        await f.model.start()
        #expect(f.model.review == nil)
        #expect(!f.model.isRunning)
        #expect(f.model.message?.contains("readiness changed") == true)
        #expect(try f.receipts.receipts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }

    @Test("Dismissal withdraws retained effect permission and stale completion cannot repopulate UI") @MainActor
    func dismissalDuringWork() async throws {
        let entered = Gate(), release = Gate()
        let f = try fixture(schedule: { intents, id, validate in
            let intent = try intents.inspect(id: id)
            let request = FaceFolderScanRequest(imageURLs: intent.prepared.imageURLs, folderURL: intent.prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                await entered.open(); await release.wait()
                #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try validate() }
                return .init(folderURL: request.folderURL, outcome: .cancelled)
            })
        }); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        f.model.acknowledgesScan = true
        let task = Task { await f.model.start() }
        await entered.wait()
        f.model.dismiss()
        #expect(f.model.isRunning)
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        #expect(f.model.review == nil)
        #expect(f.model.message?.contains("Wait for") == true)
        await release.open(); await task.value
        #expect(!f.model.isRunning)
        #expect(f.model.receipt == nil)
        #expect(try f.receipts.receipts().count == 1)
    }

    @Test("Readiness is checked again by the retained worker after admission") @MainActor
    func readinessDuringWork() async throws {
        let entered = Gate(), release = Gate()
        let f = try fixture(schedule: { intents, id, validate in
            let intent = try intents.inspect(id: id)
            let request = FaceFolderScanRequest(imageURLs: intent.prepared.imageURLs, folderURL: intent.prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                await entered.open(); await release.wait()
                #expect(throws: MCPNativeFaceScanReviewModel.Failure.self) { try validate() }
                return .init(folderURL: request.folderURL, outcome: .cancelled)
            })
        }); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        f.model.acknowledgesScan = true
        let task = Task { await f.model.start() }
        await entered.wait()
        f.state.change(.verificationFailed)
        await release.open(); await task.value
        #expect(f.model.operation?.outcome == .failed)
        #expect(f.model.receipt?.completion?.outcome == .failed)
        #expect(!f.model.canStart)
    }

    @Test("Successful retained work presents its exact durable terminal receipt and cannot replay") @MainActor
    func terminalReceipt() async throws {
        let f = try fixture(schedule: { intents, id, validate in
            let intent = try intents.inspect(id: id)
            let request = FaceFolderScanRequest(imageURLs: intent.prepared.imageURLs, folderURL: intent.prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                try? validate()
                return .init(folderURL: request.folderURL, outcome: .completed)
            })
        }); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        let intentID = try #require(f.model.review?.intent.id)
        f.model.acknowledgesScan = true
        await f.model.start()
        #expect(f.model.operation?.outcome == .verified)
        #expect(f.model.receipt?.operationID == f.model.operation?.id)
        #expect(f.model.receipt?.intentID == intentID)
        #expect(f.model.message?.contains("completed") == true)
        await f.model.start()
        #expect(try f.receipts.receipts().count == 1)
    }
}
