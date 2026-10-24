import Foundation

/// A production bridge between the credential-free delivery workflow and the existing curl-backed
/// FTP service. The inventory is copied when the transport is built. Credentials are resolved only
/// inside `FTPService`, immediately before an operation, and are never represented in a transfer,
/// checkpoint, progress value, or outward error.
nonisolated enum DeliveryFTPTransportFactory {
    /// `onCompatibilityLearned` receives the connection UUID, the upload outcome and the file
    /// name whenever an upload taught something new about the server's temporary-name/rename
    /// support (see `FTPConnection.learnServerCompatibility`), so the owner can persist it.
    /// The transport applies the same learning to its own copy for the rest of its lifetime.
    static func make(
        connections: [FTPConnection],
        secretLoader: FTPService.DeliverySecretLoader = .keychain,
        processRunner: FTPService.DeliveryProcessRunner = .live,
        retryDelay: Duration = FTPService.transientRetryDelay,
        makeTemporaryToken: @escaping @Sendable () -> String = FTPService.randomTemporaryToken,
        onCompatibilityLearned: @escaping @Sendable (UUID, FTPUploadOutcome, String) -> Void = { _, _, _ in }
    ) -> DeliveryUploadTransport {
        let inventory = connections
        let service = FTPService()
        let compatibility = DeliveryServerCompatibility(connections)

        return DeliveryUploadTransport(
            upload: { transfer in
                do {
                    var resolved = try resolve(transfer, in: inventory)
                    guard !resolved.requiresFirstInsecureUploadAcknowledgement else {
                        throw DeliveryFTPTransportError.insecureTransportNotAcknowledged
                    }
                    try await validateExactLocalEvidence(transfer)
                    compatibility.apply(to: &resolved)
                    let outcome = try await service.uploadDeliveryFile(
                        localURL: transfer.localURL,
                        outputFilename: transfer.outputFilename,
                        connection: resolved,
                        secretLoader: secretLoader,
                        processRunner: processRunner,
                        retryDelay: retryDelay,
                        makeTemporaryToken: makeTemporaryToken
                    )
                    if compatibility.learn(resolved.id, from: outcome, fileName: transfer.outputFilename) {
                        onCompatibilityLearned(resolved.id, outcome, transfer.outputFilename)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as DeliveryFTPTransportError {
                    throw error
                } catch let error as FTPService.DeliveryBoundaryError {
                    throw map(error)
                } catch {
                    throw DeliveryFTPTransportError.uploadFailed
                }
            },
            remoteStat: { transfer in
                do {
                    let resolved = try resolve(transfer, in: inventory)
                    switch try await service.observeDeliveryRemoteFile(
                        outputFilename: transfer.outputFilename,
                        connection: resolved,
                        secretLoader: secretLoader,
                        processRunner: processRunner
                    ) {
                    case .unavailable: return .unavailable
                    case .missing: return .missing
                    case let .exists(byteCount): return .exists(byteCount: byteCount)
                    }
                } catch let error as DeliveryFTPTransportError {
                    throw error
                } catch let error as FTPService.DeliveryBoundaryError {
                    throw map(error)
                } catch {
                    throw DeliveryFTPTransportError.remoteObservationUnavailable
                }
            }
        )
    }

    private static func resolve(
        _ transfer: DeliveryUploadTransfer,
        in inventory: [FTPConnection]
    ) throws -> FTPConnection {
        guard let identifier = UUID(uuidString: transfer.connectionIdentifier),
              identifier.uuidString.lowercased() == transfer.connectionIdentifier else {
            throw DeliveryFTPTransportError.invalidConnectionIdentifier
        }

        let matches = inventory.filter { $0.id == identifier }
        guard matches.count == 1, var connection = matches.first else {
            throw DeliveryFTPTransportError.connectionUnavailable
        }
        guard isSafeFilename(transfer.outputFilename),
              transfer.localURL.isFileURL,
              transfer.localURL.lastPathComponent == transfer.outputFilename,
              isSafeRemoteDirectory(transfer.remoteDirectory),
              transfer.expectedByteCount >= 0,
              isValidSHA256(transfer.expectedSHA256) else {
            throw DeliveryFTPTransportError.unsafeTransfer
        }

        do {
            let values = try transfer.localURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.fileSize.map(Int64.init) == transfer.expectedByteCount else {
                throw DeliveryFTPTransportError.unsafeTransfer
            }
        } catch let error as DeliveryFTPTransportError {
            throw error
        } catch {
            throw DeliveryFTPTransportError.unsafeTransfer
        }

        // A deadline profile may resolve a subdirectory dynamically. Only the path changes; host,
        // protocol, port, username, and security policy always come from the UUID-selected inventory.
        connection.remotePath = transfer.remoteDirectory
        return connection
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
              value.utf8.count <= 255,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("/"), !value.contains("\\") else { return false }
        return URL(fileURLWithPath: value).lastPathComponent == value
    }

    private static func isSafeRemoteDirectory(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("\\"), !value.contains("://") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0 != "." && $0 != ".."
        }
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    /// Re-establishes the cryptographic identity at the production transport boundary. The upload
    /// coordinator publishes progress after its own inspection, and that callback is an actor
    /// reentrancy point at which same-size bytes could otherwise be substituted before curl reads
    /// the path. This check also runs before Keychain access.
    private static func validateExactLocalEvidence(
        _ transfer: DeliveryUploadTransfer
    ) async throws {
        do {
            let before = try transfer.localURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard before.isRegularFile == true,
                  before.fileSize.map(Int64.init) == transfer.expectedByteCount else {
                throw DeliveryFTPTransportError.unsafeTransfer
            }
            let digest = try await HashStream.hashFile(at: transfer.localURL).lowercaseHexString
            let after = try transfer.localURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard after.isRegularFile == true,
                  after.fileSize == before.fileSize,
                  digest == transfer.expectedSHA256 else {
                throw DeliveryFTPTransportError.unsafeTransfer
            }
        } catch let error as DeliveryFTPTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeliveryFTPTransportError.unsafeTransfer
        }
    }

    private static func map(
        _ error: FTPService.DeliveryBoundaryError
    ) -> DeliveryFTPTransportError {
        switch error {
        case .credentialUnavailable: .credentialUnavailable
        case .invalidConnection: .connectionUnavailable
        case .invalidTransfer: .unsafeTransfer
        case .processLaunchFailed: .uploadFailed
        case let .transferFailed(category):
            switch category {
            case .loginDenied: .loginDenied
            case .accessDenied: .accessDenied
            case .serverUnreachable: .serverUnreachable
            case .ftpsUnsupported: .ftpsUnsupported
            case .certificateUntrusted: .certificateUntrusted
            case .secureConnectionFailed: .secureConnectionFailed
            case .timedOut: .timedOut
            case .fileRejected: .fileRejected
            }
        }
    }
}

/// What this transport knows about each connection's temporary-name/rename support: seeded
/// from the saved profiles and updated by every upload, so later files in a batch benefit.
private nonisolated final class DeliveryServerCompatibility: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [UUID: FTPConnection]

    init(_ connections: [FTPConnection]) {
        profiles = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func apply(to connection: inout FTPConnection) {
        guard let known = lock.withLock({ profiles[connection.id] }) else { return }
        connection.serverRefusesRename = known.serverRefusesRename
        connection.serverRefusesTemporaryName = known.serverRefusesTemporaryName
        connection.renameRefusalCount = known.renameRefusalCount
        connection.lastRenameRefusalFileName = known.lastRenameRefusalFileName
    }

    /// Returns true when the outcome changed what is known.
    func learn(_ identifier: UUID, from outcome: FTPUploadOutcome, fileName: String) -> Bool {
        lock.withLock {
            guard var profile = profiles[identifier] else { return false }
            let changed = profile.learnServerCompatibility(from: outcome, fileName: fileName)
            profiles[identifier] = profile
            return changed
        }
    }
}

/// Fixed, non-diagnostic errors. In particular, no underlying Keychain status, curl output,
/// connection field, URL, username, filename, or secret can cross the transport boundary.
nonisolated enum DeliveryFTPTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidConnectionIdentifier
    case connectionUnavailable
    case credentialUnavailable
    case insecureTransportNotAcknowledged
    case unsafeTransfer
    case uploadFailed
    case remoteObservationUnavailable
    // Fixed transfer categories derived from curl's exit status — never its output.
    case loginDenied
    case accessDenied
    case serverUnreachable
    case ftpsUnsupported
    case certificateUntrusted
    case secureConnectionFailed
    case timedOut
    case fileRejected

    /// True when every remaining file would fail the same way, so the batch should stop.
    var isServerLevel: Bool {
        switch self {
        case .invalidConnectionIdentifier, .connectionUnavailable, .credentialUnavailable,
             .insecureTransportNotAcknowledged, .loginDenied, .accessDenied, .serverUnreachable,
             .ftpsUnsupported, .certificateUntrusted, .secureConnectionFailed:
            true
        case .unsafeTransfer, .uploadFailed, .remoteObservationUnavailable, .timedOut, .fileRejected:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConnectionIdentifier:
            "The delivery connection identifier is invalid."
        case .connectionUnavailable:
            "The saved delivery connection is unavailable or invalid."
        case .credentialUnavailable:
            "The credential for the saved delivery connection is unavailable."
        case .insecureTransportNotAcknowledged:
            "Acknowledge this insecure delivery connection before its first upload."
        case .unsafeTransfer:
            "The staged delivery file or remote path is invalid."
        case .uploadFailed:
            "The delivery server did not accept the file."
        case .remoteObservationUnavailable:
            "Remote file size information is unavailable."
        case .loginDenied: FTPFailureCategory.loginDenied.userMessage
        case .accessDenied: FTPFailureCategory.accessDenied.userMessage
        case .serverUnreachable: FTPFailureCategory.serverUnreachable.userMessage
        case .ftpsUnsupported: FTPFailureCategory.ftpsUnsupported.userMessage
        case .certificateUntrusted: FTPFailureCategory.certificateUntrusted.userMessage
        case .secureConnectionFailed: FTPFailureCategory.secureConnectionFailed.userMessage
        case .timedOut: FTPFailureCategory.timedOut.userMessage
        case .fileRejected: FTPFailureCategory.fileRejected.userMessage
        }
    }
}

extension FTPService {
    /// Injectable without exposing a secret to `DeliveryUploadTransport` or its caller.
    nonisolated struct DeliverySecretLoader: Sendable {
        fileprivate let load: @Sendable (String) -> String?

        nonisolated init(load: @escaping @Sendable (String) -> String?) {
            self.load = load
        }

        nonisolated static let keychain = Self { KeychainService.load(forKey: $0) }
    }

    nonisolated struct DeliveryProcessResult: Equatable, Sendable {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String

        nonisolated init(
            terminationStatus: Int32,
            standardOutput: String = "",
            standardError: String = ""
        ) {
            self.terminationStatus = terminationStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    /// The runner receives a netrc path, never its contents. This makes protocol flags and curl
    /// result handling testable without placing a credential in an argument vector.
    nonisolated struct DeliveryProcessRunner: Sendable {
        fileprivate let run: @Sendable (URL, [String]) async throws -> DeliveryProcessResult

        nonisolated init(
            run: @escaping @Sendable (URL, [String]) async throws -> DeliveryProcessResult
        ) {
            self.run = run
        }

        nonisolated static let live = Self { executableURL, arguments in
            try await FTPCurlProcessExecutor.run(
                executableURL: executableURL,
                arguments: arguments
            )
        }
    }

    nonisolated enum DeliveryRemoteObservation: Equatable, Sendable {
        case unavailable
        case missing
        case exists(byteCount: Int64?)
    }

    nonisolated enum DeliveryBoundaryError: Error, Equatable, Sendable {
        case credentialUnavailable
        case invalidConnection
        case invalidTransfer
        case processLaunchFailed
        /// curl ran and failed; only the fixed category crosses this boundary, never output.
        case transferFailed(FTPFailureCategory)
    }

    /// Delivery-only upload entry point. Legacy password-taking callers remain source-compatible,
    /// while new workflow code has no API through which it can receive a credential.
    ///
    /// Uses the same temporary-name-then-rename upload as the legacy path
    /// (`FTPService.performUpload`), so the remote stat that follows targets the final name and
    /// a cancelled or broken transfer never leaves a truncated file under it. Cancelling the
    /// calling task terminates curl.
    @discardableResult
    nonisolated func uploadDeliveryFile(
        localURL: URL,
        outputFilename: String,
        connection: FTPConnection,
        secretLoader: DeliverySecretLoader = .keychain,
        processRunner: DeliveryProcessRunner = .live,
        retryDelay: Duration = FTPService.transientRetryDelay,
        makeTemporaryToken: @escaping @Sendable () -> String = FTPService.randomTemporaryToken
    ) async throws -> FTPUploadOutcome {
        // macOS's /usr/bin/curl has no sftp protocol; refuse before touching the credential.
        guard !connection.useSFTP else { throw DeliveryBoundaryError.invalidConnection }
        guard localURL.lastPathComponent == outputFilename,
              validDeliveryConnection(connection) else {
            throw DeliveryBoundaryError.invalidTransfer
        }
        let credential = try deliveryCredential(
            for: connection,
            secretLoader: secretLoader
        )
        let netrcURL = try makeDeliveryNetrc(connection: connection, credential: credential)
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        let curlURL = URL(fileURLWithPath: "/usr/bin/curl")
        do {
            return try await Self.performUpload(
                localPath: localURL.path,
                filename: outputFilename,
                connection: connection,
                netrcPath: netrcURL.path,
                retryDelay: retryDelay,
                makeTemporaryToken: makeTemporaryToken
            ) { arguments, _ in
                try await processRunner.run(curlURL, arguments)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FTPError {
            throw DeliveryBoundaryError.transferFailed(error.category ?? .fileRejected)
        } catch {
            throw DeliveryBoundaryError.processLaunchFailed
        }
    }

    /// A curl HEAD/SIZE probe. This can establish only remote existence and, when the server
    /// reports Content-Length, byte size. It is deliberately not content or cryptographic proof.
    nonisolated func observeDeliveryRemoteFile(
        outputFilename: String,
        connection: FTPConnection,
        secretLoader: DeliverySecretLoader = .keychain,
        processRunner: DeliveryProcessRunner = .live
    ) async throws -> DeliveryRemoteObservation {
        guard !connection.useSFTP else { throw DeliveryBoundaryError.invalidConnection }
        guard validDeliveryConnection(connection), !outputFilename.isEmpty else {
            throw DeliveryBoundaryError.invalidTransfer
        }
        let credential = try deliveryCredential(
            for: connection,
            secretLoader: secretLoader
        )
        let netrcURL = try makeDeliveryNetrc(connection: connection, credential: credential)
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        let arguments = Self.deliveryRemoteStatArguments(
            remoteURL: Self.remoteUploadURL(for: outputFilename, connection: connection),
            netrcPath: netrcURL.path,
            connection: connection
        )
        let result: DeliveryProcessResult
        do {
            result = try await processRunner.run(URL(fileURLWithPath: "/usr/bin/curl"), arguments)
        } catch {
            return .unavailable
        }
        if result.terminationStatus == 78 { return .missing }
        guard result.terminationStatus == 0 else { return .unavailable }
        return .exists(byteCount: Self.deliveryContentLength(in: result.standardOutput))
    }

    nonisolated static func deliveryRemoteStatArguments(
        remoteURL: String,
        netrcPath: String,
        connection: FTPConnection
    ) -> [String] {
        var arguments = [
            "--netrc-file", netrcPath,
            "--head",
            "--silent",
            "--show-error",
            "--globoff",
            "--connect-timeout", "10",
            "--max-time", "30",
            remoteURL,
        ]
        arguments.append(contentsOf: Self.transportFlags(for: connection))
        return arguments
    }

    nonisolated static func deliveryContentLength(in headers: String) -> Int64? {
        for line in headers.split(whereSeparator: \Character.isNewline).reversed() {
            let components = line.split(separator: ":", maxSplits: 1)
            guard components.count == 2,
                  components[0].trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            let value = components[1].trimmingCharacters(in: .whitespaces)
            if let count = Int64(value), count >= 0 { return count }
        }
        return nil
    }

    private nonisolated func validDeliveryConnection(_ connection: FTPConnection) -> Bool {
        !connection.host.isEmpty && !connection.username.isEmpty
            && (1 ... 65_535).contains(connection.port)
            && !connection.host.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
            && !connection.username.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
            && !connection.host.contains("#") && !connection.username.contains("#")
    }

    private nonisolated func deliveryCredential(
        for connection: FTPConnection,
        secretLoader: DeliverySecretLoader
    ) throws -> String {
        // Any non-empty password is usable: makeDeliveryNetrc writes it as a quoted netrc token.
        guard let credential = secretLoader.load(connection.keychainKey),
              !credential.isEmpty else {
            throw DeliveryBoundaryError.credentialUnavailable
        }
        return credential
    }

    private nonisolated func makeDeliveryNetrc(
        connection: FTPConnection,
        credential: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("netrc")
        guard let content = try? Self.netrcContent(
                  host: connection.host,
                  username: connection.username,
                  password: credential
              ),
              let data = content.data(using: .utf8) else {
            throw DeliveryBoundaryError.credentialUnavailable
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw DeliveryBoundaryError.processLaunchFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw DeliveryBoundaryError.processLaunchFailed
        }
    }
}
