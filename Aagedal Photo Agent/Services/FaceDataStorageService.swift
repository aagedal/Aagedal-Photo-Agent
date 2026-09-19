import Foundation
import os.log

nonisolated private let faceDataLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "FaceDataStorageService")

/// The explicit deletion intent is applied to the latest reserved disk snapshot.
nonisolated enum FaceDataDeletionSelection: Sendable {
    case photos(Set<URL>)
    case faces(Set<UUID>)
}

nonisolated struct FaceDataStorageService: Sendable {

    static let faceDataDirectoryName = ".face_data"
    private static let dataFileName = "face_data.json"
    private static let thumbnailsDirectoryName = "thumbnails"

    // MARK: - Directory Helpers

    private func faceDataDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(Self.faceDataDirectoryName)
    }

    private func dataFileURL(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.dataFileName)
    }

    private func thumbnailsDirectory(for folderURL: URL) -> URL {
        faceDataDirectory(for: folderURL).appendingPathComponent(Self.thumbnailsDirectoryName)
    }

    private func thumbnailURL(for faceID: UUID, folderURL: URL) -> URL {
        thumbnailsDirectory(for: folderURL).appendingPathComponent("\(faceID.uuidString).jpg")
    }

    // MARK: - Load

    func faceDataExists(for folderURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: dataFileURL(for: folderURL).path)
    }

    func loadFaceData(for folderURL: URL, relocateCorruptFile: Bool = false) -> FolderFaceData? {
        let fileURL = dataFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let faceData = try JSONDecoder().decode(FolderFaceData.self, from: data)
            return faceData
        } catch {
            faceDataLog.error("Failed to decode face data at \(fileURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            guard relocateCorruptFile else { return nil }
            // Only a caller holding the folder reservation may relocate corrupt data.
            // Move corrupt file aside so it doesn't block future loads
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(Self.dataFileName).corrupt.\(timestamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                faceDataLog.error("Moved corrupt face data to \(backupURL.lastPathComponent, privacy: .private(mask: .hash))")
            } catch {
                faceDataLog.error("Failed to move corrupt face data aside: \(error.localizedDescription, privacy: .private)")
            }
            return nil
        }
    }

    func loadThumbnail(for faceID: UUID, folderURL: URL) -> Data? {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        do {
            return try Data(contentsOf: url)
        } catch {
            faceDataLog.warning("Failed to load thumbnail for face \(faceID.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    // MARK: - Save

    func saveFaceData(_ faceData: FolderFaceData) throws {
        let dir = faceDataDirectory(for: faceData.folderURL)
        let thumbDir = thumbnailsDirectory(for: faceData.folderURL)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(faceData)
        try data.write(to: dataFileURL(for: faceData.folderURL), options: .atomic)
    }

    func saveThumbnail(_ jpegData: Data, for faceID: UUID, folderURL: URL) throws {
        let thumbDir = thumbnailsDirectory(for: folderURL)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try jpegData.write(to: thumbnailURL(for: faceID, folderURL: folderURL))
    }

    // MARK: - Delete

    func deleteThumbnail(for faceID: UUID, folderURL: URL) throws {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already gone — not an error
        } catch {
            faceDataLog.warning("Failed to delete thumbnail for face \(faceID.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func deleteFaceData(for folderURL: URL) throws {
        let dir = faceDataDirectory(for: folderURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Cleanup

    func shouldCleanup(faceData: FolderFaceData, policy: FaceCleanupPolicy) -> Bool {
        guard let maxAge = policy.timeInterval else { return false }
        return Date().timeIntervalSince(faceData.lastScanDate) > maxAge
    }

    func applyCleanupIfNeeded(for folderURL: URL, policy: FaceCleanupPolicy) throws {
        guard let faceData = loadFaceData(for: folderURL) else { return }
        if shouldCleanup(faceData: faceData, policy: policy) {
            try deleteFaceData(for: folderURL)
        }
    }
}

/// Immutable folder state returned after every face-data and thumbnail read has finished on the
/// serialized filesystem actor. Thumbnail bytes deliberately cross the actor boundary instead of
/// `NSImage`; AppKit image objects remain owned by the main-actor view model.
nonisolated struct FaceDataFolderLoadEvidence: @unchecked Sendable {
    enum CleanupDisposition: Sendable, Equatable {
        case notRequested
        case retained
        case deletionFailed(String)
        case deleted(cancellationRequestedAfterCommit: Bool)
    }

    let folderURL: URL
    let faceData: FolderFaceData?
    let thumbnailData: [UUID: Data]
    let requestedThumbnailCount: Int
    let processedThumbnailCount: Int
    let cleanupDisposition: CleanupDisposition
}

/// A cancelled folder load retains its exact thumbnail prefix for diagnostics, but callers must
/// not publish it as a complete folder snapshot.
nonisolated struct CancelledFaceDataFolderLoadEvidence: Sendable, Equatable {
    let folderURL: URL
    let requestedThumbnailCount: Int
    let processedThumbnailCount: Int
}

nonisolated enum FaceDataFolderLoadResult: @unchecked Sendable {
    case complete(FaceDataFolderLoadEvidence)
    case cancelled(CancelledFaceDataFolderLoadEvidence)
}

nonisolated struct FaceDataDocumentLoadEvidence: Sendable {
    let folderURL: URL
    let documentExisted: Bool
    let faceData: FolderFaceData?
}

nonisolated enum FaceDataDocumentLoadResult: Sendable {
    case complete(FaceDataDocumentLoadEvidence)
    case cancelled(folderURL: URL)
}

nonisolated enum FaceThumbnailLoadResult: Sendable {
    case complete(Data?)
    case cancelled
}

/// Durable evidence for one face-data document commit and its optional orphan-thumbnail cleanup.
/// The document is installed first, so cancellation or a cleanup failure can leave only harmless
/// unreferenced thumbnails rather than a document that points at thumbnails already removed.
nonisolated struct FaceDataPersistenceEvidence: Sendable, Equatable {
    struct ThumbnailFailure: Sendable, Equatable {
        let faceID: UUID
        let message: String
    }

    let folderURL: URL
    let documentCommitted: Bool
    let requestedThumbnailDeletionCount: Int
    let deletedThumbnailIDs: [UUID]
    let thumbnailFailures: [ThumbnailFailure]
    let cancellationRequestedAfterCommit: Bool
}

nonisolated enum FaceDataPersistenceResult: Sendable, Equatable {
    case committed(FaceDataPersistenceEvidence)
    case cancelledBeforeCommit(folderURL: URL)
    case failedBeforeCommit(folderURL: URL, message: String)

    var failureMessage: String? {
        switch self {
        case .failedBeforeCommit(_, let message):
            message
        case .committed(let evidence):
            evidence.thumbnailFailures.first?.message
        case .cancelledBeforeCommit:
            nil
        }
    }
}

nonisolated enum FaceThumbnailPersistenceResult: Sendable, Equatable {
    case committed(faceID: UUID, cancellationRequestedAfterCommit: Bool)
    case cancelledBeforeCommit(faceID: UUID)
    case failed(faceID: UUID, message: String)
}

nonisolated enum FaceDataDeletionResult: Sendable, Equatable {
    case committed(folderURL: URL, cancellationRequestedAfterCommit: Bool)
    case cancelledBeforeCommit(folderURL: URL)
    case failed(folderURL: URL, message: String)

    var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}

/// Immutable file-identity evidence used to decide which photos need another face scan.
nonisolated struct FaceScanFileClassification: Sendable, Equatable {
    let imageURLsToScan: [URL]
    let removedOrModifiedPaths: Set<String>
    let unchangedPaths: Set<String>
}

/// Classification stops at a precise URL boundary when cancellation is observed. Callers must
/// not install a partial classification because it could incorrectly discard existing faces.
nonisolated enum FaceScanFileClassificationResult: Sendable, Equatable {
    case complete(FaceScanFileClassification)
    case cancelled(processedFileCount: Int, requestedFileCount: Int)
}

/// A signature read is non-preemptible once Foundation enters the filesystem. Cancellation
/// therefore records whether the read completed instead of publishing its value as current.
nonisolated enum FaceScanFileSignatureResult: Sendable, Equatable {
    case captured(imageURL: URL, signature: FileSignature?)
    case cancelled(imageURL: URL, readCompleted: Bool)
}

/// Serializes incremental face-scan file identity reads away from the app's default MainActor.
/// The same actor owns the initial classification transaction and the per-image signature reads
/// performed after detection, so neither path can overlap a slow volume probe.
actor FaceScanFileSignatureService {
    /// Run blocking Foundation calls on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and the actor's transaction ordering.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = FaceScanFileSignatureService()

    typealias SignatureReader = @Sendable (URL) -> FileSignature?

    private let readSignature: SignatureReader

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.face-scan-signatures", qos: .utility
        ),
        readSignature: @escaping SignatureReader = { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modificationDate = attrs[.modificationDate] as? Date else {
                return nil
            }
            let fileSize: Int64?
            if let value = attrs[.size] as? NSNumber {
                fileSize = value.int64Value
            } else {
                fileSize = attrs[.size] as? Int64
            }
            guard let fileSize else { return nil }
            return FileSignature(modificationDate: modificationDate, fileSize: fileSize)
        }
    ) {
        self.filesystemQueue = filesystemQueue
        self.readSignature = readSignature
    }

    func classify(
        imageURLs: [URL],
        existingSignatures: [String: FileSignature]
    ) -> FaceScanFileClassificationResult {
        let currentPaths = Set(imageURLs.map(\.path))
        let existingPaths = Set(existingSignatures.keys)
        var imageURLsToScan: [URL] = []
        var unchangedPaths: Set<String> = []
        var processedFileCount = 0

        for url in imageURLs {
            guard !Task.isCancelled else {
                return .cancelled(
                    processedFileCount: processedFileCount,
                    requestedFileCount: imageURLs.count
                )
            }
            let currentSignature = readSignature(url)
            processedFileCount += 1
            guard !Task.isCancelled else {
                return .cancelled(
                    processedFileCount: processedFileCount,
                    requestedFileCount: imageURLs.count
                )
            }

            if let existingSignature = existingSignatures[url.path],
               currentSignature == existingSignature {
                unchangedPaths.insert(url.path)
            } else {
                imageURLsToScan.append(url)
            }
        }

        let removedOrModifiedPaths = existingPaths.subtracting(currentPaths).union(
            Set(imageURLsToScan.map(\.path)).intersection(existingPaths)
        )
        return .complete(FaceScanFileClassification(
            imageURLsToScan: imageURLsToScan,
            removedOrModifiedPaths: removedOrModifiedPaths,
            unchangedPaths: unchangedPaths
        ))
    }

    func signature(for imageURL: URL) -> FaceScanFileSignatureResult {
        guard !Task.isCancelled else {
            return .cancelled(imageURL: imageURL, readCompleted: false)
        }
        let signature = readSignature(imageURL)
        guard !Task.isCancelled else {
            return .cancelled(imageURL: imageURL, readCompleted: true)
        }
        return .captured(imageURL: imageURL, signature: signature)
    }
}

/// Serializes folder-navigation reads, scan writes, interactive mutation commits, thumbnail
/// cleanup, and whole-folder deletion away from the app's default MainActor.
///
/// Foundation reads cannot be interrupted once entered, so cancellation is sampled before and
/// after the document read and every thumbnail read. Expiration cleanup is a durable mutation:
/// cancellation observed after deletion is recorded in complete evidence rather than pretending
/// the deleted data still exists.
actor FaceDataFolderLoadService {
    /// Run blocking Foundation calls on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and the actor's transaction ordering.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = FaceDataFolderLoadService()

    typealias FaceDataLoader = @Sendable (URL) -> FolderFaceData?
    typealias FaceDataExistenceChecker = @Sendable (URL) -> Bool
    typealias ThumbnailLoader = @Sendable (UUID, URL) -> Data?
    typealias FaceDataDeleter = @Sendable (URL) throws -> Void
    typealias FaceDataSaver = @Sendable (FolderFaceData) throws -> Void
    typealias ThumbnailSaver = @Sendable (Data, UUID, URL) throws -> Void
    typealias ThumbnailDeleter = @Sendable (UUID, URL) throws -> Void
    typealias CurrentDate = @Sendable () -> Date

    private let loadDocumentFaceData: FaceDataLoader
    private let loadFaceData: FaceDataLoader
    private let faceDataExists: FaceDataExistenceChecker
    private let loadThumbnail: ThumbnailLoader
    private let deleteFaceData: FaceDataDeleter
    private let saveFaceData: FaceDataSaver
    private let saveThumbnail: ThumbnailSaver
    private let deleteThumbnail: ThumbnailDeleter
    private let currentDate: CurrentDate

    init(
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.face-data-storage", qos: .utility
        ),
        loadFaceData: FaceDataLoader? = nil,
        faceDataExists: @escaping FaceDataExistenceChecker = { folderURL in
            FaceDataStorageService().faceDataExists(for: folderURL)
        },
        loadThumbnail: @escaping ThumbnailLoader = { faceID, folderURL in
            FaceDataStorageService().loadThumbnail(for: faceID, folderURL: folderURL)
        },
        deleteFaceData: @escaping FaceDataDeleter = { folderURL in
            try FaceDataStorageService().deleteFaceData(for: folderURL)
        },
        saveFaceData: @escaping FaceDataSaver = { faceData in
            try FaceDataStorageService().saveFaceData(faceData)
        },
        saveThumbnail: @escaping ThumbnailSaver = { data, faceID, folderURL in
            try FaceDataStorageService().saveThumbnail(data, for: faceID, folderURL: folderURL)
        },
        deleteThumbnail: @escaping ThumbnailDeleter = { faceID, folderURL in
            try FaceDataStorageService().deleteThumbnail(for: faceID, folderURL: folderURL)
        },
        currentDate: @escaping CurrentDate = Date.init
    ) {
        self.filesystemQueue = filesystemQueue
        self.loadDocumentFaceData = loadFaceData ?? { folderURL in
            FaceDataStorageService().loadFaceData(for: folderURL)
        }
        self.loadFaceData = loadFaceData ?? { folderURL in
            FaceDataStorageService().loadFaceData(for: folderURL, relocateCorruptFile: true)
        }
        self.faceDataExists = faceDataExists
        self.loadThumbnail = loadThumbnail
        self.deleteFaceData = deleteFaceData
        self.saveFaceData = saveFaceData
        self.saveThumbnail = saveThumbnail
        self.deleteThumbnail = deleteThumbnail
        self.currentDate = currentDate
    }

    func loadDocument(folderURL: URL) -> FaceDataDocumentLoadResult {
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        let existed = faceDataExists(folderURL)
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        let faceData = loadDocumentFaceData(folderURL)
        guard !Task.isCancelled else {
            return .cancelled(folderURL: standardizedFolderURL)
        }
        return .complete(FaceDataDocumentLoadEvidence(
            folderURL: standardizedFolderURL,
            documentExisted: existed,
            faceData: faceData
        ))
    }

    func loadThumbnailData(faceID: UUID, folderURL: URL) -> FaceThumbnailLoadResult {
        guard !Task.isCancelled else { return .cancelled }
        let data = loadThumbnail(faceID, folderURL)
        return Task.isCancelled ? .cancelled : .complete(data)
    }

    /// Interactive mutations do not own the scan's long-lived lease. Admit them on this
    /// filesystem executor and retain ownership through document and thumbnail changes.
    func persistWithFolderReservation(
        _ faceData: FolderFaceData,
        deletingThumbnailIDs thumbnailIDs: [UUID] = [],
        expectedSnapshot: FolderFaceData? = nil
    ) -> FaceDataPersistenceResult {
        let folderURL = faceData.folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }
        do {
            let reservation = try MCPProcessReservation.acquireFolder(folderURL)
            defer { reservation.release() }
            if let expectedSnapshot {
                // Decode without recovery: corrupt, removed, or foreign-owned documents must
                // never be replaced by an older interactive whole-document snapshot.
                guard expectedSnapshot.folderURL.standardizedFileURL.path == folderURL.path,
                      let current = loadDocumentFaceData(folderURL),
                      current.folderURL.standardizedFileURL.path == folderURL.path else {
                    return .failedBeforeCommit(folderURL: folderURL,
                        message: "Face data changed on disk. Reload the folder and reapply the edit.")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(current) == encoder.encode(expectedSnapshot) else {
                    return .failedBeforeCommit(folderURL: folderURL,
                        message: "Face data changed on disk. Reload the folder and reapply the edit.")
                }
            }
            return persist(faceData, deletingThumbnailIDs: thumbnailIDs)
        } catch {
            return .failedBeforeCommit(folderURL: folderURL, message: error.localizedDescription)
        }
    }

    /// The caller of this primitive must supply any enclosing operation reservation (as
    /// face scans do). Interactive callers use `persistWithFolderReservation` instead.
    func persist(
        _ faceData: FolderFaceData,
        deletingThumbnailIDs thumbnailIDs: [UUID] = []
    ) -> FaceDataPersistenceResult {
        let folderURL = faceData.folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }

        do {
            try saveFaceData(faceData)
        } catch {
            return .failedBeforeCommit(
                folderURL: folderURL,
                message: error.localizedDescription
            )
        }

        var deletedIDs: [UUID] = []
        var failures: [FaceDataPersistenceEvidence.ThumbnailFailure] = []
        for faceID in thumbnailIDs {
            guard !Task.isCancelled else { break }
            do {
                try deleteThumbnail(faceID, faceData.folderURL)
                deletedIDs.append(faceID)
            } catch {
                failures.append(.init(faceID: faceID, message: error.localizedDescription))
            }
        }

        return .committed(FaceDataPersistenceEvidence(
            folderURL: folderURL,
            documentCommitted: true,
            requestedThumbnailDeletionCount: thumbnailIDs.count,
            deletedThumbnailIDs: deletedIDs,
            thumbnailFailures: failures,
            cancellationRequestedAfterCommit: Task.isCancelled
                || deletedIDs.count + failures.count < thumbnailIDs.count
        ))
    }

    func persistThumbnail(
        _ data: Data,
        faceID: UUID,
        folderURL: URL
    ) -> FaceThumbnailPersistenceResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(faceID: faceID)
        }
        do {
            try saveThumbnail(data, faceID, folderURL)
            return .committed(
                faceID: faceID,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        } catch {
            return .failed(faceID: faceID, message: error.localizedDescription)
        }
    }

    func deleteAllWithFolderReservation(for folderURL: URL) -> FaceDataDeletionResult {
        let folderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: folderURL)
        }
        do {
            let reservation = try MCPProcessReservation.acquireFolder(folderURL)
            defer { reservation.release() }
            return deleteAll(for: folderURL)
        } catch {
            return .failed(folderURL: folderURL, message: error.localizedDescription)
        }
    }

    func deleteAll(for folderURL: URL) -> FaceDataDeletionResult {
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelledBeforeCommit(folderURL: standardizedFolderURL)
        }
        do {
            try deleteFaceData(folderURL)
            return .committed(
                folderURL: standardizedFolderURL,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        } catch {
            return .failed(
                folderURL: standardizedFolderURL,
                message: error.localizedDescription
            )
        }
    }

    /// Folder browsing may recover corrupt documents or expire old results. Hold the
    /// shared reservation across those mutations and the complete thumbnail snapshot.
    func loadWithFolderReservation(
        folderURL: URL,
        cleanupPolicy: FaceCleanupPolicy
    ) throws -> FaceDataFolderLoadResult {
        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: folderURL.standardizedFileURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }
        let reservation = try MCPProcessReservation.acquireFolder(folderURL)
        defer { reservation.release() }
        return load(folderURL: folderURL, cleanupPolicy: cleanupPolicy)
    }

    /// Face deletion must not release admission between its snapshot and commit.
    /// Return the original snapshot on write failure and the committed snapshot even if
    /// thumbnail cleanup fails; callers must not confuse cleanup with a failed document write.
    func deletePhotoFacesWithFolderReservation(
        folderURL: URL,
        imageURLs: Set<URL>
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        try deleteFacesWithFolderReservation(folderURL: folderURL, selection: .photos(imageURLs))
    }

    func deleteFacesWithFolderReservation(
        folderURL: URL,
        selection: FaceDataDeletionSelection
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        guard !Task.isCancelled else {
            return (.cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: folderURL.standardizedFileURL,
                requestedThumbnailCount: 0, processedThumbnailCount: 0
            )), nil)
        }
        let reservation = try MCPProcessReservation.acquireFolder(folderURL)
        defer { reservation.release() }
        return try deleteFaces(folderURL: folderURL, selection: selection)
    }

    /// The caller owns the folder reservation through photo Trash and this commit.
    func deleteFaces(
        folderURL: URL,
        selection: FaceDataDeletionSelection
    ) throws -> (load: FaceDataFolderLoadResult, persistence: FaceDataPersistenceResult?) {
        let loaded = load(folderURL: folderURL, cleanupPolicy: .never)
        guard case .complete(let evidence) = loaded, var data = evidence.faceData else {
            return (loaded, nil)
        }
        // A persisted URL must never redirect this transaction outside its reserved folder.
        guard data.folderURL.standardizedFileURL.path == folderURL.standardizedFileURL.path else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let removedIDs: Set<UUID>
        switch selection {
        case .photos(let imageURLs):
            guard imageURLs.allSatisfy({
                $0.deletingLastPathComponent().standardizedFileURL.path == folderURL.standardizedFileURL.path
            }) else { throw CocoaError(.fileReadCorruptFile) }
            let paths = Set(imageURLs.map { $0.standardizedFileURL.path })
            removedIDs = Set(data.faces.filter {
                paths.contains($0.imageURL.standardizedFileURL.path)
            }.map(\.id))
        case .faces(let faceIDs):
            removedIDs = faceIDs.intersection(data.faces.map(\.id))
        }
        guard !removedIDs.isEmpty else { return (loaded, nil) }
        for index in data.groups.indices {
            data.groups[index].faceIDs.removeAll { removedIDs.contains($0) }
            if removedIDs.contains(data.groups[index].representativeFaceID),
               let replacement = data.groups[index].faceIDs.first {
                data.groups[index].representativeFaceID = replacement
            }
        }
        data.groups.removeAll { $0.faceIDs.isEmpty }
        data.faces.removeAll { removedIDs.contains($0.id) }
        let persistence = persist(data, deletingThumbnailIDs: removedIDs.sorted {
            $0.uuidString < $1.uuidString
        })
        guard case .committed = persistence else { return (loaded, persistence) }
        return (.complete(FaceDataFolderLoadEvidence(
            folderURL: evidence.folderURL,
            faceData: data,
            thumbnailData: evidence.thumbnailData.filter { !removedIDs.contains($0.key) },
            requestedThumbnailCount: evidence.requestedThumbnailCount,
            processedThumbnailCount: evidence.processedThumbnailCount,
            cleanupDisposition: evidence.cleanupDisposition
        )), persistence)
    }

    /// The caller must own the enclosing folder reservation (for example a face scan).
    /// Document-only consumers use the non-mutating `loadDocument` path instead.
    func load(
        folderURL: URL,
        cleanupPolicy: FaceCleanupPolicy
    ) -> FaceDataFolderLoadResult {
        let standardizedFolderURL = folderURL.standardizedFileURL
        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }

        guard let faceData = loadFaceData(folderURL) else {
            let evidence = FaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                faceData: nil,
                thumbnailData: [:],
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0,
                cleanupDisposition: cleanupPolicy == .never ? .notRequested : .retained
            )
            return Task.isCancelled
                ? .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: 0,
                    processedThumbnailCount: 0
                ))
                : .complete(evidence)
        }

        guard !Task.isCancelled else {
            return .cancelled(CancelledFaceDataFolderLoadEvidence(
                folderURL: standardizedFolderURL,
                requestedThumbnailCount: 0,
                processedThumbnailCount: 0
            ))
        }

        let cleanupDisposition: FaceDataFolderLoadEvidence.CleanupDisposition
        if let maximumAge = cleanupPolicy.timeInterval,
           currentDate().timeIntervalSince(faceData.lastScanDate) > maximumAge {
            do {
                try deleteFaceData(folderURL)
                return .complete(FaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    faceData: nil,
                    thumbnailData: [:],
                    requestedThumbnailCount: 0,
                    processedThumbnailCount: 0,
                    cleanupDisposition: .deleted(
                        cancellationRequestedAfterCommit: Task.isCancelled
                    )
                ))
            } catch {
                cleanupDisposition = .deletionFailed(error.localizedDescription)
            }
        } else {
            cleanupDisposition = cleanupPolicy == .never ? .notRequested : .retained
        }

        let faceIDs = Self.orderedThumbnailFaceIDs(in: faceData)
        var thumbnails: [UUID: Data] = [:]
        thumbnails.reserveCapacity(faceIDs.count)
        var processedThumbnailCount = 0

        for faceID in faceIDs {
            guard !Task.isCancelled else {
                return .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: faceIDs.count,
                    processedThumbnailCount: processedThumbnailCount
                ))
            }
            let data = loadThumbnail(faceID, folderURL)
            guard !Task.isCancelled else {
                return .cancelled(CancelledFaceDataFolderLoadEvidence(
                    folderURL: standardizedFolderURL,
                    requestedThumbnailCount: faceIDs.count,
                    processedThumbnailCount: processedThumbnailCount
                ))
            }
            if let data {
                thumbnails[faceID] = data
            }
            processedThumbnailCount += 1
        }

        return .complete(FaceDataFolderLoadEvidence(
            folderURL: standardizedFolderURL,
            faceData: faceData,
            thumbnailData: thumbnails,
            requestedThumbnailCount: faceIDs.count,
            processedThumbnailCount: processedThumbnailCount,
            cleanupDisposition: cleanupDisposition
        ))
    }

    private static func orderedThumbnailFaceIDs(in faceData: FolderFaceData) -> [UUID] {
        var result: [UUID] = []
        result.reserveCapacity(faceData.faces.count)
        var seen: Set<UUID> = []

        // Load visible group representatives first, then the remaining detail-view faces.
        for faceID in faceData.groups.map(\.representativeFaceID) + faceData.faces.map(\.id) {
            if seen.insert(faceID).inserted {
                result.append(faceID)
            }
        }
        return result
    }
}
