import Foundation

nonisolated struct FavoriteFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var url: URL
    var name: String
    /// Security-scoped bookmark captured when this favorite was added. Optional for backward
    /// compatibility with favorites that previously persisted only a plain filesystem path.
    var bookmarkData: Data?

    init(id: UUID = UUID(), url: URL, bookmarkData: Data? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.bookmarkData = bookmarkData
    }
}
