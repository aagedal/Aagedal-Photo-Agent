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
    func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview
    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws
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
    private let service: any AutomationTranscriptionReviewServing
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(service: any AutomationTranscriptionReviewServing = AutomationTranscriptionReviewService()) {
        self.service = service
    }

    /// A reload invalidates a prior source snapshot even when the durable list fails.
    /// Last recorded request statuses remain visible and are explicitly marked stale.
    func refresh() {
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
        guard requests.contains(request), request.state == .awaitingReview, message == nil else { return }
        begin()
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
        guard requests.contains(request), request.state == .awaitingReview, message == nil else { return }
        begin()
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

    func clear() {
        generation = UUID(); task?.cancel(); task = nil
        selectedRequest = nil; review = nil; isLoading = false; message = nil
    }

    private func begin() { clear(); isLoading = true }
    private func finish() { isLoading = false; task = nil }

    nonisolated static func status(_ record: MCPVoiceTranscriptionReviewRequestStore.Record) -> String {
        switch record.state {
        case .awaitingReview: "Awaiting native intent review. Provider admission and execution are unavailable; no consent was granted."
        case .cancelled: "Cancelled before provider admission. No transcription was started by this request."
        }
    }
}
