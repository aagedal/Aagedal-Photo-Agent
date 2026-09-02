import Foundation
import os.log

nonisolated private let faceDataLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "FaceDataStorageService")

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

    func loadFaceData(for folderURL: URL) -> FolderFaceData? {
        let fileURL = dataFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let faceData = try JSONDecoder().decode(FolderFaceData.self, from: data)
            return faceData
        } catch {
            faceDataLog.error("Failed to decode face data at \(fileURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
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

    func deleteThumbnail(for faceID: UUID, folderURL: URL) {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File already gone — not an error
        } catch {
            faceDataLog.warning("Failed to delete thumbnail for face \(faceID.uuidString, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
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

/// Serializes folder-navigation face-data reads away from the app's default MainActor.
///
/// Foundation reads cannot be interrupted once entered, so cancellation is sampled before and
/// after the document read and every thumbnail read. Expiration cleanup is a durable mutation:
/// cancellation observed after deletion is recorded in complete evidence rather than pretending
/// the deleted data still exists.
actor FaceDataFolderLoadService {
    typealias FaceDataLoader = @Sendable (URL) -> FolderFaceData?
    typealias ThumbnailLoader = @Sendable (UUID, URL) -> Data?
    typealias FaceDataDeleter = @Sendable (URL) throws -> Void
    typealias CurrentDate = @Sendable () -> Date

    private let loadFaceData: FaceDataLoader
    private let loadThumbnail: ThumbnailLoader
    private let deleteFaceData: FaceDataDeleter
    private let currentDate: CurrentDate

    init(
        loadFaceData: @escaping FaceDataLoader = { folderURL in
            FaceDataStorageService().loadFaceData(for: folderURL)
        },
        loadThumbnail: @escaping ThumbnailLoader = { faceID, folderURL in
            FaceDataStorageService().loadThumbnail(for: faceID, folderURL: folderURL)
        },
        deleteFaceData: @escaping FaceDataDeleter = { folderURL in
            try FaceDataStorageService().deleteFaceData(for: folderURL)
        },
        currentDate: @escaping CurrentDate = Date.init
    ) {
        self.loadFaceData = loadFaceData
        self.loadThumbnail = loadThumbnail
        self.deleteFaceData = deleteFaceData
        self.currentDate = currentDate
    }

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
