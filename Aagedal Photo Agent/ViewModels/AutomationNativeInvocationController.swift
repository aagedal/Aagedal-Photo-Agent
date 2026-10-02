import AppKit
import Foundation
import Observation

/// Owns presentation only. No serializable helper value can approve a provider or
/// start transcription. The existing native model re-inspects each UI handoff.
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

    func start() {
        guard listener == nil, !isChecking, !UITestLaunchConfiguration.current.isEnabled else { return }
        isChecking = true
        let expected = UUID(); generation = expected
        startup = Task { [weak self] in
            let candidate = await Task.detached(priority: .utility) {
                do {
                    let facade = MCPAutomationFacade()
                    guard try facade.authorizationStore.load().isEnabled else { return nil as AutomationNativeInvocationChannel.Listener? }
                    let service = AutomationNativeTranscriptionReviewInvocationService(
                        requests: .init(storageDirectory: try MCPVoiceTranscriptionReviewRequestStore.defaultStorageDirectory()),
                        plans: .init(storageDirectory: MCPVoiceTranscriptionPlanStore.defaultStorageDirectory()),
                        facade: facade,
                        registry: .init(storageDirectory: try AutomationOperationRegistry.defaultStorageDirectory()))
                    let candidate = try AutomationNativeInvocationChannel.Listener { request in
                        switch try service.invoke(requestID: request.requestID, requestEpoch: request.requestEpoch) {
                        case .review:
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
                    try candidate.start()
                    return candidate
                } catch { return nil }
            }.value
            guard let self, self.generation == expected, !Task.isCancelled else {
                candidate?.stop()
                return
            }
            self.listener = candidate
            self.isAvailable = candidate != nil
            self.isChecking = false
            self.startup = nil
        }
    }

    func stop() {
        generation = UUID()
        startup?.cancel(); startup = nil
        listener?.stop(); listener = nil
        pendingReview = nil; isAvailable = false; isChecking = false
    }

    func present(requestID: UUID, requestEpoch: UUID) {
        pendingReview = Review(requestID: requestID, requestEpoch: requestEpoch)
    }

    func consume(_ review: Review) {
        if pendingReview == review { pendingReview = nil }
    }
}
