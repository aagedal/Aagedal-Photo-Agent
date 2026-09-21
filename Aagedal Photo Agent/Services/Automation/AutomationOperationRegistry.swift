import CryptoKit
import Foundation

/// Durable coordination records, not execution or mutation authority. Owners must check
/// cancellation at safe boundaries and report outcomes only after verifying real work.
nonisolated final class AutomationOperationRegistry: Sendable {
    enum Failure: Error, Equatable {
        case invalidArguments, unknownOperation, wrongOwner, invalidTransition
        case capacity, storageUnavailable, invalidStorage
    }

    enum State: String, Codable, Sendable { case queued, running, completed, cancelled }
    /// Deliberately closed: durable history must never accept filenames or metadata.
    enum Kind: String, Codable, Sendable {
        case faceScan = "face_scan"
        case metadataTemplate = "metadata_template"
        case developTemplate = "develop_template"
        case voiceTranscription = "voice_transcription"
        case iptcPatch = "iptc_patch"
        case iptcDraft = "iptc_draft"
    }
    enum Outcome: String, Codable, Sendable {
        case verified, failed, cancelled, partialUncertain, recoveryRequired, stale
    }

    struct Record: Codable, Equatable, Sendable {
        let id: UUID
        let ownerID: UUID
        let kind: Kind
        let createdAt: Date
        let ownerLeaseManaged: Bool?
        fileprivate(set) var updatedAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var outcome: Outcome?
        fileprivate(set) var cancellationRequestedAt: Date?

        var isTerminal: Bool { state == .completed || state == .cancelled }
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        var records: [Record]
    }
    private struct Envelope: Codable { let payload: Data; let sha256: String }

    private let persistence: AutomationOperationPersistence
    private let maximumRecords: Int
    private let maximumBytes: Int

    init(storageDirectory: URL, maximumRecords: Int = 256, maximumBytes: Int = 1_048_576) {
        self.maximumRecords = min(max(0, maximumRecords), 256)
        self.maximumBytes = min(max(0, maximumBytes), 1_048_576)
        persistence = AutomationOperationPersistence(directory: storageDirectory,
            maximumBytes: min(max(0, maximumBytes), 1_048_576))
    }

    /// Shared by the unsandboxed app and helper. Resolving the location creates no files.
    static func defaultStorageDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("Operations", isDirectory: true)
    }

    /// No implicit eviction: retained records remain inspectable until explicitly removed.
    func enqueue(kind: Kind, ownerID: UUID, now: Date = Date(), ownerLease: AutomationOperationPersistence.OwnerLease? = nil) throws -> Record {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidArguments }
        if let ownerLease { try persistence.validateOwnerLease(ownerLease, ownerID: ownerID) }
        return try transaction { records in
            guard records.count < maximumRecords else { throw Failure.capacity }
            let record = Record(id: UUID(), ownerID: ownerID, kind: kind, createdAt: now,
                ownerLeaseManaged: ownerLease == nil ? nil : true, updatedAt: now, state: .queued)
            records.append(record)
            return record
        }
    }

    func records() throws -> [Record] { try transaction(readOnly: true) { $0 } }

    func inspect(_ id: UUID) throws -> Record {
        try transaction(readOnly: true) { records in
            guard let record = records.first(where: { $0.id == id }) else { throw Failure.unknownOperation }
            return record
        }
    }

    func start(_ id: UUID, ownerID: UUID, now: Date = Date()) throws -> Record {
        try update(id, ownerID: ownerID, now: now) { record in
            guard record.state == .queued, record.cancellationRequestedAt == nil else { throw Failure.invalidTransition }
            record.state = .running
        }
    }

    /// Any authorized coordinator can request cancellation; only the actual owner can
    /// acknowledge it. Repeated requests and requests after completion are harmless.
    func requestCancellation(_ id: UUID, now: Date = Date()) throws -> Record {
        try update(id, ownerID: nil, now: now) { record in
            if !record.isTerminal, record.cancellationRequestedAt == nil { record.cancellationRequestedAt = now }
        }
    }

    func finish(_ id: UUID, ownerID: UUID, outcome: Outcome, now: Date = Date()) throws -> Record {
        try update(id, ownerID: ownerID, now: now) { record in
            guard !record.isTerminal, outcome != .cancelled,
                  outcome != .verified || record.state == .running else { throw Failure.invalidTransition }
            record.state = .completed
            record.outcome = outcome
        }
    }

    /// `.cancelled` means no uncertain effects remain; owners use partialUncertain or
    /// recoveryRequired when cancellation left effects that still need reconciliation.
    func acknowledgeCancellation(_ id: UUID, ownerID: UUID, outcome: Outcome = .cancelled,
                                 now: Date = Date()) throws -> Record {
        try update(id, ownerID: ownerID, now: now) { record in
            guard !record.isTerminal, record.cancellationRequestedAt != nil,
                  [.cancelled, .partialUncertain, .recoveryRequired].contains(outcome) else { throw Failure.invalidTransition }
            record.state = .cancelled
            record.outcome = outcome
        }
    }

    func removeTerminal(_ id: UUID, ownerID: UUID) throws {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.unknownOperation }
            guard records[index].ownerID == ownerID else { throw Failure.wrongOwner }
            guard records[index].isTerminal else { throw Failure.invalidTransition }
            records.remove(at: index)
        }
    }

    /// The caller must establish that this owner has stopped and can no longer execute
    /// work before calling. Neither loading records nor elapsed time proves owner death.
    /// Close its unresolved records with recoveryRequired, retaining their identity and
    /// cancellation evidence without claiming that effects succeeded or were cancelled.
    /// Returns only changed records; repeating reconciliation leaves timestamps intact.
    func reconcileStoppedOwner(ownerID: UUID, now: Date = Date()) throws -> [Record] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidArguments }
        return try transaction { records in
            let indices = records.indices.filter { records[$0].ownerID == ownerID && !records[$0].isTerminal }
            // Validate the whole batch before changing any record, including on clock rollback.
            guard indices.allSatisfy({ now >= records[$0].updatedAt }) else { throw Failure.invalidArguments }
            return indices.map { index in
                records[index].state = .completed
                records[index].outcome = .recoveryRequired
                records[index].updatedAt = now
                return records[index]
            }
        }
    }

    func acquireOwnerLease(ownerID: UUID) throws -> AutomationOperationPersistence.OwnerLease {
        guard let lease = try persistence.acquireOwnerLease(ownerID: ownerID, create: true) else {
            throw Failure.storageUnavailable
        }
        return lease
    }

    /// Only a released kernel lock proves abandonment. Missing evidence, legacy
    /// records, elapsed time and process IDs never establish that writes have stopped.
    /// Work is never replayed: uncertain effects always require explicit recovery.
    func reconcileAbandonedOwners(now: Date = Date()) throws -> [Record] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidArguments }
        var leases: [AutomationOperationPersistence.OwnerLease] = []
        defer { withExtendedLifetime(leases) {} }
        return try transaction { records in
            let owners = Set(records.filter { !$0.isTerminal && $0.ownerLeaseManaged == true }.map(\.ownerID))
            var stopped = Set<UUID>()
            for owner in owners {
                if let lease = try persistence.acquireOwnerLease(ownerID: owner, create: false) {
                    leases.append(lease)
                    stopped.insert(owner)
                }
            }
            let indices = records.indices.filter {
                !records[$0].isTerminal && records[$0].ownerLeaseManaged == true && stopped.contains(records[$0].ownerID)
            }
            guard indices.allSatisfy({ now >= records[$0].updatedAt }) else { throw Failure.invalidArguments }
            return indices.map { index in
                records[index].state = .completed
                records[index].outcome = .recoveryRequired
                records[index].updatedAt = now
                return records[index]
            }
        }
    }

    private func update(_ id: UUID, ownerID: UUID?, now: Date,
                        body: (inout Record) throws -> Void) throws -> Record {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.unknownOperation }
            if let ownerID, records[index].ownerID != ownerID { throw Failure.wrongOwner }
            guard now.timeIntervalSinceReferenceDate.isFinite, now >= records[index].updatedAt else { throw Failure.invalidArguments }
            let before = records[index]
            try body(&records[index])
            if records[index] != before { records[index].updatedAt = now }
            return records[index]
        }
    }

    private func transaction<T>(readOnly: Bool = false, _ body: (inout [Record]) throws -> T) throws -> T {
        try persistence.transaction(readOnly: readOnly) { data in
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
    }

    private func decode(_ data: Data) throws -> [Record] {
        do {
            guard let envelopeObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(envelopeObject.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard Self.digest(envelope.payload) == envelope.sha256,
                  let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "records"],
                  let recordObjects = object["records"] as? [[String: Any]] else { throw Failure.invalidStorage }
            let required: Set<String> = ["id", "ownerID", "kind", "createdAt", "updatedAt", "state"]
            for record in recordObjects {
                guard required.isSubset(of: Set(record.keys)),
                      Set(record.keys).isSubset(of: required.union(["outcome", "cancellationRequestedAt", "ownerLeaseManaged"])) else { throw Failure.invalidStorage }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, archive.records.count <= maximumRecords,
                  Set(archive.records.map(\.id)).count == archive.records.count else { throw Failure.invalidStorage }
            for record in archive.records {
                guard record.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      record.updatedAt.timeIntervalSinceReferenceDate.isFinite, record.updatedAt >= record.createdAt,
                      record.isTerminal == (record.outcome != nil) else { throw Failure.invalidStorage }
                if let requested = record.cancellationRequestedAt {
                    guard requested >= record.createdAt, requested <= record.updatedAt else { throw Failure.invalidStorage }
                }
                if record.state == .cancelled {
                    guard record.cancellationRequestedAt != nil,
                          [.cancelled, .partialUncertain, .recoveryRequired].contains(record.outcome) else { throw Failure.invalidStorage }
                } else if record.outcome == .cancelled { throw Failure.invalidStorage }
            }
            return archive.records
        } catch { throw Failure.invalidStorage }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
