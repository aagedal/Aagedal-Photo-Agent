import AppKit
import Foundation
import Observation

/// Owns authenticated presentation and exact one-use native grant consumption.
/// No serializable helper value can approve a provider. Existing rooted native
/// admission rechecks the complete request after consumption.
@MainActor @Observable
final class AutomationNativeInvocationController {
    static let shared = AutomationNativeInvocationController()

    struct Review: Equatable, Sendable {
        let id = UUID()
        let requestID: UUID
        let requestEpoch: UUID
    }

    private(set) var pendingReview: Review?
    private(set) var isAvailable = false
    private(set) var isChecking = false
    private var listener: AutomationNativeInvocationChannel.Listener?
    private var generation = UUID()
    private var startup: Task<Void, Never>?
    @ObservationIgnored private weak var executionModel: AutomationTranscriptionReviewModel?

    func registerExecutionModel(_ model: AutomationTranscriptionReviewModel) { executionModel = model }
    func unregisterExecutionModel(_ model: AutomationTranscriptionReviewModel) {
        if executionModel === model { executionModel = nil }
    }

    /// A bounded utility-to-main-actor handoff. Timeout retires queued work before
    /// returning; a delayed UI task cannot consume consent after the caller leaves.
    nonisolated final class ExecutionHandoff: @unchecked Sendable {
        private let condition = NSCondition()
        private var retired = false
        private var result: Bool?
        func resolve(_ consume: () -> Bool) {
            condition.lock(); defer { condition.unlock() }
            guard !retired else { return }
            result = consume(); retired = true; condition.signal()
        }
        func wait(timeout: TimeInterval = 1) -> Bool {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !retired {
                if !condition.wait(until: deadline) { retired = true }
            }
            return result ?? false
        }
    }

    func start() {
        let fixture = UITestNativeInvocationConfiguration.current
        guard listener == nil, !isChecking,
              !UITestLaunchConfiguration.current.isEnabled || fixture != nil else { return }
        isChecking = true
        let expected = UUID(); generation = expected
        startup = Task { [weak self] in
            let candidate = await Task.detached(priority: .utility) {
                var stage = "fixtureInitialization"
                do {
                    if fixture != nil { try await UITestTranscriptionReviewFixture.initializeForNativeInvocation() }
                    stage = "authorization"
                    let facade = fixture?.facade ?? MCPAutomationFacade()
                    guard try facade.authorizationStore.load().isEnabled else { return nil as AutomationNativeInvocationChannel.Listener? }
                    let service = AutomationNativeTranscriptionReviewInvocationService(
                        requests: try fixture?.requests ?? .init(storageDirectory: MCPVoiceTranscriptionReviewRequestStore.defaultStorageDirectory()),
                        plans: fixture?.plans ?? .init(storageDirectory: MCPVoiceTranscriptionPlanStore.defaultStorageDirectory()),
                        facade: facade,
                        registry: try fixture?.registry ?? .init(storageDirectory: AutomationOperationRegistry.defaultStorageDirectory()))
                    let candidate = try AutomationNativeInvocationChannel.Listener(
                        directory: fixture?.socketDirectory ?? AutomationNativeInvocationChannel.defaultDirectory) { request in
                        switch try service.invoke(requestID: request.requestID, requestEpoch: request.requestEpoch) {
                        case .review(let retained):
                            if request.kind == .start {
                                let handoff = ExecutionHandoff()
                                Task { @MainActor in
                                    handoff.resolve {
                                        let controller = AutomationNativeInvocationController.shared
                                        guard controller.generation == expected else { return false }
                                        return controller.executionModel?.consumeHelperExecutionGrant(retained) ?? false
                                    }
                                }
                                guard handoff.wait() else { return try .init(status: .unavailable) }
                                // Scheduling after exact native consent consumption
                                // is not durable admission or provider completion.
                                return try .init(status: .executionRequested)
                            }
                            Task { @MainActor in
                                let controller = AutomationNativeInvocationController.shared
                                guard controller.generation == expected else { return }
                                controller.present(requestID: request.requestID, requestEpoch: request.requestEpoch)
                            }
                            return try .init(status: .reviewRequired)
                        case .linked(let operationID):
                            return try .init(status: .linkedOperation, operationID: operationID)
                        }
                    }
                    stage = "listenerStartup"
                    try candidate.start()
                    return candidate
                } catch {
                    if let fixture {
                        try? JSONSerialization.data(withJSONObject: ["stage": stage, "error": String(reflecting: error)]).write(
                            to: fixture.rootURL.appendingPathComponent("transcription-helper-listener-failure.json"), options: .atomic)
                    }
                    return nil
                }
            }.value
            guard let self, self.generation == expected, !Task.isCancelled else {
                candidate?.stop()
                return
            }
            self.listener = candidate
            self.isAvailable = candidate != nil
            self.isChecking = false
            self.startup = nil
            if let fixture {
                let available = self.isAvailable
                await Task.detached(priority: .utility) {
                    try? JSONSerialization.data(withJSONObject: ["available": available]).write(
                        to: fixture.rootURL.appendingPathComponent("transcription-helper-listener-ready.json"), options: .atomic)
                }.value
            }
        }
    }

    func stop() {
        generation = UUID()
        startup?.cancel(); startup = nil
        listener?.stop(); listener = nil
        pendingReview = nil; isAvailable = false; isChecking = false
        executionModel?.invalidateExecutionReview()
        executionModel = nil
    }

    func present(requestID: UUID, requestEpoch: UUID) {
        pendingReview = Review(requestID: requestID, requestEpoch: requestEpoch)
    }

    func consume(_ review: Review) {
        if pendingReview == review { pendingReview = nil }
    }
}
