import Foundation
import Observation

nonisolated protocol AutomationOperationHistoryServing: Sendable {
    func records() async throws -> [AutomationOperationRegistry.Record]
    func requestCancellation(_ id: UUID) async throws
    func removeFinished(_ id: UUID) async throws
}

/// File IO stays off the presentation actor. History never supplies mutation authority.
actor AutomationOperationHistoryService: AutomationOperationHistoryServing {
    nonisolated let filesystemQueue = DispatchSerialQueue(
        label: "com.aagedal.photo-agent.automation-operation-history", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { filesystemQueue.asUnownedSerialExecutor() }
    private let registry: AutomationOperationRegistry

    init(registry: AutomationOperationRegistry) { self.registry = registry }

    func records() throws -> [AutomationOperationRegistry.Record] {
        guard try !registry.records().isEmpty else { return [] }
        _ = try registry.reconcileAbandonedOwners()
        return try registry.records().sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func requestCancellation(_ id: UUID) throws { _ = try registry.requestCancellation(id) }

    func removeFinished(_ id: UUID) throws {
        let record = try registry.inspect(id)
        guard Self.canRemove(record) else { throw AutomationOperationRegistry.Failure.invalidTransition }
        try registry.removeTerminal(id, ownerID: record.ownerID)
    }

    nonisolated static func canRemove(_ record: AutomationOperationRegistry.Record) -> Bool {
        record.isTerminal && [.verified, .failed, .cancelled, .stale].contains(record.outcome)
    }
}

@MainActor @Observable
final class AutomationOperationHistoryModel {
    private(set) var records: [AutomationOperationRegistry.Record] = []
    private(set) var isLoading = false
    private(set) var message: String?
    private let service: any AutomationOperationHistoryServing

    init(service: any AutomationOperationHistoryServing) { self.service = service }

    func refresh() async {
        await perform { try await self.service.records() }
    }

    func requestCancellation(_ id: UUID) async {
        await perform {
            try await self.service.requestCancellation(id)
            return try await self.service.records()
        }
    }

    func removeFinished(_ id: UUID) async {
        await perform {
            try await self.service.removeFinished(id)
            return try await self.service.records()
        }
    }

    private func perform(_ operation: () async throws -> [AutomationOperationRegistry.Record]) async {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do { records = try await operation() }
        catch {
            // Keep the last observed records visible, explicitly marked as stale.
            message = "Operation history could not be refreshed. Displayed records may be out of date. Try Refresh again before taking further action."
        }
    }
}
