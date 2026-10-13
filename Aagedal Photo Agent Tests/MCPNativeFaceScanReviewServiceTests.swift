import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Exact native face review consent")
struct MCPNativeFaceScanReviewServiceTests {
    nonisolated private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var time = Date()
        private var monotonicTime = ContinuousClock.now
        private var session = true
        func read() -> Data? { lock.withLock { data } }
        func write(_ value: Data?) { lock.withLock { data = value } }
        func now() -> Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
        func monotonicNow() -> ContinuousClock.Instant { lock.withLock { monotonicTime } }
        func advanceMonotonic(_ seconds: TimeInterval) {
            lock.withLock { monotonicTime = monotonicTime.advanced(by: .seconds(seconds)) }
        }
        func withdraw() { lock.withLock { session = false } }
        func validate() throws {
            try lock.withLock { if !session { throw MCPNativeFaceScanReviewService.Failure.unavailableApproval } }
        }
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
        let photos: URL
        let state: State
        let authority: MCPAuthorizationStore
        let operations: MCPFaceScanOperationService
        let service: MCPNativeFaceScanReviewService
    }
    private func fixture(capacity: Int = 256, schedule: @escaping MCPFaceScanOperationService.Scheduler) throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/native-face-consent-\(UUID())", isDirectory: true)
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("synthetic photo".utf8).write(to: photos.appendingPathComponent("photo.jpg"))
        let state = State()
        let authority = MCPAuthorizationStore(readConfigurationData: { state.read() }, writeConfigurationData: { state.write($0) })
        try authority.addRoot(photos); try authority.setEnabled(true)
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authority), clock: { state.now() })
        let operations = MCPFaceScanOperationService(intents: intents,
            registry: .init(storageDirectory: root.appendingPathComponent("operations")),
            receipts: .init(storageDirectory: root.appendingPathComponent("receipts"), maximumReceipts: capacity), schedule: schedule)
        let service = MCPNativeFaceScanReviewService(intents: intents, operations: operations,
            validateSession: { try state.validate() }, clock: { state.now() },
            monotonicClock: { state.monotonicNow() })
        return .init(root: root, photos: photos, state: state, authority: authority, operations: operations, service: service)
    }
    private func refusingScheduler(_: MCPFaceScanIntentStore, _: UUID,
        _: @escaping @Sendable () throws -> Void) async throws -> FaceFolderScanSubmission {
        Issue.record("Unconsented scan was scheduled")
        return .init(admission: .refused(.scanAlreadyRunning), task: nil)
    }

    @Test("Explicit native review consent survives real scanner checks and retains exact document evidence") @MainActor
    func nativeScannerIntegration() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/native-face-review-integration-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("generated.jpg")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // Explicit pixels keep this generated fixture independent of allocated bytes.
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(.gray, atX: x, y: y) } }
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: photo)
        let state = State()
        let authority = MCPAuthorizationStore(readConfigurationData: { state.read() }, writeConfigurationData: { state.write($0) })
        try authority.addRoot(photos); try authority.setEnabled(true)
        let intents = MCPFaceScanIntentStore(admission: .init(authorizationStore: authority), clock: { state.now() })
        let receipts = MCPFaceScanReceiptStore(storageDirectory: root.appendingPathComponent("receipts"))
        let registry = AutomationOperationRegistry(storageDirectory: root.appendingPathComponent("operations"))
        let scanner = FaceRecognitionViewModel(readService: SwiftExifReadService(),
            writeEngine: SwiftExifWriteEngine(), faceModelAvailability: .available,
            scanDetector: { _, _ in FaceDetectionService.DetectionResult(faces: []) })
        let operations = MCPFaceScanOperationService.native(intents: intents, registry: registry,
            receipts: receipts, scanner: scanner)
        let service = MCPNativeFaceScanReviewService(intents: intents, operations: operations,
            validateSession: { try state.validate() }, clock: { state.now() },
            monotonicClock: { state.monotonicNow() })
        let review = try service.prepare(arguments: ["path": .string(photos.path)])
        let canonicalPhoto = try authority.authorizeExistingPath(photo.path).url
        #expect(review.intent.prepared.imageURLs == [canonicalPhoto])
        #expect(try receipts.receipts().isEmpty)
        let approval = try service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        #expect(try receipts.receipts().isEmpty)
        let operation = try await service.submit(approval)
        let completed = try await operations.waitForCompletion(operation.id)
        #expect(completed.outcome == .verified)
        let receipt = try #require(try receipts.receipts().first)
        #expect(receipt.intentID == review.intent.id)
        #expect(receipt.operationID == operation.id)
        #expect(receipt.snapshotRevision == review.intent.prepared.snapshotRevision)
        #expect(receipt.photoCount == 1)
        #expect(receipt.phase == .completed)
        let evidence = try #require(receipt.completion)
        #expect(evidence.outcome == .verified)
        #expect(evidence.processedCount == 1)
        #expect(evidence.committedDocumentCount == 1)
        #expect(evidence.documents.count == 1)
        #expect(evidence.documents.first?.result == .committed)
        #expect(evidence.documents.first?.documentCommitted == true)
        #expect(evidence.documents.first?.authorityRefused == false)
        #expect(evidence.submissionMismatch == false)
        let saved = try #require(FaceDataStorageService().loadFaceData(for: photos))
        #expect(saved.scanComplete)
        #expect(Set(saved.scannedFiles.keys) == [canonicalPhoto.path])
        #expect(saved.faces.isEmpty)
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) {
            try await service.submit(approval)
        }
        #expect(try receipts.receipts().count == 1)
        _ = try await operations.shutdown()
    }

    @Test("Jersey scan review requires explicit reset acknowledgement and replacing review revokes consent")
    func resetAndReviewReplacement() async throws {
        let f = try fixture(schedule: refusingScheduler); defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path), "includeJerseyNumbers": .bool(true)])
        #expect(review.intent.prepared.forceFullScan)
        #expect(review.consequences.contains { $0.contains("resets") })
        #expect(throws: MCPNativeFaceScanReviewService.Failure.acknowledgementRequired) {
            try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        }
        let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: true)
        _ = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try await f.service.submit(approval) }
        #expect(throws: MCPNativeFaceScanReviewService.Failure.changedReview) {
            try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: true)
        }
    }

    @Test("Expiry, authorization withdrawal and inventory drift refuse before scheduling", arguments: ["expiry", "authorization", "inventory", "session", "revoke"])
    func changedAdmission(kind: String) async throws {
        let f = try fixture(schedule: refusingScheduler); defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        switch kind {
        case "expiry": f.state.advance(301)
        case "authorization": try f.authority.setEnabled(false)
        case "inventory": try Data("added".utf8).write(to: f.photos.appendingPathComponent("added.jpg"))
        case "session": f.state.withdraw()
        default: f.service.revoke(approval)
        }
        await #expect(throws: (any Error).self) { try await f.service.submit(approval) }
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try await f.service.submit(approval) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations/operations.json").path))
    }

    @Test("Consumed authority is single use, survives preview expiry and ends after worker drain")
    func retainedCapability() async throws {
        let entered = Gate(), release = Gate()
        let f = try fixture(schedule: { intents, id, validate in
            let intent = try intents.inspect(id: id)
            let request = FaceFolderScanRequest(imageURLs: intent.prepared.imageURLs,
                folderURL: intent.prepared.folderURL, forceFullScan: false, includeJerseyNumbers: false)
            try validate()
            return .init(admission: .scheduled(request), task: Task {
                await entered.open(); await release.wait()
                do { try validate() }
                catch { Issue.record("Admitted consent incorrectly expired: \(error)") }
                return .init(folderURL: request.folderURL, outcome: .completed)
            })
        }); defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        let operation = try await f.service.submit(approval)
        await entered.wait()
        f.state.advance(600)
        f.state.advanceMonotonic(600)
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try await f.service.submit(approval) }
        await release.open()
        #expect(try await f.operations.waitForCompletion(operation.id).outcome == .verified)
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try await f.service.submit(approval) }
    }

    @Test("Frozen wall clock cannot extend the review or approval admission lifetime", arguments: [true, false])
    func frozenWallClock(approveBeforeExpiry: Bool) async throws {
        let f = try fixture(schedule: refusingScheduler)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        if approveBeforeExpiry {
            let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
            f.state.advanceMonotonic(MCPFaceScanIntentStore.lifetime)
            await #expect(throws: MCPNativeFaceScanReviewService.Failure.expiredApproval) {
                try await f.service.submit(approval)
            }
            await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) {
                try await f.service.submit(approval)
            }
        } else {
            f.state.advanceMonotonic(MCPFaceScanIntentStore.lifetime)
            #expect(throws: MCPNativeFaceScanReviewService.Failure.expiredApproval) {
                try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("operations/operations.json").path))
    }

    @Test("Durable admission refusal consumes native consent without scheduling or replay")
    func admissionFailureConsumesConsent() async throws {
        let f = try fixture(capacity: 0, schedule: refusingScheduler)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        await #expect(throws: MCPFaceScanReceiptStore.Failure.capacity) { try await f.service.submit(approval) }
        await #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try await f.service.submit(approval) }
        #expect(throws: MCPNativeFaceScanReviewService.Failure.changedReview) {
            try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        }
    }

    @Test("Session withdrawal is rechecked by the retained scanner effect capability")
    func withdrawalDuringWork() async throws {
        let entered = Gate(), release = Gate()
        let f = try fixture(schedule: { intents, id, validate in
            let intent = try intents.inspect(id: id)
            let request = FaceFolderScanRequest(imageURLs: intent.prepared.imageURLs, folderURL: intent.prepared.folderURL)
            return .init(admission: .scheduled(request), task: Task {
                await entered.open(); await release.wait()
                #expect(throws: MCPNativeFaceScanReviewService.Failure.unavailableApproval) { try validate() }
                return .init(folderURL: request.folderURL, outcome: .cancelled)
            })
        }); defer { try? FileManager.default.removeItem(at: f.root) }
        let review = try f.service.prepare(arguments: ["path": .string(f.photos.path)])
        let approval = try f.service.approve(review, acknowledgesScan: true, acknowledgesReset: false)
        let operation = try await f.service.submit(approval)
        await entered.wait(); f.state.withdraw(); await release.open()
        #expect(try await f.operations.waitForCompletion(operation.id).outcome == .failed)
    }
}
