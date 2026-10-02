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
    }

    func present(requestID: UUID, requestEpoch: UUID) {
        pendingReview = Review(requestID: requestID, requestEpoch: requestEpoch)
    }

    func consume(_ review: Review) {
        if pendingReview == review { pendingReview = nil }
    }
}
