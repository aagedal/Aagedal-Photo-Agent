import CryptoKit
import Foundation

/// Separate transcription intent domain. Checksums detect corruption; they never
/// authenticate consent. Native admission and operation linkage remain unavailable.
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
    enum State: String, Codable, Sendable { case awaitingReview, cancelled }

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
        var planID: String { intent.planID }
    }
    struct CapacitySnapshot: Equatable, Sendable {
        let epoch: UUID
        let retainedCount: Int
        let maximumRecords: Int
        let cancelledBeforeAdmissionCount: Int
    }
    private struct Archive: Codable { let schemaVersion: Int; var currentEpoch: String; var records: [Record] }
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
    /// This milestone has no admission API. Cancellation retains intent without execution.
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
                var archive = try data.map(decode) ?? Archive(schemaVersion: 1, currentEpoch: UUID().uuidString.lowercased(), records: [])
                let result = try body(&archive)
                if readOnly { return (result, data ?? Data()) }
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
                  let records = object["records"] as? [[String: Any]] else { throw Failure.invalidStorage }
            for record in records {
                let required: Set<String> = ["requestID", "requestEpoch", "intent", "intentSHA256", "batchIdentity", "createdAt", "updatedAt", "state"]
                guard required.isSubset(of: Set(record.keys)), Set(record.keys).isSubset(of: required.union(["cancellationRequestedAt"])),
                      !record.values.contains(where: { $0 is NSNull }),
                      let intent = record["intent"] as? [String: Any],
                      Set(intent.keys) == ["schemaVersion", "planID", "planCreatedAt", "planExpiresAt", "options", "photos"] else { throw Failure.invalidStorage }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, Self.canonicalUUID(archive.currentEpoch),
                  archive.records.count <= maximumRecords, Set(archive.records.map(\.requestID)).count == archive.records.count else { throw Failure.invalidStorage }
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
                switch record.state {
                case .awaitingReview: guard record.cancellationRequestedAt == nil else { throw Failure.invalidStorage }
                case .cancelled: guard record.cancellationRequestedAt != nil else { throw Failure.invalidStorage }
                }
            }
            return archive
        } catch { throw Failure.invalidStorage }
    }
    private static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
