import Foundation

struct MetadataHistoryEntry: Codable, Sendable, Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let fieldName: String
    let oldValue: String?
    let newValue: String?
}

struct MetadataSidecar: Codable, Sendable {
    static let currentVersion = 1
    static let historyLimit = 20

    var version: Int = currentVersion
    var sourceFile: String
    var lastModified: Date
    var pendingChanges: Bool
    var metadata: IPTCMetadata
    var imageMetadataSnapshot: IPTCMetadata?
    var history: [MetadataHistoryEntry]

    init(
        sourceFile: String,
        lastModified: Date = Date(),
        pendingChanges: Bool = false,
        metadata: IPTCMetadata = IPTCMetadata(),
        imageMetadataSnapshot: IPTCMetadata? = nil,
        history: [MetadataHistoryEntry] = []
    ) {
        self.version = Self.currentVersion
        self.sourceFile = sourceFile
        self.lastModified = lastModified
        self.pendingChanges = pendingChanges
        self.metadata = metadata
        self.imageMetadataSnapshot = imageMetadataSnapshot
        self.history = history
    }
}

extension Array where Element == MetadataHistoryEntry {
    mutating func trimToHistoryLimit() {
        let limit = MetadataSidecar.historyLimit
        guard count > limit else { return }
        removeFirst(count - limit)
    }
}
