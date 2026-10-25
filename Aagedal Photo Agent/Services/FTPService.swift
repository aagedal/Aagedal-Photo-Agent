import Foundation

struct FTPUploadProgress: Sendable {
    var fileName: String
    var bytesUploaded: Int64
    var totalBytes: Int64
    var fractionCompleted: Double
    var isComplete: Bool
}

/// What a successful upload learned about the server, folded into the profile by
/// `FTPConnection.learnServerCompatibility(from:fileName:)`.
nonisolated struct FTPUploadOutcome: Equatable, Sendable {
    /// The temporary file arrived but RNFR/RNTO was refused (typical for write-only drop
    /// boxes); the file was re-sent directly under its final name.
    var renameRefused: Bool = false
    /// The server refused to store the temporary name itself (dot-file or extension filter);
    /// the file was re-sent directly under its final name, which the server accepted.
    var temporaryNameRefused: Bool = false
    /// The file arrived under the temporary name and was renamed into place.
    var renamedIntoPlace: Bool = false
}

/// Fixed, credential-free classification of a failed curl transfer. Derived from curl's exit
/// status (and, for timeouts, curl's own diagnostic wording) inside `FTPService`, so callers
/// that must never see server output can still act on and report the kind of failure.
nonisolated enum FTPFailureCategory: String, Codable, Equatable, Sendable {
    /// The server refused the user name/password.
    case loginDenied
    /// Logged in, but the server refused access to the remote folder.
    case accessDenied
    /// DNS, connection refused or a connect timeout — nothing reached the server.
    case serverUnreachable
    /// Explicit FTPS was required but the server doesn't offer AUTH TLS.
    case ftpsUnsupported
    /// The server's TLS certificate failed verification.
    case certificateUntrusted
    /// Another TLS handshake failure.
    case secureConnectionFailed
    /// The transfer started but stalled or exceeded its time limit.
    case timedOut
    /// The server rejected this file (or the transfer broke) — other files may still succeed.
    case fileRejected

    /// True when every other file in the batch would fail the same way, so a batch should stop
    /// rather than retry each remaining file (and, for logins, risk a server lockout).
    var isServerLevel: Bool {
        switch self {
        case .loginDenied, .accessDenied, .serverUnreachable, .ftpsUnsupported,
             .certificateUntrusted, .secureConnectionFailed:
            true
        case .timedOut, .fileRejected:
            false
        }
    }

    /// One-sentence, credential-free explanation for the user.
    var userMessage: String {
        switch self {
        case .loginDenied: "Login denied — check the user name and password."
        case .accessDenied: "The server denied access to the remote folder — check the folder and its permissions."
        case .serverUnreachable: "The server couldn't be reached — check the host, port and network."
        case .ftpsUnsupported: "The server doesn't support FTPS — edit the server to use plain FTP or a different port."
        case .certificateUntrusted: "The server's certificate isn't trusted."
        case .secureConnectionFailed: "The secure (TLS) connection to the server failed."
        case .timedOut: "The transfer stalled and timed out."
        case .fileRejected: "The server did not accept the file."
        }
    }
}

struct FTPService: Sendable {
    /// Upload a single file to the FTP server using curl.
    ///
    /// The file is sent to a temporary name (`.<name>.part`) and renamed to its final name only
    /// after a complete transfer, so a hot folder never ingests a truncated image (see
    /// `performUpload`). Returns what the upload learned about the server's rename support.
    @discardableResult
    nonisolated func uploadFile(
        localURL: URL,
        connection: FTPConnection,
        password: String,
        runner: FTPCurlRunner = .live,
        retryDelay: Duration = FTPService.transientRetryDelay,
        makeTemporaryToken: @escaping @Sendable () -> String = FTPService.randomTemporaryToken,
        progressHandler: @Sendable @escaping (FTPUploadProgress) -> Void
    ) async throws -> FTPUploadOutcome {
        try Task.checkCancellation()
        guard !connection.useSFTP else { throw FTPError.sftpUnavailable }
        let netrcContent = try Self.netrcContent(
            host: connection.host,
            username: connection.username,
            password: password
        )

        let fileName = localURL.lastPathComponent
        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        // Write credentials to a temporary .netrc file so the password
        // is not visible to other processes via `ps`.
        let netrcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("netrc")
        guard let netrcData = netrcContent.data(using: .utf8) else {
            throw FTPError.encodingFailed
        }
        try Self.writeNetrcAtomically(netrcData, to: netrcURL)
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        // curl progress bar format: "  % Total    % Received % Xferd  Average Speed..."
        let progressParser: @Sendable (String) -> Void = { chunk in
            if let percentStr = chunk.split(separator: " ").first(where: { $0.hasSuffix("%") || Double($0) != nil }),
               let percent = Double(percentStr.replacingOccurrences(of: "%", with: "")) {
                let fraction = min(percent / 100.0, 1.0)
                progressHandler(FTPUploadProgress(
                    fileName: fileName,
                    bytesUploaded: Int64(fraction * Double(fileSize)),
                    totalBytes: Int64(fileSize),
                    fractionCompleted: fraction,
                    isComplete: false
                ))
            }
        }

        let outcome = try await Self.performUpload(
            localPath: localURL.path,
            filename: fileName,
            connection: connection,
            netrcPath: netrcURL.path,
            retryDelay: retryDelay,
            makeTemporaryToken: makeTemporaryToken
        ) { arguments, isTransfer in
            try await runner.run(arguments, isTransfer ? progressParser : nil)
        }

        progressHandler(FTPUploadProgress(
            fileName: fileName,
            bytesUploaded: Int64(fileSize),
            totalBytes: Int64(fileSize),
            fractionCompleted: 1.0,
            isComplete: true
        ))
        return outcome
    }

    // MARK: - Upload algorithm (shared by the legacy and Deadline delivery paths)

    /// curl's `CURLE_QUOTE_ERROR`: a quote command (here: the post-transfer RNFR/RNTO) was
    /// refused. Post-quote commands only run after a complete transfer, so this status means
    /// the temporary file arrived but could not be renamed.
    nonisolated static let curlQuoteErrorExitCode: Int32 = 21
    /// curl's `CURLE_UPLOAD_FAILED`: the server refused the STOR command (550/553/452…). On the
    /// temporary name this is usually a dot-file or extension filter.
    nonisolated static let curlUploadRefusedExitCode: Int32 = 25

    /// Exit statuses retried in-app: couldn't connect (7), timed out/stalled (28), send (55)
    /// and receive (56) errors — the transient failures of a bad network. Everything else
    /// (notably login failures) is never retried, so a wrong password can't lock an account.
    nonisolated static let transientExitCodes: Set<Int32> = [7, 28, 55, 56]
    nonisolated static let maximumTransferAttempts = 4
    nonisolated static let transientRetryDelay: Duration = .seconds(2)

    /// A short random token so every attempt uses a fresh temporary name: a leftover from an
    /// earlier attempt on a server that allows neither overwrite nor delete can't block it.
    nonisolated static func randomTemporaryToken() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    /// The temporary name a file is uploaded under before being renamed into place:
    /// `.<name>.<token>.part`.
    ///
    /// The name deliberately does *not* end in the image extension: hot-folder ingesters that
    /// match `*.jpg` would otherwise pick up the partial file mid-transfer, which is exactly
    /// what the temporary name prevents. The leading dot hides it from scanners that skip
    /// hidden files, and `.part` from those that match extensions. Servers that refuse such a
    /// name (dot-file or extension filters) are handled by a direct re-send and remembered.
    ///
    /// Returns `nil` (upload directly) when the name can't safely be used in an RNFR/RNTO
    /// command — control characters would split the FTP command line — or would exceed a
    /// 255-byte file-name limit.
    nonisolated static func temporaryUploadName(for filename: String, token: String) -> String? {
        let candidate = ".\(filename).\(token).part"
        guard !filename.isEmpty,
              candidate.utf8.count <= 255,
              !filename.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { return nil }
        return candidate
    }

    /// Uploads one file and, unless the profile is known to need direct uploads, atomically:
    ///
    /// 1. STOR to `.<name>.<token>.part` (curl `-T` to the temporary URL), then — only after a
    ///    complete transfer — post-quote `DELE <name>` (failure ignored: some servers, e.g. IIS,
    ///    refuse to RNTO over an existing file), `RNFR <temp>`, `RNTO <name>`. Post-quote
    ///    commands run in the URL's directory, so the bare names are relative to it. They are
    ///    passed through a `-K` config file, never argv: `Process` converts arguments to NFD,
    ///    which would make "å" in RNFR differ byte-for-byte from the NFC name curl STORed.
    /// 2. Transient failures (7/28/55/56) are retried in-app, each attempt with a fresh
    ///    temporary name, so a broken attempt never surfaces under the final name.
    /// 3. If the server refuses the temporary name itself (curl 25 on its STOR) or the rename
    ///    (curl 21), the temporary file is deleted best-effort and the file is re-sent once
    ///    directly; the outcome reports which, for `FTPConnection.learnServerCompatibility`.
    /// 4. On failure or cancellation the temporary file is deleted best-effort (skipped for
    ///    server-level failures, where a cleanup connection would fail the same way).
    ///
    /// `run` executes one curl invocation; its second argument is true for the transfer itself
    /// (callers attach progress parsing to it) and false for the cleanup command.
    nonisolated static func performUpload(
        localPath: String,
        filename: String,
        connection: FTPConnection,
        netrcPath: String,
        retryDelay: Duration = transientRetryDelay,
        makeTemporaryToken: @Sendable () -> String = randomTemporaryToken,
        run: @escaping @Sendable (_ arguments: [String], _ isTransfer: Bool) async throws -> DeliveryProcessResult
    ) async throws -> FTPUploadOutcome {
        var useTemporaryName = !connection.uploadsDirectly && !connection.useSFTP
        var outcome = FTPUploadOutcome()
        var attempt = 0

        while true {
            attempt += 1
            try Task.checkCancellation()
            let temporaryName = useTemporaryName
                ? temporaryUploadName(for: filename, token: makeTemporaryToken())
                : nil
            let result: DeliveryProcessResult
            do {
                result = try await withQuoteConfig(
                    temporaryName.map { quoteCommands(filename: filename, temporaryName: $0) } ?? []
                ) { configPath in
                    try await run(uploadArguments(
                        localPath: localPath,
                        filename: filename,
                        temporaryName: temporaryName,
                        quoteConfigPath: configPath,
                        netrcPath: netrcPath,
                        connection: connection
                    ), true)
                }
            } catch is CancellationError {
                if let temporaryName {
                    await removeTemporaryUpload(temporaryName, netrcPath: netrcPath, connection: connection, run: run)
                }
                throw CancellationError()
            }

            let status = result.terminationStatus
            if status == 0 {
                outcome.renamedIntoPlace = temporaryName != nil
                return outcome
            }
            if let temporaryName, status == curlQuoteErrorExitCode || status == curlUploadRefusedExitCode {
                // The server accepted the transfer but not the rename (21), or refused the
                // temporary name itself (25): clean up and re-send once under the final name.
                await removeTemporaryUpload(temporaryName, netrcPath: netrcPath, connection: connection, run: run)
                if status == curlQuoteErrorExitCode {
                    outcome.renameRefused = true
                } else {
                    outcome.temporaryNameRefused = true
                }
                useTemporaryName = false
                attempt = 0
                continue
            }
            let category = failureCategory(exitCode: status, stderr: result.standardError)
            if transientExitCodes.contains(status), attempt < maximumTransferAttempts {
                // 28/55/56 may have left a partial temporary file; 7 never connected.
                if let temporaryName, status != 7 {
                    await removeTemporaryUpload(temporaryName, netrcPath: netrcPath, connection: connection, run: run)
                }
                if retryDelay > .zero { try await Task.sleep(for: retryDelay) }
                continue
            }
            if let temporaryName, !category.isServerLevel {
                await removeTemporaryUpload(temporaryName, netrcPath: netrcPath, connection: connection, run: run)
            }
            throw FTPError.uploadFailed(status, result.standardError)
        }
    }

    /// The post-transfer commands that move a complete temporary upload into place.
    /// "-" = after the transfer, and only if it succeeded; "*" = ignore a failure.
    nonisolated static func quoteCommands(filename: String, temporaryName: String) -> [String] {
        [
            "-*DELE \(filename)",
            "-RNFR \(temporaryName)",
            "-RNTO \(filename)",
        ]
    }

    /// curl config-file text for `quote` options. Values are double-quoted with `\` and `"`
    /// escaped (curl's config syntax); control characters never reach here (see
    /// `temporaryUploadName`). Written as UTF-8 exactly as the Swift string holds it.
    nonisolated static func curlConfigContent(quoteCommands: [String]) -> String {
        quoteCommands.map { command in
            var escaped = ""
            for scalar in command.unicodeScalars {
                switch scalar {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return "quote = \"\(escaped)\"\n"
        }.joined()
    }

    /// Writes `quoteCommands` to a private (0600) curl config file for the duration of
    /// `body`, then removes it. With no commands, `body` gets `nil` and no file is written.
    nonisolated static func withQuoteConfig<T>(
        _ quoteCommands: [String],
        _ body: (String?) async throws -> T
    ) async throws -> T {
        guard !quoteCommands.isEmpty else { return try await body(nil) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("curlrc")
        try writePrivateFile(Data(curlConfigContent(quoteCommands: quoteCommands).utf8), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url.path)
    }

    /// Best-effort `DELE` of a leftover temporary upload. Runs detached so a cancelled upload
    /// can still clean up after itself; bounded by short curl timeouts.
    nonisolated private static func removeTemporaryUpload(
        _ temporaryName: String,
        netrcPath: String,
        connection: FTPConnection,
        run: @escaping @Sendable ([String], Bool) async throws -> DeliveryProcessResult
    ) async {
        await Task.detached {
            _ = try? await withQuoteConfig(["-DELE \(temporaryName)"]) { configPath in
                try await run(cleanupArguments(
                    quoteConfigPath: configPath ?? "",
                    netrcPath: netrcPath,
                    connection: connection
                ), false)
            }
        }.value
    }

    /// The full curl argument vector for one transfer attempt: direct to `filename`, or to
    /// `temporaryName` with the rename commands read from `quoteConfigPath` (`-K`).
    nonisolated static func uploadArguments(
        localPath: String,
        filename: String,
        temporaryName: String?,
        quoteConfigPath: String?,
        netrcPath: String,
        connection: FTPConnection
    ) -> [String] {
        var arguments = curlArguments(
            localPath: localPath,
            remoteURL: remoteUploadURL(for: temporaryName ?? filename, connection: connection),
            netrcPath: netrcPath,
            connection: connection
        )
        if temporaryName != nil, let quoteConfigPath {
            arguments += ["-K", quoteConfigPath]
        }
        return arguments
    }

    /// `curl --head` on the remote directory with a post-quote `DELE` (from the `-K` config):
    /// connects, changes into the folder and deletes the temporary file without listing or
    /// transferring anything (listing is often forbidden on drop boxes).
    nonisolated static func cleanupArguments(
        quoteConfigPath: String,
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
            "--max-time", "20",
            remoteDirectoryURL(connection: connection),
            "-K", quoteConfigPath,
        ]
        arguments.append(contentsOf: transportFlags(for: connection))
        return arguments
    }

    // MARK: - Connection test

    /// Probes a connection without transferring a file: connect + authenticate + list the
    /// configured remote directory. Reuses the same credential handling and transport/security
    /// flags as the upload path so a passing test reflects what an upload would do. Fails fast
    /// (`--connect-timeout`, no retries) — a probe should surface an unreachable server
    /// immediately rather than retrying for several seconds.
    ///
    /// Uploads create a missing remote folder (`--ftp-create-dirs`), so when only the folder
    /// can't be entered the server root is listed instead; if that works the test passes and
    /// the returned note says so. Returns `nil` when the configured folder itself listed.
    nonisolated func testConnection(
        connection: FTPConnection,
        password: String,
        runner: FTPCurlRunner = .live
    ) async throws -> String? {
        try Task.checkCancellation()
        guard !connection.useSFTP else { throw FTPError.sftpUnavailable }
        let netrcContent = try Self.netrcContent(
            host: connection.host,
            username: connection.username,
            password: password
        )

        let netrcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("netrc")
        guard let netrcData = netrcContent.data(using: .utf8) else {
            throw FTPError.encodingFailed
        }
        try Self.writeNetrcAtomically(netrcData, to: netrcURL)
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        let directoryProbe = try await runner.run(Self.testConnectionArguments(
            remoteURL: Self.remoteDirectoryURL(connection: connection),
            netrcPath: netrcURL.path,
            connection: connection
        ), nil)
        if directoryProbe.terminationStatus == 0 { return nil }

        // Login worked but the folder couldn't be entered: check the root before blaming the server.
        var root = connection
        root.remotePath = "/"
        if Self.isMissingDirectoryStatus(directoryProbe.terminationStatus),
           Self.remoteDirectoryURL(connection: root) != Self.remoteDirectoryURL(connection: connection) {
            let rootProbe = try await runner.run(Self.testConnectionArguments(
                remoteURL: Self.remoteDirectoryURL(connection: root),
                netrcPath: netrcURL.path,
                connection: connection
            ), nil)
            if rootProbe.terminationStatus == 0 {
                return "Connected. The folder “\(connection.remotePath)” doesn't exist yet or can't be listed; uploads will try to create it."
            }
        }
        throw FTPError.connectionTestFailed(directoryProbe.terminationStatus, directoryProbe.standardError)
    }

    /// curl exit statuses meaning login worked but the remote folder could not be entered
    /// (9 = server denied changing into it, 78 = it does not exist).
    nonisolated static func isMissingDirectoryStatus(_ status: Int32) -> Bool {
        status == 9 || status == 78
    }

    // MARK: - URLs and arguments

    /// Builds the remote upload target URL for a file. Extracted as a pure function
    /// so the filename encoding is unit-testable.
    ///
    /// The filename is percent-encoded so characters the URL parser treats specially
    /// survive into the remote path — most importantly `#` (a URL fragment) and `?`
    /// (a query), either of which silently truncates the path so the file would upload
    /// under a mangled name (e.g. "Shot #3.jpg" → `STOR Shot `, verified against curl).
    /// Spaces, `%`, brackets and non-ASCII are encoded too. curl percent-decodes the
    /// path for both FTP and SFTP before issuing the transfer command, so the file
    /// lands on the server under its real name.
    ///
    /// The configured remote directory is percent-encoded with `.urlPathAllowed`, which
    /// keeps its `/` path separators intact but encodes characters the URL parser would
    /// otherwise act on — `#` (fragment) and `?` (query) would truncate the directory the
    /// same way they truncate filenames, and a space would break the URL. `--globoff` in
    /// `curlArguments` additionally keeps any `[]`/`{}` there from being misread as glob
    /// patterns. curl percent-decodes the path before issuing the transfer command.
    nonisolated static func remoteUploadURL(for filename: String, connection: FTPConnection) -> String {
        let scheme = connection.useSFTP ? "sftp" : "ftp"
        let rawPath = connection.remotePath.hasSuffix("/")
            ? connection.remotePath
            : connection.remotePath + "/"
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return "\(scheme)://\(connection.host):\(connection.port)\(encodedPath)\(encodedName)"
    }

    /// Builds the URL for the configured remote directory (trailing slash), used by the
    /// connection test to list it. The trailing slash is what makes curl treat the target
    /// as a directory to list rather than a file to fetch.
    nonisolated static func remoteDirectoryURL(connection: FTPConnection) -> String {
        let scheme = connection.useSFTP ? "sftp" : "ftp"
        let rawPath = connection.remotePath.hasSuffix("/")
            ? connection.remotePath
            : connection.remotePath + "/"
        let encodedPath = rawPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawPath
        return "\(scheme)://\(connection.host):\(connection.port)\(encodedPath)"
    }

    /// Builds the curl argument vector for a connection test (directory listing). Shares
    /// the transport/security flags with the upload path via `transportFlags`, but fails
    /// fast: a short `--connect-timeout` and no retries, so an unreachable server is
    /// surfaced immediately instead of after several retry cycles.
    nonisolated static func testConnectionArguments(
        remoteURL: String,
        netrcPath: String,
        connection: FTPConnection
    ) -> [String] {
        var arguments = [
            "--netrc-file", netrcPath,
            "--connect-timeout", "10",
            "--max-time", "20",
            "--globoff",
            "--list-only",
            remoteURL,
        ]
        arguments.append(contentsOf: transportFlags(for: connection))
        return arguments
    }

    /// The TLS/SFTP/insecure flags shared by the upload and test-connection paths, so a
    /// passing test exercises the same transport security an upload would.
    nonisolated static func transportFlags(for connection: FTPConnection) -> [String] {
        var flags: [String] = []
        if connection.useSFTP {
            if connection.allowInsecureHostVerification {
                flags.append("--insecure")
            }
        } else if connection.useTLS {
            // Explicit FTPS: require AUTH TLS and abort if the server can't upgrade,
            // rather than silently transferring credentials in the clear. --insecure
            // additionally skips certificate verification for self-signed servers.
            flags.append("--ssl-reqd")
            if connection.allowInsecureHostVerification {
                flags.append("--insecure")
            }
        }
        return flags
    }

    /// Builds the curl argument vector for one direct transfer to `remoteURL`. Extracted as a
    /// pure function so the security-critical transport flags are unit-testable: explicit FTPS
    /// must add `--ssl-reqd` (so a TLS failure aborts rather than silently sending credentials
    /// in the clear), and plain FTP must carry no TLS/insecure flags.
    ///
    /// There is deliberately no `--retry`: curl's `--retry-all-errors` retried login failures
    /// (risking account lockouts) and restarted a broken STOR under the final name. Transient
    /// failures are retried in-app instead (`runRetryingTransientFailures`), always against the
    /// temporary name.
    nonisolated static func curlArguments(
        localPath: String,
        remoteURL: String,
        netrcPath: String,
        connection: FTPConnection
    ) -> [String] {
        var arguments = [
            "-T", localPath,
            "--netrc-file", netrcPath,
            "--progress-bar",
            // Take the URL literally: never treat `[`/`]`/`{`/`}` in the configured
            // remote directory as curl glob patterns, which would otherwise abort the
            // upload with "bad range specification". The filename component is
            // percent-encoded upstream (see remoteUploadURL); this guards the
            // remaining unencoded path (the user's remote directory).
            "--globoff",
            // Never let a black-holed server freeze progress indefinitely: give up on a
            // connection attempt after 15 s, and abort a transfer that moves less than
            // 1 byte/s for 60 s. With the in-app retries a dead server fails in ~1 minute.
            "--connect-timeout", "15",
            "--speed-limit", "1",
            "--speed-time", "60",
            remoteURL,
        ]

        if !connection.useSFTP {
            arguments.append("--ftp-create-dirs")
        }
        arguments.append(contentsOf: transportFlags(for: connection))
        return arguments
    }

    // MARK: - Failure classification

    /// Maps a curl exit status to a fixed category. curl 28 covers both a connect timeout
    /// (nothing reached the server) and a stalled transfer; curl's own diagnostic tells them
    /// apart, and an unrecognized 28 is treated conservatively as unreachable.
    nonisolated static func failureCategory(exitCode: Int32, stderr: String = "") -> FTPFailureCategory {
        switch exitCode {
        case 67: return .loginDenied
        case 9: return .accessDenied
        case 1, 5, 6, 7: return .serverUnreachable
        case 28:
            let lowered = stderr.lowercased()
            if lowered.contains("too slow") || lowered.contains("operation timed out") {
                return .timedOut
            }
            return .serverUnreachable
        case 64: return .ftpsUnsupported
        case 51, 60, 83: return .certificateUntrusted
        case 35, 58, 59, 66, 77, 80, 90, 91: return .secureConnectionFailed
        default: return .fileRejected
        }
    }

    // MARK: - Credentials

    /// Builds the one-line netrc entry curl reads credentials from. The login and password are
    /// written as quoted tokens (supported by curl ≥ 7.84, macOS ships 8.x) so spaces, `#`,
    /// quotes and backslashes survive intact instead of splitting the token, starting a comment
    /// or injecting extra `machine` entries. Inside quotes curl unescapes `\"`, `\\`, `\n`,
    /// `\r` and `\t`. The host is a bare `machine` token and must not contain such characters
    /// (no valid host name does).
    nonisolated static func netrcContent(host: String, username: String, password: String) throws -> String {
        if host.isEmpty { throw FTPError.invalidCredential("host", reason: "is empty") }
        if host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
            || host.contains("#") || host.contains("\"") {
            throw FTPError.invalidCredential("host", reason: "contains spaces, '#' or quotes")
        }
        if username.isEmpty { throw FTPError.invalidCredential("username", reason: "is empty") }
        if password.isEmpty { throw FTPError.invalidCredential("password", reason: "is empty") }
        return "machine \(host) login \(netrcQuoted(username)) password \(netrcQuoted(password))\n"
    }

    nonisolated static func netrcQuoted(_ value: String) -> String {
        // Escape by Unicode scalar, not Character: a quote or backslash followed by a combining
        // mark forms one Character that would otherwise slip through unescaped.
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": quoted += "\\\\"
            case "\"": quoted += "\\\""
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// Create the .netrc with mode 0o600 in a single open(2) call so the file
    /// never exists with default umask permissions (closes the chmod TOCTOU
    /// against other processes running as the same user).
    nonisolated static func writePrivateFile(_ data: Data, to url: URL) throws {
        try writeNetrcAtomically(data, to: url)
    }

    nonisolated private static func writeNetrcAtomically(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else {
            throw FTPError.netrcCreationFailed(errno)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    enum FTPError: LocalizedError {
        case uploadFailed(Int32, String)
        case connectionTestFailed(Int32, String)
        case encodingFailed
        case invalidCredential(String, reason: String)
        case netrcCreationFailed(Int32)
        case sftpUnavailable

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let code, let stderr):
                return Self.describe(code: code, stderr: stderr, prefix: "Upload failed")
            case .connectionTestFailed(let code, let stderr):
                return Self.describe(code: code, stderr: stderr, prefix: "Connection test failed")
            case .encodingFailed:
                return "Failed to encode FTP credentials as UTF-8"
            case .invalidCredential(let field, let reason):
                return "FTP \(field) \(reason). Edit the server to fix it."
            case .netrcCreationFailed(let errno):
                return "Failed to create temporary credential file (errno \(errno))"
            case .sftpUnavailable:
                return FTPConnection.sftpUnavailableMessage
            }
        }

        /// The fixed failure category for a curl failure; `nil` for local/configuration errors.
        var category: FTPFailureCategory? {
            switch self {
            case .uploadFailed(let code, let stderr), .connectionTestFailed(let code, let stderr):
                return FTPService.failureCategory(exitCode: code, stderr: stderr)
            case .invalidCredential, .sftpUnavailable, .encodingFailed, .netrcCreationFailed:
                return nil
            }
        }

        /// True when the failure means every other file in the batch would fail the
        /// same way — the server is unreachable, rejecting auth, refusing TLS, the
        /// credentials or protocol are unusable — so the upload loop should stop rather
        /// than retry each remaining file in turn. File-specific failures (e.g. 23 disk
        /// write, 26 local read, 25 STOR refused, a stalled transfer) stay non-fatal.
        var isServerLevel: Bool {
            category?.isServerLevel ?? true
        }

        nonisolated static func isServerLevelExitCode(_ code: Int32) -> Bool {
            FTPService.failureCategory(exitCode: code).isServerLevel
        }

        private static func describe(code: Int32, stderr: String, prefix: String) -> String {
            let description = curlExitCodeDescription(code, prefix: prefix)
            if let detail = extractCurlError(from: stderr) {
                return "\(description) \u{2014} \(detail)"
            }
            return description
        }

        private static func curlExitCodeDescription(_ code: Int32, prefix: String) -> String {
            switch code {
            case 1:  return "\(prefix): protocol not supported by macOS's curl"
            case 5:  return "\(prefix): proxy connection refused"
            case 6:  return "\(prefix): could not resolve host"
            case 7:  return "\(prefix): could not connect to server"
            case 9:  return "\(prefix): the server denied access to the remote folder — check the folder and its permissions"
            case 21: return "\(prefix): the server refused a command (rename)"
            case 23: return "\(prefix): could not write data to disk"
            case 25: return "\(prefix): the server refused to store the file"
            case 26: return "\(prefix): could not read local file"
            case 28: return "\(prefix): connection timed out or stalled"
            case 35: return "\(prefix): SSL/TLS handshake error"
            case 51, 60, 83: return "\(prefix): The server's certificate isn't trusted"
            case 55: return "\(prefix): error sending data"
            case 56: return "\(prefix): error receiving data"
            case 58, 59, 66, 77, 80, 90, 91: return "\(prefix): the secure (TLS) connection failed"
            case 64: return "\(prefix): The server doesn't support FTPS — edit the server to use plain FTP or a different port"
            case 67: return "\(prefix): Login denied — check the user name and password"
            case 78: return "\(prefix): remote folder not found"
            default:
                return prefix == "Upload failed"
                    ? "The upload stopped unexpectedly. Try again; if it keeps failing, use Test Connection in Settings → FTP."
                    : "The connection test failed unexpectedly. Check the server settings and try again."
            }
        }

        /// Extracts the last "curl: (N) ..." diagnostic from stderr. `--progress-bar` redraws
        /// with carriage returns, so the diagnostic can follow progress output on one line.
        nonisolated static func extractCurlError(from stderr: String) -> String? {
            stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .compactMap { line -> String? in
                    guard let range = line.range(of: "curl: (") else { return nil }
                    return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
                }
                .last
        }
    }
}

// MARK: - curl process execution

/// Runs one `/usr/bin/curl` invocation. The second argument, when non-nil, receives stderr
/// chunks as they arrive (the legacy path parses progress from it). Injectable so tests never
/// launch curl or touch a server.
nonisolated struct FTPCurlRunner: Sendable {
    let run: @Sendable (_ arguments: [String], _ stderrChunk: (@Sendable (String) -> Void)?) async throws
        -> FTPService.DeliveryProcessResult

    nonisolated init(
        run: @escaping @Sendable (_ arguments: [String], _ stderrChunk: (@Sendable (String) -> Void)?) async throws
            -> FTPService.DeliveryProcessResult
    ) {
        self.run = run
    }

    nonisolated static let live = Self { arguments, stderrChunk in
        try await FTPCurlProcessExecutor.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: arguments,
            stderrChunk: stderrChunk
        )
    }
}

private nonisolated final class FTPCurlProcessBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit = 64 * 1024

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            storage.append(data)
            if storage.count > limit { storage = storage.suffix(limit) }
        }
    }

    var string: String {
        lock.withLock { String(decoding: storage, as: UTF8.self) }
    }
}

private nonisolated final class FTPCurlProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var cancelled = false
    private var transferComplete = false
    private var progressTail = ""
    private var process: Process?

    func install(_ process: Process) -> Bool {
        lock.withLock {
            self.process = process
            return cancelled
        }
    }

    /// Watches curl's progress output for "100.0%": every byte is sent and curl is only
    /// waiting for the server's acknowledgement and then running the post-transfer rename.
    func observeProgress(_ text: String) {
        lock.withLock {
            guard !transferComplete else { return }
            let window = progressTail + text
            if window.contains("100.0%") { transferComplete = true }
            progressTail = String(window.suffix(8))
        }
    }

    func cancel() {
        let (process, deferTermination) = lock.withLock { () -> (Process?, Bool) in
            cancelled = true
            return (self.process, transferComplete)
        }
        guard let process else { return }
        if deferTermination {
            // Interrupting now could leave the file half-renamed (after `DELE <name>`, before
            // `RNTO`) or record a delivered file as cancelled. Let curl finish the short
            // acknowledgement + rename phase; terminate only if it hangs.
            FTPCurlProcessExecutor.terminate(process, after: FTPCurlProcessExecutor.postTransferGracePeriod)
        } else {
            FTPCurlProcessExecutor.terminate(process)
        }
    }

    func claim() -> (claimed: Bool, cancelled: Bool) {
        lock.withLock {
            guard !resumed else { return (false, cancelled) }
            resumed = true
            return (true, cancelled)
        }
    }
}

/// The one place curl processes are launched. Cancellation sends SIGTERM and, if curl is still
/// running after a short grace period (e.g. blocked on a dead socket), SIGKILL — so Cancel stops
/// an in-flight file promptly. On exit the pipes are drained to EOF before the result is built,
/// so curl's final "curl: (N) …" line is never lost to the readability-handler race.
nonisolated enum FTPCurlProcessExecutor {
    static let terminationGracePeriod: TimeInterval = 2

    static func run(
        executableURL: URL,
        arguments: [String],
        stderrChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> FTPService.DeliveryProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        let state = FTPCurlProcessState()
        let stdoutBuffer = FTPCurlProcessBuffer()
        let stderrBuffer = FTPCurlProcessBuffer()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBuffer.append(data)
            if let text = String(data: data, encoding: .utf8) {
                state.observeProgress(text)
                stderrChunk?(text)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever the handlers had not read yet (curl's last error line).
                    stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                    let outcome = state.claim()
                    guard outcome.claimed else { return }
                    // A clean exit 0 means the file arrived (and was renamed): report it even
                    // if a cancel arrived meanwhile, or Resume would upload it a second time.
                    let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                    if outcome.cancelled, !succeeded {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: FTPService.DeliveryProcessResult(
                            terminationStatus: process.terminationStatus,
                            standardOutput: stdoutBuffer.string,
                            standardError: stderrBuffer.string
                        ))
                    }
                }
                do {
                    try process.run()
                    if state.install(process) { terminate(process) }
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let outcome = state.claim()
                    if outcome.claimed {
                        continuation.resume(throwing: outcome.cancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// How long a cancel waits once the transfer reached 100% (server acknowledgement plus the
    /// post-transfer DELE/RNFR/RNTO) before terminating curl anyway.
    static let postTransferGracePeriod: TimeInterval = 15

    /// SIGTERM now (or after `delay`), SIGKILL after the grace period if curl hasn't exited.
    static func terminate(_ process: Process, after delay: TimeInterval = 0) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let sendTerm: @Sendable () -> Void = {
            guard process.isRunning, process.processIdentifier == pid else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + terminationGracePeriod) {
                if process.isRunning, process.processIdentifier == pid {
                    kill(pid, SIGKILL)
                }
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: sendTerm)
        } else {
            sendTerm()
        }
    }
}
