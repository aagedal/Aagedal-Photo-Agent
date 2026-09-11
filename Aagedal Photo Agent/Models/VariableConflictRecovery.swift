import Foundation
import CryptoKit

nonisolated enum VariableConflictRecoveryError: LocalizedError, Sendable {
    case obsoleteReview, requestRunning, incompletePayload, unsafeExport, exportVerificationFailed
    var errorDescription: String? {
        switch self {
        case .obsoleteReview: return "The retained variable requests changed. Review and export them again before discarding."
        case .requestRunning: return "Variable processing is still running. Wait for the captured work to settle before reviewing it."
        case .incompletePayload: return "The complete captured variable input is unavailable. Retained work cannot be discarded."
        case .unsafeExport: return "Choose a separate recovery JSON file outside photo metadata folders and linked locations. Existing photos and sidecars must be preserved."
        case .exportVerificationFailed: return "The recovery export could not be verified. All retained variable work was preserved. Export again before discarding."
        }
    }
}

/// Ordinary IPTC JSON omits technical state. Every metadata record in this export uses this
/// wrapper, including baselines and partially completed receipts. Immutable reference wrappers
/// avoid copying many large metadata values onto the encoder worker thread stack.
nonisolated final class VariableRecoveryMetadata: Codable, Sendable {
    let editorial: IPTCMetadata
    let cameraRaw: CameraRawSettings?
    let orientation: Int?
    init(_ value: IPTCMetadata) {
        editorial = value; cameraRaw = value.cameraRaw; orientation = value.exifOrientation
    }
}
nonisolated final class VariableRecoverySidecar: Codable, Sendable {
    let record: MetadataSidecar
    let metadata: VariableRecoveryMetadata
    let originalSnapshotKnown: Bool
    let originalSnapshot: VariableRecoveryMetadata?
    init(_ value: MetadataSidecar) {
        record = value; metadata = .init(value.metadata)
        originalSnapshotKnown = value.imageMetadataSnapshot != nil
        originalSnapshot = value.imageMetadataSnapshot.map(VariableRecoveryMetadata.init)
    }
}
nonisolated final class VariableRecoveryPhysicalResult: Codable, Sendable {
    let requestID: UUID
    let imageURL: URL
    let installedSidecar: VariableRecoverySidecar?
    let didWriteEmbedded: Bool
    let didWriteXMP: Bool
    let embeddedWriteMayHaveOccurred: Bool
    let wasCancelled: Bool
    let wasSkipped: Bool
    let committedButUnverifiedSidecarURL: URL?
    let failure: String?
    let resultingPhysicalBaseline: MetadataSidecarReplayCreationEvidence?
    init(_ value: PendingMetadataWriteResult) {
        requestID = value.requestID; imageURL = value.imageURL
        installedSidecar = value.installedSidecar.map(VariableRecoverySidecar.init)
        didWriteEmbedded = value.didWriteEmbedded; didWriteXMP = value.didWriteXMP
        embeddedWriteMayHaveOccurred = value.embeddedWriteMayHaveOccurred
        wasCancelled = value.wasCancelled; wasSkipped = value.wasSkipped
        committedButUnverifiedSidecarURL = value.committedButUnverifiedSidecarURL
        failure = value.failure; resultingPhysicalBaseline = value.resultingPhysicalBaseline
    }
}
nonisolated final class VariableRecoveryWriteResult: Codable, Sendable {
    let requestID: UUID
    let imageURL: URL
    let preparedSidecar: VariableRecoverySidecar?
    let physicalResult: VariableRecoveryPhysicalResult?
    let wasCancelled: Bool
    let failure: String?
    let savedToHistory: Bool
    let committedButUnverifiedSidecarURL: URL?
    init(_ value: VariableMetadataWriteResult) {
        requestID = value.requestID; imageURL = value.imageURL
        preparedSidecar = value.preparedSidecar.map(VariableRecoverySidecar.init)
        physicalResult = value.physicalResult.map(VariableRecoveryPhysicalResult.init)
        wasCancelled = value.wasCancelled; failure = value.failure; savedToHistory = value.savedToHistory
        committedButUnverifiedSidecarURL = value.committedButUnverifiedSidecarURL
    }
}
nonisolated struct VariableMetadataRequestRecoverySnapshot: Codable, Sendable {
    let requestID: UUID
    let imageURL: URL
    let folderURL: URL
    let requestedMode: String
    let originalMetadata: VariableRecoveryMetadata
    let capturedMetadata: VariableRecoveryMetadata
    let baselineMetadata: VariableRecoveryMetadata
    let baselineSidecar: VariableRecoverySidecar?
    let capturedSidecar: VariableRecoverySidecar
    let baselineRecordExisted: Bool
    let baselineHistory: [MetadataHistoryEntry]
    let fullChanges: [MetadataHistoryEntry]
    let initialPhysicalEvidence: MetadataSidecarReplayCreationEvidence?
    let currentPhysicalEvidence: MetadataSidecarReplayCreationEvidence
    let preparedSidecar: VariableRecoverySidecar?
    let completedResult: VariableRecoveryWriteResult?
    let unverifiedCompletion: VariableRecoveryPhysicalResult?
    let lastResult: VariableRecoveryWriteResult?
    let jsonWasCommitted: Bool
    let committedRecord: VariableRecoverySidecar?
    let creationEvidenceInvalidated: Bool
    let creationMirrorCompleted: Bool
    let creationInstalledXMPData: Data?
}

/// Admissions can fail before a request exists. The caller supplies the complete frozen payload
/// as JSON, never an executor closure or a fresh disk read. Its exact bytes are retained alongside
/// a human-readable JSON projection in the exported document.
nonisolated struct VariableConflictEntry: Sendable {
    let id: UUID
    let imageURL: URL
    let folderURL: URL
    let admissionPayload: Data?
    let request: VariableMetadataWriteRequest?
    let failure: String?
    init(id: UUID, imageURL: URL, folderURL: URL, admissionPayload: Data? = nil,
         request: VariableMetadataWriteRequest? = nil, failure: String? = nil) {
        self.id = id; self.imageURL = imageURL; self.folderURL = folderURL
        self.admissionPayload = admissionPayload; self.request = request; self.failure = failure
    }
}
nonisolated struct VariableConflictSnapshot: Identifiable, Sendable {
    let id: UUID
    let photoURL: URL
    let reason: String
    let generation: UInt64
    let entryIDs: [UUID]
    fileprivate let exportData: Data
    var requestCount: Int { entryIDs.count }
}
nonisolated struct VariableConflictExportReceipt: Sendable {
    let exportURL: URL
    let sha256: String
    let reviewID: UUID
    let generation: UInt64
    let entryIDs: [UUID]
}

/// This core never mutates the caller's retained lists. The caller must freeze the reviewed photo,
/// settle in-flight execution, and recheck that same freeze/generation after an awaited verification
/// before synchronously removing the returned IDs. All filesystem work stays off MainActor.
@MetadataSidecarFilesystemActor
struct VariableConflictRecovery {
    static func makeSnapshot(photoURL: URL, reason: String, generation: UInt64,
                             entries: [VariableConflictEntry]) throws -> VariableConflictSnapshot {
        let photo = canonical(photoURL)
        let id = UUID()
        let data = try document(id: id, photo: photo, reason: reason, generation: generation, entries: entries)
        return .init(id: id, photoURL: photo, reason: reason, generation: generation,
            entryIDs: entries.map(\.id), exportData: data)
    }

    static func export(_ snapshot: VariableConflictSnapshot, to url: URL,
        currentEntries: [VariableConflictEntry], generation: UInt64, protectedPhotoURLs: [URL],
        access: CaptionConflictExportAccess = .init()
    ) throws -> VariableConflictExportReceipt {
        try validate(snapshot, entries: currentEntries, generation: generation)
        try validateDestination(url, protected: protectedPhotoURLs + currentEntries.map(\.imageURL) + [snapshot.photoURL])
        try access.writeAtomic(snapshot.exportData, url)
        try validateDestination(url, protected: protectedPhotoURLs + currentEntries.map(\.imageURL) + [snapshot.photoURL])
        let installed = try access.read(url)
        guard installed == snapshot.exportData else { throw VariableConflictRecoveryError.exportVerificationFailed }
        try validate(snapshot, entries: currentEntries, generation: generation)
        return .init(exportURL: url, sha256: hash(installed), reviewID: snapshot.id,
            generation: snapshot.generation, entryIDs: snapshot.entryIDs)
    }

    /// Revalidates the actual private export, complete immutable payloads, receipt states, ID set,
    /// and generation. Successful verification authorizes only these in-memory IDs, never files.
    static func verifyDiscard(_ snapshot: VariableConflictSnapshot, receipt: VariableConflictExportReceipt,
        currentEntries: [VariableConflictEntry], generation: UInt64, protectedPhotoURLs: [URL]
    ) throws -> [UUID] {
        try validate(snapshot, entries: currentEntries, generation: generation)
        guard receipt.reviewID == snapshot.id, receipt.generation == snapshot.generation,
              receipt.entryIDs == snapshot.entryIDs else { throw VariableConflictRecoveryError.obsoleteReview }
        try validateDestination(receipt.exportURL,
            protected: protectedPhotoURLs + currentEntries.map(\.imageURL) + [snapshot.photoURL])
        let data = try Data(contentsOf: receipt.exportURL)
        guard data == snapshot.exportData, hash(data) == receipt.sha256 else {
            throw VariableConflictRecoveryError.exportVerificationFailed
        }
        try validate(snapshot, entries: currentEntries, generation: generation)
        return snapshot.entryIDs
    }

    private static func validate(_ snapshot: VariableConflictSnapshot,
                                 entries: [VariableConflictEntry], generation: UInt64) throws {
        guard generation == snapshot.generation, entries.map(\.id) == snapshot.entryIDs,
              try document(id: snapshot.id, photo: snapshot.photoURL, reason: snapshot.reason,
                generation: generation, entries: entries) == snapshot.exportData else {
            throw VariableConflictRecoveryError.obsoleteReview
        }
    }

    private static func document(id: UUID, photo: URL, reason: String, generation: UInt64,
                                 entries: [VariableConflictEntry]) throws -> Data {
        guard photo.isFileURL, !entries.isEmpty, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.imageURL.isFileURL && canonical($0.imageURL).path == photo.path }) else {
            throw VariableConflictRecoveryError.obsoleteReview
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Foundation Date's native reference epoch keeps subsecond event payloads lossless.
        encoder.dateEncodingStrategy = .deferredToDate
        var encoded: [[String: Any]] = []
        for entry in entries {
            guard entry.admissionPayload != nil || entry.request != nil else { throw VariableConflictRecoveryError.incompletePayload }
            var value: [String: Any] = ["entryID": entry.id.uuidString, "imageURL": entry.imageURL.absoluteString,
                "folderURL": entry.folderURL.absoluteString, "failure": entry.failure.map { $0 as Any } ?? NSNull()]
            if let payload = entry.admissionPayload {
                guard let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    throw VariableConflictRecoveryError.incompletePayload
                }
                value["admissionPayload"] = decoded
                value["admissionPayloadExactBytesBase64"] = payload.base64EncodedString()
            }
            if let request = entry.request {
                guard canonical(request.imageURL).path == photo.path,
                      canonical(request.folderURL).path == canonical(entry.folderURL).path else { throw VariableConflictRecoveryError.obsoleteReview }
                value["request"] = try JSONSerialization.jsonObject(with: encoder.encode(request.recoverySnapshot()))
            }
            encoded.append(value)
        }
        let result: [String: Any] = ["formatVersion": 1, "reviewID": id.uuidString,
            "photoURL": photo.absoluteString, "reason": reason, "generation": NSNumber(value: generation),
            "dateEncoding": "Foundation Date seconds since 2001-01-01 UTC",
            "entries": encoded]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func validateDestination(_ url: URL, protected photos: [URL]) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "json" else { throw VariableConflictRecoveryError.unsafeExport }
        // Inspect lexical ancestors first: Foundation can rewrite physical /private paths to a
        // logical /var alias during standardization. Explicit linked paths remain unsafe.
        var cursor = url
        while cursor.path != "/" {
            if cursor.lastPathComponent.lowercased() == MetadataSidecarService.sidecarDirectoryName {
                throw VariableConflictRecoveryError.unsafeExport
            }
            if let attributes = try attributesIfPresent(cursor),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw VariableConflictRecoveryError.unsafeExport
            }
            cursor.deleteLastPathComponent()
        }
        let destination = canonical(url)
        guard !destination.pathComponents.contains(where: { $0.lowercased() == MetadataSidecarService.sidecarDirectoryName }) else {
            throw VariableConflictRecoveryError.unsafeExport
        }
        for photo in photos {
            guard destination.path != canonical(photo).path, destination.path != canonical(XMPSidecarService().sidecarURL(for: photo)).path else {
                throw VariableConflictRecoveryError.unsafeExport
            }
        }
        guard try attributesIfPresent(url.deletingLastPathComponent())?[.type] as? FileAttributeType == .typeDirectory else {
            throw VariableConflictRecoveryError.unsafeExport
        }
        if let attributes = try attributesIfPresent(url) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw VariableConflictRecoveryError.unsafeExport
            }
        }
    }
    private static func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
}
