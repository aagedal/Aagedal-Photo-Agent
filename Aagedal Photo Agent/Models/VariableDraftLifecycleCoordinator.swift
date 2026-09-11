import Foundation

/// A variable request can own the only copy of an unsaved template while its first JSON write
/// is pending. Keep that owner alive, and let the existing Close/Quit flow stop safely.
@MainActor
final class VariableDraftLifecycleCoordinator {
    static let shared = VariableDraftLifecycleCoordinator()
    private var owners: [UUID: @MainActor () throws -> Void] = [:]
    var hasPendingWork: Bool { !owners.isEmpty }

    func register(ownerID: UUID, requirePersisted: @escaping @MainActor () throws -> Void) {
        owners[ownerID] = requirePersisted
    }
    func unregister(ownerID: UUID) { owners.removeValue(forKey: ownerID) }
    func requirePersisted() throws {
        for check in Array(owners.values) { try check() }
    }
}
