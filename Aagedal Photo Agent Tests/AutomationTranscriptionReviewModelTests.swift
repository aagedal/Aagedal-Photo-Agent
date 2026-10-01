import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Read-only native transcription intent inbox")
struct AutomationTranscriptionReviewModelTests {
    private struct Fixture {
        let root: URL
        let photos: [URL]
        let memos: [URL]
        let authority: MCPAuthorizationStore
        let facade: MCPAutomationFacade
        let plans: MCPVoiceTranscriptionPlanStore
        let requests: MCPVoiceTranscriptionReviewRequestStore
        let record: MCPVoiceTranscriptionReviewRequestStore.Record
        let preview: MCPJSONValue
        var service: AutomationTranscriptionReviewService { .init(plans: plans, facade: facade, requests: requests) }
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/transcription-inbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let box = UITestTranscriptionReviewFixture.ConfigurationBox()
        let authority = MCPAuthorizationStore(readConfigurationData: { box.read() }, writeConfigurationData: { box.write($0) })
        try authority.addRoot(root); try authority.setEnabled(true)
        let facade = MCPAutomationFacade(authorizationStore: authority)
        var inputs: [MCPJSONValue] = [], photos: [URL] = [], memos: [URL] = []
        for index in 1...2 {
            let photo = root.appendingPathComponent("frame\(index)-**untrusted**-å.jpg")
            let memo = root.appendingPathComponent("memo\(index).wav")
            try Data("photo \(index)".utf8).write(to: photo); try Data("WAV \(index)".utf8).write(to: memo)
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "profileIdentifier": "custom-reviewed-profile",
                "imageFilename": photo.lastPathComponent, "memoFilename": memo.lastPathComponent])
                .write(to: root.appendingPathComponent(".\(photo.lastPathComponent).voice-memo.json"))
            let evidence = try #require(facade.inspectPhotoVoiceMemo(path: photo.path).objectValue)
            var input = evidence.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(photo.path); inputs.append(.object(input)); photos.append(photo); memos.append(memo)
        }
        let plans = MCPVoiceTranscriptionPlanStore(storageDirectory: root.appendingPathComponent("plans"))
        let preview = try plans.prepare(arguments: ["photos": .array(Array(inputs.reversed())), "provider": .string("whisper"),
            "language": .string("auto"), "translate": .bool(true), "useGPU": .bool(true)], facade: facade)
        let requests = MCPVoiceTranscriptionReviewRequestStore(storageDirectory: root.appendingPathComponent("requests"))
        let planID = try #require(preview.objectValue?["planID"]?.stringValue)
        let epoch = try requests.capacitySnapshot().epoch
        let record = try requests.request(requestID: UUID(), requestEpoch: epoch, planID: planID, plans: plans, facade: facade)
        return Fixture(root: root, photos: photos, memos: memos, authority: authority, facade: facade,
            plans: plans, requests: requests, record: record, preview: preview)
    }

    private actor ControlledService: AutomationTranscriptionReviewServing {
        var retained: [MCPVoiceTranscriptionReviewRequestStore.Record]
        let review: AutomationTranscriptionReview
        var failList = false
        var holdInspection = false
        var holdNextList = false
        var heldInspection: CheckedContinuation<AutomationTranscriptionReview, Never>?
        var heldList: CheckedContinuation<[MCPVoiceTranscriptionReviewRequestStore.Record], Never>?
        var listSnapshot: [MCPVoiceTranscriptionReviewRequestStore.Record] = []
        var inspectionPending: Bool { heldInspection != nil }
        var listPending: Bool { heldList != nil }
        var cancellations = 0
        var cleanupEpochs: [UUID] = []
        var snapshot: MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot
        var holdCapacity = false
        var heldCapacity: CheckedContinuation<MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot, Never>?
        var capacityPending: Bool { heldCapacity != nil }
        var capacityReadSnapshot: MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot?
        var holdCleanup = false
        var heldCleanup: CheckedContinuation<UUID, Never>?
        var cleanupPending: Bool { heldCleanup != nil }
        init(record: MCPVoiceTranscriptionReviewRequestStore.Record, review: AutomationTranscriptionReview) {
            retained = [record]; self.review = review
            snapshot = .init(epoch: UUID(uuidString: record.requestEpoch)!, retainedCount: 1,
                maximumRecords: 64, cancelledBeforeAdmissionCount: record.state == .cancelled ? 1 : 0)
        }
        func configure(failList: Bool = false, holdInspection: Bool = false, holdNextList: Bool = false) {
            self.failList = failList; self.holdInspection = holdInspection; self.holdNextList = holdNextList
        }
        func requests() async throws -> [MCPVoiceTranscriptionReviewRequestStore.Record] {
            if failList { throw MCPVoiceTranscriptionReviewRequestStore.Failure.storageUnavailable }
            if holdNextList {
                holdNextList = false; listSnapshot = retained
                return await withCheckedContinuation { heldList = $0 }
            }
            return retained
        }
        func setRecords(_ records: [MCPVoiceTranscriptionReviewRequestStore.Record]) { retained = records }
        func setCapacity(_ snapshot: MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot, hold: Bool = false) {
            self.snapshot = snapshot; holdCapacity = hold
        }
        func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot {
            guard holdCapacity else { return snapshot }
            holdCapacity = false; capacityReadSnapshot = snapshot
            return await withCheckedContinuation { heldCapacity = $0 }
        }
        func configureCleanup(hold: Bool) { holdCleanup = hold }
        func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID {
            cleanupEpochs.append(expectedEpoch)
            guard snapshot.epoch == expectedEpoch else { throw MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch }
            guard retained.contains(where: { $0.state == .cancelled }) else {
                throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
            }
            retained.removeAll { $0.state == .cancelled }
            snapshot = .init(epoch: UUID(), retainedCount: retained.count, maximumRecords: snapshot.maximumRecords,
                cancelledBeforeAdmissionCount: 0)
            if holdCleanup { return await withCheckedContinuation { heldCleanup = $0 } }
            return snapshot.epoch
        }
        func finishCleanup() { heldCleanup?.resume(returning: snapshot.epoch); heldCleanup = nil }
        func finishCapacity() {
            if let snapshot = capacityReadSnapshot { heldCapacity?.resume(returning: snapshot) }
            heldCapacity = nil; capacityReadSnapshot = nil
        }
        func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview {
            guard holdInspection else { return review }
            return await withCheckedContinuation { heldInspection = $0 }
        }
        func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws { cancellations += 1; retained = [] }
        func finishInspection() { heldInspection?.resume(returning: review); heldInspection = nil }
        func finishList() { heldList?.resume(returning: listSnapshot); heldList = nil }
    }

    @MainActor private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await condition(), "Timed out waiting for controlled intent review")
    }

    @Test("Native review retains exact order and unresolved intent without modifying carriers or request")
    func readOnlyInspection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let photoBytes = try f.photos.map { try Data(contentsOf: $0) }, audioBytes = try f.memos.map { try Data(contentsOf: $0) }
        let service = f.service
        #expect(try await service.requests() == [f.record])
        let review = try await service.inspect(f.record)
        #expect(review.paths == Array(f.photos.reversed()).map { $0.standardizedFileURL.path })
        #expect(review.providerDisplayName == "Whisper" && review.language == "auto" && review.translate && review.useGPU)
        #expect(try f.requests.records() == [f.record])
        #expect(try f.photos.map { try Data(contentsOf: $0) } == photoBytes)
        #expect(try f.memos.map { try Data(contentsOf: $0) } == audioBytes)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Changed WAV, revoked authorization and helper cancellation refuse selected intent", arguments: ["wav", "authorization", "cancelled"])
    func revalidate(kind: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service
        if kind == "wav" { try Data("changed".utf8).write(to: f.memos[0]) }
        if kind == "authorization" { try f.authority.setEnabled(false) }
        if kind == "cancelled" {
            _ = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!, requestEpoch: UUID(uuidString: f.record.requestEpoch)!)
        }
        await #expect(throws: (any Error).self) { try await service.inspect(f.record) }
        if kind != "cancelled" { #expect(try f.requests.records() == [f.record]) }
    }

    @Test("Expired intent remains durably awaiting review and can be cancelled without source admission")
    func expiredIntentCancellation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let expiry = try #require(ISO8601DateFormatter().date(from: f.record.intent.planExpiresAt))
        let service = AutomationTranscriptionReviewService(plans: f.plans, facade: f.facade,
            requests: f.requests, inspectionTime: { expiry.addingTimeInterval(1) })
        await #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.expiredPlan) { try await service.inspect(f.record) }
        #expect(try f.requests.records() == [f.record])
        // Cancellation does not re-admit stale sources or require an unexpired plan.
        try Data("changed WAV".utf8).write(to: f.memos[0])
        try await service.cancel(f.record)
        #expect(try f.requests.records().first?.state == .cancelled)
    }

    @Test("Cancellation preserves original epoch and cannot target a recreated request")
    func cancelRecreatedRequest() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = f.service, id = UUID(uuidString: f.record.requestID)!, epoch = UUID(uuidString: f.record.requestEpoch)!
        try await service.cancel(f.record)
        let cancelled = try #require(f.requests.records().first)
        #expect(cancelled.state == .cancelled && cancelled.requestEpoch == f.record.requestEpoch)
        let next = try f.requests.recoverCancelledCapacity(expectedEpoch: epoch)
        let recreated = try f.requests.request(requestID: id, requestEpoch: next, planID: f.record.planID, plans: f.plans, facade: f.facade)
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) { try await service.cancel(f.record) }
        #expect(try f.requests.records() == [recreated])
    }

    @Test("Review parser preserves plain path text and rejects false consent or malformed intent", arguments: ["consent", "execution", "provider", "count"])
    func malformedPreview(kind: String) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try AutomationTranscriptionReview(f.preview).paths.contains { $0.contains("**untrusted**") })
        var value = try #require(f.preview.objectValue)
        switch kind {
        case "consent": value["consentGranted"] = .bool(true)
        case "execution": value["executionAvailable"] = .bool(true)
        case "provider": var options = try #require(value["options"]?.objectValue); options["provider"] = .string("untrusted"); value["options"] = .object(options)
        default: value["photoCount"] = .integer(1)
        }
        #expect(throws: MCPVoiceTranscriptionPlanStore.Failure.invalidStorage) { try AutomationTranscriptionReview(.object(value)) }
    }

    @Test("Failed refresh clears a review while retaining explicitly stale request status") @MainActor
    func preserveStatusesOnError() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        model.inspect(f.record); try await waitUntil { !model.isLoading }
        #expect(model.review != nil)
        await service.configure(failList: true)
        model.refresh(); try await waitUntil { !model.isLoading }
        #expect(model.requests == [f.record] && model.review == nil && model.selectedRequest == nil)
        #expect(model.message?.contains("out of date") == true)
        model.cancel(f.record)
        #expect(await service.cancellations == 0)
    }

    @Test("Late inspection cannot republish after reload, cancellation or navigation", arguments: ["refresh", "cancel", "clear"]) @MainActor
    func lateInspection(action: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        await service.configure(holdInspection: true)
        model.inspect(f.record); try await waitUntil { await service.inspectionPending }
        if action == "refresh" { model.refresh() }
        else if action == "cancel" { model.cancel(f.record) }
        else { model.clear() }
        try await waitUntil { !model.isLoading }
        await service.finishInspection()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.review == nil && model.selectedRequest == nil && !model.isLoading)
        #expect(model.requests == (action == "cancel" ? [] : [f.record]))
    }

    @Test("Late list snapshot cannot overwrite confirmed cancellation") @MainActor
    func lateList() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        await service.configure(holdNextList: true)
        model.refresh(); try await waitUntil { await service.listPending }
        model.cancel(f.record); try await waitUntil { !model.isLoading }
        #expect(model.requests.isEmpty)
        await service.finishList(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.requests.isEmpty && model.review == nil && model.message == nil)
    }

    @Test("Native cleanup rotates capacity and preserves exact awaiting intent and source evidence")
    func nativeCapacityPreservation() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let awaiting = try f.requests.request(requestID: UUID(), requestEpoch: epoch, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        let sourceBytes = try (f.photos + f.memos).map { try Data(contentsOf: $0) }
        try await f.service.cancel(f.record)
        let capacity = try await f.service.requestCapacity()
        #expect(capacity.retainedCount == 2 && capacity.maximumRecords == 64 && capacity.cancelledBeforeAdmissionCount == 1)
        let rotated = try await f.service.recoverCancelledCapacity(expectedEpoch: capacity.epoch)
        #expect(rotated != epoch)
        #expect(try f.requests.records() == [awaiting])
        #expect(try (f.photos + f.memos).map { try Data(contentsOf: $0) } == sourceBytes)
        #expect(try await f.service.inspect(awaiting).planID == awaiting.planID)
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.staleEpoch) {
            try await f.service.recoverCancelledCapacity(expectedEpoch: epoch)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".photo_metadata").path))
    }

    @Test("Native cleanup preserves cancelled-after-admission and linked uncertain evidence")
    func preserveAdmittedAndUncertainEvidence() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let owner = UUID(), operation = UUID()
        let registry = AutomationOperationRegistry(storageDirectory: f.root.appendingPathComponent("operations"))
        let admittedIntent = try f.requests.request(requestID: UUID(), requestEpoch: epoch, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        let admittedID = UUID(uuidString: admittedIntent.requestID)!
        _ = try f.requests.admit(admittedID, requestEpoch: epoch, expected: admittedIntent,
            operationID: UUID(), ownerID: UUID(), registry: registry)
        let admitted = try f.requests.cancel(admittedID, requestEpoch: epoch)
        let linkedIntent = try f.requests.request(requestID: UUID(), requestEpoch: epoch, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        let linkedID = UUID(uuidString: linkedIntent.requestID)!
        _ = try f.requests.admit(linkedID, requestEpoch: epoch, expected: linkedIntent,
            operationID: operation, ownerID: owner, registry: registry)
        let lease = try registry.acquireOwnerLease(ownerID: owner)
        defer { withExtendedLifetime(lease) {} }
        _ = try registry.enqueue(kind: .voiceTranscription, ownerID: owner, operationID: operation, ownerLease: lease)
        _ = try registry.configureBatch(operation, ownerID: owner, itemCount: f.record.intent.photoCount)
        _ = try f.requests.link(linkedID, requestEpoch: epoch, operationID: operation, registry: registry)
        let linked = try f.requests.cancel(linkedID, requestEpoch: epoch)
        _ = try registry.finish(operation, ownerID: owner, outcome: .partialUncertain)
        let operations = try registry.records()
        try await f.service.cancel(f.record)
        let capacity = try await f.service.requestCapacity()
        #expect(capacity.retainedCount == 3 && capacity.cancelledBeforeAdmissionCount == 1)
        _ = try await f.service.recoverCancelledCapacity(expectedEpoch: epoch)
        #expect(try f.requests.records() == [admitted, linked])
        #expect(try registry.records() == operations)
        #expect(admitted.state == .admitted && linked.state == .linked)
        #expect(AutomationTranscriptionReviewModel.status(linked).contains("not confirmed stopped"))
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try await f.service.inspect(admitted)
        }
        await #expect(throws: MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition) {
            try await f.service.cancel(linked)
        }
        #expect(try f.requests.records() == [admitted, linked])
    }

    @Test("Disabled authority refuses native capacity inspection and cleanup")
    func capacityAuthority() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.cancel(f.record)
        let capacity = try await f.service.requestCapacity()
        let before = try f.requests.records()
        try f.authority.setEnabled(false)
        await #expect(throws: MCPAuthorizationError.disabled) { try await f.service.requestCapacity() }
        await #expect(throws: MCPAuthorizationError.disabled) { try await f.service.recoverCancelledCapacity(expectedEpoch: capacity.epoch) }
        #expect(try f.requests.records() == before)
        #expect(try f.requests.capacitySnapshot() == capacity)
    }

    @Test("Evidence polling preserves exact selection and clears a helper-cancelled review") @MainActor
    func selectedEvidenceRefresh() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        model.inspect(f.record); try await waitUntil { !model.isLoading }
        model.refreshRequestEvidence(); try await waitUntil { !model.isRefreshingEvidence }
        #expect(model.selectedRequest == f.record && model.review != nil)
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!,
            requestEpoch: UUID(uuidString: f.record.requestEpoch)!)
        await service.setRecords([cancelled])
        model.refreshRequestEvidence(); try await waitUntil { !model.isRefreshingEvidence }
        #expect(model.requests == [cancelled] && model.selectedRequest == nil && model.review == nil)
    }

    @Test("Successful status polling preserves a rejected source-review message") @MainActor
    func pollingPreservesSourceRefusal() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let model = AutomationTranscriptionReviewModel(service: f.service)
        model.refresh(); try await waitUntil { !model.isLoading }
        try Data("changed WAV".utf8).write(to: f.memos[0])
        model.inspect(f.record); try await waitUntil { !model.isLoading }
        let refusal = try #require(model.message)
        #expect(model.review == nil && model.selectedRequest == nil)
        model.refreshRequestEvidence(); try await waitUntil { !model.isRefreshingEvidence }
        #expect(model.message == refusal && model.requests == [f.record])
        #expect(model.review == nil && model.selectedRequest == nil)
        model.refresh(); try await waitUntil { !model.isLoading }
        #expect(model.message == nil)
    }

    @Test("Polling cancellation invalidates a late selected-source inspection") @MainActor
    func pollInvalidatesInspection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        await service.configure(holdInspection: true)
        model.inspect(f.record); try await waitUntil { await service.inspectionPending }
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!,
            requestEpoch: UUID(uuidString: f.record.requestEpoch)!)
        await service.setRecords([cancelled])
        model.refreshRequestEvidence(); try await waitUntil { !model.isRefreshingEvidence }
        await service.finishInspection(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.requests == [cancelled] && model.selectedRequest == nil && model.review == nil && !model.isLoading)
    }

    @Test("Confirmed cleanup cancels a late evidence poll and clears selected intent") @MainActor
    func cleanupInvalidatesLatePoll() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!, requestEpoch: epoch)
        let awaiting = try f.requests.request(requestID: UUID(), requestEpoch: epoch, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        let service = ControlledService(record: cancelled, review: try .init(f.preview))
        await service.setRecords([cancelled, awaiting])
        await service.setCapacity(.init(epoch: epoch, retainedCount: 2, maximumRecords: 64, cancelledBeforeAdmissionCount: 1))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        model.inspect(awaiting); try await waitUntil { !model.isLoading }
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        #expect(model.canRecoverCancelledCapacity && model.review != nil)
        await service.configure(holdNextList: true)
        model.refreshRequestEvidence(); try await waitUntil { await service.listPending }
        model.recoverCancelledCapacity(expectedEpoch: epoch)
        try await waitUntil { !model.isRecoveringCapacity && !model.isRefreshingEvidence && !model.isInspectingCapacity }
        #expect(model.requests == [awaiting] && model.review == nil && model.selectedRequest == nil)
        #expect(model.capacity?.retainedCount == 1 && model.capacity?.cancelledBeforeAdmissionCount == 0 && model.capacity?.epoch != epoch)
        await service.finishList(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.requests == [awaiting] && model.capacityMessage?.contains("Removed") == true)
        #expect(await service.cleanupEpochs == [epoch])
    }

    @Test("Confirmed cleanup rejects a late selected-source completion") @MainActor
    func cleanupInvalidatesInspection() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!, requestEpoch: epoch)
        let awaiting = try f.requests.request(requestID: UUID(), requestEpoch: epoch, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        let service = ControlledService(record: cancelled, review: try .init(f.preview))
        await service.setRecords([cancelled, awaiting])
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        await service.configure(holdInspection: true)
        model.inspect(awaiting); try await waitUntil { await service.inspectionPending }
        model.recoverCancelledCapacity(expectedEpoch: epoch)
        try await waitUntil { !model.isRecoveringCapacity && !model.isRefreshingEvidence && !model.isInspectingCapacity }
        await service.finishInspection(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.requests == [awaiting] && model.review == nil && model.selectedRequest == nil && !model.isLoading)
    }

    @Test("Navigation rejects late maintenance presentation and follow-up reads") @MainActor
    func lateCleanupCompletion() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!, requestEpoch: epoch)
        let service = ControlledService(record: cancelled, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        await service.configureCleanup(hold: true)
        model.recoverCancelledCapacity(expectedEpoch: epoch); try await waitUntil { await service.cleanupPending }
        model.clear()
        await service.finishCleanup(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.capacity == nil && model.capacityMessage == nil && model.requests == [cancelled])
        #expect(!model.isRecoveringCapacity && !model.isRefreshingEvidence && !model.isInspectingCapacity)
    }

    @Test("Confirmation cannot rebind to a newer displayed capacity epoch") @MainActor
    func displayedEpochDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        let cancelled = try f.requests.cancelBeforeAdmission(UUID(uuidString: f.record.requestID)!, requestEpoch: epoch)
        let service = ControlledService(record: cancelled, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        let next = UUID()
        await service.setCapacity(.init(epoch: next, retainedCount: 1, maximumRecords: 64, cancelledBeforeAdmissionCount: 1))
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        model.recoverCancelledCapacity(expectedEpoch: epoch)
        #expect(await service.cleanupEpochs.isEmpty)
        #expect(model.capacity?.epoch == next && !model.isRecoveringCapacity)
    }

    @Test("A stale store epoch refuses confirmed cleanup and preserves new cancellation evidence") @MainActor
    func storeEpochDrift() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let epoch = try f.requests.capacitySnapshot().epoch
        try await f.service.cancel(f.record)
        let model = AutomationTranscriptionReviewModel(service: f.service)
        model.inspectRequestCapacity(); try await waitUntil { !model.isInspectingCapacity }
        let next = try f.requests.recoverCancelledCapacity(expectedEpoch: epoch)
        let fresh = try f.requests.request(requestID: UUID(), requestEpoch: next, planID: f.record.planID,
            plans: f.plans, facade: f.facade)
        try await f.service.cancel(fresh)
        let retained = try f.requests.records()
        model.recoverCancelledCapacity(expectedEpoch: epoch)
        try await waitUntil { !model.isRecoveringCapacity && !model.isRefreshingEvidence }
        #expect(try f.requests.records() == retained)
        #expect(model.requests == retained && model.capacity == nil)
        #expect(model.capacityMessage?.contains("could not be confirmed") == true)
    }

    @Test("Cancellation or navigation rejects a late capacity completion", arguments: ["cancel", "clear"]) @MainActor
    func lateCapacityRead(action: String) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = ControlledService(record: f.record, review: try .init(f.preview))
        let model = AutomationTranscriptionReviewModel(service: service)
        model.refresh(); try await waitUntil { !model.isLoading }
        let capacity = MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot(epoch: UUID(uuidString: f.record.requestEpoch)!,
            retainedCount: 1, maximumRecords: 64, cancelledBeforeAdmissionCount: 0)
        await service.setCapacity(capacity, hold: true)
        model.inspectRequestCapacity(); try await waitUntil { await service.capacityPending }
        if action == "cancel" { model.cancel(f.record); try await waitUntil { !model.isLoading } }
        else { model.clear() }
        await service.finishCapacity(); try await Task.sleep(for: .milliseconds(50))
        #expect(model.capacity == nil && !model.isInspectingCapacity && !model.isRecoveringCapacity)
    }

    @Test("UI fixture requires both explicit opt-in gates")
    func fixtureGates() {
        let enabled = UITestLaunchConfiguration(arguments: ["app", "--ui-testing"])
        let ordinary = UITestLaunchConfiguration(arguments: ["app"])
        #expect(UITestTranscriptionReviewFixture.service(configuration: ordinary, environment: ["AAGEDAL_UI_TEST_TRANSCRIPTION_REVIEW": "1"]) == nil)
        #expect(UITestTranscriptionReviewFixture.service(configuration: enabled, environment: [:]) == nil)
    }
}
