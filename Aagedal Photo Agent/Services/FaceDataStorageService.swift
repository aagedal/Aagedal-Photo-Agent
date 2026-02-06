import Foundation
import os.log

nonisolated private let faceDataLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AagedalPhotoAgent", category: "FaceDataStorageService")

nonisolated struct FaceDataStorageService: Sendable {

    private static let faceDataDirectoryName = ".face_data"
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

    func loadFaceData(for folderURL: URL) -> FolderFaceData? {
        let fileURL = dataFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let faceData = try JSONDecoder().decode(FolderFaceData.self, from: data)
            return faceData
        } catch {
            faceDataLog.error("Failed to decode face data at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func loadThumbnail(for faceID: UUID, folderURL: URL) -> Data? {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        return try? Data(contentsOf: url)
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
        try data.write(to: dataFileURL(for: faceData.folderURL))
    }

    func saveThumbnail(_ jpegData: Data, for faceID: UUID, folderURL: URL) throws {
        let thumbDir = thumbnailsDirectory(for: folderURL)
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try jpegData.write(to: thumbnailURL(for: faceID, folderURL: folderURL))
    }

    // MARK: - Delete

    func deleteThumbnail(for faceID: UUID, folderURL: URL) {
        let url = thumbnailURL(for: faceID, folderURL: folderURL)
        try? FileManager.default.removeItem(at: url)
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
