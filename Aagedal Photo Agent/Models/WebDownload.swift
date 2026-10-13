import Foundation

nonisolated struct WebMediaItem: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let position: Int
    let kind: String
    let downloadURL: String
    let width: Int
    let height: Int
    let username: String
    let displayName: String
    let description: String
    let publishedAt: String
    let postID: String
    let `extension`: String

    var resolution: String { width > 0 && height > 0 ? "\(width) × \(height)" : "Best available" }
}

nonisolated struct WebPostInspection: Codable, Sendable {
    let url: String
    let items: [WebMediaItem]
    let versions: [String: String]
    // The chosen package generation remains fixed through inspection and download.
    var generation: String = "bundled"

    enum CodingKeys: String, CodingKey { case url, items, versions }
}

nonisolated struct WebDownloadedFile: Codable, Sendable {
    let item: WebMediaItem
    let filename: String
}

nonisolated struct WebDownloadResult: Codable, Sendable {
    let files: [WebDownloadedFile]
    let versions: [String: String]
}

nonisolated struct WebImportProvenance: Codable, Sendable {
    let schemaVersion: Int
    let postURL: String
    let downloadedAt: Date
    let downloaderVersions: [String: String]
    let media: WebMediaItem
    let originalFilename: String
    let originalSHA256: String
    let workingFilename: String
    let metadataStorage: String
}
