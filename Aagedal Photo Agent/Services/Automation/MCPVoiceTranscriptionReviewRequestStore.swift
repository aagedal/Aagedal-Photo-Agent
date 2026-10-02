import CryptoKit
import Foundation

/// Separate transcription intent domain. Checksums detect corruption; they never
/// authenticate consent. Internal admission/linkage are coordination evidence only;
/// no helper or native review UI can grant provider consent through this store.
nonisolated final class MCPVoiceTranscriptionReviewRequestStore: Sendable {
    enum Failure: String, Error, Equatable, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownRequest = "unknown_voice_transcription_review_request"
        case conflictingRequest = "conflicting_voice_transcription_review_request"
        case staleEpoch = "stale_voice_transcription_review_request_epoch"
        case invalidTransition = "invalid_voice_transcription_review_request_transition"
        case capacity = "voice_transcription_review_request_capacity"
        case storageUnavailable = "voice_transcription_review_request_storage_unavailable"
        case invalidStorage = "invalid_voice_transcription_review_request_storage"
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide only canonical requestEpoch, requestID and planID handles."
            case .unknownRequest: "The transcription review intent is not retained."
            case .conflictingRequest: "This request ID already names another transcription intent."
            case .staleEpoch: "Use the current transcription review epoch for new intent; retain the original epoch for retries."
            case .invalidTransition: "This transcription request cannot enter the requested state. Uncertain work cannot be replayed."
            case .capacity: "The bounded transcription review archive is full."
            case .storageUnavailable: "Private transcription review storage is unavailable."
            case .invalidStorage: "The transcription review archive cannot be verified."
            }
        }
    }
    enum State: String, Codable, Sendable { case awaitingReview, admitted, linked, cancelled }

    /// Immutable internal coordination identity. The executor reserves the exact operation
    /// before its pre-start admission hook; this is never provider consent or root authority.
    struct Admission: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let admissionID: String
        let requestID: String
        let requestEpoch: String
        let intentSHA256: String
        let batchIdentity: String
        let operationID: String
        let ownerID: String

        fileprivate func validate(for record: Record) throws {
            guard schemaVersion == 1,
                  [admissionID, requestID, requestEpoch, operationID, ownerID].allSatisfy(MCPVoiceTranscriptionReviewRequestStore.canonicalUUID),
                  requestID == record.requestID, requestEpoch == record.requestEpoch,
                  intentSHA256 == record.intentSHA256, batchIdentity == record.batchIdentity else { throw Failure.invalidStorage }
        }
    }

    /// Ordered, versioned immutable intent. Native runtime/model identities and consent
    /// are deliberately absent: those require fresh native review before admission.
    struct Intent: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let planID: String
        let planCreatedAt: String
        let planExpiresAt: String
        let options: [String: MCPJSONValue]
        let photos: [[String: MCPJSONValue]]
        var photoCount: Int { photos.count }
        var sha256: String { get throws { try Self.digest(self) } }
        var batchIdentity: String { get throws { try Self.digest(photos) } }

        init(preview: MCPJSONValue) throws {
            guard let value = preview.objectValue, value["schemaVersion"] == .integer(1),
                  value["previewOnly"] == .bool(true), value["executionAvailable"] == .bool(false),
                  value["commitAvailable"] == .bool(false), value["consentGranted"] == .bool(false),
                  let planID = value["planID"]?.stringValue,
                  let createdAt = value["createdAt"]?.stringValue, let expiresAt = value["expiresAt"]?.stringValue,
                  let options = value["options"]?.objectValue, case .array(let items) = value["photos"] else {
                throw Failure.invalidStorage
            }
            schemaVersion = 1; self.planID = planID; planCreatedAt = createdAt; planExpiresAt = expiresAt
            self.options = options
            photos = try items.map { item in
                guard let photo = item.objectValue, let path = photo["canonicalPath"] else { throw Failure.invalidStorage }
                var result = photo.filter { Self.photoKeys.contains($0.key) }
                result["path"] = path
                return result
            }
            try validate()
        }
        fileprivate static let photoKeys = MCPVoiceTranscriptionPlanStore.Request.photoKeys.union(["photoIdentity", "audioIdentity", "rootID"])
        /// Reuse the durable intent contract at native session boundaries, including
        /// values decoded independently of this store. This is structural validation.
        func requireValid() throws { try validate() }
        fileprivate func validate() throws {
            guard schemaVersion == 1, MCPVoiceTranscriptionReviewRequestStore.canonicalUUID(planID),
                  let created = ISO8601DateFormatter().date(from: planCreatedAt),
                  let expiry = ISO8601DateFormatter().date(from: planExpiresAt), expiry > created,
                  expiry <= created.addingTimeInterval(MCPVoiceTranscriptionPlanStore.lifetime),
                  !photos.isEmpty, Set(options.keys) == MCPVoiceTranscriptionPlanStore.Request.keys.subtracting(["photos"]) else {
                throw Failure.invalidStorage
            }
            var arguments = options
            arguments["photos"] = .array(photos.map { .object($0.filter { MCPVoiceTranscriptionPlanStore.Request.photoKeys.contains($0.key) }) })
            _ = try MCPVoiceTranscriptionPlanStore.Request(arguments: arguments)
            for photo in photos {
                guard Set(photo.keys) == Self.photoKeys,
                      MCPVoiceTranscriptionReviewRequestStore.canonicalUUID(photo["rootID"]?.stringValue ?? ""),
                      ["photoIdentity", "audioIdentity"].allSatisfy({ Self.validDigest(photo[$0]?.stringValue ?? "") }) else { throw Failure.invalidStorage }
            }
        }
        fileprivate static func digest<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        }
        fileprivate static func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
    struct Record: Codable, Equatable, Sendable {
        let requestID: String
        let requestEpoch: String
        let intent: Intent
        let intentSHA256: String
        let batchIdentity: String
        let createdAt: Date
        fileprivate(set) var updatedAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var cancellationRequestedAt: Date?
        fileprivate(set) var admission: Admission?
        fileprivate(set) var admittedAt: Date?
        fileprivate(set) var linkedAt: Date?
        /// Only durable linkage exposes an operation handle. Reserved admission IDs are
        /// not acceptance receipts and never authorize work after an interrupted enqueue.
        var operationID: String? { state == .linked ? admission?.operationID : nil }
        var planID: String { intent.planID }
    }
    struct CapacitySnapshot: Equatable, Sendable {
        let epoch: UUID
        let retainedCount: Int
        let maximumRecords: Int
        let cancelledBeforeAdmissionCount: Int
    }
    private struct Archive: Codable { var schemaVersion: Int; var currentEpoch: String; var records: [Record] }
    private struct Envelope: Codable { let payload: Data; let sha256: String }
    let storageDirectory: URL
    private let persistence: AutomationOperationPersistence
    private let maximumRecords: Int
    private let maximumBytes: Int

    init(storageDirectory: URL, maximumRecords: Int = 64, maximumBytes: Int = 1_048_576) {
        self.storageDirectory = storageDirectory
        self.maximumRecords = min(max(0, maximumRecords), 64)
        self.maximumBytes = min(max(0, maximumBytes), 1_048_576)
        persistence = AutomationOperationPersistence(directory: storageDirectory, maximumBytes: self.maximumBytes)
    }
    static func defaultStorageDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Failure.storageUnavailable }
        return base.appendingPathComponent("Aagedal Photo Agent/Automation/.aagedal-photo-agent-voice-transcription-review-requests", isDirectory: true)
    }
    func capacitySnapshot() throws -> CapacitySnapshot {
        try transaction { CapacitySnapshot(epoch: UUID(uuidString: $0.currentEpoch)!, retainedCount: $0.records.count,
            maximumRecords: maximumRecords, cancelledBeforeAdmissionCount: $0.records.filter { $0.state == .cancelled }.count) }
    }
    func records() throws -> [Record] { try transaction(readOnly: true) { $0.records } }
    func inspect(_ requestID: UUID, requestEpoch: UUID) throws -> Record {
        try transaction(readOnly: true) { archive in
            guard let record = archive.records.first(where: { $0.requestID == requestID.uuidString.lowercased() }) else { throw Failure.unknownRequest }
            guard record.requestEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            return record
        }
    }
    /// Exact retries retrieve retained evidence, even if the original plan expired.
    /// New intent is saved with all source/relationship/WAV reservations still held.
    func request(requestID: UUID, requestEpoch: UUID, planID: String,
                 plans: MCPVoiceTranscriptionPlanStore, facade: MCPAutomationFacade, now: Date = Date()) throws -> Record {
        guard Self.canonicalUUID(planID), now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidArguments }
        do {
            let existing = try inspect(requestID, requestEpoch: requestEpoch)
            guard existing.planID == planID else { throw Failure.conflictingRequest }
            return existing
        } catch Failure.unknownRequest { }
        // Refuse stale epochs before touching any photo or plan.
        try transaction(readOnly: true) { archive in
            guard archive.currentEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
        }
        return try plans.withValidatedPreview(planID: planID, facade: facade, now: now) { preview in
            let intent = try Intent(preview: preview)
            guard let created = ISO8601DateFormatter().date(from: intent.planCreatedAt),
                  let expiry = ISO8601DateFormatter().date(from: intent.planExpiresAt), now >= created, now < expiry else { throw Failure.invalidArguments }
            return try transaction { archive in
                let id = requestID.uuidString.lowercased(), epoch = requestEpoch.uuidString.lowercased()
                if let existing = archive.records.first(where: { $0.requestID == id }) {
                    guard existing.requestEpoch == epoch else { throw Failure.staleEpoch }
                    guard existing.intent == intent else { throw Failure.conflictingRequest }
                    return existing
                }
                guard archive.currentEpoch == epoch else { throw Failure.staleEpoch }
                guard archive.records.count < maximumRecords else { throw Failure.capacity }
                let record = Record(requestID: id, requestEpoch: epoch, intent: intent,
                    intentSHA256: try intent.sha256, batchIdentity: try intent.batchIdentity,
                    createdAt: now, updatedAt: now, state: .awaitingReview)
                archive.records.append(record)
                return record
            }
        }
    }
    /// Admission is one-way. Even an exact retry cannot reopen an interrupted admission.
    /// The expected native snapshot binds the hook to the entire retained immutable intent.
    func admit(_ requestID: UUID, requestEpoch: UUID, expected: Record,
               operationID: UUID, ownerID: UUID, registry: AutomationOperationRegistry, now: Date = Date()) throws -> Record {
        do {
            return try registry.withAvailableOperationID(operationID) {
                return try transaction { archive in
                    guard let index = archive.records.firstIndex(where: { $0.requestID == requestID.uuidString.lowercased() }) else { throw Failure.unknownRequest }
                    let record = archive.records[index]
                    guard record.requestEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
                    guard record == expected else { throw Failure.conflictingRequest }
                    guard record.state == .awaitingReview, record.cancellationRequestedAt == nil else { throw Failure.invalidTransition }
                    try Self.validateFreshBoundary(record, now: now)
                    let operation = operationID.uuidString.lowercased()
                    guard !archive.records.contains(where: { $0.admission?.operationID == operation }) else { throw Failure.conflictingRequest }
                    archive.records[index].admission = Admission(schemaVersion: 1, admissionID: UUID().uuidString.lowercased(),
                        requestID: record.requestID, requestEpoch: record.requestEpoch,
                        intentSHA256: record.intentSHA256, batchIdentity: record.batchIdentity,
                        operationID: operation, ownerID: ownerID.uuidString.lowercased())
                    archive.records[index].admittedAt = now
                    archive.records[index].state = .admitted
                    archive.records[index].updatedAt = now
                    return archive.records[index]
                }
            }
        } catch AutomationOperationRegistry.Failure.invalidArguments {
            throw Failure.conflictingRequest
        }
    }

    /// History is locked before request storage. Verify the actual exact reserved record,
    /// never a caller-supplied snapshot or a kind/count/time-only candidate operation.
    func link(_ requestID: UUID, requestEpoch: UUID, operationID: UUID,
              registry: AutomationOperationRegistry, now: Date = Date()) throws -> Record {
        try registry.withLockedRecords { operations in
            try update(requestID, requestEpoch: requestEpoch, now: now) { record in
                guard let admission = record.admission,
                      admission.operationID == operationID.uuidString.lowercased(),
                      let operation = operations.first(where: { $0.id == operationID }),
                      admission.ownerID == operation.ownerID.uuidString.lowercased(),
                      operation.kind == .voiceTranscription, operation.ownerLeaseManaged == true,
                      let admittedAt = record.admittedAt, operation.createdAt >= admittedAt else { throw Failure.invalidTransition }
                // An exact linkage retry retrieves retained status; it never schedules work.
                if record.state == .linked { return }
                guard record.state == .admitted, record.cancellationRequestedAt == nil,
                      operation.state == .queued, operation.cancellationRequestedAt == nil,
                      let progress = operation.batchProgress, progress.itemCount == record.intent.photoCount,
                      progress.items.allSatisfy({ $0.state == .queued && $0.outcome == nil }),
                      now >= operation.updatedAt else { throw Failure.invalidTransition }
                try Self.validateFreshBoundary(record, now: now)
                record.state = .linked; record.linkedAt = now
            }
        }
    }

    /// Called by the retained executor at safe effect boundaries. Storage failure or an
    /// incorrect operation link refuses work; request cancellation is durable evidence.
    func checkCancellation(_ requestID: UUID, requestEpoch: UUID, operationID: UUID) throws {
        let record = try inspect(requestID, requestEpoch: requestEpoch)
        guard record.state == .linked, record.operationID == operationID.uuidString.lowercased() else { throw Failure.invalidTransition }
        if record.cancellationRequestedAt != nil { throw CancellationError() }
    }

    /// Post-admission cancellation preserves uncertain evidence and cannot free capacity.
    func cancel(_ requestID: UUID, requestEpoch: UUID, now: Date = Date()) throws -> Record {
        try update(requestID, requestEpoch: requestEpoch, now: now) { record in
            if record.cancellationRequestedAt != nil { return }
            if record.state == .awaitingReview { record.state = .cancelled }
            record.cancellationRequestedAt = now
        }
    }

    private static func validateFreshBoundary(_ record: Record, now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= record.updatedAt,
              let expiry = ISO8601DateFormatter().date(from: record.intent.planExpiresAt), now < expiry else { throw Failure.invalidArguments }
    }

    /// Proven pre-admission cancellation retains intent without execution.
    func cancelBeforeAdmission(_ requestID: UUID, requestEpoch: UUID, now: Date = Date()) throws -> Record {
        try update(requestID, requestEpoch: requestEpoch, now: now) { record in
            if record.state == .cancelled { return }
            guard record.state == .awaitingReview else { throw Failure.invalidTransition }
            record.state = .cancelled; record.cancellationRequestedAt = now
        }
    }
    /// Explicit native maintenance retires only proven pre-admission cancellations.
    /// Every rotation prevents old handles and retired intent from silently replaying.
    @discardableResult func recoverCancelledCapacity(expectedEpoch: UUID) throws -> UUID {
        try transaction { archive in
            guard archive.currentEpoch == expectedEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            guard archive.records.contains(where: { $0.state == .cancelled }) else { throw Failure.invalidTransition }
            archive.records.removeAll { $0.state == .cancelled }
            let epoch = UUID(); archive.currentEpoch = epoch.uuidString.lowercased(); return epoch
        }
    }
    private func update(_ requestID: UUID, requestEpoch: UUID, now: Date, _ body: (inout Record) throws -> Void) throws -> Record {
        try transaction { archive in
            guard let index = archive.records.firstIndex(where: { $0.requestID == requestID.uuidString.lowercased() }) else { throw Failure.unknownRequest }
            guard archive.records[index].requestEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            guard now.timeIntervalSinceReferenceDate.isFinite, now >= archive.records[index].updatedAt else { throw Failure.invalidArguments }
            let before = archive.records[index]; try body(&archive.records[index])
            if before != archive.records[index] { archive.records[index].updatedAt = now }
            return archive.records[index]
        }
    }
    private func transaction<T>(readOnly: Bool = false, _ body: (inout Archive) throws -> T) throws -> T {
        do {
            return try persistence.transaction(readOnly: readOnly) { data in
                var archive = try data.map(decode) ?? Archive(schemaVersion: 2, currentEpoch: UUID().uuidString.lowercased(), records: [])
                let result = try body(&archive)
                if readOnly { return (result, data ?? Data()) }
                archive.schemaVersion = 2
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let payload = try encoder.encode(archive)
                let bytes = try encoder.encode(Envelope(payload: payload, sha256: Self.digest(payload)))
                guard bytes.count <= maximumBytes else { throw Failure.capacity }
                return (result, bytes)
            }
        } catch let failure as AutomationOperationRegistry.Failure {
            switch failure { case .capacity: throw Failure.capacity; case .invalidStorage: throw Failure.invalidStorage; default: throw Failure.storageUnavailable }
        }
    }
    private func decode(_ bytes: Data) throws -> Archive {
        do {
            guard let outer = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(outer.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard Self.digest(envelope.payload) == envelope.sha256,
                  let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "currentEpoch", "records"],
                  let version = object["schemaVersion"] as? Int, [1, 2].contains(version),
                  let records = object["records"] as? [[String: Any]] else { throw Failure.invalidStorage }
            for record in records {
                let required: Set<String> = ["requestID", "requestEpoch", "intent", "intentSHA256", "batchIdentity", "createdAt", "updatedAt", "state"]
                guard required.isSubset(of: Set(record.keys)), Set(record.keys).isSubset(of: required.union(version == 1 ? ["cancellationRequestedAt"] : ["cancellationRequestedAt", "admission", "admittedAt", "linkedAt"])),
                      !record.values.contains(where: { $0 is NSNull }),
                      let intent = record["intent"] as? [String: Any],
                      Set(intent.keys) == ["schemaVersion", "planID", "planCreatedAt", "planExpiresAt", "options", "photos"] else { throw Failure.invalidStorage }
                if let admission = record["admission"] as? [String: Any] {
                    guard Set(admission.keys) == ["schemaVersion", "admissionID", "requestID", "requestEpoch", "intentSHA256", "batchIdentity", "operationID", "ownerID"],
                          !admission.values.contains(where: { $0 is NSNull }) else { throw Failure.invalidStorage }
                }
                if version == 1 {
                    guard ["awaitingReview", "cancelled"].contains(record["state"] as? String ?? "") else { throw Failure.invalidStorage }
                }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard [1, 2].contains(archive.schemaVersion), Self.canonicalUUID(archive.currentEpoch),
                  archive.records.count <= maximumRecords, Set(archive.records.map(\.requestID)).count == archive.records.count,
                  Set(archive.records.compactMap { $0.admission?.admissionID }).count == archive.records.filter { $0.admission != nil }.count,
                  Set(archive.records.compactMap { $0.admission?.operationID }).count == archive.records.filter { $0.admission != nil }.count else { throw Failure.invalidStorage }
            for record in archive.records {
                try record.intent.validate()
                guard Self.canonicalUUID(record.requestID), Self.canonicalUUID(record.requestEpoch),
                      try record.intent.sha256 == record.intentSHA256, try record.intent.batchIdentity == record.batchIdentity,
                      record.createdAt.timeIntervalSinceReferenceDate.isFinite, record.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      record.updatedAt >= record.createdAt,
                      let planCreated = ISO8601DateFormatter().date(from: record.intent.planCreatedAt),
                      let planExpiry = ISO8601DateFormatter().date(from: record.intent.planExpiresAt),
                      record.createdAt >= planCreated, record.createdAt < planExpiry else { throw Failure.invalidStorage }
                if let time = record.cancellationRequestedAt {
                    guard time.timeIntervalSinceReferenceDate.isFinite, time >= record.createdAt, time <= record.updatedAt else { throw Failure.invalidStorage }
                }
                if let admission = record.admission {
                    try admission.validate(for: record)
                    guard let admittedAt = record.admittedAt, admittedAt.timeIntervalSinceReferenceDate.isFinite,
                          admittedAt >= record.createdAt, admittedAt <= record.updatedAt, admittedAt < planExpiry,
                          record.cancellationRequestedAt.map({ $0 >= admittedAt }) ?? true else { throw Failure.invalidStorage }
                } else { guard record.admittedAt == nil else { throw Failure.invalidStorage } }
                if let linkedAt = record.linkedAt {
                    guard let admittedAt = record.admittedAt, linkedAt.timeIntervalSinceReferenceDate.isFinite,
                          linkedAt >= admittedAt, linkedAt <= record.updatedAt, linkedAt < planExpiry,
                          record.cancellationRequestedAt.map({ $0 >= linkedAt }) ?? true else { throw Failure.invalidStorage }
                }
                switch record.state {
                case .awaitingReview:
                    guard record.cancellationRequestedAt == nil, record.admission == nil, record.linkedAt == nil else { throw Failure.invalidStorage }
                case .cancelled:
                    guard record.cancellationRequestedAt != nil, record.admission == nil, record.linkedAt == nil else { throw Failure.invalidStorage }
                case .admitted:
                    guard record.admission != nil, record.linkedAt == nil else { throw Failure.invalidStorage }
                case .linked:
                    guard record.admission != nil, record.linkedAt != nil else { throw Failure.invalidStorage }
                }
            }
            return archive
        } catch { throw Failure.invalidStorage }
    }
    private static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
