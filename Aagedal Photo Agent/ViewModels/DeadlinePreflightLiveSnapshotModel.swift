import Foundation
import Observation

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

    @ObservationIgnored private let coordinator: DeadlinePreflightLiveSnapshotCoordinator

    init(coordinator: DeadlinePreflightLiveSnapshotCoordinator? = nil) {
        self.coordinator = coordinator ?? DeadlinePreflightLiveSnapshotCoordinator()
    }

    func refresh(_ request: DeadlinePreflightLiveCaptureRequest) async {
        workspaceInput = nil
        if let input = await coordinator.latest(request) {
            workspaceInput = input
        }
    }

    func clear() async {
        workspaceInput = nil
        await coordinator.cancel()
    }
}
