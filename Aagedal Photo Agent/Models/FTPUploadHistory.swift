import Foundation

struct FTPUploadFileRecord: Codable, Sendable, Identifiable {
    var id: String { filePath }
    let filePath: String
    let fileName: String
    let fileSize: Int64
    let modifiedDate: Date
}

struct FTPUploadHistoryEntry: Codable, Sendable, Identifiable {
    let id: UUID
    let serverName: String
    let startedAt: Date
    var completedAt: Date?
    let fileCount: Int
    let totalBytes: Int64
    let files: [FTPUploadFileRecord]
    let didRenderJPEG: Bool
}

struct FTPUploadHistory: Codable, Sendable {
    static let maxEntries = 3
    var entries: [FTPUploadHistoryEntry] = []

    mutating func addEntry(_ entry: FTPUploadHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }

    mutating func markCompleted(id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].completedAt = Date()
        }
    }
}
