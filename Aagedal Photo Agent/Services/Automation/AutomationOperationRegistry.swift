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

    enum BatchItemState: String, Codable, Sendable { case queued, running, completed }
    /// Only closed status evidence is durable; photo identities and metadata stay out.
    enum BatchItemOutcome: String, Codable, Sendable {
        case draftSaved, failed, stale, cancelled, recoveryRequired
    }
    struct BatchItem: Codable, Equatable, Sendable {
        let index: Int
        fileprivate(set) var state: BatchItemState
        fileprivate(set) var outcome: BatchItemOutcome?
    }
    struct BatchProgress: Codable, Equatable, Sendable {
        fileprivate(set) var items: [BatchItem]
        var itemCount: Int { items.count }
        var completedCount: Int { items.filter { $0.state == .completed }.count }
    }

    struct RecoveryResolution: Codable, Equatable, Sendable {
        enum Disposition: String, Codable, Sendable { case unchanged, restored }
        let disposition: Disposition
        let receiptSHA256: String
        let resolvedAt: Date
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
        fileprivate(set) var recoveryResolution: RecoveryResolution?
        fileprivate(set) var batchProgress: BatchProgress?

        var isTerminal: Bool { state == .completed || state == .cancelled }
        var canRemove: Bool {
            isTerminal && ([.verified, .failed, .cancelled, .stale].contains(outcome)
                || recoveryResolution != nil)
        }
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        var records: [Record]
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

    /// Read-only, synchronous evidence access. The operation archive lock remains held
    /// until the callback returns, including any request-archive transaction it performs.
    /// Always acquire operation history before native-review requests; callbacks must
    /// never reenter this registry or launch work that outlives the callback.
    func withLockedRecords<T>(_ body: ([Record]) throws -> T) throws -> T {
        try transaction(readOnly: true) { records in try body(records) }
    }

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

    /// Configure once before any item runs. Indices describe request order, never paths.
    func configureBatch(_ id: UUID, ownerID: UUID, itemCount: Int, now: Date = Date()) throws -> Record {
        guard (1...64).contains(itemCount) else { throw Failure.invalidArguments }
        return try update(id, ownerID: ownerID, now: now) { record in
            guard record.kind == .voiceTranscription, !record.isTerminal, record.cancellationRequestedAt == nil,
                  record.batchProgress == nil else { throw Failure.invalidTransition }
            record.batchProgress = BatchProgress(items: (0..<itemCount).map {
                BatchItem(index: $0, state: .queued)
            })
        }
    }

    func startBatchItem(_ id: UUID, ownerID: UUID, index: Int, now: Date = Date()) throws -> Record {
        try update(id, ownerID: ownerID, now: now) { record in
            guard record.state == .running, record.cancellationRequestedAt == nil,
                  var progress = record.batchProgress else { throw Failure.invalidTransition }
            guard progress.items.indices.contains(index) else { throw Failure.invalidArguments }
            guard progress.items[index].state == .queued,
                  progress.items.prefix(index).allSatisfy({ $0.state == .completed }),
                  !progress.items.contains(where: { $0.state == .running }) else { throw Failure.invalidTransition }
            progress.items[index].state = .running
            record.batchProgress = progress
        }
    }

    /// Cancellation can race a completed save. Preserve the owner's exact result for
    /// the running item, while refusing to start any subsequent item after the request.
    func finishBatchItem(_ id: UUID, ownerID: UUID, index: Int, outcome: BatchItemOutcome,
                         now: Date = Date()) throws -> Record {
        try update(id, ownerID: ownerID, now: now) { record in
            guard record.state == .running, var progress = record.batchProgress else { throw Failure.invalidTransition }
            guard progress.items.indices.contains(index) else { throw Failure.invalidArguments }
            guard progress.items[index].state == .running,
                  outcome != .cancelled || record.cancellationRequestedAt != nil else { throw Failure.invalidTransition }
            progress.items[index].state = .completed
            progress.items[index].outcome = outcome
            record.batchProgress = progress
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
            guard Self.validBatchTerminal(record.batchProgress, outcome: outcome) else { throw Failure.invalidTransition }
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
            guard Self.validBatchTerminal(record.batchProgress, outcome: outcome) else { throw Failure.invalidTransition }
            record.state = .cancelled
            record.outcome = outcome
        }
    }

    func removeTerminal(_ id: UUID, ownerID: UUID) throws {
        try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.unknownOperation }
            guard records[index].ownerID == ownerID else { throw Failure.wrongOwner }
            guard records[index].canRemove else { throw Failure.invalidTransition }
            records.remove(at: index)
        }
    }

    /// Native recovery supplies only an exact resolved journal while retaining its lock.
    /// Preserve the original publication outcome; this receipt proves separate restoration
    /// or unchanged-staging resolution, never successful publication or mutation authority.
    /// An absent record is harmless (legacy material or an explicitly removed record).
    @discardableResult
    func recordRecoveryResolution(_ receipt: MCPIPTCPatchXMPRecoveryStore.HistoryDisposition,
                                  now: Date = Date()) throws -> Record? {
        let id = receipt.operationID
        let disposition: RecoveryResolution.Disposition = receipt.resolution == .restored ? .restored : .unchanged
        let receiptSHA256 = receipt.receiptSHA256
        guard Self.validReceiptDigest(receiptSHA256), now.timeIntervalSinceReferenceDate.isFinite else {
            throw Failure.invalidArguments
        }
        return try transaction { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
            guard records[index].kind == .iptcPatch, records[index].isTerminal else {
                throw Failure.invalidTransition
            }
            // Staging can precede a refusal or clean cancellation. Those confirmed
            // outcomes already permit removal and need no uncertainty-resolution marker.
            guard [.recoveryRequired, .partialUncertain].contains(records[index].outcome) else {
                return records[index]
            }
            if let previous = records[index].recoveryResolution {
                guard previous.disposition == disposition, previous.receiptSHA256 == receiptSHA256 else {
                    throw Failure.invalidTransition
                }
                return records[index]
            }
            guard now >= records[index].updatedAt else { throw Failure.invalidArguments }
            records[index].recoveryResolution = .init(disposition: disposition,
                receiptSHA256: receiptSHA256, resolvedAt: now)
            records[index].updatedAt = now
            return records[index]
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
            let schemaVersion = records.contains(where: { $0.batchProgress != nil }) ? 2 : 1
            let payload = try encoder.encode(Archive(schemaVersion: schemaVersion, records: records))
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
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard [1, 2].contains(archive.schemaVersion),
                  (archive.schemaVersion == 2) == recordObjects.contains(where: { $0["batchProgress"] != nil }) else {
                throw Failure.invalidStorage
            }
            let required: Set<String> = ["id", "ownerID", "kind", "createdAt", "updatedAt", "state"]
            for record in recordObjects {
                guard required.isSubset(of: Set(record.keys)),
                      Set(record.keys).isSubset(of: required.union(["outcome", "cancellationRequestedAt", "ownerLeaseManaged", "recoveryResolution", "batchProgress"])) else { throw Failure.invalidStorage }
                if let progress = record["batchProgress"] {
                    guard let fields = progress as? [String: Any], Set(fields.keys) == ["items"],
                          let items = fields["items"] as? [[String: Any]] else { throw Failure.invalidStorage }
                    for item in items {
                        guard Set(["index", "state"]).isSubset(of: Set(item.keys)),
                              Set(item.keys).isSubset(of: ["index", "state", "outcome"]),
                              item["outcome"] == nil || item["outcome"] is String else { throw Failure.invalidStorage }
                    }
                }
                if let resolution = record["recoveryResolution"] {
                    guard let fields = resolution as? [String: Any],
                          Set(fields.keys) == ["disposition", "receiptSHA256", "resolvedAt"] else { throw Failure.invalidStorage }
                }
            }
            guard archive.records.count <= maximumRecords,
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
                if let progress = record.batchProgress {
                    guard record.kind == .voiceTranscription, Self.validBatch(progress),
                          record.cancellationRequestedAt != nil || !progress.items.contains(where: { $0.outcome == .cancelled }),
                          record.state != .queued || progress.items.allSatisfy({ $0.state == .queued }),
                          !record.isTerminal || Self.validBatchTerminal(progress, outcome: record.outcome!) else {
                        throw Failure.invalidStorage
                    }
                }
                if let resolution = record.recoveryResolution {
                    guard record.kind == .iptcPatch, record.isTerminal,
                          [.recoveryRequired, .partialUncertain].contains(record.outcome),
                          Self.validReceiptDigest(resolution.receiptSHA256),
                          resolution.resolvedAt.timeIntervalSinceReferenceDate.isFinite,
                          resolution.resolvedAt >= record.createdAt, resolution.resolvedAt <= record.updatedAt else {
                        throw Failure.invalidStorage
                    }
                }
            }
            return archive.records
        } catch { throw Failure.invalidStorage }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validBatch(_ progress: BatchProgress) -> Bool {
        guard (1...64).contains(progress.items.count) else { return false }
        var encounteredPending = false
        for (index, item) in progress.items.enumerated() {
            guard item.index == index, (item.state == .completed) == (item.outcome != nil) else { return false }
            if item.state == .completed {
                guard !encounteredPending else { return false }
            } else if item.state == .running {
                guard !encounteredPending else { return false }
                encounteredPending = true
            } else {
                encounteredPending = true
            }
        }
        return true
    }

    private static func validBatchTerminal(_ progress: BatchProgress?, outcome: Outcome) -> Bool {
        guard let progress else { return true }
        if outcome == .verified { return progress.items.allSatisfy { $0.state == .completed && $0.outcome == .draftSaved } }
        if [.failed, .stale, .cancelled].contains(outcome) {
            return !progress.items.contains { $0.state == .running || $0.outcome == .recoveryRequired }
        }
        return true
    }

    private static func validReceiptDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
