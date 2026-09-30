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
        case storageUnavailable = "native_review_request_storage_unavailable"
        case invalidStorage = "invalid_native_review_request_storage"

        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide canonical request and plan identifiers."
            case .unknownRequest: "The native review request is not retained."
            case .conflictingRequest: "The request identifier already names a different review intent."
            case .invalidTransition: "This native review request cannot enter the requested state."
            case .capacity: "The native review request archive is full."
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
        let planID: String
        let purpose: Purpose
        let createdAt: Date
        fileprivate(set) var updatedAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var admittedAt: Date?
        fileprivate(set) var operationID: UUID?
        fileprivate(set) var cancellationRequestedAt: Date?

        private enum CodingKeys: String, CodingKey {
            case requestID, planID, purpose, createdAt, updatedAt, state
            case admittedAt, operationID, cancellationRequestedAt
        }

        fileprivate init(requestID: UUID, planID: String, purpose: Purpose, createdAt: Date) {
            self.requestID = requestID
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

    private struct Archive: Codable { let schemaVersion: Int; let records: [Record] }
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

    /// Capacity never evicts an idempotency record, including cancelled requests.
    func request(requestID: UUID, planID: String, purpose: Purpose, now: Date = Date()) throws -> Record {
        guard Self.canonicalUUID(planID), now.timeIntervalSinceReferenceDate.isFinite else {
            throw Failure.invalidArguments
        }
        return try transaction { records in
            if let existing = records.first(where: { $0.requestID == requestID }) {
                guard existing.planID == planID, existing.purpose == purpose else { throw Failure.conflictingRequest }
                return existing
            }
            guard records.count < maximumRecords else { throw Failure.capacity }
            let record = Record(requestID: requestID, planID: planID, purpose: purpose, createdAt: now)
            records.append(record)
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
    func admit(_ requestID: UUID, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
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
    func cancel(_ requestID: UUID, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
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
    func markUnknownDisposition(_ requestID: UUID, now: Date = Date()) throws -> Record {
        try update(requestID, now: now) { record in
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
        do {
            return try persistence.transaction(readOnly: readOnly) { data in
                var records = try data.map(decode) ?? []
                let result = try body(&records)
                if readOnly { return (result, data ?? Data()) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(Archive(schemaVersion: 1, records: records))
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

    private func decode(_ data: Data) throws -> [Record] {
        do {
            guard let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(outer.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard Self.digest(envelope.payload) == envelope.sha256,
                  let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "records"],
                  let objects = object["records"] as? [[String: Any]] else { throw Failure.invalidStorage }
            let required: Set<String> = ["requestID", "planID", "purpose", "createdAt", "updatedAt", "state"]
            let optional: Set<String> = ["admittedAt", "operationID", "cancellationRequestedAt"]
            for record in objects {
                guard required.isSubset(of: Set(record.keys)),
                      Set(record.keys).isSubset(of: required.union(optional)),
                      !record.values.contains(where: { $0 is NSNull }) else { throw Failure.invalidStorage }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, archive.records.count <= maximumRecords,
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
            return archive.records
        } catch { throw Failure.invalidStorage }
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
