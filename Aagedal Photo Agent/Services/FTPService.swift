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

        var arguments = [
            "-T", localURL.path,
            "-u", "\(connection.username):\(password)",
            "--progress-bar",
            remoteURL,
        ]

        if connection.useSFTP {
            arguments.append(contentsOf: ["--insecure"])
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

        try process.run()
        process.waitUntilExit()

        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw FTPError.uploadFailed(process.terminationStatus)
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

        var errorDescription: String? {
            switch self {
            case .uploadFailed(let code):
                return "FTP upload failed (exit code: \(code))"
            }
        }
    }
}
