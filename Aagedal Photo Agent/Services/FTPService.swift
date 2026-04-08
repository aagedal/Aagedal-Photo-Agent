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

    /// Upload a single file to the FTP server using curl.
    nonisolated func uploadFile(
        localURL: URL,
        connection: FTPConnection,
        password: String,
        progressHandler: @Sendable @escaping (FTPUploadProgress) -> Void
    ) async throws {
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
        FileManager.default.createFile(atPath: netrcURL.path, contents: netrcData, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        var arguments = [
            "-T", localURL.path,
            "--netrc-file", netrcURL.path,
            "--progress-bar",
            "--retry", "3",
            "--retry-delay", "2",
            "--retry-all-errors",
            remoteURL,
        ]

        if connection.useSFTP {
            if connection.allowInsecureHostVerification {
                arguments.append(contentsOf: ["--insecure"])
            }
        } else {
            arguments.append(contentsOf: ["--ftp-create-dirs"])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe() // discard

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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
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
                continuation.resume(throwing: error)
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

    enum FTPError: LocalizedError {
        case uploadFailed(Int32, String)
        case encodingFailed

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
