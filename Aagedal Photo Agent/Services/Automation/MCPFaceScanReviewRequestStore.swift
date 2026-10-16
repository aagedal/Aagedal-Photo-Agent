import CryptoKit
import Darwin
import Foundation

/// Durable review intent only. No record grants consent, admission, or execution.
nonisolated final class MCPFaceScanReviewRequestStore: Sendable {
    enum Failure: String, Error, Equatable, LocalizedError {
        case invalidArguments = "invalid_arguments"
        case unknownRequest = "unknown_face_scan_review_request"
        case conflictingRequest = "conflicting_face_scan_review_request"
        case staleEpoch = "stale_face_scan_review_request_epoch"
        case expiredRequest = "expired_face_scan_review_request"
        case invalidTransition = "invalid_face_scan_review_request_transition"
        case capacity = "face_scan_review_request_capacity"
        case invalidStorage = "invalid_face_scan_review_request_storage"
        case storageUnavailable = "face_scan_review_request_storage_unavailable"
        var errorDescription: String? {
            switch self {
            case .invalidArguments: "Provide valid face review request arguments."
            case .unknownRequest: "The face review request is not retained."
            case .conflictingRequest: "This request identifier names different face review evidence."
            case .staleEpoch: "Refresh face review capacity and use its current epoch."
            case .expiredRequest: "The original face review preparation expired or its clock witness was lost. Prepare a new request."
            case .invalidTransition: "This face review request cannot enter the requested state."
            case .capacity: "The bounded face review request archive is full."
            case .invalidStorage: "The face review request archive cannot be verified."
            case .storageUnavailable: "Private face review request storage is unavailable."
            }
        }
    }
    enum State: String, Codable, Sendable { case awaitingReview, cancelled }
    struct MonotonicWitness: Codable, Equatable, Sendable {
        let bootSessionID: String
        /// Continuous elapsed boot time, including system sleep.
        let uptime: TimeInterval
    }
    struct Intent: Codable, Equatable, Sendable {
        let canonicalPath: String
        let rootID: String
        let folderIdentity: MCPFileIdentity
        let forceFullScan: Bool
        let includeJerseyNumbers: Bool
        let snapshotRevision: String
        let photoCount: Int
        let preparedAt: Date
        let expiresAt: Date
        let monotonicWitness: MonotonicWitness
    }
    struct Record: Codable, Equatable, Sendable {
        let requestID: String
        let requestEpoch: String
        let intent: Intent
        let intentSHA256: String
        let createdAt: Date
        fileprivate(set) var updatedAt: Date
        fileprivate(set) var state: State
        fileprivate(set) var cancellationRequestedAt: Date?
        var protocolValue: MCPJSONValue {
            var result: [String: MCPJSONValue] = ["schemaVersion": .integer(1),
                "requestID": .string(requestID), "requestEpoch": .string(requestEpoch),
                "status": .string(state.rawValue), "canonicalPath": .string(intent.canonicalPath),
                "rootID": .string(intent.rootID), "snapshotRevision": .string(intent.snapshotRevision),
                "photoCount": .integer(Int64(intent.photoCount)), "forceFullScan": .bool(intent.forceFullScan),
                "includeJerseyNumbers": .bool(intent.includeJerseyNumbers), "intentSHA256": .string(intentSHA256),
                "preparedAt": .string(ISO8601DateFormatter().string(from: intent.preparedAt)),
                "expiresAt": .string(ISO8601DateFormatter().string(from: intent.expiresAt)),
                "executionAvailable": .bool(false), "mutationAuthorized": .bool(false), "modelReadinessChecked": .bool(false)]
            if let cancellationRequestedAt { result["cancellationRequestedAt"] = .string(ISO8601DateFormatter().string(from: cancellationRequestedAt)) }
            return .object(result)
        }
    }
    struct CapacitySnapshot: Equatable, Sendable {
        let epoch: UUID
        let retainedCount: Int
        let maximumRecords: Int
        let cancelledBeforeAdmissionCount: Int
    }
    private struct Archive: Codable { let schemaVersion: Int; var currentEpoch: String; var records: [Record] }
    private struct Envelope: Codable { let payload: Data; let sha256: String }
    static let lifetime: TimeInterval = 300
    let storageDirectory: URL
    private let persistence: AutomationOperationPersistence
    private let maximumRecords: Int
    private let maximumBytes: Int
    private let clock: @Sendable () -> Date
    private let monotonicWitness: @Sendable () -> MonotonicWitness?

    init(storageDirectory: URL, maximumRecords: Int = 64, maximumBytes: Int = 1_048_576,
         clock: @escaping @Sendable () -> Date = { Date() },
         monotonicWitness: @escaping @Sendable () -> MonotonicWitness? = { MCPFaceScanReviewRequestStore.systemWitness() }) {
        self.storageDirectory = storageDirectory
        self.maximumRecords = min(max(0, maximumRecords), 64)
        self.maximumBytes = min(max(0, maximumBytes), 1_048_576)
        self.clock = clock; self.monotonicWitness = monotonicWitness
        persistence = AutomationOperationPersistence(directory: storageDirectory, maximumBytes: self.maximumBytes)
    }
    static func defaultStorageDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw Failure.storageUnavailable }
        return base.appendingPathComponent("Aagedal Photo Agent/Automation/.aagedal-photo-agent-face-scan-review-requests", isDirectory: true)
    }
    func capacitySnapshot() throws -> CapacitySnapshot {
        try transaction { CapacitySnapshot(epoch: UUID(uuidString: $0.currentEpoch)!, retainedCount: $0.records.count,
            maximumRecords: maximumRecords, cancelledBeforeAdmissionCount: $0.records.filter { $0.state == .cancelled }.count) }
    }
    func records() throws -> [Record] { try transaction(readOnly: true) { $0.records } }
    /// Status retrieval never refreshes the preparation window or implies freshness.
    func inspect(_ requestID: UUID, requestEpoch: UUID) throws -> Record {
        try transaction(readOnly: true) { archive in
            guard let record = archive.records.first(where: { $0.requestID == requestID.uuidString.lowercased() }) else { throw Failure.unknownRequest }
            guard record.requestEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            return record
        }
    }
    func request(requestID: UUID, requestEpoch: UUID, arguments: [String: MCPJSONValue],
                 admission: MCPFaceScanAdmissionService) throws -> Record {
        let request = try MCPFaceScanAdmissionService.Request(arguments: arguments)
        // The original evidence wins on exact retry, even after expiry/cancellation.
        do {
            let existing = try inspect(requestID, requestEpoch: requestEpoch)
            guard existing.intent.canonicalPath == URL(fileURLWithPath: request.path).standardizedFileURL.path,
                  existing.intent.forceFullScan == request.forceFullScan,
                  existing.intent.includeJerseyNumbers == request.includeJerseyNumbers else { throw Failure.conflictingRequest }
            return existing
        } catch Failure.unknownRequest { }
        try transaction(readOnly: true) { archive in
            guard archive.currentEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            guard archive.records.count < maximumRecords else { throw Failure.capacity }
        }
        let start = clock()
        guard start.timeIntervalSinceReferenceDate.isFinite, let witness = monotonicWitness(), Self.valid(witness) else { throw Failure.expiredRequest }
        let prepared = try admission.prepare(arguments: arguments)
        let intent = Intent(canonicalPath: prepared.folderURL.path, rootID: prepared.rootID.uuidString.lowercased(),
            folderIdentity: prepared.folderIdentity, forceFullScan: prepared.forceFullScan,
            includeJerseyNumbers: prepared.includeJerseyNumbers, snapshotRevision: prepared.snapshotRevision,
            photoCount: prepared.imageURLs.count, preparedAt: start, expiresAt: start.addingTimeInterval(Self.lifetime), monotonicWitness: witness)
        try validateFreshness(intent)
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= start, now < intent.expiresAt else { throw Failure.expiredRequest }
        return try transaction { archive in
            let id = requestID.uuidString.lowercased(), epoch = requestEpoch.uuidString.lowercased()
            if let existing = archive.records.first(where: { $0.requestID == id }) {
                guard existing.requestEpoch == epoch else { throw Failure.staleEpoch }
                // Concurrent identical submissions retain the winner's original lifetime.
                guard Self.samePreparation(existing.intent, intent) else { throw Failure.conflictingRequest }
                return existing
            }
            guard archive.currentEpoch == epoch else { throw Failure.staleEpoch }
            guard archive.records.count < maximumRecords else { throw Failure.capacity }
            try validateFreshness(intent)
            let record = Record(requestID: id, requestEpoch: epoch, intent: intent, intentSHA256: try Self.intentDigest(intent),
                createdAt: now, updatedAt: now, state: .awaitingReview)
            archive.records.append(record); return record
        }
    }
    func validateFreshness(_ record: Record) throws {
        guard let id = UUID(uuidString: record.requestID), let epoch = UUID(uuidString: record.requestEpoch) else { throw Failure.invalidArguments }
        guard try inspect(id, requestEpoch: epoch) == record else { throw Failure.conflictingRequest }
        guard record.state == .awaitingReview else { throw Failure.invalidTransition }
        try validateFreshness(record.intent)
    }
    /// A no-I/O final publication guard after off-thread revalidation. This checks
    /// only the original lifetime and state; it grants no current storage authority.
    func checkLifetime(_ record: Record) throws {
        guard record.state == .awaitingReview else { throw Failure.invalidTransition }
        try validateFreshness(record.intent)
    }
    private func validateFreshness(_ intent: Intent) throws {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= intent.preparedAt, now < intent.expiresAt,
              let witness = monotonicWitness(), Self.valid(witness),
              witness.bootSessionID == intent.monotonicWitness.bootSessionID,
              witness.uptime >= intent.monotonicWitness.uptime,
              witness.uptime - intent.monotonicWitness.uptime < Self.lifetime else { throw Failure.expiredRequest }
    }
    /// Fresh rooted recapture checks authority and complete inventory without renewing time.
    func revalidate(_ record: Record, admission: MCPFaceScanAdmissionService) throws -> MCPFaceScanAdmissionService.PreparedFolder {
        guard let id = UUID(uuidString: record.requestID), let epoch = UUID(uuidString: record.requestEpoch) else { throw Failure.invalidArguments }
        try validateFreshness(record)
        let prepared = try admission.prepare(arguments: ["path": .string(record.intent.canonicalPath),
            "forceFullScan": .bool(record.intent.forceFullScan), "includeJerseyNumbers": .bool(record.intent.includeJerseyNumbers)])
        guard prepared.folderURL.path == record.intent.canonicalPath,
              prepared.rootID.uuidString.lowercased() == record.intent.rootID,
              prepared.folderIdentity == record.intent.folderIdentity,
              prepared.snapshotRevision == record.intent.snapshotRevision,
              prepared.imageURLs.count == record.intent.photoCount else { throw MCPFaceScanAdmissionService.Failure.staleSnapshot }
        try validateFreshness(record)
        guard try inspect(id, requestEpoch: epoch) == record else { throw Failure.conflictingRequest }
        return prepared
    }
    func cancel(_ requestID: UUID, requestEpoch: UUID) throws -> Record {
        try transaction { archive in
            guard let index = archive.records.firstIndex(where: { $0.requestID == requestID.uuidString.lowercased() }) else { throw Failure.unknownRequest }
            guard archive.records[index].requestEpoch == requestEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            if archive.records[index].state == .cancelled { return archive.records[index] }
            let now = clock()
            guard now.timeIntervalSinceReferenceDate.isFinite, now >= archive.records[index].updatedAt else { throw Failure.invalidArguments }
            archive.records[index].state = .cancelled
            archive.records[index].cancellationRequestedAt = now; archive.records[index].updatedAt = now
            return archive.records[index]
        }
    }
    @discardableResult func recoverCancelledCapacity(expectedEpoch: UUID) throws -> UUID {
        try transaction { archive in
            guard archive.currentEpoch == expectedEpoch.uuidString.lowercased() else { throw Failure.staleEpoch }
            guard archive.records.contains(where: { $0.state == .cancelled }) else { throw Failure.invalidTransition }
            archive.records.removeAll { $0.state == .cancelled }
            let epoch = UUID(); archive.currentEpoch = epoch.uuidString.lowercased(); return epoch
        }
    }
    private static func samePreparation(_ a: Intent, _ b: Intent) -> Bool {
        a.canonicalPath == b.canonicalPath && a.rootID == b.rootID && a.folderIdentity == b.folderIdentity
            && a.forceFullScan == b.forceFullScan && a.includeJerseyNumbers == b.includeJerseyNumbers
            && a.snapshotRevision == b.snapshotRevision && a.photoCount == b.photoCount
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
                let required: Set<String> = ["requestID", "requestEpoch", "intent", "intentSHA256", "createdAt", "updatedAt", "state"]
                guard required.isSubset(of: Set(record.keys)), Set(record.keys).isSubset(of: required.union(["cancellationRequestedAt"])),
                      !record.values.contains(where: { $0 is NSNull }), let intent = record["intent"] as? [String: Any],
                      Set(intent.keys) == ["canonicalPath", "rootID", "folderIdentity", "forceFullScan", "includeJerseyNumbers", "snapshotRevision", "photoCount", "preparedAt", "expiresAt", "monotonicWitness"],
                      let identity = intent["folderIdentity"] as? [String: Any], Set(identity.keys) == ["device", "inode"],
                      let witness = intent["monotonicWitness"] as? [String: Any], Set(witness.keys) == ["bootSessionID", "uptime"] else { throw Failure.invalidStorage }
            }
            let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
            guard archive.schemaVersion == 1, Self.canonicalUUID(archive.currentEpoch), archive.records.count <= maximumRecords,
                  Set(archive.records.map(\.requestID)).count == archive.records.count else { throw Failure.invalidStorage }
            for record in archive.records {
                let i = record.intent
                guard Self.canonicalUUID(record.requestID), Self.canonicalUUID(record.requestEpoch), Self.canonicalUUID(i.rootID),
                      i.canonicalPath.hasPrefix("/"), !i.canonicalPath.contains("\0"), i.canonicalPath.utf8.count <= 4096,
                      URL(fileURLWithPath: i.canonicalPath).standardizedFileURL.path == i.canonicalPath,
                      !i.includeJerseyNumbers || i.forceFullScan,
                      i.snapshotRevision.hasPrefix("sha256:"), Self.validDigest(String(i.snapshotRevision.dropFirst(7))),
                      i.photoCount > 0, i.photoCount <= MCPFaceScanAdmissionService.maximumPhotos,
                      Self.valid(i.monotonicWitness), i.preparedAt.timeIntervalSinceReferenceDate.isFinite,
                      i.expiresAt.timeIntervalSinceReferenceDate.isFinite, i.expiresAt.timeIntervalSince(i.preparedAt) == Self.lifetime,
                      record.createdAt.timeIntervalSinceReferenceDate.isFinite, record.createdAt >= i.preparedAt, record.createdAt < i.expiresAt,
                      record.updatedAt.timeIntervalSinceReferenceDate.isFinite, record.updatedAt >= record.createdAt,
                      try Self.intentDigest(i) == record.intentSHA256 else { throw Failure.invalidStorage }
                switch record.state {
                case .awaitingReview: guard record.cancellationRequestedAt == nil, record.updatedAt == record.createdAt else { throw Failure.invalidStorage }
                case .cancelled:
                    guard let time = record.cancellationRequestedAt, time.timeIntervalSinceReferenceDate.isFinite,
                          time >= record.createdAt, time == record.updatedAt else { throw Failure.invalidStorage }
                }
            }
            return archive
        } catch { throw Failure.invalidStorage }
    }
    private static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    private static func validDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func valid(_ value: MonotonicWitness) -> Bool { canonicalUUID(value.bootSessionID) && value.uptime.isFinite && value.uptime >= 0 }
    private static func intentDigest(_ intent: Intent) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(intent))
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func systemWitness() -> MonotonicWitness? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size <= 128 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let id = String(cString: buffer).lowercased()
        guard canonicalUUID(id) else { return nil }
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return nil }
        let elapsed = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return MonotonicWitness(bootSessionID: id, uptime: elapsed)
    }
}
