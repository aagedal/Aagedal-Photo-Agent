import CryptoKit
import Foundation

/// Durable helper-to-native intent, never consent or authority to execute a plan.
/// Admission is written before execution. An admission whose operation link is lost
/// remains uncertain and must never be automatically replayed.
nonisolated final class MCPNativeReviewRequestStore: Sendable {
    enum Failure: String, Error, Equatable, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownRequest = "unknown_native_review_request"
        case conflictingRequest = "conflicting_native_review_request"
        case invalidTransition = "invalid_native_review_request_transition"
        case capacity = "native_review_request_capacity"
        case staleEpoch = "stale_native_review_request_epoch"
        case storageUnavailable = "native_review_request_storage_unavailable"
        case invalidStorage = "invalid_native_review_request_storage"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide canonical request and plan identifiers."
            case .unknownRequest: "The native review request is not retained."
            case .conflictingRequest: "The request identifier already names a different review intent."
            case .invalidTransition: "This native review request cannot enter the requested state."
            case .capacity: "The native review request archive is full."
            case .staleEpoch: "Refresh native review capacity and use its current epoch for new requests."
            case .storageUnavailable: "Private native review request storage is unavailable."
            case .invalidStorage: "The native review request archive cannot be verified."
            }
        }
    }
    enum Purpose: String, Codable, Sendable { case pendingDraft, xmpPublication }
    enum State: String, Codable, Sendable {
        case awaitingReview, admitted, linked, cancelled, unknownDisposition
    }

    struct Record: Codable, Equatable, Sendable {
        let requestID: UUID
        let requestEpoch: UUID?
        let planID: String
        let purpose: Purpose
        let createdAt: Date
        fileprivate(set) var updatedAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var admittedAt: Date?
        fileprivate(set) var operationID: UUID?
        fileprivate(set) var cancellationRequestedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case requestID, requestEpoch, planID, purpose, createdAt, updatedAt, state
            case admittedAt, operationID, cancellationRequestedAt
        }

        fileprivate init(requestID: UUID, requestEpoch: UUID?, planID: String, purpose: Purpose, createdAt: Date) {
            self.requestID = requestID
            self.requestEpoch = requestEpoch
            self.planID = planID
            self.purpose = purpose
            self.createdAt = createdAt
            updatedAt = createdAt
            state = .awaitingReview
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            let request = try fields.decode(String.self, forKey: .requestID)
            guard let id = UUID(uuidString: request), id.uuidString.lowercased() == request else {
                throw Failure.invalidStorage
            }
            requestID = id
            if let epoch = try fields.decodeIfPresent(String.self, forKey: .requestEpoch) {
                guard let id = UUID(uuidString: epoch), id.uuidString.lowercased() == epoch else {
                    throw Failure.invalidStorage
                }
                requestEpoch = id
            } else { requestEpoch = nil }
            planID = try fields.decode(String.self, forKey: .planID)
            purpose = try fields.decode(Purpose.self, forKey: .purpose)
            createdAt = try fields.decode(Date.self, forKey: .createdAt)
            updatedAt = try fields.decode(Date.self, forKey: .updatedAt)
            state = try fields.decode(State.self, forKey: .state)
            admittedAt = try fields.decodeIfPresent(Date.self, forKey: .admittedAt)
            cancellationRequestedAt = try fields.decodeIfPresent(Date.self, forKey: .cancellationRequestedAt)
            if let operation = try fields.decodeIfPresent(String.self, forKey: .operationID) {
                guard let id = UUID(uuidString: operation), id.uuidString.lowercased() == operation else {
                    throw Failure.invalidStorage
                }
                operationID = id
            }
        }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(requestID.uuidString.lowercased(), forKey: .requestID)
            try fields.encodeIfPresent(requestEpoch?.uuidString.lowercased(), forKey: .requestEpoch)
            try fields.encode(planID, forKey: .planID)
            try fields.encode(purpose, forKey: .purpose)
            try fields.encode(createdAt, forKey: .createdAt)
            try fields.encode(updatedAt, forKey: .updatedAt)
            try fields.encode(state, forKey: .state)
            try fields.encodeIfPresent(admittedAt, forKey: .admittedAt)
            try fields.encodeIfPresent(operationID?.uuidString.lowercased(), forKey: .operationID)
            try fields.encodeIfPresent(cancellationRequestedAt, forKey: .cancellationRequestedAt)
        }
    }

    struct CapacitySnapshot: Equatable, Sendable {
        let epoch: UUID
        let retainedCount: Int
        let maximumRecords: Int
        let cancelledBeforeAdmissionCount: Int
        /// Nil means operation history was not consulted; zero means it was checked.
        let confirmedTerminalCount: Int?

        init(epoch: UUID, retainedCount: Int, maximumRecords: Int,
             cancelledBeforeAdmissionCount: Int, confirmedTerminalCount: Int? = nil) {
            self.epoch = epoch
            self.retainedCount = retainedCount
            self.maximumRecords = maximumRecords
            self.cancelledBeforeAdmissionCount = cancelledBeforeAdmissionCount
            self.confirmedTerminalCount = confirmedTerminalCount
        }
    }

    struct CapacityRecoveryResult: Equatable, Sendable {
        let epoch: UUID
        let retiredCount: Int
    }

    private struct Archive: Codable {
        var schemaVersion: Int
        var currentEpoch: UUID?
        var legacyCreationAllowed: Bool
        var records: [Record]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, currentEpoch, legacyCreationAllowed, records
        }

        init(schemaVersion: Int = 1, currentEpoch: UUID? = nil,
             legacyCreationAllowed: Bool = true, records: [Record] = []) {
            self.schemaVersion = schemaVersion
            self.currentEpoch = currentEpoch
            self.legacyCreationAllowed = legacyCreationAllowed
            self.records = records
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
            records = try fields.decode([Record].self, forKey: .records)
            if schemaVersion == 1 {
                currentEpoch = nil
                legacyCreationAllowed = true
            } else if schemaVersion == 2 {
                let epoch = try fields.decode(String.self, forKey: .currentEpoch)
                guard let id = UUID(uuidString: epoch), id.uuidString.lowercased() == epoch else {
                    throw Failure.invalidStorage
                }
                currentEpoch = id
                legacyCreationAllowed = try fields.decode(Bool.self, forKey: .legacyCreationAllowed)
            } else { throw Failure.invalidStorage }
        }

        func encode(to encoder: Encoder) throws {
            guard schemaVersion == 2, let currentEpoch else { throw Failure.invalidStorage }
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(schemaVersion, forKey: .schemaVersion)
            try fields.encode(currentEpoch.uuidString.lowercased(), forKey: .currentEpoch)
            try fields.encode(legacyCreationAllowed, forKey: .legacyCreationAllowed)
            try fields.encode(records, forKey: .records)
        }
    }
    private struct Envelope: Codable { let payload: Data; let sha256: String }
    private let persistence: AutomationOperationPersistence
    let storageDirectory: URL
    private let maximumRecords: Int
    private let maximumBytes: Int

    init(storageDirectory: URL, maximumRecords: Int = 256, maximumBytes: Int = 1_048_576) {
        self.storageDirectory = storageDirectory
        self.maximumRecords = min(max(0, maximumRecords), 256)
        self.maximumBytes = min(max(0, maximumBytes), 1_048_576)
        persistence = AutomationOperationPersistence(directory: storageDirectory,
            maximumBytes: min(max(0, maximumBytes), 1_048_576))
    }

    static func defaultStorageDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent(".aagedal-photo-agent-native-review-requests", isDirectory: true)
    }

    /// This is a durable mutation: the first snapshot initializes or migrates the epoch.
    func capacitySnapshot() throws -> CapacitySnapshot {
        try archiveTransaction { archive in
            CapacitySnapshot(epoch: archive.currentEpoch!, retainedCount: archive.records.count,
                             maximumRecords: maximumRecords,
                             cancelledBeforeAdmissionCount: archive.records.filter(Self.canRetire).count)
        }
    }

    /// Counts only exact linked operations whose confirmed terminal evidence is at
    /// least as recent as the request. History remains locked through this snapshot.
    /// Like capacitySnapshot(), this durably initializes or migrates the request epoch.
    func terminalCapacitySnapshot(registry: AutomationOperationRegistry) throws -> CapacitySnapshot {
        try withLockedOperations(registry) { operations in
            try archiveTransaction { archive in
                CapacitySnapshot(epoch: archive.currentEpoch!, retainedCount: archive.records.count,
                    maximumRecords: maximumRecords,
                    cancelledBeforeAdmissionCount: archive.records.filter(Self.canRetire).count,
                    confirmedTerminalCount: archive.records.filter { Self.canRetireConfirmedTerminal($0, operations: operations) }.count)
            }
        }
    }

    /// Explicit native maintenance, never eviction. Reload and revalidate while holding
    /// operation history before request storage, so history cannot be removed between
    /// checking evidence and retiring requests. Operation and recovery archives are untouched.
    func recoverConfirmedTerminalCapacity(expectedEpoch: UUID,
                                           registry: AutomationOperationRegistry) throws -> CapacityRecoveryResult {
        try withLockedOperations(registry) { operations in
            try archiveTransaction { archive in
                guard archive.currentEpoch == expectedEpoch else { throw Failure.staleEpoch }
                let retiredCount = archive.records.filter { Self.canRetireConfirmedTerminal($0, operations: operations) }.count
                guard retiredCount > 0 else { throw Failure.invalidTransition }
                archive.records.removeAll { Self.canRetireConfirmedTerminal($0, operations: operations) }
                archive.currentEpoch = UUID()
                archive.legacyCreationAllowed = false
                return CapacityRecoveryResult(epoch: archive.currentEpoch!, retiredCount: retiredCount)
            }
        }
    }

    private func withLockedOperations<T>(_ registry: AutomationOperationRegistry,
                                         _ body: ([AutomationOperationRegistry.Record]) throws -> T) throws -> T {
        do { return try registry.withLockedRecords(body) }
        catch let failure as AutomationOperationRegistry.Failure {
            switch failure {
            case .invalidStorage: throw Failure.invalidStorage
            case .capacity: throw Failure.capacity
            default: throw Failure.storageUnavailable
            }
        }
    }

    private static func canRetireConfirmedTerminal(_ request: Record,
                                                   operations: [AutomationOperationRegistry.Record]) -> Bool {
        guard request.state == .linked, let admittedAt = request.admittedAt,
              let operationID = request.operationID,
              let operation = operations.first(where: { $0.id == operationID }),
              operation.kind == (request.purpose == .pendingDraft ? .iptcDraft : .iptcPatch),
              operation.isTerminal, [.verified, .failed, .cancelled, .stale].contains(operation.outcome),
              operation.createdAt >= admittedAt, operation.updatedAt >= request.updatedAt else { return false }
        // Recovery-resolved uncertainty remains out of scope: canRemove is intentionally
        // broader than proof that a linked request has a confirmed original outcome.
        return true
    }

    /// Recovery is explicit native maintenance. No admitted or linked evidence is retired.
    func recoverCancelledCapacity(expectedEpoch: UUID) throws -> CapacityRecoveryResult {
        try archiveTransaction { archive in
            guard archive.currentEpoch == expectedEpoch else { throw Failure.staleEpoch }
            let retiredCount = archive.records.filter(Self.canRetire).count
            guard retiredCount > 0 else { throw Failure.invalidTransition }
            archive.records.removeAll(where: Self.canRetire)
            archive.currentEpoch = UUID()
            archive.legacyCreationAllowed = false
            return CapacityRecoveryResult(epoch: archive.currentEpoch!, retiredCount: retiredCount)
        }
    }

    private static func canRetire(_ record: Record) -> Bool {
        record.state == .cancelled && record.admittedAt == nil && record.operationID == nil
    }

    /// New helper requests bind their UUID to the epoch observed before submission.
    /// Exact retained retries remain valid across rotations of the current epoch.
    func request(requestID: UUID, requestEpoch: UUID, planID: String,
                 purpose: Purpose, now: Date = Date()) throws -> Record {
        try request(requestID: requestID, epoch: requestEpoch, planID: planID, purpose: purpose, now: now)
    }

    /// Compatibility for native fixtures and retained legacy requests. Rotation permanently
    /// disables new epochless creation so a retired legacy UUID cannot be replayed.
    func request(requestID: UUID, planID: String, purpose: Purpose, now: Date = Date()) throws -> Record {
        try request(requestID: requestID, epoch: nil, planID: planID, purpose: purpose, now: now)
    }

    private func request(requestID: UUID, epoch: UUID?, planID: String,
                         purpose: Purpose, now: Date) throws -> Record {
        guard Self.canonicalUUID(planID), now.timeIntervalSinceReferenceDate.isFinite else {
            throw Failure.invalidArguments
        }
        return try archiveTransaction { archive in
            if let existing = archive.records.first(where: { $0.requestID == requestID }) {
                guard existing.requestEpoch == epoch else { throw Failure.staleEpoch }
                guard existing.planID == planID, existing.purpose == purpose else { throw Failure.conflictingRequest }
                return existing
            }
            if let epoch {
                guard epoch == archive.currentEpoch else { throw Failure.staleEpoch }
            } else {
                guard archive.legacyCreationAllowed else { throw Failure.staleEpoch }
            }
            guard archive.records.count < maximumRecords else { throw Failure.capacity }
            let record = Record(requestID: requestID, requestEpoch: epoch, planID: planID,
                                purpose: purpose, createdAt: now)
            archive.records.append(record)
            return record
        }
    }

    func records() throws -> [Record] { try transaction(readOnly: true) { $0 } }

    func inspect(_ requestID: UUID) throws -> Record {
        try transaction(readOnly: true) { records in
            guard let record = records.first(where: { $0.requestID == requestID }) else { throw Failure.unknownRequest }
            return record
        }
    }

    /// The caller separately obtains current native consent and revalidates the plan.
    /// Persisting this transition must succeed before entering any executor.
    func admit(_ requestID: UUID, requestEpoch: UUID? = nil, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
            guard record.requestEpoch == requestEpoch else { throw Failure.staleEpoch }
            guard record.state == .awaitingReview else { throw Failure.invalidTransition }
            record.state = .admitted
            record.admittedAt = now
        }
    }

    /// A single operation may satisfy only one request. Failed linking after execution
    /// is deliberately not repaired by admitting or executing the request again.
    func link(_ requestID: UUID, operationID: UUID, now: Date = Date()) throws -> Record {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.requestID == requestID }) else { throw Failure.unknownRequest }
            guard now.timeIntervalSinceReferenceDate.isFinite, now >= records[index].updatedAt else { throw Failure.invalidArguments }
            guard records[index].state == .admitted,
                  !records.contains(where: { $0.operationID == operationID }) else { throw Failure.invalidTransition }
            records[index].state = .linked
            records[index].operationID = operationID
            records[index].updatedAt = now
            return records[index]
        }
    }

    /// Cancellation before admission proves no native execution was admitted. After
    /// admission a missing link cannot prove whether execution created any effects.
    /// A linked record retains its operation identity for cooperative cancellation.
    func cancel(_ requestID: UUID, requestEpoch: UUID? = nil, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
            guard record.requestEpoch == requestEpoch else { throw Failure.staleEpoch }
            if record.cancellationRequestedAt != nil { return }
            record.cancellationRequestedAt = now
            switch record.state {
            case .awaitingReview: record.state = .cancelled
            case .admitted: record.state = .unknownDisposition
            case .linked, .cancelled, .unknownDisposition: break
            }
        }
    }

    /// Call at native startup only after the prior native execution session has ended.
    /// Constructing a helper store or reading it must not invalidate a live admission.
    /// This never launches work or fabricates an operation link.
    func reconcileUnlinkedAdmissions(now: Date = Date()) throws -> [Record] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidArguments }
        return try transaction { records in
            let indices = records.indices.filter { records[$0].state == .admitted }
            guard indices.allSatisfy({ now >= records[$0].updatedAt }) else { throw Failure.invalidArguments }
            return indices.map { index in
                records[index].state = .unknownDisposition
                records[index].updatedAt = now
                return records[index]
            }
        }
    }

    /// A submission failure after admission cannot establish whether an operation
    /// was durably enqueued. Retain the one-way admission without permitting replay.
    func markUnknownDisposition(_ requestID: UUID, requestEpoch: UUID? = nil, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
            guard record.requestEpoch == requestEpoch else { throw Failure.staleEpoch }
            switch record.state {
            case .admitted: record.state = .unknownDisposition
            case .unknownDisposition, .linked: break
            case .awaitingReview, .cancelled: throw Failure.invalidTransition
            }
        }
    }

    private func update(_ requestID: UUID, now: Date, body: (inout Record) throws -> Void) throws -> Record {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.requestID == requestID }) else { throw Failure.unknownRequest }
            guard now.timeIntervalSinceReferenceDate.isFinite, now >= records[index].updatedAt else { throw Failure.invalidArguments }
            let before = records[index]
            try body(&records[index])
            if records[index] != before { records[index].updatedAt = now }
            return records[index]
        }
    }

    private func transaction<T>(readOnly: Bool = false, _ body: (inout [Record]) throws -> T) throws -> T {
        try archiveTransaction(readOnly: readOnly) { archive in try body(&archive.records) }
    }

    private func archiveTransaction<T>(readOnly: Bool = false, _ body: (inout Archive) throws -> T) throws -> T {
        do {
            return try persistence.transaction(readOnly: readOnly) { data in
                var archive = try data.map(decode) ?? Archive()
                if !readOnly, archive.schemaVersion == 1 {
                    archive.schemaVersion = 2
                    archive.currentEpoch = UUID()
                }
                let result = try body(&archive)
                if readOnly { return (result, data ?? Data()) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(archive)
                let bytes = try encoder.encode(Envelope(payload: payload, sha256: Self.digest(payload)))
                guard bytes.count <= maximumBytes else { throw Failure.capacity }
                return (result, bytes)
            }
        } catch let failure as AutomationOperationRegistry.Failure {
            switch failure {
            case .capacity: throw Failure.capacity
            case .invalidStorage: throw Failure.invalidStorage
            default: throw Failure.storageUnavailable
            }
        }
    }

    private func decode(_ data: Data) throws -> Archive {
        do {
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(outer.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard Self.digest(envelope.payload) == envelope.sha256,
                  let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  let version = object["schemaVersion"] as? Int,
                  [1, 2].contains(version),
                  Set(object.keys) == (version == 1 ? ["schemaVersion", "records"] :
                      ["schemaVersion", "currentEpoch", "legacyCreationAllowed", "records"]),
                  !object.values.contains(where: { $0 is NSNull }),
                  let objects = object["records"] as? [[String: Any]] else { throw Failure.invalidStorage }
            let required: Set<String> = ["requestID", "planID", "purpose", "createdAt", "updatedAt", "state"]
            let optional: Set<String> = version == 1
                ? ["admittedAt", "operationID", "cancellationRequestedAt"]
                : ["requestEpoch", "admittedAt", "operationID", "cancellationRequestedAt"]
            for record in objects {
                guard required.isSubset(of: Set(record.keys)),
                      Set(record.keys).isSubset(of: required.union(optional)),
                      !record.values.contains(where: { $0 is NSNull }) else { throw Failure.invalidStorage }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.records.count <= maximumRecords,
                  Set(archive.records.map(\.requestID)).count == archive.records.count else { throw Failure.invalidStorage }
            let operationIDs = archive.records.compactMap(\.operationID)
            guard Set(operationIDs).count == operationIDs.count else { throw Failure.invalidStorage }
            for record in archive.records {
                guard Self.canonicalUUID(record.planID),
                      record.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      record.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      record.updatedAt >= record.createdAt else { throw Failure.invalidStorage }
                for timestamp in [record.admittedAt, record.cancellationRequestedAt].compactMap({ $0 }) {
                    guard timestamp.timeIntervalSinceReferenceDate.isFinite,
                          timestamp >= record.createdAt, timestamp <= record.updatedAt else { throw Failure.invalidStorage }
                }
                guard (record.state == .linked) == (record.operationID != nil) else { throw Failure.invalidStorage }
                switch record.state {
                case .awaitingReview:
                    guard record.admittedAt == nil, record.cancellationRequestedAt == nil else { throw Failure.invalidStorage }
                case .cancelled:
                    guard record.admittedAt == nil, record.cancellationRequestedAt != nil else { throw Failure.invalidStorage }
                case .admitted:
                    guard record.admittedAt != nil, record.cancellationRequestedAt == nil else { throw Failure.invalidStorage }
                case .linked, .unknownDisposition:
                    guard record.admittedAt != nil else { throw Failure.invalidStorage }
                    if let cancellation = record.cancellationRequestedAt {
                        guard cancellation >= record.admittedAt! else { throw Failure.invalidStorage }
                    }
                }
            }
            return archive
        } catch { throw Failure.invalidStorage }
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
