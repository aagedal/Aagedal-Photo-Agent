import Foundation

/// Credential-free facts about the network protection used for a delivery. This value is safe to
/// persist in Activity and receipts: it contains no host, user name, path, or certificate details.
nonisolated struct DeliveryTransportSecurity: Codable, Equatable, Hashable, Sendable {
    enum ProtocolKind: String, Codable, Equatable, Hashable, Sendable {
        case sftp
        case explicitFTPS
        case ftp

        var displayName: String {
            switch self {
            case .sftp: "SFTP"
            case .explicitFTPS: "FTPS"
            case .ftp: "FTP"
            }
        }
    }

    let protocolKind: ProtocolKind
    let verificationEnabled: Bool

    var isInsecure: Bool { protocolKind == .ftp || !verificationEnabled }

    var badgeTitle: String {
        if protocolKind == .ftp { return "Insecure FTP" }
        if !verificationEnabled { return "Verification off" }
        return protocolKind.displayName
    }

    var evidenceDescription: String {
        let verification = verificationEnabled ? "verification on" : "verification off"
        return "\(protocolKind.displayName) · \(verification)"
    }
}

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
    /// The exact insecure transport state explicitly accepted before its first upload. A change
    /// to protocol or verification invalidates this acknowledgement.
    var firstUploadAcknowledgedSecurity: DeliveryTransportSecurity?

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
        case firstUploadAcknowledgedSecurity
    }

    nonisolated init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useSFTP: Bool = false,
        useTLS: Bool = false,
        allowInsecureHostVerification: Bool = false,
        firstUploadAcknowledgedSecurity: DeliveryTransportSecurity? = nil
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
        self.firstUploadAcknowledgedSecurity = firstUploadAcknowledgedSecurity
    }

    nonisolated var keychainKey: String { "ftpConnection-\(id.uuidString)" }

    /// Safe starting point for newly-created user profiles. The general initializer retains its
    /// source-compatible FTP defaults for callers that explicitly construct protocol fixtures.
    nonisolated static var secureDefault: Self {
        Self(port: 22, useSFTP: true)
    }

    nonisolated var transportSecurity: DeliveryTransportSecurity {
        if useSFTP {
            return DeliveryTransportSecurity(
                protocolKind: .sftp,
                verificationEnabled: !allowInsecureHostVerification
            )
        }
        if useTLS {
            return DeliveryTransportSecurity(
                protocolKind: .explicitFTPS,
                verificationEnabled: !allowInsecureHostVerification
            )
        }
        return DeliveryTransportSecurity(protocolKind: .ftp, verificationEnabled: false)
    }

    nonisolated var requiresFirstInsecureUploadAcknowledgement: Bool {
        transportSecurity.isInsecure && firstUploadAcknowledgedSecurity != transportSecurity
    }

    mutating func acknowledgeFirstInsecureUpload() {
        firstUploadAcknowledgedSecurity = transportSecurity.isInsecure ? transportSecurity : nil
    }

    mutating func normalizeTransportAcknowledgement() {
        guard firstUploadAcknowledgedSecurity == transportSecurity,
              transportSecurity.isInsecure else {
            firstUploadAcknowledgedSecurity = nil
            return
        }
    }

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
        firstUploadAcknowledgedSecurity = try container.decodeIfPresent(
            DeliveryTransportSecurity.self,
            forKey: .firstUploadAcknowledgedSecurity
        )
        normalizeTransportAcknowledgement()
    }
}
