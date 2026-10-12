import CryptoKit
import Darwin
import Foundation

nonisolated struct DevelopTemplateBatchCheckpointInventoryEntry: Sendable, Identifiable {
    enum Issue: String, Sendable { case corrupt, newerVersion, unavailable }
    let id: String
    let checkpoint: DevelopTemplateBatchCheckpoint?
    let issue: Issue?
}

nonisolated enum DevelopTemplateBatchCheckpointError: Error, Equatable {
    case invalidCheckpoint, corruptCheckpoint, unsupportedVersion, immutableIntentChanged, receiptChanged, terminalCheckpoint
}

/// Durable evidence for native recovery presentation. Loading never grants permission to
/// replay a write: original carriers, rooted authority and fresh consent remain required.
nonisolated struct DevelopTemplateBatchCheckpoint: Codable, Sendable {
    let formatVersion: Int
    let batchID: UUID
    let sequence: UInt64
    let outcome: DevelopTemplateBatchExecutionResult.Outcome
    let activeRequestID: UUID?
    let completedCount: Int
    let recoveryData: Data
    let sha256: String
    let immutableIntentData: Data
    let receipts: [Data?]
    var needsReview: Bool {
        activeRequestID != nil || outcome == .prepared || outcome == .running || outcome == .recoveryRequired
    }
}

/// One private journal per captured batch. The shared anchored persistence primitive
/// locks reload/replacement across instances, refuses symlinks, and fsyncs file and parents.
/// An existing corrupt or newer checkpoint is refused, never replaced.
actor DevelopTemplateBatchCheckpointStore {
    private let directory: URL
    private static let receiptKeys: Set<String> = ["wroteEmbedded", "embeddedMayHaveBeenWritten",
        "writtenSourceRevision", "wroteXMP", "writtenXMPData", "committedButUnverifiedJSON",
        "installedRecord", "wasCancelled", "failure"]

    init(directory: URL) { self.directory = directory }

    func retain(_ result: DevelopTemplateBatchExecutionResult) throws {
        guard result.results.count == result.intent.requests.count,
              zip(result.intent.requests, result.results).allSatisfy({ request, receipt in
                  receipt == nil || receipt?.requestID == request.id
              }) else { throw DevelopTemplateBatchCheckpointError.invalidCheckpoint }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(result.recoveryPayload)
        guard payload.count <= DevelopTemplateBatchExecutionService.maximumRecoveryBytes else {
            throw DevelopTemplateBatchFailure.retentionLimit
        }
        let parts = try Self.parts(payload)
        let receipts = try zip(parts.photos, result.results).map { photo, receipt -> Data? in
            guard let receipt else { return nil }
            return try Self.receiptData(photo, completed: receipt.completed)
        }
        try persistence(result.intent.id).transaction { existing in
            let previous = try existing.map { try Self.decode($0, batchID: result.intent.id) }
            if let previous {
                guard previous.immutableIntentData == parts.intent else {
                    throw DevelopTemplateBatchCheckpointError.immutableIntentChanged
                }
                guard previous.outcome == .prepared || previous.outcome == .running else {
                    throw DevelopTemplateBatchCheckpointError.terminalCheckpoint
                }
                guard result.outcome != .prepared || previous.outcome == .prepared else {
                    throw DevelopTemplateBatchCheckpointError.invalidCheckpoint
                }
                // An unresolved in-flight request cannot be cleared or replaced by a
                // second executor; only its returned physical receipt resolves it.
                if let active = previous.activeRequestID,
                   result.activeRequestID != active {
                    guard let index = result.intent.requests.firstIndex(where: { $0.id == active }),
                          result.activeRequestID == nil, receipts[index] != nil else {
                        throw DevelopTemplateBatchCheckpointError.invalidCheckpoint
                    }
                }
                for index in receipts.indices where previous.receipts[index] != nil {
                    guard receipts[index] == previous.receipts[index] else {
                        throw DevelopTemplateBatchCheckpointError.receiptChanged
                    }
                }
                guard previous.sequence < UInt64.max else { throw DevelopTemplateBatchCheckpointError.invalidCheckpoint }
            } else {
                guard result.outcome == .prepared, result.activeRequestID == nil,
                      result.results.allSatisfy({ $0 == nil }) else {
                    throw DevelopTemplateBatchCheckpointError.invalidCheckpoint
                }
            }
            let checkpoint = DevelopTemplateBatchCheckpoint(formatVersion: 1, batchID: result.intent.id,
                sequence: (previous?.sequence ?? 0) + 1, outcome: result.outcome,
                activeRequestID: result.activeRequestID, completedCount: result.completedCount,
                recoveryData: payload, sha256: Self.hash(payload), immutableIntentData: parts.intent, receipts: receipts)
            try Self.validate(checkpoint)
            return ((), try encoder.encode(checkpoint))
        }
    }

    func load(_ batchID: UUID) throws -> DevelopTemplateBatchCheckpoint {
        try persistence(batchID).transaction(readOnly: true) { existing in
            guard let existing else { throw DevelopTemplateBatchCheckpointError.corruptCheckpoint }
            return (try Self.decode(existing, batchID: batchID), existing)
        }
    }

    /// A malformed entry fails the listing so it remains visible for explicit investigation.
    func allCheckpoints() throws -> [DevelopTemplateBatchCheckpoint] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                guard let id = UUID(uuidString: url.lastPathComponent) else {
                    throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
                }
                return try load(id)
            }
    }

    /// Read-only discovery keeps unreadable entries visible beside valid evidence.
    /// The selected directory and every ancestor must be real directories; no
    /// journal, lock, or permissions are created or repaired during inspection.
    func recoveryInventory() throws -> [DevelopTemplateBatchCheckpointInventoryEntry] {
        let root = try openInventoryDirectory()
        guard let stream = fdopendir(root) else {
            Darwin.close(root)
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw AutomationOperationRegistry.Failure.storageUnavailable }
                break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count < 1_024 else { throw AutomationOperationRegistry.Failure.capacity }
            names.append(name)
        }
        var retainedBytes = 0
        let entries = try names.sorted().map { name -> DevelopTemplateBatchCheckpointInventoryEntry in
            guard let id = UUID(uuidString: name), name == id.uuidString else {
                return .init(id: name, checkpoint: nil, issue: .corrupt)
            }
            do {
                let checkpoint = try load(id)
                guard checkpoint.recoveryData.count <= DevelopTemplateBatchExecutionService.maximumRecoveryBytes - retainedBytes else {
                    throw AutomationOperationRegistry.Failure.capacity
                }
                retainedBytes += checkpoint.recoveryData.count
                return .init(id: name, checkpoint: checkpoint, issue: nil)
            }
            catch DevelopTemplateBatchCheckpointError.unsupportedVersion {
                return .init(id: name, checkpoint: nil, issue: .newerVersion)
            } catch DevelopTemplateBatchCheckpointError.corruptCheckpoint {
                return .init(id: name, checkpoint: nil, issue: .corrupt)
            } catch AutomationOperationRegistry.Failure.capacity { throw AutomationOperationRegistry.Failure.capacity }
            catch { return .init(id: name, checkpoint: nil, issue: .unavailable) }
        }
        let fresh = try openInventoryDirectory()
        defer { Darwin.close(fresh) }
        var original = stat(), current = stat()
        guard fstat(root, &original) == 0, fstat(fresh, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        return entries
    }

    private func openInventoryDirectory() throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        let components = directory.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw AutomationOperationRegistry.Failure.storageUnavailable
        }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw AutomationOperationRegistry.Failure.storageUnavailable }
        do {
            for component in components {
                let next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw AutomationOperationRegistry.Failure.storageUnavailable }
                Darwin.close(current); current = next
            }
            var status = stat()
            guard fstat(current, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
                throw AutomationOperationRegistry.Failure.storageUnavailable
            }
            return current
        } catch { Darwin.close(current); throw error }
    }

    private func persistence(_ id: UUID) -> AutomationOperationPersistence {
        AutomationOperationPersistence(directory: directory.appendingPathComponent(id.uuidString, isDirectory: true),
            maximumBytes: DevelopTemplateBatchExecutionService.maximumRecoveryBytes * 4)
    }
    private static func decode(_ data: Data, batchID: UUID) throws -> DevelopTemplateBatchCheckpoint {
        guard let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = header["formatVersion"] as? Int else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        guard version == 1 else { throw DevelopTemplateBatchCheckpointError.unsupportedVersion }
        guard let checkpoint = try? JSONDecoder().decode(DevelopTemplateBatchCheckpoint.self, from: data),
              checkpoint.batchID == batchID else { throw DevelopTemplateBatchCheckpointError.corruptCheckpoint }
        try validate(checkpoint)
        return checkpoint
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func canonical(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    private static func receiptData(_ photo: [String: Any], completed: Bool) throws -> Data {
        try canonical(["physical": photo.filter { receiptKeys.contains($0.key) }, "completed": completed])
    }
    private static func parts(_ data: Data) throws -> (intent: Data, photos: [[String: Any]]) {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["formatVersion"] as? Int == 1, value["kind"] as? String == "Develop template batch",
              let photos = value["photos"] as? [[String: Any]], !photos.isEmpty,
              photos.count <= DevelopTemplateBatchIntent.maximumPhotos else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        var ids = Set<String>()
        for photo in photos {
            guard photo["formatVersion"] as? Int == 1, photo["kind"] as? String == "Primary Develop",
                  let id = photo["requestID"] as? String, UUID(uuidString: id) != nil,
                  ids.insert(id).inserted else { throw DevelopTemplateBatchCheckpointError.corruptCheckpoint }
        }
        for key in ["outcome", "activeRequestID", "failure", "retentionFailure", "unexpectedReceipt", "resultCompletions"] { value.removeValue(forKey: key) }
        value["photos"] = photos.map { $0.filter { !receiptKeys.contains($0.key) } }
        return (try canonical(value), photos)
    }
    private static func validate(_ checkpoint: DevelopTemplateBatchCheckpoint) throws {
        guard checkpoint.formatVersion == 1 else { throw DevelopTemplateBatchCheckpointError.unsupportedVersion }
        guard checkpoint.sequence > 0,
              checkpoint.recoveryData.count <= DevelopTemplateBatchExecutionService.maximumRecoveryBytes,
              checkpoint.sha256 == hash(checkpoint.recoveryData) else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        let parts = try parts(checkpoint.recoveryData)
        guard let payload = try JSONSerialization.jsonObject(with: checkpoint.recoveryData) as? [String: Any] else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        guard payload["batchID"] as? String == checkpoint.batchID.uuidString,
              payload["outcome"] as? String == checkpoint.outcome.rawValue,
              payload["activeRequestID"] as? String == checkpoint.activeRequestID?.uuidString,
              parts.intent == checkpoint.immutableIntentData, parts.photos.count == checkpoint.receipts.count,
              checkpoint.completedCount >= 0, checkpoint.completedCount <= parts.photos.count else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        guard let completions = payload["resultCompletions"] as? [Any], completions.count == parts.photos.count,
              completions.filter({ ($0 as? Bool) == true }).count == checkpoint.completedCount else {
            throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
        }
        var sawPending = false
        var sawIncompleteReceipt = false
        for index in parts.photos.indices {
            let photo = parts.photos[index], receipt = checkpoint.receipts[index]
            if receipt == nil {
                sawPending = true
                guard completions[index] is NSNull,
                      photo["wroteEmbedded"] as? Bool == false,
                      photo["embeddedMayHaveBeenWritten"] as? Bool == false,
                      photo["wroteXMP"] as? Bool == false,
                      photo["installedRecord"] == nil, photo["committedButUnverifiedJSON"] == nil else {
                    throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
                }
            } else {
                guard !sawPending, !sawIncompleteReceipt, completions[index] is Bool else {
                    throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
                }
                sawIncompleteReceipt = completions[index] as? Bool == false
            }
            if let receipt, receipt != (try receiptData(photo, completed: completions[index] as? Bool ?? false)) {
                throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
            }
        }
        if let active = checkpoint.activeRequestID {
            guard checkpoint.outcome != .completed,
                  let index = parts.photos.firstIndex(where: { $0["requestID"] as? String == active.uuidString }),
                  checkpoint.receipts[index] == nil,
                  completions.prefix(index).allSatisfy({ ($0 as? Bool) == true }) else {
                throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
            }
        }
        if checkpoint.outcome == .prepared {
            guard checkpoint.activeRequestID == nil, checkpoint.receipts.allSatisfy({ $0 == nil }),
                  payload["unexpectedReceipt"] == nil else { throw DevelopTemplateBatchCheckpointError.corruptCheckpoint }
        }
        if checkpoint.outcome == .completed {
            guard checkpoint.completedCount == parts.photos.count,
                  checkpoint.activeRequestID == nil, checkpoint.receipts.allSatisfy({ $0 != nil }),
                  payload["unexpectedReceipt"] == nil else {
                throw DevelopTemplateBatchCheckpointError.corruptCheckpoint
            }
        }
    }
}
