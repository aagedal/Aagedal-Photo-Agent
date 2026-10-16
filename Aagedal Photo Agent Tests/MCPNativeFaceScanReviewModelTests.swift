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
    @MainActor private func fixture(
        schedule: @escaping MCPFaceScanOperationService.Scheduler,
        preflightCheckpoint: (@Sendable () throws -> Void)? = nil,
        readReceipt: (@Sendable (MCPFaceScanReceiptStore, UUID) throws -> MCPFaceScanReceiptStore.Receipt?)? = nil
    ) throws -> Fixture {
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
        let reader: @Sendable (UUID) throws -> MCPFaceScanReceiptStore.Receipt?
        if let readReceipt {
            reader = { id in try readReceipt(receipts, id) }
        } else {
            reader = { id in try receipts.receipts().first { $0.operationID == id } }
        }
        let model = MCPNativeFaceScanReviewModel(intents: intents, operations: operations,
            receipts: receipts, readiness: { state.readiness() }, modelPreflight: {
                try preflightCheckpoint?()
                return state.preflight()
            }, readReceipt: reader)
        return .init(root: root, photos: photos, state: state, model: model,
                     receipts: receipts, intents: intents)
    }
    private func refuse(_: MCPFaceScanAdmissionService.RetainedFolder, _: UUID,
                        _: @escaping @Sendable () throws -> Void) async throws -> FaceFolderScanSubmission {
        Issue.record("Unexpected scheduling without valid native consent/readiness")
        return .init(admission: .refused(.scanAlreadyRunning), task: nil)
    }

    nonisolated private enum Context {
        @TaskLocal static var marker: UUID?
    }

    @MainActor private func durableRequest(_ f: Fixture) throws -> (MCPFaceScanReviewRequestStore, MCPFaceScanReviewRequestStore.Record) {
        let authority = MCPAuthorizationStore(readConfigurationData: { f.state.read() }, writeConfigurationData: { f.state.write($0) })
        let requests = MCPFaceScanReviewRequestStore(storageDirectory: f.root.appendingPathComponent("requests"))
        let record = try requests.request(requestID: UUID(), requestEpoch: requests.capacitySnapshot().epoch,
            arguments: ["path": .string(f.photos.path), "includeJerseyNumbers": .bool(true)],
            admission: .init(authorizationStore: authority))
        return (requests, record)
    }

    @Test("Explicit durable adoption reviews exact original evidence without enabling execution") @MainActor
    func durableReviewOnly() async throws {
        let f = try fixture(schedule: refuse)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (requests, record) = try durableRequest(f)
        await f.model.prepare(record: record, requests: requests)
        let review = try #require(f.model.review)
        #expect(review.intent.durableRequest?.intentSHA256 == record.intentSHA256)
        #expect(review.intent.prepared.snapshotRevision == record.intent.snapshotRevision)
        #expect(review.intent.createdAt == record.intent.preparedAt)
        #expect(review.intent.expiresAt == record.intent.expiresAt)
        #expect(review.intent.prepared.forceFullScan && review.intent.prepared.includeJerseyNumbers)
        #expect(!f.model.acknowledgesScan && !f.model.acknowledgesReset)
        f.model.acknowledgesScan = true; f.model.acknowledgesReset = true
        #expect(!f.model.canStart)
        await f.model.start()
        #expect(f.model.operation == nil && f.model.receipt == nil)
        await f.model.prepare(record: record, requests: requests)
        #expect(f.model.review?.intent.id == review.intent.id)
        #expect(!f.model.acknowledgesScan && !f.model.acknowledgesReset)
        f.model.dismiss()
        #expect(f.model.review == nil)
        #expect(try requests.records() == [record])
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }

    @Test("Dismissal during durable preflight prevents delayed adoption publication") @MainActor
    func dismissedDurableReview() async throws {
        let entered = Gate(), release = DispatchSemaphore(value: 0)
        let f = try fixture(schedule: refuse, preflightCheckpoint: {
            #expect(!Thread.isMainThread)
            Task { await entered.open() }
            release.wait()
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let (requests, record) = try durableRequest(f)
        let task = Task { await f.model.prepare(record: record, requests: requests) }
        await entered.wait()
        f.model.dismiss(); release.signal()
        await task.value
        #expect(f.model.review == nil && !f.model.isPreparing && !f.model.canStart)
        #expect(try requests.records() == [record])
    }

    @Test("Review worker preserves task context and cancellation across blocking work") @MainActor
    func workerContextAndCancellation() async throws {
        let worker = MCPNativeFaceScanReviewModel.ReviewWorker()
        let entered = Gate(), release = DispatchSemaphore(value: 0), marker = UUID()
        let task = Task {
            try await Context.$marker.withValue(marker) {
                try await worker.run {
                    #expect(!Thread.isMainThread)
                    #expect(Context.marker == marker)
                    Task { await entered.open() }
                    // Avoid trapping the main actor if executor ownership regresses.
                    if !Thread.isMainThread { release.wait() }
                    return true
                }
            }
        }
        await entered.wait()
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            Issue.record("Cancelled blocking review work published a result")
        } catch is CancellationError {}
    }

    @Test("Cancelled or dismissed model loading cannot publish a late review", arguments: [true, false]) @MainActor
    func withdrawalDuringModelLoading(cancel: Bool) async throws {
        let entered = Gate(), release = DispatchSemaphore(value: 0)
        let f = try fixture(schedule: refuse, preflightCheckpoint: {
            #expect(!Thread.isMainThread)
            Task { await entered.open() }
            if !Thread.isMainThread { release.wait() }
            #expect(Task.isCancelled == cancel)
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = Task { await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false) }
        await entered.wait()
        if cancel { task.cancel() }
        else { f.model.dismiss() }
        release.signal()
        await task.value
        #expect(f.model.review == nil)
        #expect(!f.model.isPreparing)
        #expect(!f.model.canStart)
        #expect(try f.receipts.receipts().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations").path))
    }

    @Test("Dismissal or cancellation during receipt I/O rejects delayed publication", arguments: [true, false]) @MainActor
    func dismissalDuringReceiptRead(cancel: Bool) async throws {
        let entered = Gate(), release = DispatchSemaphore(value: 0)
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                .init(folderURL: request.folderURL, outcome: .completed)
            })
        }, readReceipt: { receipts, id in
            #expect(!Thread.isMainThread)
            Task { await entered.open() }
            if !Thread.isMainThread { release.wait() }
            return try receipts.receipts().first { $0.operationID == id }
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        f.model.acknowledgesScan = true
        let task = Task { await f.model.start() }
        await entered.wait()
        #expect(!f.model.canCancel)
        await f.model.cancel()
        #expect(f.model.message == "Loading the completed face scan receipt…")
        if cancel { task.cancel() }
        else { f.model.dismiss() }
        #expect(f.model.receipt == nil)
        release.signal()
        await task.value
        #expect(!f.model.isRunning)
        #expect(f.model.receipt == nil)
        if cancel {
            #expect(f.model.operation?.outcome == .verified)
            #expect(f.model.message?.contains("receipt could not be loaded") == true)
        } else {
            #expect(f.model.message == nil)
        }
        #expect(try f.receipts.receipts().count == 1)
    }

    @Test("A failed receipt read preserves the terminal operation and durable completion") @MainActor
    func failedReceiptRead() async throws {
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                .init(folderURL: request.folderURL, outcome: .completed)
            })
        }, readReceipt: { _, _ in throw CocoaError(.fileReadNoPermission) })
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        f.model.acknowledgesScan = true
        await f.model.start()
        #expect(f.model.operation?.outcome == .verified)
        #expect(f.model.receipt == nil)
        #expect(f.model.message?.contains("receipt could not be loaded") == true)
        #expect(!f.model.canStart)
        await f.model.start()
        #expect(try f.receipts.receipts().count == 1)
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
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
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
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
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

    @Test("Mismatched or incomplete receipts never publish completion or permit replay", arguments: [
        "intentID", "operationID", "snapshotRevision", "photoCount", "forceFullScan",
        "includeJerseyNumbers", "phase", "outcome", "missing"
    ]) @MainActor
    func mismatchedReceipt(field: String) async throws {
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                .init(folderURL: request.folderURL, outcome: .completed)
            })
        }, readReceipt: { receipts, id in
            let original = try #require(receipts.receipts().first { $0.operationID == id })
            if field == "missing" { return nil }
            // Substitute evidence from another request or phase.
            // Leave the durable archive untouched for recovery inspection.
            let data = try JSONEncoder().encode(original)
            var value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch field {
            case "intentID", "operationID": value[field] = UUID().uuidString
            case "snapshotRevision": value[field] = "sha256:" + String(repeating: "0", count: 64)
            case "photoCount": value[field] = original.photoCount + 1
            case "forceFullScan", "includeJerseyNumbers": value[field] = true
            case "phase": value[field] = "executionPossible"; value.removeValue(forKey: "completion")
            case "outcome":
                var completion = try #require(value["completion"] as? [String: Any])
                completion["outcome"] = "failed"
                value["completion"] = completion
            default: Issue.record("Unknown receipt substitution")
            }
            return try JSONDecoder().decode(MCPFaceScanReceiptStore.Receipt.self,
                from: JSONSerialization.data(withJSONObject: value))
        })
        defer { try? FileManager.default.removeItem(at: f.root) }
        let originalBytes = try Data(contentsOf: f.photos.appendingPathComponent("photo.jpg"))
        await f.model.prepare(folder: f.photos, forceFullScan: false, includeJerseyNumbers: false)
        let intent = try #require(f.model.review?.intent)
        f.model.acknowledgesScan = true
        await f.model.start()
        let operation = try #require(f.model.operation)
        #expect(operation.isTerminal)
        #expect(operation.outcome == .verified)
        #expect(f.model.receipt == nil)
        #expect(f.model.message?.contains("receipt could not be loaded") == true)
        #expect(!f.model.canStart)
        #expect(!f.model.canCancel)
        let durable = try #require(f.receipts.receipts().first)
        try durable.requireCompletion(intent: intent, operation: operation)
        await f.model.start()
        #expect(try f.receipts.receipts().count == 1)
        #expect(try Data(contentsOf: f.photos.appendingPathComponent("photo.jpg")) == originalBytes)
    }

    @Test("Successful retained work presents its exact durable terminal receipt and cannot replay") @MainActor
    func terminalReceipt() async throws {
        let f = try fixture(schedule: { retained, _, validate in
            let prepared = retained.prepared
            let request = FaceFolderScanRequest(imageURLs: prepared.imageURLs, folderURL: prepared.folderURL)
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
        let operation = try #require(f.model.operation)
        let receipt = try #require(f.model.receipt)
        let intent = try f.intents.inspect(id: intentID)
        for field in ["kind", "state"] {
            let data = try JSONEncoder().encode(operation)
            var value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if field == "kind" { value[field] = "voice_transcription" }
            else { value[field] = "running"; value.removeValue(forKey: "outcome") }
            let substituted = try JSONDecoder().decode(AutomationOperationRegistry.Record.self,
                from: JSONSerialization.data(withJSONObject: value))
            #expect(throws: MCPFaceScanReceiptStore.Failure.mismatchedCompletion) {
                try receipt.requireCompletion(intent: intent, operation: substituted)
            }
        }
        await f.model.start()
        #expect(try f.receipts.receipts().count == 1)
    }
}
