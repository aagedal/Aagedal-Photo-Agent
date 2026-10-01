import Foundation
import Observation

/// Read-only presentation of an exact revalidated helper intent. Paths stay plain text.
nonisolated struct AutomationTranscriptionReview: Sendable {
    let planID: String
    let paths: [String]
    let provider: String
    let language: String
    let translate: Bool
    let useGPU: Bool
    let expiresAt: Date

    init(_ preview: MCPJSONValue) throws {
        guard let value = preview.objectValue, value["schemaVersion"] == .integer(1),
              value["previewOnly"] == .bool(true), value["commitAvailable"] == .bool(false),
              value["executionAvailable"] == .bool(false), value["consentGranted"] == .bool(false),
              let id = value["planID"]?.stringValue, UUID(uuidString: id)?.uuidString.lowercased() == id,
              let expiry = value["expiresAt"]?.stringValue, let date = ISO8601DateFormatter().date(from: expiry),
              let options = value["options"]?.objectValue,
              case .array(let photos) = value["photos"], !photos.isEmpty, photos.count <= 8,
              value["photoCount"] == .integer(Int64(photos.count)),
              let provider = options["provider"]?.stringValue, let language = options["language"]?.stringValue,
              case .bool(let translate) = options["translate"], case .bool(let gpu) = options["useGPU"] else {
            throw MCPVoiceTranscriptionPlanStore.Failure.invalidStorage
        }
        var arguments = options
        arguments["photos"] = .array(try photos.map { item in
            guard let photo = item.objectValue, let path = photo["canonicalPath"]?.stringValue,
                  photo["associationState"] == .string("available"),
                  photo["executionAvailable"] == .bool(false), photo["consentGranted"] == .bool(false) else {
                throw MCPVoiceTranscriptionPlanStore.Failure.invalidStorage
            }
            var input = photo.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }
            input["path"] = .string(path)
            return .object(input)
        })
        let request: MCPVoiceTranscriptionPlanStore.Request
        do { request = try .init(arguments: arguments) }
        catch { throw MCPVoiceTranscriptionPlanStore.Failure.invalidStorage }
        planID = id; paths = request.paths; self.provider = provider; self.language = language
        self.translate = translate; useGPU = gpu; expiresAt = date
    }

    var providerDisplayName: String {
        switch provider {
        case "appleSpeech": "Apple Speech"
        case "whisper": "Whisper"
        case "customWhisper": "Custom Whisper"
        default: "Unavailable"
        }
    }
}

/// Implementations must bind every inspection and cancellation to the exact displayed
/// request, including its original epoch. No method can admit provider execution.
nonisolated protocol AutomationTranscriptionReviewServing: Sendable {
    func requests() async throws -> [MCPVoiceTranscriptionReviewRequestStore.Record]
    func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot
    func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID
    func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview
    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws
}

// Alternate services must explicitly support native maintenance; no helper fallback exists.
extension AutomationTranscriptionReviewServing {
    func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot {
        throw MCPVoiceTranscriptionReviewRequestStore.Failure.storageUnavailable
    }
    func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID {
        throw MCPVoiceTranscriptionReviewRequestStore.Failure.storageUnavailable
    }
}

/// Durable reads and source revalidation stay off the presentation actor.
actor AutomationTranscriptionReviewService: AutomationTranscriptionReviewServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-transcription-review", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private let plans: MCPVoiceTranscriptionPlanStore
    private let facade: MCPAutomationFacade
    private let retainedRequests: MCPVoiceTranscriptionReviewRequestStore?
    private let inspectionTime: @Sendable () -> Date

    init(plans: MCPVoiceTranscriptionPlanStore? = nil, facade: MCPAutomationFacade = .init(),
         requests: MCPVoiceTranscriptionReviewRequestStore? = nil,
         inspectionTime: @escaping @Sendable () -> Date = { Date() }) {
        self.plans = plans ?? .init(storageDirectory: MCPVoiceTranscriptionPlanStore.defaultStorageDirectory())
        self.facade = facade; retainedRequests = requests; self.inspectionTime = inspectionTime
    }

    private func requestStore() throws -> MCPVoiceTranscriptionReviewRequestStore {
        try retainedRequests ?? .init(storageDirectory: MCPVoiceTranscriptionReviewRequestStore.defaultStorageDirectory())
    }

    func requests() throws -> [MCPVoiceTranscriptionReviewRequestStore.Record] {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        let records = try requestStore().records()
        try Task.checkCancellation()
        guard try facade.authorizationStore.load() == authorization else {
            throw MCPVoiceTranscriptionPlanStore.Failure.authorityChanged
        }
        return records.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.requestID < $1.requestID
        }
    }

    /// Explicit capacity inspection may initialize the bounded archive; list polling does not.
    func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        let store = try requestStore()
        try Task.checkCancellation()
        guard try facade.authorizationStore.load() == authorization else {
            throw MCPVoiceTranscriptionPlanStore.Failure.authorityChanged
        }
        return try store.capacitySnapshot()
    }

    /// Native confirmation supplies the displayed epoch. Only proven pre-admission
    /// cancellations are eligible; awaiting, admitted and linked intent stays retained.
    func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        let store = try requestStore()
        try Task.checkCancellation()
        guard try facade.authorizationStore.load() == authorization else {
            throw MCPVoiceTranscriptionPlanStore.Failure.authorityChanged
        }
        return try store.recoverCancelledCapacity(expectedEpoch: expectedEpoch)
    }

    func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) throws -> AutomationTranscriptionReview {
        try Task.checkCancellation()
        let store = try requestStore()
        let handles = try Self.handles(request)
        guard request.state == .awaitingReview,
              try store.inspect(handles.id, requestEpoch: handles.epoch) == request else {
            throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
        }
        let result = try plans.withValidatedPreview(planID: request.planID, facade: facade, now: inspectionTime()) { preview in
            try Task.checkCancellation()
            guard try MCPVoiceTranscriptionReviewRequestStore.Intent(preview: preview) == request.intent,
                  try store.inspect(handles.id, requestEpoch: handles.epoch) == request else {
                throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
            }
            return try AutomationTranscriptionReview(preview)
        }
        try Task.checkCancellation()
        guard try store.inspect(handles.id, requestEpoch: handles.epoch) == request else {
            throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
        }
        return result
    }

    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        try Task.checkCancellation()
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        let store = try requestStore(), handles = try Self.handles(request)
        guard request.state == .awaitingReview,
              try store.inspect(handles.id, requestEpoch: handles.epoch) == request else {
            throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
        }
        try Task.checkCancellation()
        guard try facade.authorizationStore.load() == authorization else {
            throw MCPVoiceTranscriptionPlanStore.Failure.authorityChanged
        }
        _ = try store.cancelBeforeAdmission(handles.id, requestEpoch: handles.epoch)
    }

    private static func handles(_ record: MCPVoiceTranscriptionReviewRequestStore.Record) throws -> (id: UUID, epoch: UUID) {
        guard let id = UUID(uuidString: record.requestID), let epoch = UUID(uuidString: record.requestEpoch) else {
            throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidStorage
        }
        return (id, epoch)
    }
}

@MainActor @Observable
final class AutomationTranscriptionReviewModel {
    private(set) var requests: [MCPVoiceTranscriptionReviewRequestStore.Record] = []
    private(set) var selectedRequest: MCPVoiceTranscriptionReviewRequestStore.Record?
    private(set) var review: AutomationTranscriptionReview?
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var capacity: MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot?
    private(set) var capacityMessage: String?
    private(set) var isInspectingCapacity = false
    private(set) var isRecoveringCapacity = false
    private(set) var isRefreshingEvidence = false
    var isBusyWithCapacity: Bool { isInspectingCapacity || isRecoveringCapacity }
    var canRecoverCancelledCapacity: Bool {
        !isBusyWithCapacity && !isCancelling && (capacity?.cancelledBeforeAdmissionCount ?? 0) > 0
    }
    private let service: any AutomationTranscriptionReviewServing
    private(set) var isCancelling = false
    private var inspectingRequest: MCPVoiceTranscriptionReviewRequestStore.Record?
    private var evidenceGeneration = UUID()
    private var evidenceTask: Task<Void, Never>?
    private var capacityGeneration = UUID()
    private var capacityTask: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(service: any AutomationTranscriptionReviewServing = AutomationTranscriptionReviewService()) {
        self.service = service
    }

    /// A reload invalidates a prior source snapshot even when the durable list fails.
    /// Last recorded request statuses remain visible and are explicitly marked stale.
    func refresh() {
        guard !isRecoveringCapacity, !isCancelling else { return }
        begin()
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let requests = try await service.requests()
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.requests = requests
                self.finish()
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = "Transcription requests could not be refreshed. Displayed request statuses may be out of date. Refresh before reviewing or cancelling."
                self.finish()
            }
        }
    }

    func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) {
        guard !isRecoveringCapacity, !isCancelling, requests.contains(request), request.state == .awaitingReview, message == nil else { return }
        begin()
        inspectingRequest = request
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let review = try await service.inspect(request)
                guard review.planID == request.planID else {
                    throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
                }
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.selectedRequest = request; self.review = review
                self.finish()
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = "This transcription intent cannot be reviewed. It may be cancelled, expired or changed. Refresh requests and prepare a new preview if needed. No consent was granted."
                self.finish()
            }
        }
    }

    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) {
        guard !isRecoveringCapacity, !isCancelling, requests.contains(request), request.state == .awaitingReview, message == nil else { return }
        invalidateCapacity()
        begin()
        isCancelling = true
        let expected = generation
        task = Task { [weak self, service] in
            var cancellationFailed = false
            do { try await service.cancel(request) }
            catch { cancellationFailed = true }
            do {
                let requests = try await service.requests()
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.requests = requests
                if cancellationFailed {
                    self.message = "Cancellation could not be confirmed. Request statuses were refreshed; inspect the retained evidence before retrying."
                }
                self.finish()
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = "Cancellation and current request status could not be confirmed. Displayed request statuses may be out of date. Refresh before retrying."
                self.finish()
            }
        }
    }

    /// Polling preserves an exact selected review only while its retained record
    /// remains unchanged. A helper cancellation or read failure invalidates selection.
    func refreshRequestEvidence() {
        guard !isRecoveringCapacity, !isCancelling, !isRefreshingEvidence,
              !isLoading || inspectingRequest != nil else { return }
        isRefreshingEvidence = true
        let expected = evidenceGeneration
        evidenceTask = Task { [weak self, service] in
            do {
                let records = try await service.requests()
                guard let self, self.evidenceGeneration == expected, !Task.isCancelled else { return }
                self.requests = records
                if let selected = self.selectedRequest ?? self.inspectingRequest,
                   !records.contains(selected) || selected.state != .awaitingReview {
                    self.invalidateReview()
                }
                // Status polling cannot revalidate a rejected source preview or clear
                // its refusal. Explicit refresh owns retrying that review boundary.
                self.isRefreshingEvidence = false; self.evidenceTask = nil
            } catch {
                guard let self, self.evidenceGeneration == expected, !Task.isCancelled else { return }
                self.invalidateReview()
                self.message = "Transcription requests could not be refreshed. Displayed request statuses may be out of date. Refresh before reviewing or cancelling."
                self.isRefreshingEvidence = false; self.evidenceTask = nil
            }
        }
    }

    func inspectRequestCapacity() {
        guard !isBusyWithCapacity, !isCancelling else { return }
        capacity = nil; capacityMessage = nil; isInspectingCapacity = true
        let expected = capacityGeneration
        capacityTask = Task { [weak self, service] in
            do {
                let snapshot = try await service.requestCapacity()
                guard let self, self.capacityGeneration == expected, !Task.isCancelled else { return }
                self.capacity = snapshot
                self.isInspectingCapacity = false; self.capacityTask = nil
            } catch {
                guard let self, self.capacityGeneration == expected, !Task.isCancelled else { return }
                self.capacityMessage = "Transcription request capacity could not be inspected. " + error.localizedDescription
                self.isInspectingCapacity = false; self.capacityTask = nil
            }
        }
    }

    /// The epoch is captured when native confirmation opens and never rebound on
    /// acceptance. Clearing cancels concurrent polls, selection reads and capacity reads.
    func recoverCancelledCapacity(expectedEpoch: UUID) {
        guard canRecoverCancelledCapacity, let snapshot = capacity, snapshot.epoch == expectedEpoch else { return }
        clear()
        isRecoveringCapacity = true
        let expected = capacityGeneration
        capacityTask = Task { [weak self, service] in
            do {
                _ = try await service.recoverCancelledCapacity(expectedEpoch: expectedEpoch)
                guard let self, self.capacityGeneration == expected, !Task.isCancelled else { return }
                self.capacityMessage = "Removed transcription requests cancelled before admission. Removed requests cannot be retried. New intents need a new request ID and current epoch; retained requests keep their original epoch. No consent was granted."
                self.isRecoveringCapacity = false; self.capacityTask = nil
                self.refreshRequestEvidence()
                self.inspectRequestCapacityPreservingMessage()
            } catch {
                guard let self, self.capacityGeneration == expected, !Task.isCancelled else { return }
                self.capacityMessage = "Cleanup could not be confirmed. Review transcription request capacity again before retrying. " + error.localizedDescription
                self.isRecoveringCapacity = false; self.capacityTask = nil
                self.refreshRequestEvidence()
            }
        }
    }

    private func inspectRequestCapacityPreservingMessage() {
        let result = capacityMessage
        inspectRequestCapacity()
        capacityMessage = result
    }

    func clear() {
        invalidateReview()
        invalidateEvidence()
        invalidateCapacity()
    }

    private func invalidateReview() {
        generation = UUID(); task?.cancel(); task = nil
        selectedRequest = nil; inspectingRequest = nil; review = nil; isLoading = false; isCancelling = false; message = nil
    }
    private func invalidateEvidence() {
        evidenceGeneration = UUID(); evidenceTask?.cancel(); evidenceTask = nil; isRefreshingEvidence = false
    }
    private func invalidateCapacity() {
        capacityGeneration = UUID(); capacityTask?.cancel(); capacityTask = nil
        capacity = nil; capacityMessage = nil; isInspectingCapacity = false; isRecoveringCapacity = false
    }
    private func begin() { invalidateReview(); invalidateEvidence(); isLoading = true }
    private func finish() { isLoading = false; isCancelling = false; task = nil; inspectingRequest = nil }

    nonisolated static func status(_ record: MCPVoiceTranscriptionReviewRequestStore.Record) -> String {
        if record.cancellationRequestedAt != nil && (record.state == .admitted || record.state == .linked) {
            return "Cancellation requested after admission. Work is not confirmed stopped or completed. Admission and operation evidence remains retained; this request cannot be replayed or removed. Inspect retained operation history."
        }
        return switch record.state {
        case .awaitingReview: "Awaiting native intent review. Provider admission and execution are unavailable; no consent was granted."
        case .cancelled: "Cancelled before provider admission. No transcription was started by this request."
        case .admitted: "Admission evidence is retained, but an operation link is unconfirmed. Work is not confirmed stopped or completed. This request cannot be replayed or removed; inspect retained operation history."
        case .linked: "Operation linkage is retained. A link does not confirm execution, completion or success. This request cannot be replayed or removed; inspect retained operation history."
        }
    }
}
