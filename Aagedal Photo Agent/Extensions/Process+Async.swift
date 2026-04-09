import Foundation

/// Guards a `CheckedContinuation` against double-resume when Task cancellation
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

    /// Returns `true` if this is the first call (caller should resume the continuation).
    /// Returns `false` if already resumed (caller must NOT resume).
    nonisolated func claimResume() -> Bool {
        lock.withLock {
            if _resumed { return false }
            _resumed = true
            return true
        }
    }
}

extension Process {
    /// Runs the process asynchronously and returns (stdout, stderr) as strings.
    /// Terminates the subprocess if the enclosing Task is cancelled.
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

        let state = CancellationState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    guard state.claimResume() else { return }

                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

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
                    if state.claimResume() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            process.terminate()
        }
    }
}
