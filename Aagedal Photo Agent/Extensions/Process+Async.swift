import Foundation

extension Process {
    /// Runs the process asynchronously and returns (stdout, stderr) as strings.
    @Sendable
    nonisolated static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let dir = currentDirectoryURL {
            process.currentDirectoryURL = dir
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    let message = stderr.isEmpty
                        ? "Process exited with status \(proc.terminationStatus)"
                        : "Process exited with status \(proc.terminationStatus): \(stderr.prefix(500))"
                    continuation.resume(throwing: NSError(
                        domain: "Process+Async", code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    ))
                    return
                }

                continuation.resume(returning: (stdout, stderr))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
