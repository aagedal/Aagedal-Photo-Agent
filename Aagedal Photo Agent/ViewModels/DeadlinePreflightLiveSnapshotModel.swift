import Foundation
import Observation

/// The only persisted preferences consumed while composing a live Deadline request. Keeping this
/// value typed lets the scheduling boundary compare effective Deadline inputs after the broad
/// `UserDefaults.didChangeNotification` without treating unrelated settings as capture changes.
nonisolated struct DeadlineValidationPreferenceSnapshot: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        let field: String
        let value: String
    }

    let requirementLevels: [Entry]
    let minimumLengths: [Entry]

    init(defaults: UserDefaults) {
        requirementLevels = MetadataRequirements.load(from: defaults)
            .map { Entry(field: $0.key.rawValue, value: $0.value.rawValue) }
            .sorted { $0.field < $1.field }
        minimumLengths = MetadataRequirements.loadMinimumLengths(from: defaults)
            .map { Entry(field: $0.key.rawValue, value: String($0.value)) }
            .sorted { $0.field < $1.field }
    }
}

/// Value-only identity owned by Deadline capture. Each member names one input family used by
/// `DeadlinePreflightLiveCaptureRequest`; no general application-preferences generation appears
/// here.
nonisolated struct DeadlineLiveCaptureRevision: Hashable, Sendable {
    let selectionSource: UInt64
    let metadata: UInt64
    let profile: UInt64
    let renameResources: UInt64
    let templateResources: UInt64
    let exportConfiguration: UInt64
    let developSettings: UInt64
    let connectionInventory: UInt64
    let requiredLists: Int
    let renameDirectory: String?
    let validationPreferences: DeadlineValidationPreferenceSnapshot
}

/// Serializes asynchronous live-fact capture and only publishes the newest request. Filesystem
/// probes execute in a detached task so SwiftUI body evaluation and the main actor remain free of
/// directory scans, image decoding, capacity queries, and write probes.
actor DeadlinePreflightLiveSnapshotCoordinator {
    typealias Capture = @Sendable (DeadlinePreflightLiveCaptureRequest) async throws -> DeadlineWorkspaceInput

    private let capture: Capture
    private var generation: UInt64 = 0
    private var activeTask: Task<DeadlineWorkspaceInput, Error>?

    init(
        adapter: DeadlinePreflightLiveSnapshotAdapter = DeadlinePreflightLiveSnapshotAdapter()
    ) {
        capture = { request in try await adapter.capture(request) }
    }

    init(capture: @escaping Capture) {
        self.capture = capture
    }

    func latest(_ request: DeadlinePreflightLiveCaptureRequest) async -> DeadlineWorkspaceInput? {
        generation &+= 1
        let requestedGeneration = generation
        activeTask?.cancel()
        let operation = capture
        // Keep the actual detached task so replacement cancellation reaches every
        // `Task.checkCancellation()` in filesystem/image capture.
        let task = Task.detached(priority: .userInitiated) { try await operation(request) }
        activeTask = task
        let result = await task.result
        guard requestedGeneration == generation else { return nil }
        activeTask = nil
        guard case let .success(input) = result else { return nil }
        return input
    }

    func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
    }
}

@MainActor
@Observable
final class DeadlinePreflightLiveSnapshotModel {
    private(set) var workspaceInput: DeadlineWorkspaceInput?
    private(set) var validationPreferences: DeadlineValidationPreferenceSnapshot

    @ObservationIgnored private let coordinator: DeadlinePreflightLiveSnapshotCoordinator
    @ObservationIgnored private let captureDebounce: Duration

    init(
        coordinator: DeadlinePreflightLiveSnapshotCoordinator? = nil,
        captureDebounce: Duration = .milliseconds(150),
        defaults: UserDefaults = AppDefaults.store
    ) {
        self.coordinator = coordinator ?? DeadlinePreflightLiveSnapshotCoordinator()
        self.captureDebounce = captureDebounce
        validationPreferences = DeadlineValidationPreferenceSnapshot(defaults: defaults)
    }

    func refresh(_ request: DeadlinePreflightLiveCaptureRequest) async {
        do {
            try await Task.sleep(for: captureDebounce)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        workspaceInput = nil
        if let input = await coordinator.latest(request) {
            workspaceInput = input
        }
    }

    /// Returns true only when a preference that contributes to Deadline validation changed.
    @discardableResult
    func refreshValidationPreferences(from defaults: UserDefaults = AppDefaults.store) -> Bool {
        let current = DeadlineValidationPreferenceSnapshot(defaults: defaults)
        guard current != validationPreferences else { return false }
        validationPreferences = current
        return true
    }

    func clear() async {
        workspaceInput = nil
        await coordinator.cancel()
    }
}
