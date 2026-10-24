import Foundation

struct FTPUploadProgress: Sendable {
    var fileName: String
    var bytesUploaded: Int64
    var totalBytes: Int64
    var fractionCompleted: Double
    var isComplete: Bool
}

struct FTPService: Sendable {
    /// Thread-safe buffer for accumulating stderr output from curl.
    private final class LockedBuffer: @unchecked Sendable {
        nonisolated(unsafe) private var buffer = ""
        private let lock = NSLock()
        private let characterLimit = 64 * 1024

        nonisolated func append(_ string: String) {
            lock.withLock {
                buffer += string
                if buffer.count > characterLimit {
                    buffer = String(buffer.suffix(characterLimit))
                }
            }
        }

        nonisolated var value: String {
            lock.withLock { buffer }
        }
    }

    /// Guards a continuation against double-resume when Task cancellation
    /// races with normal process termination.
    private final class CancellationState: @unchecked Sendable {
        nonisolated(unsafe) private var _resumed = false
        nonisolated(unsafe) private var _cancelled = false
        nonisolated(unsafe) private var _launched = false
        private let lock = NSLock()

        nonisolated var isCancelled: Bool {
            lock.withLock { _cancelled }
        }

        nonisolated func markCancelled() {
            lock.withLock { _cancelled = true }
        }

        nonisolated func markLaunched() -> Bool {
            lock.withLock {
                _launched = true
                return _cancelled
            }
        }

        nonisolated var isLaunched: Bool {
            lock.withLock { _launched }
        }

        nonisolated func claimResume() -> Bool {
            lock.withLock {
                if _resumed { return false }
                _resumed = true
                return true
            }
        }
    }

    /// Upload a single file to the FTP server using curl.
    nonisolated func uploadFile(
        localURL: URL,
        connection: FTPConnection,
        password: String,
        progressHandler: @Sendable @escaping (FTPUploadProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard !connection.useSFTP else { throw FTPError.sftpUnavailable }
        let netrcContent = try Self.netrcContent(
            host: connection.host,
            username: connection.username,
            password: password
        )

        let remoteURL = Self.remoteUploadURL(for: localURL.lastPathComponent, connection: connection)

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

        let arguments = Self.curlArguments(
            localPath: localURL.path,
            remoteURL: remoteURL,
            netrcPath: netrcURL.path,
            connection: connection
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Discard stdout. nullDevice (vs an undrained Pipe) can't fill its buffer
        // and block curl if the server ever writes a chatty response.
        process.standardOutput = FileHandle.nullDevice

        // Parse progress from stderr and capture output for error reporting
        let stderrBuffer = LockedBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }

            stderrBuffer.append(str)

            // curl progress bar format: "  % Total    % Received % Xferd  Average Speed..."
            // Look for percentage
            if let percentStr = str.split(separator: " ").first(where: { $0.hasSuffix("%") || Double($0) != nil }),
               let percent = Double(percentStr.replacingOccurrences(of: "%", with: "")) {
                let fraction = min(percent / 100.0, 1.0)
                let progress = FTPUploadProgress(
                    fileName: localURL.lastPathComponent,
                    bytesUploaded: Int64(fraction * Double(fileSize)),
                    totalBytes: Int64(fileSize),
                    fractionCompleted: fraction,
                    isComplete: false
                )
                progressHandler(progress)
            }
        }

        let state = CancellationState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { proc in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard state.claimResume() else { return }

                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let stderr = stderrBuffer.value
                        continuation.resume(throwing: FTPError.uploadFailed(proc.terminationStatus, stderr))
                    }
                }
                do {
                    try process.run()
                    if state.markLaunched() {
                        process.terminate()
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if state.claimResume() {
                        continuation.resume(throwing: state.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            if state.isLaunched {
                process.terminate()
            }
        }

        let finalProgress = FTPUploadProgress(
            fileName: localURL.lastPathComponent,
            bytesUploaded: Int64(fileSize),
            totalBytes: Int64(fileSize),
            fractionCompleted: 1.0,
            isComplete: true
        )
        progressHandler(finalProgress)
    }

    /// Probes a connection without transferring a file: connect + authenticate + list the
    /// configured remote directory. Reuses the same credential handling and transport/security
    /// flags as the upload path so a passing test reflects what an upload would do. Fails fast
    /// (`--connect-timeout`, no `--retry`) — a probe should surface an unreachable server
    /// immediately rather than retrying for several seconds.
    ///
    /// Uploads create a missing remote folder (`--ftp-create-dirs`), so when only the folder
    /// can't be entered the server root is listed instead; if that works the test passes and
    /// the returned note says so. Returns `nil` when the configured folder itself listed.
    nonisolated func testConnection(connection: FTPConnection, password: String) async throws -> String? {
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

        let directoryProbe = try await runProbe(arguments: Self.testConnectionArguments(
            remoteURL: Self.remoteDirectoryURL(connection: connection),
            netrcPath: netrcURL.path,
            connection: connection
        ))
        if directoryProbe.status == 0 { return nil }

        // Login worked but the folder couldn't be entered: check the root before blaming the server.
        var root = connection
        root.remotePath = "/"
        if Self.isMissingDirectoryStatus(directoryProbe.status),
           Self.remoteDirectoryURL(connection: root) != Self.remoteDirectoryURL(connection: connection) {
            let rootProbe = try await runProbe(arguments: Self.testConnectionArguments(
                remoteURL: Self.remoteDirectoryURL(connection: root),
                netrcPath: netrcURL.path,
                connection: connection
            ))
            if rootProbe.status == 0 {
                return "Connected. The folder “\(connection.remotePath)” doesn't exist yet or can't be listed; uploads will try to create it."
            }
        }
        throw FTPError.connectionTestFailed(directoryProbe.status, directoryProbe.stderr)
    }

    /// curl exit statuses meaning login worked but the remote folder could not be entered
    /// (9 = server denied changing into it, 78 = it does not exist).
    nonisolated static func isMissingDirectoryStatus(_ status: Int32) -> Bool {
        status == 9 || status == 78
    }

    /// Runs one fail-fast curl probe and returns its exit status and captured stderr.
    nonisolated private func runProbe(arguments: [String]) async throws -> (status: Int32, stderr: String) {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        let stderrBuffer = LockedBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            stderrBuffer.append(str)
        }

        let state = CancellationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, stderr: String), any Error>) in
                process.terminationHandler = { proc in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    guard state.claimResume() else { return }
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: (proc.terminationStatus, stderrBuffer.value))
                    }
                }
                do {
                    try process.run()
                    if state.markLaunched() {
                        process.terminate()
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if state.claimResume() {
                        continuation.resume(throwing: state.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            if state.isLaunched {
                process.terminate()
            }
        }
    }

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
    /// fast: a short `--connect-timeout` and no `--retry`, so an unreachable server is
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

    /// Builds the curl argument vector for an upload. Extracted as a pure function
    /// so the security-critical transport flags are unit-testable: explicit FTPS
    /// must add `--ssl-reqd` (so a TLS failure aborts rather than silently sending
    /// credentials in the clear), and plain FTP must carry no TLS/insecure flags.
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
            // 1 byte/s for 60 s. With the retries below a dead server fails in ~1 minute.
            "--connect-timeout", "15",
            "--speed-limit", "1",
            "--speed-time", "60",
            "--retry", "3",
            "--retry-delay", "2",
            "--retry-all-errors",
            remoteURL,
        ]

        if !connection.useSFTP {
            arguments.append("--ftp-create-dirs")
        }
        arguments.append(contentsOf: transportFlags(for: connection))
        return arguments
    }

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

        /// True when the failure means every other file in the batch would fail the
        /// same way — the server is unreachable, rejecting auth, refusing TLS, the
        /// credentials or protocol are unusable — so the upload loop should stop rather
        /// than retry each remaining file in turn. File-specific failures (e.g. 23 disk
        /// write, 26 local read) stay non-fatal.
        var isServerLevel: Bool {
            switch self {
            case .uploadFailed(let code, _), .connectionTestFailed(let code, _):
                return Self.isServerLevelExitCode(code)
            case .invalidCredential, .sftpUnavailable, .encodingFailed, .netrcCreationFailed:
                return true
            }
        }

        nonisolated static func isServerLevelExitCode(_ code: Int32) -> Bool {
            switch code {
            case 1, 5, 6, 7, 9, 28, 35, 51, 67:
                // unsupported protocol, proxy refused, DNS, connect, access denied,
                // timeout, TLS handshake, cert verify, login denied
                return true
            default:
                return false
            }
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
            case 9:  return "\(prefix): access denied by server"
            case 23: return "\(prefix): could not write data to disk"
            case 25: return "\(prefix): could not start FTP upload"
            case 26: return "\(prefix): could not read local file"
            case 28: return "\(prefix): connection timed out or stalled"
            case 35: return "\(prefix): SSL/TLS handshake error"
            case 51: return "\(prefix): server certificate verification failed"
            case 55: return "\(prefix): error sending data"
            case 56: return "\(prefix): error receiving data"
            case 67: return "\(prefix): login denied (check username/password)"
            case 78: return "\(prefix): remote folder not found"
            default: return "\(prefix) (curl exit code \(code))"
            }
        }

        /// Extracts the last "curl: (N) ..." diagnostic line from stderr.
        private static func extractCurlError(from stderr: String) -> String? {
            stderr.split(separator: "\n")
                .last { $0.hasPrefix("curl:") }
                .map(String.init)
        }
    }
}
