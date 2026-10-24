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

nonisolated struct FTPConnection: Codable, Identifiable, Hashable, Sendable {
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
    /// The server accepts temporary uploads but refuses to rename them (RNFR/RNTO), as
    /// write-only drop boxes do. Set only after refusals on two different files (a single
    /// refusal can be a transient 421/450 or a name-specific RNTO refusal), so later uploads
    /// go straight to the final name. Cleared when the host, port or user name changes, or by
    /// "Reset Server Compatibility".
    var serverRefusesRename: Bool
    /// The server refuses to store the temporary `.<name>.<token>.part` file itself (dot-file
    /// or extension filters, e.g. vsftpd `deny_file`, pure-ftpd anonymous dot-file blocking,
    /// agency servers that accept only `.jpg`) while accepting the final name.
    var serverRefusesTemporaryName: Bool
    /// Rename refusals seen on distinct files since the last successful rename.
    var renameRefusalCount: Int
    /// The file of the last counted rename refusal, so retries of one file count once.
    var lastRenameRefusalFileName: String?

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
        case serverRefusesRename
        case serverRefusesTemporaryName
        case renameRefusalCount
        case lastRenameRefusalFileName
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
        firstUploadAcknowledgedSecurity: DeliveryTransportSecurity? = nil,
        serverRefusesRename: Bool = false,
        serverRefusesTemporaryName: Bool = false
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
        self.serverRefusesRename = serverRefusesRename
        self.serverRefusesTemporaryName = serverRefusesTemporaryName
        self.renameRefusalCount = 0
        self.lastRenameRefusalFileName = nil
    }

    /// Uploads go straight to the final name (no temporary name + rename).
    nonisolated var uploadsDirectly: Bool { serverRefusesRename || serverRefusesTemporaryName }

    /// Whether anything about the server's rename/temporary-name support has been learned.
    nonisolated var hasLearnedServerCompatibility: Bool {
        serverRefusesRename || serverRefusesTemporaryName || renameRefusalCount > 0
    }

    /// Folds what one upload of `fileName` learned into the profile. Returns true when a
    /// persisted field changed.
    @discardableResult
    nonisolated mutating func learnServerCompatibility(
        from outcome: FTPUploadOutcome,
        fileName: String
    ) -> Bool {
        var changed = false
        if outcome.temporaryNameRefused, !serverRefusesTemporaryName {
            serverRefusesTemporaryName = true
            changed = true
        }
        if outcome.renameRefused {
            if lastRenameRefusalFileName != fileName {
                renameRefusalCount += 1
                lastRenameRefusalFileName = fileName
                changed = true
            }
            if renameRefusalCount >= 2, !serverRefusesRename {
                serverRefusesRename = true
                changed = true
            }
        } else if outcome.renamedIntoPlace, renameRefusalCount > 0 {
            // A rename worked: earlier refusals were transient or name-specific.
            renameRefusalCount = 0
            lastRenameRefusalFileName = nil
            changed = true
        }
        return changed
    }

    /// Forgets everything learned about rename/temporary-name support.
    nonisolated mutating func resetServerCompatibility() {
        serverRefusesRename = false
        serverRefusesTemporaryName = false
        renameRefusalCount = 0
        lastRenameRefusalFileName = nil
    }

    nonisolated var keychainKey: String { "ftpConnection-\(id.uuidString)" }

    /// Safe starting point for newly-created user profiles: explicit FTPS with certificate
    /// verification. SFTP is not offered because macOS's `/usr/bin/curl` is built without it.
    /// The general initializer retains its source-compatible FTP defaults for callers that
    /// explicitly construct protocol fixtures.
    nonisolated static var secureDefault: Self {
        Self(port: 21, useSFTP: false, useTLS: true, allowInsecureHostVerification: false)
    }

    /// macOS ships `/usr/bin/curl` without the sftp/scp protocols, so an SFTP profile can never
    /// connect. Legacy profiles keep decoding, but Test and Upload refuse them with this message.
    nonisolated static let sftpUnavailableMessage =
        "SFTP isn't available with macOS's built-in curl. Edit this server and use FTPS (FTP with TLS) instead."

    /// Why Save must stay disabled for the edited profile, or `nil` when it can be saved.
    /// Credentials go into a netrc file at upload time, so an empty user name or password
    /// would otherwise only fail later, file by file.
    /// Validates the profile as it will be saved, i.e. after `normalizeHostInput()`.
    nonisolated func saveValidationMessage(password: String) -> String? {
        var normalized = self
        if let message = normalized.normalizeHostInput() { return message }
        return normalized.validationMessageForNormalizedFields(password: password)
    }

    private nonisolated func validationMessageForNormalizedFields(password: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a connection name." }
        if host.isEmpty { return "Enter a host." }
        if host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
            || host.contains("#") || host.contains("\"") {
            return "The host can't contain spaces, '#' or quotes."
        }
        if host.contains("/") || host.contains("@") {
            return "Enter only the server name in Host — the user name and folder have their own fields."
        }
        if !(1 ... 65_535).contains(port) { return "Enter a port between 1 and 65535." }
        if username.isEmpty { return "Enter a user name." }
        if password.isEmpty { return "Enter a password." }
        return nil
    }

    /// Cleans up what people paste into the Host field: surrounding whitespace, a scheme
    /// (`ftp://`, `ftps://`, `sftp://`), a `:port` suffix (moved into `port`) and a `/path`
    /// suffix (moved into `remotePath` when that is still the default `/`). Returns a message
    /// when the input can't be normalized unambiguously (a path while a different remote
    /// folder is set, an embedded user name, or an invalid port), leaving the fields unchanged.
    @discardableResult
    nonisolated mutating func normalizeHostInput() -> String? {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = value.range(of: "://") {
            let scheme = value[value.startIndex ..< schemeRange.lowerBound].lowercased()
            guard ["ftp", "ftps", "sftp"].contains(scheme) else {
                return "Enter only the server name in Host, without “\(scheme)://”."
            }
            value = String(value[schemeRange.upperBound...])
        }
        if value.contains("@") {
            return "Enter only the server name in Host — put the user name in the Username field."
        }

        var path: String?
        if let slash = value.firstIndex(of: "/") {
            let suffix = String(value[slash...])
            value = String(value[..<slash])
            let trimmedPath = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmedPath.isEmpty { path = "/" + trimmedPath }
        }

        var parsedPort: Int?
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            // Bracketed IPv6 literal, optionally followed by :port.
            let remainder = value[value.index(after: close)...]
            if remainder.hasPrefix(":") {
                guard let number = Int(remainder.dropFirst()), (1 ... 65_535).contains(number) else {
                    return "Enter a port between 1 and 65535."
                }
                parsedPort = number
                value = String(value[...close])
            }
        } else if value.filter({ $0 == ":" }).count == 1, let colon = value.firstIndex(of: ":") {
            // host:port (a bare IPv6 literal has several colons and is left alone).
            guard let number = Int(value[value.index(after: colon)...]),
                  (1 ... 65_535).contains(number) else {
                return "Enter a port between 1 and 65535."
            }
            parsedPort = number
            value = String(value[..<colon])
        }

        if let path {
            let currentPath = remotePath.trimmingCharacters(in: .whitespaces)
            let slashes = CharacterSet(charactersIn: "/")
            if currentPath.isEmpty || currentPath == "/" {
                remotePath = path
            } else if currentPath.trimmingCharacters(in: slashes) != path.trimmingCharacters(in: slashes) {
                return "Host contains a folder (“\(path)”) but Remote Path is “\(currentPath)”. Remove the folder from Host."
            }
        }
        host = value
        if let parsedPort { port = parsedPort }
        return nil
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
        serverRefusesRename = try container.decodeIfPresent(Bool.self, forKey: .serverRefusesRename) ?? false
        serverRefusesTemporaryName = try container.decodeIfPresent(
            Bool.self, forKey: .serverRefusesTemporaryName) ?? false
        renameRefusalCount = max(0, try container.decodeIfPresent(Int.self, forKey: .renameRefusalCount) ?? 0)
        lastRenameRefusalFileName = try container.decodeIfPresent(
            String.self, forKey: .lastRenameRefusalFileName)
        normalizeTransportAcknowledgement()
        // Migrate profiles saved before host validation: "ftp://host:2121/path" produced
        // unusable URLs. Applied only when it normalizes cleanly.
        var migrated = self
        if migrated.normalizeHostInput() == nil { self = migrated }
    }
}
