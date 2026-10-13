import CryptoKit
import Foundation

/// Bounded private coordination evidence. No photo paths, names, face identities,
/// embeddings, error text or native consent claims enter this archive. Physical
/// thumbnail UUIDs are retained only for exact completion/recovery correlation.
nonisolated final class MCPFaceScanReceiptStore: Sendable {
    enum Failure: Error, Equatable { case capacity, invalidStorage, invalidTransition }
    enum Phase: String, Codable, Sendable { case admitted, executionPossible, completed }
    struct Completion: Codable, Equatable, Sendable {
        var outcome: AutomationOperationRegistry.Outcome
        let processedCount: Int
        let failureCount: Int
        let unsignedFileCount: Int
        let committedThumbnailCount: Int
        let committedDocumentCount: Int
        let resetCommitted: Bool
        let persistenceFailed: Bool
        var committedThumbnailIDs: [UUID] = []
        var documents: [DocumentEvidence] = []
        var reset: ResetEvidence? = nil
        var submissionMismatch: Bool = false
        var completionUnavailable: Bool = false
        var coordinationFailed: Bool = false
    }
    struct DocumentEvidence: Codable, Equatable, Sendable {
        enum Result: String, Codable, Sendable { case committed, cancelledBeforeCommit, failedBeforeCommit }
        let result: Result
        let documentCommitted: Bool
        let requestedThumbnailDeletionCount: Int
        let deletedThumbnailIDs: [UUID]
        let failedThumbnailIDs: [UUID]
        let cancellationRequestedAfterCommit: Bool
        let authorityRefused: Bool
    }
    struct ResetEvidence: Codable, Equatable, Sendable {
        enum Result: String, Codable, Sendable { case committed, committedButUnverified, cancelledBeforeCommit, failed }
        let result: Result
        let cancellationRequestedAfterCommit: Bool
    }
    struct Receipt: Codable, Equatable, Sendable {
        let intentID: UUID
        let operationID: UUID
        let snapshotRevision: String
        let photoCount: Int
        let forceFullScan: Bool
        let includeJerseyNumbers: Bool
        var phase: Phase
        var completion: Completion?
    }
    private struct Archive: Codable { let version: Int; var receipts: [Receipt] }
    private struct Envelope: Codable { let payload: Data; let sha256: String }
    private let persistence: AutomationOperationPersistence
    private let maximumReceipts: Int

    init(storageDirectory: URL, maximumReceipts: Int = 256, maximumBytes: Int = 1_048_576) {
        persistence = .init(directory: storageDirectory, maximumBytes: min(max(0, maximumBytes), 1_048_576))
        self.maximumReceipts = min(max(0, maximumReceipts), 256)
    }

    /// Resolving the managed location does not create an archive. UI tests must
    /// explicitly supply disposable storage rather than inspecting personal history.
    static func defaultStorageDirectory(applicationSupportDirectory: URL? = nil,
                                        arguments: [String] = ProcessInfo.processInfo.arguments) throws -> URL {
        if arguments.contains("--ui-testing") {
            guard let index = arguments.firstIndex(of: "--ui-test-face-receipt-root"),
                  arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/"),
                  !arguments[index + 1].contains("\0") else {
                throw AutomationOperationRegistry.Failure.storageUnavailable
            }
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        guard let base = applicationSupportDirectory
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              base.isFileURL, base.path.hasPrefix("/") else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        return base.appendingPathComponent("Aagedal Photo Agent", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("FaceScanReceipts", isDirectory: true)
    }

    func admit(intent: MCPFaceScanIntentStore.Intent, operationID: UUID) throws {
        try transaction { receipts in
            guard !receipts.contains(where: { $0.intentID == intent.id || $0.operationID == operationID }) else {
                throw Failure.invalidTransition
            }
            guard receipts.count < maximumReceipts else { throw Failure.capacity }
            receipts.append(.init(intentID: intent.id, operationID: operationID,
                snapshotRevision: intent.prepared.snapshotRevision, photoCount: intent.prepared.imageURLs.count,
                forceFullScan: intent.prepared.forceFullScan, includeJerseyNumbers: intent.prepared.includeJerseyNumbers,
                phase: .admitted))
        }
    }

    func markExecutionPossible(_ id: UUID) throws {
        try transaction { receipts in
            guard let index = receipts.firstIndex(where: { $0.operationID == id }), receipts[index].phase == .admitted else {
                throw Failure.invalidTransition
            }
            receipts[index].phase = .executionPossible
        }
    }

    func complete(_ id: UUID, evidence: Completion) throws {
        try transaction { receipts in
            guard let index = receipts.firstIndex(where: { $0.operationID == id }), receipts[index].phase == .executionPossible else {
                throw Failure.invalidTransition
            }
            receipts[index].phase = .completed
            receipts[index].completion = evidence
        }
    }

    func receipts() throws -> [Receipt] { try transaction(readOnly: true) { $0 } }

    private func transaction<T>(readOnly: Bool = false, _ body: (inout [Receipt]) throws -> T) throws -> T {
        try persistence.transaction(readOnly: readOnly) { existing in
            var receipts: [Receipt] = []
            if let existing {
                do {
                    guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any],
                          Set(object.keys) == ["payload", "sha256"] else { throw Failure.invalidStorage }
                    let envelope = try JSONDecoder().decode(Envelope.self, from: existing)
                    guard Self.digest(envelope.payload) == envelope.sha256 else { throw Failure.invalidStorage }
                    guard let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
                          Set(object.keys) == ["version", "receipts"],
                          let entries = object["receipts"] as? [[String: Any]] else { throw Failure.invalidStorage }
                    for entry in entries {
                        let required: Set<String> = ["intentID", "operationID", "snapshotRevision", "photoCount",
                            "forceFullScan", "includeJerseyNumbers", "phase"]
                        guard required.isSubset(of: Set(entry.keys)),
                              Set(entry.keys).isSubset(of: required.union(["completion"])) else { throw Failure.invalidStorage }
                        if let completion = entry["completion"] {
                            guard let fields = completion as? [String: Any], Set(fields.keys) == Set(["outcome",
                                "processedCount", "failureCount", "unsignedFileCount", "committedThumbnailCount",
                                "committedDocumentCount", "resetCommitted", "persistenceFailed", "committedThumbnailIDs", "documents", "reset", "submissionMismatch", "completionUnavailable", "coordinationFailed"]).subtracting(fields["reset"] == nil ? ["reset"] : []) else { throw Failure.invalidStorage }
                            guard let documents = fields["documents"] as? [[String: Any]] else { throw Failure.invalidStorage }
                            for document in documents {
                                guard Set(document.keys) == ["result", "documentCommitted", "requestedThumbnailDeletionCount",
                                    "deletedThumbnailIDs", "failedThumbnailIDs", "cancellationRequestedAfterCommit", "authorityRefused"] else {
                                    throw Failure.invalidStorage
                                }
                            }
                            if let reset = fields["reset"] {
                                guard let reset = reset as? [String: Any],
                                      Set(reset.keys) == ["result", "cancellationRequestedAfterCommit"] else { throw Failure.invalidStorage }
                            }
                        }
                    }
                    let archive = try JSONDecoder().decode(Archive.self, from: envelope.payload)
                    guard archive.version == 1 else { throw Failure.invalidStorage }
                    receipts = archive.receipts
                    try validate(receipts)
                } catch { throw Failure.invalidStorage }
            }
            let result = try body(&receipts)
            if readOnly { return (result, existing ?? Data()) }
            try validate(receipts)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(Archive(version: 1, receipts: receipts))
            return (result, try encoder.encode(Envelope(payload: payload, sha256: Self.digest(payload))))
        }
    }

    private func validate(_ receipts: [Receipt]) throws {
        guard receipts.count <= maximumReceipts, Set(receipts.map(\.intentID)).count == receipts.count,
              Set(receipts.map(\.operationID)).count == receipts.count else { throw Failure.invalidStorage }
        for receipt in receipts {
            let digest = receipt.snapshotRevision.dropFirst(7)
            guard receipt.snapshotRevision.hasPrefix("sha256:"), digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  (1...MCPFaceScanAdmissionService.maximumPhotos).contains(receipt.photoCount),
                  !receipt.includeJerseyNumbers || receipt.forceFullScan,
                  (receipt.phase == .completed) == (receipt.completion != nil) else { throw Failure.invalidStorage }
            if let completion = receipt.completion {
                guard [completion.processedCount, completion.failureCount, completion.unsignedFileCount,
                       completion.committedThumbnailCount, completion.committedDocumentCount].allSatisfy({ (0...1_000_000).contains($0) }),
                      completion.processedCount <= MCPFaceScanAdmissionService.maximumPhotos,
                      completion.failureCount <= MCPFaceScanAdmissionService.maximumPhotos,
                      completion.unsignedFileCount <= MCPFaceScanAdmissionService.maximumPhotos,
                      completion.committedThumbnailIDs.count == completion.committedThumbnailCount,
                      completion.documents.count <= 100_000,
                      completion.documents.filter({ $0.documentCommitted }).count == completion.committedDocumentCount else { throw Failure.invalidStorage }
                for document in completion.documents {
                    guard (0...1_000_000).contains(document.requestedThumbnailDeletionCount),
                          document.deletedThumbnailIDs.count <= document.requestedThumbnailDeletionCount,
                          document.failedThumbnailIDs.count <= document.requestedThumbnailDeletionCount,
                          document.result == .committed || (!document.documentCommitted
                              && document.requestedThumbnailDeletionCount == 0
                              && document.deletedThumbnailIDs.isEmpty && document.failedThumbnailIDs.isEmpty
                              && !document.cancellationRequestedAfterCommit && !document.authorityRefused) else {
                        throw Failure.invalidStorage
                    }
                }
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
