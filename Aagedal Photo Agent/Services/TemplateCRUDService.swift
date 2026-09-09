import Foundation

nonisolated struct TemplateInventorySnapshot<Value: Sendable>: Sendable {
    let requestID: UUID
    let templates: [Value]
}

nonisolated enum TemplateInventoryOperationResult<Value: Sendable>: Sendable {
    case loaded(TemplateInventorySnapshot<Value>)
    case cancelledBeforeRead(requestID: UUID)
    case cancelledAfterRead(requestID: UUID, templateCount: Int)
}

nonisolated struct TemplateMutationCommit<Value: Sendable>: Sendable {
    let requestID: UUID
    let requestedTemplate: Value?
    let requestedTemplateCommitted: Bool
    let durableTemplateIDs: [UUID]
    let refreshedTemplates: [Value]
    let inventoryRefreshFailureReason: String?
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum TemplateMutationOperationResult<Value: Sendable>: Sendable {
    case committed(TemplateMutationCommit<Value>)
    case cancelledBeforeCommit(requestID: UUID)
}

nonisolated struct TemplateMutationError<Value: Sendable>: LocalizedError, Sendable {
    let requestID: UUID
    let reason: String
    let durableTemplateIDs: [UUID]
    let refreshedTemplates: [Value]

    var errorDescription: String? { reason }
}

nonisolated struct TemplateExportCommit: Sendable {
    let requestID: UUID
    let destinationURL: URL
    let exportedTemplateCount: Int
    let cancellationObservedAfterCommit: Bool
}

nonisolated enum TemplateExportOperationResult: Sendable {
    case exported(TemplateExportCommit)
    case cancelledBeforeCommit(requestID: UUID, destinationURL: URL)
}

nonisolated struct TemplateCRUDAccess<Value: Identifiable & Sendable>: Sendable where Value.ID == UUID {
    let loadAll: @Sendable () throws -> [Value]
    let save: @Sendable (Value) throws -> Void
    let delete: @Sendable (Value) throws -> Void
    let exportAll: @Sendable (URL) throws -> Int
    let shortcutSlot: @Sendable (Value) -> Int?
    let clearingShortcutSlot: @Sendable (Value) -> Value
    let sorted: @Sendable ([Value]) -> [Value]
    var prepareTransaction: (@Sendable () -> TemplateStorageScope<Self>)? = nil
}

nonisolated extension TemplateCRUDAccess where Value == MetadataTemplate {
    static func storage(_ storage: TemplateStorageService, prepareTransaction: Bool = true) -> Self {
        var access = Self(
            loadAll: { try storage.loadAll() },
            save: { try storage.save($0) },
            delete: { try storage.delete($0) },
            exportAll: { try storage.exportAll(to: $0) },
            shortcutSlot: { $0.shortcutSlot },
            clearingShortcutSlot: {
                var template = $0
                template.shortcutSlot = nil
                return template
            },
            sorted: {
                $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        )
        if prepareTransaction {
            access.prepareTransaction = {
                let scope = storage.resolvedForTransaction()
                return TemplateStorageScope(
                    access: .storage(scope.access, prepareTransaction: false),
                    directoryURL: scope.directoryURL, release: scope.release
                )
            }
        }
        return access
    }
}

nonisolated extension TemplateCRUDAccess where Value == DevelopTemplate {
    static func storage(_ storage: DevelopTemplateStorageService, prepareTransaction: Bool = true) -> Self {
        var access = Self(
            loadAll: { try storage.loadAll() },
            save: { try storage.save($0) },
            delete: { try storage.delete($0) },
            exportAll: { destination in
                let templates = try storage.loadAll()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(templates).write(to: destination, options: .atomic)
                return templates.count
            },
            shortcutSlot: { $0.shortcutSlot },
            clearingShortcutSlot: {
                var template = $0
                template.shortcutSlot = nil
                return template
            },
            sorted: {
                $0.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        )
        if prepareTransaction {
            access.prepareTransaction = {
                let scope = storage.resolvedForTransaction()
                return TemplateStorageScope(
                    access: .storage(scope.access, prepareTransaction: false),
                    directoryURL: scope.directoryURL, release: scope.release
                )
            }
        }
        return access
    }
}

/// Owns synchronous template filesystem work on a retained Dispatch serial executor.
/// Blocking provider calls preserve caller task context without occupying cooperative threads.
/// Each method returns immutable evidence so MainActor clients can reject stale completions.
actor TemplateCRUDService<Value: Identifiable & Sendable> where Value.ID == UUID {
    private let access: TemplateCRUDAccess<Value>
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    init(access: TemplateCRUDAccess<Value>,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.templates.crud", qos: .utility
         )) {
        self.access = access
        self.filesystemQueue = filesystemQueue
    }

    private func withStorageTransaction<Result: Sendable>(
        _ operation: @Sendable (TemplateCRUDService<Value>) async throws -> Result
    ) async rethrows -> Result {
        guard let prepare = access.prepareTransaction else {
            return try await operation(self)
        }
        let scope = prepare()
        defer { scope.release() }
        let worker = TemplateCRUDService(access: scope.access, filesystemQueue: filesystemQueue)
        return try await StorageTransactionAdmission.shared.withAccess(to: [scope.directoryURL]) {
            try await operation(worker)
        }
    }

    func load(requestID: UUID) async throws -> TemplateInventoryOperationResult<Value> {
        guard !Task.isCancelled else { return .cancelledBeforeRead(requestID: requestID) }
        return try await withStorageTransaction { try await $0.loadInTransaction(requestID: requestID) }
    }

    func save(_ template: Value, requestID: UUID) async throws -> TemplateMutationOperationResult<Value> {
        guard !Task.isCancelled else { return .cancelledBeforeCommit(requestID: requestID) }
        return try await withStorageTransaction {
            try await $0.saveInTransaction(template, requestID: requestID)
        }
    }

    func delete(_ template: Value, requestID: UUID) async throws -> TemplateMutationOperationResult<Value> {
        guard !Task.isCancelled else { return .cancelledBeforeCommit(requestID: requestID) }
        return try await withStorageTransaction {
            try await $0.deleteInTransaction(template, requestID: requestID)
        }
    }

    func exportAll(to destinationURL: URL, requestID: UUID) async throws -> TemplateExportOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, destinationURL: destinationURL)
        }
        return try await withStorageTransaction {
            try await $0.exportAllInTransaction(to: destinationURL, requestID: requestID)
        }
    }

    private func loadInTransaction(requestID: UUID) throws -> TemplateInventoryOperationResult<Value> {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID)
        }
        let templates = try access.loadAll()
        guard !Task.isCancelled else {
            return .cancelledAfterRead(requestID: requestID, templateCount: templates.count)
        }
        return .loaded(TemplateInventorySnapshot(requestID: requestID, templates: templates))
    }

    private func saveInTransaction(
        _ template: Value,
        requestID: UUID
    ) throws -> TemplateMutationOperationResult<Value> {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }

        var inventory = try access.loadAll()
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        var durableTemplateIDs: [UUID] = []

        if let slot = access.shortcutSlot(template) {
            let conflicts = inventory.filter {
                access.shortcutSlot($0) == slot && $0.id != template.id
            }
            for conflict in conflicts {
                guard !Task.isCancelled else {
                    return cancellationResult(
                        requestID: requestID,
                        requestedTemplate: template,
                        requestedTemplateCommitted: false,
                        durableTemplateIDs: durableTemplateIDs,
                        inventory: inventory
                    )
                }
                let cleared = access.clearingShortcutSlot(conflict)
                do {
                    try access.save(cleared)
                } catch {
                    throw mutationError(
                        requestID: requestID,
                        error: error,
                        durableTemplateIDs: durableTemplateIDs,
                        inventory: inventory
                    )
                }
                durableTemplateIDs.append(cleared.id)
                replace(cleared, in: &inventory)
            }
        }

        guard !Task.isCancelled else {
            return cancellationResult(
                requestID: requestID,
                requestedTemplate: template,
                requestedTemplateCommitted: false,
                durableTemplateIDs: durableTemplateIDs,
                inventory: inventory
            )
        }
        do {
            try access.save(template)
        } catch {
            throw mutationError(
                requestID: requestID,
                error: error,
                durableTemplateIDs: durableTemplateIDs,
                inventory: inventory
            )
        }
        durableTemplateIDs.append(template.id)
        replace(template, in: &inventory)

        if Task.isCancelled {
            return cancellationResult(
                requestID: requestID,
                requestedTemplate: template,
                requestedTemplateCommitted: true,
                durableTemplateIDs: durableTemplateIDs,
                inventory: inventory
            )
        }
        return refreshedCommit(
            requestID: requestID,
            requestedTemplate: template,
            requestedTemplateCommitted: true,
            durableTemplateIDs: durableTemplateIDs,
            derivedInventory: inventory
        )
    }

    private func deleteInTransaction(
        _ template: Value,
        requestID: UUID
    ) throws -> TemplateMutationOperationResult<Value> {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        var inventory = try access.loadAll()
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        do {
            try access.delete(template)
        } catch {
            throw mutationError(
                requestID: requestID,
                error: error,
                durableTemplateIDs: [],
                inventory: inventory
            )
        }
        inventory.removeAll { $0.id == template.id }
        if Task.isCancelled {
            return cancellationResult(
                requestID: requestID,
                requestedTemplate: nil,
                requestedTemplateCommitted: true,
                durableTemplateIDs: [template.id],
                inventory: inventory
            )
        }
        return refreshedCommit(
            requestID: requestID,
            requestedTemplate: nil,
            requestedTemplateCommitted: true,
            durableTemplateIDs: [template.id],
            derivedInventory: inventory
        )
    }

    private func exportAllInTransaction(
        to destinationURL: URL,
        requestID: UUID
    ) throws -> TemplateExportOperationResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(requestID: requestID, destinationURL: destinationURL)
        }
        let count = try access.exportAll(destinationURL)
        return .exported(TemplateExportCommit(
            requestID: requestID,
            destinationURL: destinationURL,
            exportedTemplateCount: count,
            cancellationObservedAfterCommit: Task.isCancelled
        ))
    }

    private func refreshedCommit(
        requestID: UUID,
        requestedTemplate: Value?,
        requestedTemplateCommitted: Bool,
        durableTemplateIDs: [UUID],
        derivedInventory: [Value]
    ) -> TemplateMutationOperationResult<Value> {
        do {
            let refreshed = try access.loadAll()
            return .committed(TemplateMutationCommit(
                requestID: requestID,
                requestedTemplate: requestedTemplate,
                requestedTemplateCommitted: requestedTemplateCommitted,
                durableTemplateIDs: durableTemplateIDs,
                refreshedTemplates: refreshed,
                inventoryRefreshFailureReason: nil,
                cancellationObservedAfterCommit: false
            ))
        } catch {
            return .committed(TemplateMutationCommit(
                requestID: requestID,
                requestedTemplate: requestedTemplate,
                requestedTemplateCommitted: requestedTemplateCommitted,
                durableTemplateIDs: durableTemplateIDs,
                refreshedTemplates: access.sorted(derivedInventory),
                inventoryRefreshFailureReason: error.localizedDescription,
                cancellationObservedAfterCommit: false
            ))
        }
    }

    private func cancellationResult(
        requestID: UUID,
        requestedTemplate: Value?,
        requestedTemplateCommitted: Bool,
        durableTemplateIDs: [UUID],
        inventory: [Value]
    ) -> TemplateMutationOperationResult<Value> {
        guard !durableTemplateIDs.isEmpty else {
            return .cancelledBeforeCommit(requestID: requestID)
        }
        return .committed(TemplateMutationCommit(
            requestID: requestID,
            requestedTemplate: requestedTemplate,
            requestedTemplateCommitted: requestedTemplateCommitted,
            durableTemplateIDs: durableTemplateIDs,
            refreshedTemplates: access.sorted(inventory),
            inventoryRefreshFailureReason: nil,
            cancellationObservedAfterCommit: true
        ))
    }

    private func mutationError(
        requestID: UUID,
        error: Error,
        durableTemplateIDs: [UUID],
        inventory: [Value]
    ) -> TemplateMutationError<Value> {
        TemplateMutationError(
            requestID: requestID,
            reason: error.localizedDescription,
            durableTemplateIDs: durableTemplateIDs,
            refreshedTemplates: access.sorted(inventory)
        )
    }

    private func replace(_ template: Value, in inventory: inout [Value]) {
        if let index = inventory.firstIndex(where: { $0.id == template.id }) {
            inventory[index] = template
        } else {
            inventory.append(template)
        }
        inventory = access.sorted(inventory)
    }
}
