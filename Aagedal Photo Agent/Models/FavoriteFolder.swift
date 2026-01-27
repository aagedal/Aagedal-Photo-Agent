import Foundation

struct FavoriteFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var url: URL
    var name: String

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
    }
}
