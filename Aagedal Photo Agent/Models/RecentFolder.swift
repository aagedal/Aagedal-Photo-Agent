import Foundation

struct RecentFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var url: URL
    var name: String
    /// Security-scoped bookmark captured when the user chose this folder. Optional so recent
    /// entries written by older app versions continue to decode.
    var bookmarkData: Data?

    init(id: UUID = UUID(), url: URL, bookmarkData: Data? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.bookmarkData = bookmarkData
    }
}
