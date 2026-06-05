import Foundation

struct FTPConnection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var remotePath: String
    var useSFTP: Bool
    /// Explicit FTPS (FTP over TLS via AUTH TLS). Only meaningful when `useSFTP`
    /// is false; SFTP is already encrypted over SSH.
    var useTLS: Bool
    var allowInsecureHostVerification: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case remotePath
        case useSFTP
        case useTLS
        case allowInsecureHostVerification
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useSFTP: Bool = false,
        useTLS: Bool = false,
        allowInsecureHostVerification: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useSFTP = useSFTP
        self.useTLS = useTLS
        self.allowInsecureHostVerification = allowInsecureHostVerification
    }

    var keychainKey: String { "ftpConnection-\(id.uuidString)" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 21
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        remotePath = try container.decodeIfPresent(String.self, forKey: .remotePath) ?? "/"
        useSFTP = try container.decodeIfPresent(Bool.self, forKey: .useSFTP) ?? false
        useTLS = try container.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        allowInsecureHostVerification = try container.decodeIfPresent(Bool.self, forKey: .allowInsecureHostVerification) ?? false
    }
}
