import Foundation
import Observation

/// Presentation of an exact revalidated helper intent. Paths stay plain text.
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
/// request, including its original epoch. Execution requires a separate native binding and consent.
nonisolated protocol AutomationTranscriptionReviewServing: Sendable {
    func requests() async throws -> [MCPVoiceTranscriptionReviewRequestStore.Record]
    func requestCapacity() async throws -> MCPVoiceTranscriptionReviewRequestStore.CapacitySnapshot
    func recoverCancelledCapacity(expectedEpoch: UUID) async throws -> UUID
    func inspect(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws -> AutomationTranscriptionReview
    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws
    func prepareExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record,
        provider: AutomationVoiceTranscriptionBatchService.Provider,
        whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind?) async throws -> MCPNativeVoiceTranscriptionBindingService.PreparedBinding
    func submit(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding, nativeConsent: Bool) async throws -> AutomationOperationRegistry.Record
    func inspectOperation(_ id: UUID) async throws -> AutomationOperationRegistry.Record
    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record
    func cancelExecution(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) async throws
    func cancelRetainedExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws
}

// Alternate services must explicitly support native maintenance; no helper fallback exists.
extension AutomationTranscriptionReviewServing {
    func cancelRetainedExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws {
        throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
    }
    func prepareExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record,
        provider: AutomationVoiceTranscriptionBatchService.Provider,
        whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind?) async throws -> MCPNativeVoiceTranscriptionBindingService.PreparedBinding {
        throw MCPNativeVoiceTranscriptionBindingService.Failure.providerUnavailable
    }
    func submit(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding, nativeConsent: Bool) async throws -> AutomationOperationRegistry.Record {
        throw MCPNativeVoiceTranscriptionBindingService.Failure.providerUnavailable
    }
    func inspectOperation(_ id: UUID) async throws -> AutomationOperationRegistry.Record { throw AutomationOperationRegistry.Failure.unknownOperation }
    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record { throw AutomationOperationRegistry.Failure.unknownOperation }
    func cancelExecution(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) async throws {
        throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
    }

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
    private var bindingService: MCPNativeVoiceTranscriptionBindingService?
    private var operationRegistry: AutomationOperationRegistry?

    init(plans: MCPVoiceTranscriptionPlanStore? = nil, facade: MCPAutomationFacade = .init(),
         requests: MCPVoiceTranscriptionReviewRequestStore? = nil,
         inspectionTime: @escaping @Sendable () -> Date = { Date() },
         bindingService: MCPNativeVoiceTranscriptionBindingService? = nil,
         operationRegistry: AutomationOperationRegistry? = nil) {
        self.plans = plans ?? .init(storageDirectory: MCPVoiceTranscriptionPlanStore.defaultStorageDirectory())
        self.facade = facade; retainedRequests = requests; self.inspectionTime = inspectionTime
        self.bindingService = bindingService; self.operationRegistry = operationRegistry
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

    private func executor() throws -> MCPNativeVoiceTranscriptionBindingService {
        if let bindingService { return bindingService }
        let registry = AutomationOperationRegistry(storageDirectory: try AutomationOperationRegistry.defaultStorageDirectory())
        let batches = AutomationVoiceTranscriptionBatchService(registry: registry)
        let binding = MCPNativeVoiceTranscriptionBindingService(requests: try requestStore(), plans: plans,
            facade: facade, batches: batches, readiness: MCPNativeVoiceTranscriptionBindingService.liveReadiness,
            now: inspectionTime)
        operationRegistry = registry; bindingService = binding
        return binding
    }

    func prepareExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record,
        provider: AutomationVoiceTranscriptionBatchService.Provider,
        whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind?) async throws -> MCPNativeVoiceTranscriptionBindingService.PreparedBinding {
        _ = try inspect(request)
        let handles = try Self.handles(request)
        let prepared = try await executor().prepare(requestID: handles.id, requestEpoch: handles.epoch,
            provider: provider, whisperKind: whisperKind)
        guard prepared.request == request else { throw MCPNativeVoiceTranscriptionBindingService.Failure.requestChanged }
        return prepared
    }
    func submit(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding, nativeConsent: Bool) async throws -> AutomationOperationRegistry.Record {
        try await executor().submit(prepared: prepared, nativeConsent: nativeConsent)
    }
    func inspectOperation(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        guard let operationRegistry else { throw AutomationOperationRegistry.Failure.unknownOperation }
        return try operationRegistry.inspect(id)
    }
    func waitForCompletion(_ id: UUID) async throws -> AutomationOperationRegistry.Record {
        try await executor().waitForCompletion(id)
    }
    func cancelExecution(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) async throws {
        try saveCancellation(prepared.request)
    }
    func cancelRetainedExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) async throws {
        let authorization = try facade.authorizationStore.load()
        guard authorization.isEnabled else { throw MCPAuthorizationError.disabled }
        let handles = try Self.handles(request)
        guard request.state == .admitted || request.state == .linked,
              try requestStore().inspect(handles.id, requestEpoch: handles.epoch) == request,
              try facade.authorizationStore.load() == authorization else {
            throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
        }
        _ = try executor()
        try saveCancellation(request)
    }
    private func saveCancellation(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) throws {
        let handles = try Self.handles(request)
        let cancelled = try requestStore().cancel(handles.id, requestEpoch: handles.epoch)
        guard let id = cancelled.operationID.flatMap(UUID.init(uuidString:)), let operationRegistry else { return }
        let current = try operationRegistry.inspect(id)
        if !current.isTerminal { _ = try operationRegistry.requestCancellation(id) }
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
        !isBusyWithCapacity && !isCancelling && !isRunning && (capacity?.cancelledBeforeAdmissionCount ?? 0) > 0
    }
    private let service: any AutomationTranscriptionReviewServing
    private(set) var executionReview: MCPNativeVoiceTranscriptionBindingService.PreparedBinding?
    var executionConsent = false
    private(set) var isPreparingExecution = false
    private(set) var isRunning = false
    private(set) var isRequestingCancellation = false
    private(set) var operation: AutomationOperationRegistry.Record?
    private(set) var executionMessage: String?
    private var executionGeneration = UUID()
    private var preparationTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var activeBinding: MCPNativeVoiceTranscriptionBindingService.PreparedBinding?
    private var cancellationRequested = false
    private let beginExecution: @MainActor () -> Bool
    private let endExecution: @MainActor () -> Void
    private(set) var isCancelling = false
    private var inspectingRequest: MCPVoiceTranscriptionReviewRequestStore.Record?
    private var evidenceGeneration = UUID()
    private var evidenceTask: Task<Void, Never>?
    private var capacityGeneration = UUID()
    private var capacityTask: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(service: any AutomationTranscriptionReviewServing = AutomationTranscriptionReviewService(),
         beginExecution: @escaping @MainActor () -> Bool = { FFmpegWhisperSetupModel.shared.beginTranscription() },
         endExecution: @escaping @MainActor () -> Void = { FFmpegWhisperSetupModel.shared.finishTranscription() }) {
        self.service = service; self.beginExecution = beginExecution; self.endExecution = endExecution
    }

    func prepareExecution(provider: AutomationVoiceTranscriptionBatchService.Provider?,
                          whisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind?) {
        guard !isRunning, !isCancelling, !isRecoveringCapacity, let selectedRequest, review != nil, message == nil else { return }
        invalidateExecutionReview()
        guard let provider else {
            executionMessage = "The selected Settings provider is not ready. Complete its setup in Transcription Settings, then review again. No consent was granted."
            return
        }
        isPreparingExecution = true
        let expected = executionGeneration
        preparationTask = Task { [weak self, service] in
            do {
                let prepared = try await service.prepareExecution(selectedRequest, provider: provider, whisperKind: whisperKind)
                guard prepared.request == selectedRequest else { throw MCPNativeVoiceTranscriptionBindingService.Failure.requestChanged }
                guard let self, self.executionGeneration == expected, self.selectedRequest == selectedRequest, !Task.isCancelled else { return }
                self.executionReview = prepared
                self.isPreparingExecution = false; self.preparationTask = nil
            } catch {
                guard let self, self.executionGeneration == expected, !Task.isCancelled else { return }
                self.executionMessage = "Provider review was refused. The current Settings provider, language and options must exactly match this intent and be ready. Photos, authorization or existing reviews may also have changed. No consent was granted. " + error.localizedDescription
                self.isPreparingExecution = false; self.preparationTask = nil
            }
        }
    }

    /// Owns a retained task: dismissing Settings invalidates only unconfirmed review.
    func confirmExecution() {
        guard executionConsent, !isRunning, !isPreparingExecution, !isRefreshingEvidence,
              message == nil, let prepared = executionReview, selectedRequest == prepared.request else { return }
        guard beginExecution() else {
            executionMessage = "Finish the current transcription before starting this request."
            return
        }
        invalidateExecutionReview()
        invalidateEvidence()
        activeBinding = prepared; operation = nil; executionMessage = nil
        cancellationRequested = false; isRequestingCancellation = false; isRunning = true
        executionTask = Task { [self, service] in
            do {
                if cancellationRequested {
                    try await service.cancelExecution(prepared)
                    finishExecution(); return
                }
                let record = try await service.submit(prepared, nativeConsent: true)
                operation = record
                if cancellationRequested { await saveExecutionCancellation(prepared) }
                let polling = Task { [self, service] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: .milliseconds(200))
                            let current = try await service.inspectOperation(record.id)
                            guard !Task.isCancelled else { return }
                            operation = current
                        } catch is CancellationError { return }
                        catch { /* Only the retained owner wait proves teardown. */ }
                    }
                }
                while true {
                    do {
                        let terminal = try await service.waitForCompletion(record.id)
                        guard terminal.isTerminal else { throw AutomationOperationRegistry.Failure.invalidTransition }
                        polling.cancel(); await polling.value
                        operation = terminal
                        executionMessage = "Transcription finished: \(terminal.outcome?.rawValue ?? "unknown"). Review saved transcript drafts in Caption; photo metadata requires separate approval."
                        finishExecution(); refreshRequestEvidence(); return
                    } catch {
                        executionMessage = "Transcription status could not be confirmed. Waiting for the provider to stop safely. " + error.localizedDescription
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            } catch {
                executionMessage = "Transcription admission could not be confirmed. Inspect retained request and operation evidence before preparing new work. " + error.localizedDescription
                finishExecution(); refreshRequestEvidence()
            }
        }
    }

    func requestExecutionCancellation() {
        guard isRunning, !isRequestingCancellation, let activeBinding else { return }
        cancellationRequested = true; isRequestingCancellation = true
        Task { [self] in await saveExecutionCancellation(activeBinding) }
    }
    private func saveExecutionCancellation(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) async {
        do { try await service.cancelExecution(prepared) }
        catch {
            isRequestingCancellation = false
            executionMessage = "Cancellation could not be saved. Work is not confirmed stopped. " + error.localizedDescription
        }
    }
    private func finishExecution() {
        isRunning = false; isRequestingCancellation = false; executionTask = nil; activeBinding = nil
        endExecution()
    }
    func invalidateExecutionReview() {
        executionGeneration = UUID(); preparationTask?.cancel(); preparationTask = nil
        executionReview = nil; executionConsent = false; isPreparingExecution = false
        if !isRunning { executionMessage = nil }
    }

    /// A reload invalidates a prior source snapshot even when the durable list fails.
    /// Last recorded request statuses remain visible and are explicitly marked stale.
    func refresh() {
        guard !isRecoveringCapacity, !isCancelling, !isRunning else { return }
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
        guard !isRecoveringCapacity, !isCancelling, !isRunning, requests.contains(request), request.state == .awaitingReview, message == nil else { return }
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

    /// An authenticated helper may request native presentation, never consent.
    /// Reload and inspect the exact original epoch again after the UI handoff;
    /// expired, changed or retired intent cannot become a selected review.
    func inspectInvocation(requestID: UUID, requestEpoch: UUID) {
        guard !isRecoveringCapacity, !isCancelling, !isRunning else { return }
        begin()
        let expected = generation
        task = Task { [weak self, service] in
            do {
                let records = try await service.requests()
                guard let request = records.first(where: {
                    $0.requestID == requestID.uuidString.lowercased()
                        && $0.requestEpoch == requestEpoch.uuidString.lowercased()
                }), request.state == .awaitingReview else {
                    throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
                }
                let review = try await service.inspect(request)
                guard review.planID == request.planID else {
                    throw MCPVoiceTranscriptionReviewRequestStore.Failure.invalidTransition
                }
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.requests = records
                self.selectedRequest = request
                self.review = review
                self.finish()
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.message = "The requested transcription intent cannot be reviewed. It may be cancelled, expired or changed. No consent was granted."
                self.finish()
            }
        }
    }

    func cancel(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) {
        guard !isRecoveringCapacity, !isCancelling, !isRunning, requests.contains(request), request.state == .awaitingReview, message == nil else { return }
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

    func cancelRetainedExecution(_ request: MCPVoiceTranscriptionReviewRequestStore.Record) {
        guard !isRunning, !isCancelling, !isRecoveringCapacity, message == nil,
              requests.contains(request), request.state == .admitted || request.state == .linked else { return }
        begin(); isCancelling = true
        let expected = generation
        task = Task { [weak self, service] in
            var failure: Error?
            do { try await service.cancelRetainedExecution(request) } catch { failure = error }
            do {
                let records = try await service.requests()
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.requests = records
                if let failure { self.message = "Cancellation could not be confirmed. Retained evidence remains available. " + failure.localizedDescription }
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
                    self.invalidateReview(clearingExecutionMessage: false)
                }
                // Status polling cannot revalidate a rejected source preview or clear
                // its refusal. Explicit refresh owns retrying that review boundary.
                self.isRefreshingEvidence = false; self.evidenceTask = nil
            } catch {
                guard let self, self.evidenceGeneration == expected, !Task.isCancelled else { return }
                self.invalidateReview(clearingExecutionMessage: false)
                self.message = "Transcription requests could not be refreshed. Displayed request statuses may be out of date. Refresh before reviewing or cancelling."
                self.isRefreshingEvidence = false; self.evidenceTask = nil
            }
        }
    }

    func inspectRequestCapacity() {
        guard !isBusyWithCapacity, !isCancelling, !isRunning else { return }
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

    private func invalidateReview(clearingExecutionMessage: Bool = true) {
        let retainedMessage = executionMessage
        invalidateExecutionReview()
        if !clearingExecutionMessage { executionMessage = retainedMessage }
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
        case .awaitingReview: "Awaiting native intent and provider review. Explicit native consent is required before transcription can start."
        case .cancelled: "Cancelled before provider admission. No transcription was started by this request."
        case .admitted: "Admission evidence is retained, but an operation link is unconfirmed. Work is not confirmed stopped or completed. This request cannot be replayed or removed; inspect retained operation history."
        case .linked: "Operation linkage is retained. A link does not confirm execution, completion or success. This request cannot be replayed or removed; inspect retained operation history."
        }
    }
}
