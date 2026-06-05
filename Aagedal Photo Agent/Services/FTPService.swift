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

        nonisolated func append(_ string: String) {
            lock.withLock { buffer += string }
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
        private let lock = NSLock()

        nonisolated var isCancelled: Bool {
            lock.withLock { _cancelled }
        }

        nonisolated func markCancelled() {
            lock.withLock { _cancelled = true }
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
        // Reject credentials containing characters that would break netrc parsing
        // (whitespace / newlines split tokens, so e.g. a password "my pass" would
        // authenticate as "my", and a newline could inject extra machine entries).
        try Self.validateNetrcField(connection.host, name: "host")
        try Self.validateNetrcField(connection.username, name: "username")
        try Self.validateNetrcField(password, name: "password")

        let scheme = connection.useSFTP ? "sftp" : "ftp"
        let remotePath = connection.remotePath.hasSuffix("/")
            ? connection.remotePath
            : connection.remotePath + "/"
        let remoteURL = "\(scheme)://\(connection.host):\(connection.port)\(remotePath)\(localURL.lastPathComponent)"

        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        // Write credentials to a temporary .netrc file so the password
        // is not visible to other processes via `ps`.
        let netrcURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("netrc")
        let netrcContent = "machine \(connection.host) login \(connection.username) password \(password)\n"
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
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if state.claimResume() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            process.terminate()
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
            "--retry", "3",
            "--retry-delay", "2",
            "--retry-all-errors",
            remoteURL,
        ]

        if connection.useSFTP {
            if connection.allowInsecureHostVerification {
                arguments.append("--insecure")
            }
        } else {
            arguments.append("--ftp-create-dirs")
            if connection.useTLS {
                // Explicit FTPS: require AUTH TLS and abort if the server can't
                // upgrade, rather than silently transferring credentials in the
                // clear. --insecure additionally skips certificate verification
                // for self-signed servers (opt-in).
                arguments.append("--ssl-reqd")
                if connection.allowInsecureHostVerification {
                    arguments.append("--insecure")
                }
            }
        }
        return arguments
    }

    /// Reject characters that would corrupt netrc parsing — whitespace splits tokens
    /// and `#` starts a comment, so e.g. a password "my pass" silently authenticates
    /// as "my", and a newline would inject extra `machine`/`login`/`password` entries.
    nonisolated private static func validateNetrcField(_ value: String, name: String) throws {
        if value.isEmpty {
            throw FTPError.invalidCredential(name, reason: "is empty")
        }
        let invalid = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#"))
        if value.rangeOfCharacter(from: invalid) != nil {
            throw FTPError.invalidCredential(name, reason: "contains whitespace or '#'")
        }
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
        case encodingFailed
        case invalidCredential(String, reason: String)
        case netrcCreationFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let code, let stderr):
                let description = Self.curlExitCodeDescription(code)
                if let detail = Self.extractCurlError(from: stderr) {
                    return "\(description) \u{2014} \(detail)"
                }
                return description
            case .encodingFailed:
                return "Failed to encode FTP credentials as UTF-8"
            case .invalidCredential(let field, let reason):
                return "FTP \(field) \(reason); whitespace and '#' are not allowed"
            case .netrcCreationFailed(let errno):
                return "Failed to create temporary credential file (errno \(errno))"
            }
        }

        private static func curlExitCodeDescription(_ code: Int32) -> String {
            switch code {
            case 5:  return "Upload failed: proxy connection refused"
            case 6:  return "Upload failed: could not resolve host"
            case 7:  return "Upload failed: could not connect to server"
            case 9:  return "Upload failed: access denied by server"
            case 23: return "Upload failed: could not write data to disk"
            case 25: return "Upload failed: could not start FTP upload"
            case 26: return "Upload failed: could not read local file"
            case 28: return "Upload failed: connection timed out"
            case 35: return "Upload failed: SSL/TLS handshake error"
            case 51: return "Upload failed: server certificate verification failed"
            case 55: return "Upload failed: error sending data"
            case 56: return "Upload failed: error receiving data"
            case 67: return "Upload failed: login denied (check username/password)"
            default: return "Upload failed (curl exit code \(code))"
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
