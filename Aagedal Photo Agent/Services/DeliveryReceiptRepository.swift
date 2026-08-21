import Foundation

nonisolated struct DeliveryReceiptRetentionPolicy: Equatable, Sendable {
    let maximumReceiptCount: Int
    let maximumAgeDays: Int?

    init(maximumReceiptCount: Int = 250, maximumAgeDays: Int? = 365) {
        self.maximumReceiptCount = maximumReceiptCount
        self.maximumAgeDays = maximumAgeDays
    }

    fileprivate func validate() throws {
        guard maximumReceiptCount > 0 else {
            throw DeliveryReceiptRepositoryError.invalidRetentionPolicy
        }
        if let maximumAgeDays, maximumAgeDays <= 0 {
            throw DeliveryReceiptRepositoryError.invalidRetentionPolicy
        }
    }
}

nonisolated struct DeliveryReceiptListEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let batchIdentifier: UUID
    let profileIdentifier: UUID
    let completedAt: Date
    let destinationIdentifier: String
    let destinationPath: String
    let itemCount: Int
    let uploadAcknowledgedCount: Int
    let remoteSizeMatchedCount: Int
    let warningCount: Int
}

nonisolated enum DeliveryReceiptRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case receiptNotFound(UUID)
    case receiptAlreadyExists(UUID)
    case duplicateBatchIdentifier(UUID)
    case invalidRetentionPolicy

    var errorDescription: String? {
        switch self {
        case let .receiptNotFound(id):
            "No delivery receipt exists with ID \(id.uuidString.lowercased())."
        case let .receiptAlreadyExists(id):
            "A delivery receipt with ID \(id.uuidString.lowercased()) already exists."
        case let .duplicateBatchIdentifier(id):
            "A delivery receipt already exists for batch \(id.uuidString.lowercased())."
        case .invalidRetentionPolicy:
            "Delivery receipt retention must keep at least one receipt and use a positive age."
        }
    }
}

/// Atomic, bounded local persistence for privacy-preserving delivery receipts.
actor DeliveryReceiptRepository {
    let documentURL: URL

    private let retentionPolicy: DeliveryReceiptRetentionPolicy
    private let store: AtomicJSONDocumentStore<DeliveryReceiptRepositoryDocument>
    private var hasExclusiveAccess = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        documentURL: URL,
        retentionPolicy: DeliveryReceiptRetentionPolicy = DeliveryReceiptRetentionPolicy()
    ) {
        self.documentURL = documentURL
        self.retentionPolicy = retentionPolicy
        store = AtomicJSONDocumentStore(documentURL: documentURL)
    }

    /// Records a completed receipt without replacing either an existing receipt or batch.
    func record(_ receipt: DeliveryReceipt, now: Date = Date()) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try retentionPolicy.validate()
        try receipt.validateForPersistence()

        var document = try await loadDocument()
        guard !document.receipts.contains(where: { $0.id == receipt.id }) else {
            throw DeliveryReceiptRepositoryError.receiptAlreadyExists(receipt.id)
        }
        guard !document.receipts.contains(where: {
            $0.batchIdentifier == receipt.batchIdentifier
        }) else {
            throw DeliveryReceiptRepositoryError.duplicateBatchIdentifier(
                receipt.batchIdentifier
            )
        }

        document.receipts.append(receipt.deterministicallyOrdered)
        document.receipts = retainedReceipts(document.receipts, now: now)
        try await save(document)
    }

    /// Lists compact receipt metadata newest-first without loading editorial values (none are stored).
    func list() async throws -> [DeliveryReceiptListEntry] {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try retentionPolicy.validate()
        return sortedReceipts(try await loadDocument().receipts).map(Self.listEntry)
    }

    func read(id: UUID) async throws -> DeliveryReceipt {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try retentionPolicy.validate()
        guard let receipt = try await loadDocument().receipts.first(where: { $0.id == id }) else {
            throw DeliveryReceiptRepositoryError.receiptNotFound(id)
        }
        return receipt.deterministicallyOrdered
    }

    /// Manual deletion is intentionally explicit; retention never runs as a side effect of reads.
    func delete(id: UUID) async throws {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try retentionPolicy.validate()
        var document = try await loadDocument()
        guard document.receipts.contains(where: { $0.id == id }) else {
            throw DeliveryReceiptRepositoryError.receiptNotFound(id)
        }
        document.receipts.removeAll { $0.id == id }
        try await save(document)
    }

    /// Applies the configured count/age policy at an explicit maintenance boundary.
    @discardableResult
    func enforceRetention(now: Date = Date()) async throws -> Int {
        await beginExclusiveAccess()
        defer { endExclusiveAccess() }
        try retentionPolicy.validate()
        var document = try await loadDocument()
        let before = document.receipts.count
        document.receipts = retainedReceipts(document.receipts, now: now)
        let removed = before - document.receipts.count
        if removed > 0 {
            try await save(document)
        }
        return removed
    }

    private func beginExclusiveAccess() async {
        if !hasExclusiveAccess {
            hasExclusiveAccess = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func endExclusiveAccess() {
        guard !accessWaiters.isEmpty else {
            hasExclusiveAccess = false
            return
        }
        accessWaiters.removeFirst().resume()
    }

    private func loadDocument() async throws -> DeliveryReceiptRepositoryDocument {
        // The generic atomic store can recover any decode failure from its backup. A receipt made
        // by a newer build is not corruption: protect the primary explicitly so an older backup
        // can never be used as a path to overwrite future receipt data.
        try rejectNewerReceiptSchemaInPrimary()
        do {
            switch try await store.load() {
            case let .document(document, source):
                if document.migratedFromSchemaVersion != nil, source == .primary {
                    let migrated = document.readyForPersistence
                    try await store.save(migrated)
                    return migrated
                }
                return document.readyForPersistence
            case let .newerSchema(schemaVersion, _, _):
                throw AtomicJSONDocumentStoreError.newerSchemaRequiresReadOnly(
                    found: schemaVersion,
                    supported: DeliveryReceiptRepositoryDocument.currentSchemaVersion
                )
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return DeliveryReceiptRepositoryDocument()
        }
    }

    private func rejectNewerReceiptSchemaInPrimary() throws {
        guard FileManager.default.fileExists(atPath: documentURL.path),
              let data = try? Data(contentsOf: documentURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receipts = object["receipts"] as? [[String: Any]] else {
            return
        }
        for receipt in receipts {
            guard let version = receipt["schemaVersion"] as? Int,
                  version > DeliveryReceipt.currentSchemaVersion else {
                continue
            }
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "delivery receipt",
                found: version,
                supported: DeliveryReceipt.currentSchemaVersion
            )
        }
    }

    private func save(_ document: DeliveryReceiptRepositoryDocument) async throws {
        var deterministic = document.readyForPersistence
        deterministic.receipts = sortedReceipts(document.receipts).map(\.deterministicallyOrdered)
        try await store.save(deterministic)
    }

    private func retainedReceipts(_ receipts: [DeliveryReceipt], now: Date) -> [DeliveryReceipt] {
        var retained = receipts
        if let maximumAgeDays = retentionPolicy.maximumAgeDays,
           let cutoff = Calendar(identifier: .gregorian).date(
               byAdding: .day,
               value: -maximumAgeDays,
               to: now
           ) {
            retained.removeAll { $0.completedAt < cutoff }
        }
        return Array(sortedReceipts(retained).prefix(retentionPolicy.maximumReceiptCount))
    }

    private static func listEntry(_ receipt: DeliveryReceipt) -> DeliveryReceiptListEntry {
        DeliveryReceiptListEntry(
            id: receipt.id,
            batchIdentifier: receipt.batchIdentifier,
            profileIdentifier: receipt.profileIdentifier,
            completedAt: receipt.completedAt,
            destinationIdentifier: receipt.destination.identifier,
            destinationPath: receipt.destination.path,
            itemCount: receipt.items.count,
            uploadAcknowledgedCount: receipt.items.count {
                $0.uploadAcknowledgement.status == .protocolAcknowledged
            },
            remoteSizeMatchedCount: receipt.items.count {
                $0.remoteStatAcknowledgement.status == .matchesDeliveredByteSize
            },
            warningCount: receipt.acceptedWarningIdentifiers.count
        )
    }
}

private nonisolated struct DeliveryReceiptRepositoryDocument: VersionedJSONDocument, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var receipts: [DeliveryReceipt]
    var migratedFromSchemaVersion: Int?

    init(
        receipts: [DeliveryReceipt] = [],
        migratedFromSchemaVersion: Int? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.receipts = receipts
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
    }

    var readyForPersistence: Self {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.migratedFromSchemaVersion = nil
        copy.receipts = sortedReceipts(copy.receipts).map(\.deterministicallyOrdered)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, receipts
    }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> Self {
        switch schemaVersion {
        case 1:
            let legacy = try decoder.decode(VersionOne.self, from: data)
            return Self(receipts: legacy.receipts, migratedFromSchemaVersion: 1)
        case Self.currentSchemaVersion:
            return try decoder.decode(Self.self, from: data)
        default:
            throw AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
    }

    func validateForPersistence() throws {
        var receiptIDs = Set<UUID>()
        var batchIDs = Set<UUID>()
        for receipt in receipts {
            try receipt.validateForPersistence()
            guard receiptIDs.insert(receipt.id).inserted else {
                throw DeliveryReceiptRepositoryError.receiptAlreadyExists(receipt.id)
            }
            guard batchIDs.insert(receipt.batchIdentifier).inserted else {
                throw DeliveryReceiptRepositoryError.duplicateBatchIdentifier(
                    receipt.batchIdentifier
                )
            }
        }
    }

    private struct VersionOne: Decodable {
        let receipts: [DeliveryReceipt]
    }
}

private nonisolated func sortedReceipts(_ receipts: [DeliveryReceipt]) -> [DeliveryReceipt] {
    receipts.sorted { lhs, rhs in
        if lhs.completedAt != rhs.completedAt { return lhs.completedAt > rhs.completedAt }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}

nonisolated struct DeliveryReceiptSummaryGenerator: Sendable {
    func summary(for receipt: DeliveryReceipt) -> String {
        let uploadCount = receipt.items.count {
            $0.uploadAcknowledgement.status == .protocolAcknowledged
        }
        let remoteMatchCount = receipt.items.count {
            $0.remoteStatAcknowledgement.status == .matchesDeliveredByteSize
        }
        let verificationFailureCount = receipt.items.count {
            $0.metadataVerification.outcome == .failed
        }
        let warningCount = receipt.acceptedWarningIdentifiers.count
        let date = ISO8601DateFormatter().string(from: receipt.completedAt)

        return [
            "Delivery \(receipt.batchIdentifier.uuidString.lowercased())",
            "Completed: \(date)",
            "Profile: \(receipt.profileIdentifier.uuidString.lowercased())",
            "Destination: \(receipt.destination.identifier) \(receipt.destination.path)",
            "Items: \(receipt.items.count); upload acknowledged: \(uploadCount); remote size matched: \(remoteMatchCount)",
            "Metadata verification failures: \(verificationFailureCount); accepted warnings: \(warningCount)",
            "App: \(receipt.applicationVersion.marketingVersion) (\(receipt.applicationVersion.buildNumber))",
        ].joined(separator: "\n")
    }
}
