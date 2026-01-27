import Foundation

struct FTPConnection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var remotePath: String
    var useSFTP: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useSFTP: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useSFTP = useSFTP
    }

    var keychainKey: String { "ftpConnection-\(id.uuidString)" }
}
