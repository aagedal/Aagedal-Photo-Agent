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

        // Drain both pipes concurrently with the child's execution. Reading only in the
        // termination handler (after the process exits) deadlocks any child that writes
        // more than the ~64 KB pipe buffer to stdout/stderr: it blocks on write(), so it
        // never exits, so the handler never fires. ffmpeg's stderr and c2patool's JSON
        // report can both exceed that. Each fd has exactly one reader (no readability/
        // termination-handler race over the final bytes), and the reads run off the
        // cooperative pool so a blocking read can't starve other tasks.
        async let stdoutData = Self.readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.readToEnd(stderrPipe.fileHandleForReading)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { proc in
                    guard state.claimResume() else { return }
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }
                do {
                    try process.run()
                } catch {
                    // The child never launched, so Process won't close the pipes' write
                    // ends — close them ourselves so the background readers see EOF
                    // instead of blocking on readDataToEndOfFile forever.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    if state.claimResume() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.markCancelled()
            process.terminate()
        }

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""

        if status != 0 {
            let message = stderr.isEmpty
                ? "Process exited with status \(status)"
                : "Process exited with status \(status): \(stderr.prefix(500))"
            throw NSError(
                domain: "Process+Async", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return (stdout, stderr)
    }

    /// Reads a file handle to EOF on a background queue, off the Swift concurrency
    /// cooperative pool so the blocking read can't tie up a pool thread.
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
