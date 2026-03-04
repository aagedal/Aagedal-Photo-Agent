import Foundation

struct FTPUploadProgress: Sendable {
    var fileName: String
    var bytesUploaded: Int64
    var totalBytes: Int64
    var fractionCompleted: Double
    var isComplete: Bool
}

struct FTPService: Sendable {
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
        try netrcData.write(to: netrcURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: netrcURL) }

        var arguments = [
            "-T", localURL.path,
            "--netrc-file", netrcURL.path,
            "--progress-bar",
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

        // Parse progress from stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }

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
                    continuation.resume(throwing: FTPError.uploadFailed(proc.terminationStatus))
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
        case uploadFailed(Int32)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let code):
                return "FTP upload failed (exit code: \(code))"
            case .encodingFailed:
                return "Failed to encode FTP credentials as UTF-8"
            }
        }
    }
}
