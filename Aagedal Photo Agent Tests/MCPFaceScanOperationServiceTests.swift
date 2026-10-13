import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Durable retained face scan bridge")
struct MCPFaceScanOperationServiceTests {
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func read() -> Data? { lock.withLock { data } }
        func write(_ data: Data?) { lock.withLock { self.data = data } }
    }
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
    private struct Fixture {
        let root: URL
        let intents: MCPFaceScanIntentStore
        let intent: MCPFaceScanIntentStore.Intent
        let registry: AutomationOperationRegistry
        let receipts: MCPFaceScanReceiptStore
    }
    private func fixture(capacity: Int = 256) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/face-operation-\(UUID())", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("synthetic image".utf8).write(to: photos.appendingPathComponent("private-name.jpg"))
        let box = Box()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(photos); try authority.setEnabled(true)
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authority))
        let intent = try intents.prepare(arguments: ["path": .string(photos.path)])
        return .init(root: root, intents: intents, intent: intent,
            registry: .init(storageDirectory: root.appendingPathComponent("operations")),
            receipts: .init(storageDirectory: root.appendingPathComponent("receipts"), maximumReceipts: capacity))
    }
    private func request(_ intent: MCPFaceScanIntentStore.Intent) -> FaceFolderScanRequest {
        .init(imageURLs: intent.prepared.imageURLs, folderURL: intent.prepared.folderURL,
              forceFullScan: intent.prepared.forceFullScan, includeJerseyNumbers: intent.prepared.includeJerseyNumbers)
    }

    @Test("Native durable bridge saves the exact admitted scope and retains document evidence") @MainActor
    func nativeBridgePersistsExactScope() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let scanner = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in FaceDetectionService.DetectionResult(faces: []) })
        let service = MCPFaceScanOperationService.native(intents: f.intents, registry: f.registry,
            receipts: f.receipts, scanner: scanner)
        let expectedID = f.intent.id
        let expectedRevision = f.intent.prepared.snapshotRevision
        let operation = try await service.submit(intentID: expectedID, nativeAdmission: { intent in
            #expect(intent.id == expectedID)
            #expect(intent.prepared.snapshotRevision == expectedRevision)
        })
        let finished = try await service.waitForCompletion(operation.id)
        #expect(finished.kind == .faceScan)
        #expect(finished.outcome == .verified)
        let receipt = try #require(try f.receipts.receipts().first)
        #expect(receipt.intentID == expectedID)
        #expect(receipt.operationID == operation.id)
        #expect(receipt.snapshotRevision == expectedRevision)
        #expect(receipt.phase == .completed)
        let completion = try #require(receipt.completion)
        #expect(completion.outcome == .verified)
        #expect(completion.processedCount == f.intent.prepared.imageURLs.count)
        #expect(completion.documents.count == 1)
        #expect(completion.documents.first?.result == .committed)
        #expect(completion.documents.first?.documentCommitted == true)
        #expect(completion.documents.first?.authorityRefused == false)
        #expect(completion.committedDocumentCount == 1)
        let saved = try #require(FaceDataStorageService().loadFaceData(for: f.intent.prepared.folderURL))
        #expect(saved.scanComplete)
        #expect(saved.folderURL.standardizedFileURL == f.intent.prepared.folderURL.standardizedFileURL)
        #expect(Set(saved.scannedFiles.keys) == Set(f.intent.prepared.imageURLs.map(\.path)))
        #expect(saved.faces.isEmpty)
        _ = try await service.shutdown()
    }

    @Test("Receipt persistence refusal prevents scheduling and operation enqueue")
    func persistenceRefusal() async throws {
        let f = try fixture(capacity: 0); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                Issue.record("Receipt refusal scheduled a scan")
                return .init(admission: .refused(.scanAlreadyRunning), task: nil)
            })
        await #expect(throws: MCPFaceScanReceiptStore.Failure.capacity) {
            try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        }
        // Owner lease admission may create coordination lock storage, but refusal
        // must never persist an operation archive or schedule an executor.
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations/operations.json").path))
    }

    @Test("Exact post-effect cancelled completion remains recovery evidence")
    func cancellationAfterCommit() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = Gate(), release = Gate()
        let request = request(f.intent)
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                await entered.open()
                return .init(admission: .scheduled(request), task: Task {
                    await release.wait()
                    return .init(folderURL: request.folderURL, outcome: .cancelled, processedCount: 1,
                                 committedThumbnailIDs: [UUID()])
                })
            })
        let operation = try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        await entered.wait()
        #expect(try f.receipts.receipts().first?.phase == .executionPossible)
        _ = try await service.requestCancellation(operation.id)
        await release.open()
        let completed = try await service.waitForCompletion(operation.id)
        #expect(completed.outcome == .recoveryRequired)
        #expect(completed.cancellationRequestedAt != nil)
        let receipt = try #require(try f.receipts.receipts().first)
        #expect(receipt.completion?.committedThumbnailCount == 1)
        #expect(receipt.completion?.outcome == .recoveryRequired)
        await #expect(throws: MCPFaceScanReceiptStore.Failure.invalidTransition) {
            try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        }
        let bytes = try Data(contentsOf: f.root.appendingPathComponent("receipts/operations.json"))
        let envelope = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encoded = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encoded))
        #expect(!String(decoding: payload, as: UTF8.self).contains("private-name"))
        #expect(receipt.completion?.committedThumbnailIDs.count == 1)
    }

    @Test("Mismatched scheduled tasks drain and preserve their physical receipts")
    func mismatchedTaskDrains() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = Gate(), release = Gate()
        let wrongFolder = f.root.appendingPathComponent("wrong")
        let request = FaceFolderScanRequest(imageURLs: [], folderURL: wrongFolder)
        let committedID = UUID()
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                return .init(admission: .scheduled(request), task: Task {
                    await entered.open()
                    await release.wait()
                    return .init(folderURL: wrongFolder, outcome: .completed,
                        committedThumbnailIDs: [committedID])
                })
            })
        let operation = try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        await entered.wait()
        #expect(try f.registry.inspect(operation.id).state == .running)
        await release.open()
        #expect(try await service.waitForCompletion(operation.id).outcome == .recoveryRequired)
        let completion = try #require(try f.receipts.receipts().first?.completion)
        #expect(completion.submissionMismatch)
        #expect(completion.committedThumbnailIDs == [committedID])
    }

    @Test("Cancelling a retained submission never cancels a later task")
    func exactSubmissionCancellation() async {
        let release = Gate()
        let folder = URL(fileURLWithPath: "/tmp")
        let request = FaceFolderScanRequest(imageURLs: [], folderURL: folder)
        let first = Task {
            await release.wait()
            return FaceScanCompletion(folderURL: folder, outcome: Task.isCancelled ? .cancelled : .completed)
        }
        let later = Task {
            await release.wait()
            return FaceScanCompletion(folderURL: folder, outcome: Task.isCancelled ? .cancelled : .completed)
        }
        FaceFolderScanSubmission(admission: .scheduled(request), task: first).cancel()
        await release.open()
        #expect(await first.value.outcome == .cancelled)
        #expect(await later.value.outcome == .completed)
    }

    @Test("Direct durable registry cancellation reaches only the exact running submission")
    func directRegistryCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = Gate(), releaseUnrelated = Gate()
        let request = request(f.intent)
        let unrelated = Task {
            await releaseUnrelated.wait()
            return Task.isCancelled
        }
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                .init(admission: .scheduled(request), task: Task {
                    await entered.open()
                    // Bound the fixture independently of the watcher, so a broken
                    // cancellation path fails rather than hanging the test suite.
                    for _ in 0..<200 {
                        if Task.isCancelled { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    return .init(folderURL: request.folderURL, outcome: Task.isCancelled ? .cancelled : .completed)
                })
            })
        let operation = try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        await entered.wait()
        _ = try f.registry.requestCancellation(operation.id)
        let completed = try await service.waitForCompletion(operation.id)
        #expect(completed.state == .cancelled)
        #expect(completed.outcome == .cancelled)
        #expect(try f.receipts.receipts().first?.completion?.coordinationFailed == false)
        await releaseUnrelated.open()
        #expect(await unrelated.value == false)
    }

    @Test("Failed cancellation history reads stop the exact task and preserve uncertain receipt")
    func cancellationReadFailure() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = Gate(), release = Gate()
        let request = request(f.intent)
        let committedID = UUID()
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                .init(admission: .scheduled(request), task: Task {
                    await entered.open()
                    await release.wait()
                    for _ in 0..<200 {
                        if Task.isCancelled { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(Task.isCancelled)
                    return .init(folderURL: request.folderURL, outcome: .cancelled,
                        committedThumbnailIDs: [committedID])
                })
            })
        let operation = try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        await entered.wait()
        try Data("corrupted history".utf8).write(to: f.root.appendingPathComponent("operations/operations.json"))
        await release.open()
        await #expect(throws: (any Error).self) { try await service.waitForCompletion(operation.id) }
        let evidence = try #require(try f.receipts.receipts().first?.completion)
        #expect(evidence.coordinationFailed)
        #expect(evidence.outcome == .recoveryRequired)
        #expect(evidence.committedThumbnailIDs == [committedID])
    }

    @Test("Clean exact cancellation is acknowledged only with a durable request")
    func cancellationMapping() {
        let completion = FaceScanCompletion(folderURL: URL(fileURLWithPath: "/tmp"), outcome: .cancelled)
        #expect(MCPFaceScanOperationService.evidence(completion, cancellationRequested: true).outcome == .cancelled)
        #expect(MCPFaceScanOperationService.evidence(completion, cancellationRequested: false).outcome == .failed)
    }

    @Test("Abandoned owner recovery preserves receipt identity without replay")
    func recoveryDoesNotReplay() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = UUID(), operation = UUID()
        var lease: AutomationOperationPersistence.OwnerLease? = try f.registry.acquireOwnerLease(ownerID: owner)
        try f.receipts.admit(intent: f.intent, operationID: operation)
        _ = try f.registry.enqueue(kind: .faceScan, ownerID: owner, operationID: operation, ownerLease: lease)
        try f.receipts.markExecutionPossible(operation)
        #expect(try f.registry.reconcileAbandonedOwners().isEmpty)
        lease = nil
        let restarted = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                Issue.record("Recovery replayed an intent")
                return .init(admission: .refused(.scanAlreadyRunning), task: nil)
            })
        #expect(try await restarted.reconcileAbandonedOwners().map(\.id) == [operation])
        #expect(try f.registry.inspect(operation).outcome == .recoveryRequired)
        #expect(try f.receipts.receipts().first?.phase == .executionPossible)
        await #expect(throws: MCPFaceScanReceiptStore.Failure.invalidTransition) {
            try await restarted.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        }
    }

    @Test("No-follow receipt storage refuses symbolic replacement before scheduling")
    func linkedStorageRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = f.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("receipts"), withDestinationURL: destination)
        let service = MCPFaceScanOperationService(intents: f.intents, registry: f.registry, receipts: f.receipts,
            schedule: { _, _, _ in
                Issue.record("Linked storage scheduled a scan")
                return .init(admission: .refused(.scanAlreadyRunning), task: nil)
            })
        await #expect(throws: (any Error).self) {
            try await service.submit(intentID: f.intent.id, nativeAdmission: { _ in })
        }
        // Owner lease admission may create coordination lock storage, but refusal
        // must never persist an operation archive or schedule an executor.
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations/operations.json").path))
    }
    @Test("Recomputed checksums do not admit malformed receipt schemas", arguments: ["unknown", "duplicate", "phase"])
    func malformedArchive(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.receipts.admit(intent: f.intent, operationID: UUID())
        let archiveURL = f.root.appendingPathComponent("receipts/operations.json")
        let bytes = try Data(contentsOf: archiveURL)
        let envelope = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let encodedPayload = try #require(envelope["payload"] as? String)
        let original = try #require(Data(base64Encoded: encodedPayload))
        var payload = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var receipts = try #require(payload["receipts"] as? [[String: Any]])
        switch kind {
        case "unknown": receipts[0]["privatePhotoName"] = "untrusted"
        case "duplicate": receipts.append(receipts[0])
        default: receipts[0]["phase"] = "completed"
        }
        payload["receipts"] = receipts
        let modified = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let digest = SHA256.hash(data: modified).map { String(format: "%02x", $0) }.joined()
        let replacement = try JSONSerialization.data(withJSONObject: ["payload": modified.base64EncodedString(), "sha256": digest])
        try replacement.write(to: archiveURL)
        #expect(throws: MCPFaceScanReceiptStore.Failure.invalidStorage) { try f.receipts.receipts() }
    }

}
