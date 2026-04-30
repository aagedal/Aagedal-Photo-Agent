import Foundation
import os

private nonisolated let copyLog = Logger(subsystem: "com.aagedal.photo-agent", category: "ImportCopyService")

/// Streaming copy + verify + optional dual-destination service used by both
/// memory-card ingest and the "Back Up Edited Files" folder action.
///
/// Each file is copied in a single read pass, hashed during write, then re-read
/// from disk and re-hashed to confirm the bytes survived the filesystem round
/// trip. The destination is written to a `.partial` sidecar and atomically
/// renamed only after verification passes — partial files never become live.
///
/// Backup failures are isolated: if the secondary destination drops mid-copy,
/// the primary import still completes successfully. The `CopyResult` carries
/// the per-leg outcome so the UI can surface what happened.
actor ImportCopyService {

    // MARK: - Public Types

    struct CopyJob: Sendable, Identifiable {
        let id = UUID()
        let source: URL
        /// Desired primary destination. Conflicts resolved by `conflictPolicy`.
        let desiredPrimaryDest: URL
        /// Optional secondary mirror destination. If `nil`, no backup leg runs.
        let desiredBackupDest: URL?
    }

    enum DestinationOutcome: Sendable, Equatable {
        case copied(URL, wasRenamed: Bool, hash: Data)
        case skipped
        case failed(String)
    }

    enum VerificationOutcome: Sendable, Equatable {
        case verified
        case mismatch(expected: Data, got: Data)
        case skipped
        case failed(String)
    }

    struct CopyResult: Sendable, Identifiable {
        let id: UUID
        let source: URL
        let primary: DestinationOutcome
        let primaryVerification: VerificationOutcome
        let backup: DestinationOutcome?
        let backupVerification: VerificationOutcome?
    }

    enum CopyError: Error, LocalizedError {
        case renameSuffixExhausted(URL)
        var errorDescription: String? {
            switch self {
            case .renameSuffixExhausted(let url):
                return "Could not resolve filename conflict for \(url.lastPathComponent) after 10000 attempts."
            }
        }
    }

    // MARK: - Run

    /// Execute all jobs sequentially, calling `progress` after each file completes.
    /// Throws `CancellationError` if the surrounding `Task` is cancelled.
    func run(
        jobs: [CopyJob],
        conflictPolicy: ImportConflictPolicy,
        verificationMode: CopyVerificationMode,
        verifyBackup: Bool,
        progress: @Sendable (CopyResult) async -> Void
    ) async throws -> [CopyResult] {
        var results: [CopyResult] = []
        results.reserveCapacity(jobs.count)

        for job in jobs {
            try Task.checkCancellation()
            let result = await processJob(
                job,
                conflictPolicy: conflictPolicy,
                verificationMode: verificationMode,
                verifyBackup: verifyBackup
            )
            results.append(result)
            await progress(result)
        }
        return results
    }

    // MARK: - Per-Job Processing

    private func processJob(
        _ job: CopyJob,
        conflictPolicy: ImportConflictPolicy,
        verificationMode: CopyVerificationMode,
        verifyBackup: Bool
    ) async -> CopyResult {
        // Resolve primary destination (conflict policy).
        let primaryResolved: ResolvedDestination
        do {
            primaryResolved = try Self.resolveDestination(
                desired: job.desiredPrimaryDest,
                policy: conflictPolicy
            )
        } catch {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .failed(error.localizedDescription),
                primaryVerification: .skipped,
                backup: nil,
                backupVerification: nil
            )
        }

        // Skip → skip both legs.
        if case .skip = primaryResolved {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .skipped,
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped : nil,
                backupVerification: job.desiredBackupDest != nil ? .skipped : nil
            )
        }
        guard case let .resolved(primaryURL, wasRenamed) = primaryResolved else {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .failed("Could not resolve destination."),
                primaryVerification: .skipped,
                backup: nil,
                backupVerification: nil
            )
        }

        // Stream-copy primary.
        let primaryCopyResult: CopyAndHashResult
        do {
            primaryCopyResult = try await streamCopy(source: job.source, dest: primaryURL)
        } catch is CancellationError {
            // Caller catches; re-throw via parent run loop is handled by progress break.
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .failed("Cancelled."),
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped : nil,
                backupVerification: job.desiredBackupDest != nil ? .skipped : nil
            )
        } catch {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .failed(error.localizedDescription),
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped : nil,
                backupVerification: job.desiredBackupDest != nil ? .skipped : nil
            )
        }

        // Verify primary.
        let primaryVerification: VerificationOutcome
        switch verificationMode {
        case .off:
            primaryVerification = .skipped
        case .on:
            primaryVerification = await verify(url: primaryURL, expected: primaryCopyResult.hash)
        }

        // If verification failed, remove the partial-promoted file so it doesn't pose as good data.
        if case .mismatch = primaryVerification {
            try? FileManager.default.removeItem(at: primaryURL)
        }

        // Backup leg (best-effort, isolated from primary success).
        var backupOutcome: DestinationOutcome?
        var backupVerification: VerificationOutcome?
        if let desiredBackup = job.desiredBackupDest {
            // Don't fail backup if primary verification failed — still try backup so the user has redundancy.
            let backupResolved: ResolvedDestination
            do {
                backupResolved = try Self.resolveDestination(desired: desiredBackup, policy: conflictPolicy)
            } catch {
                backupOutcome = .failed(error.localizedDescription)
                backupVerification = .skipped
                return CopyResult(
                    id: job.id,
                    source: job.source,
                    primary: primaryVerification == .verified || primaryVerification == .skipped
                        ? .copied(primaryURL, wasRenamed: wasRenamed, hash: primaryCopyResult.hash)
                        : .failed("Verification mismatch."),
                    primaryVerification: primaryVerification,
                    backup: backupOutcome,
                    backupVerification: backupVerification
                )
            }

            switch backupResolved {
            case .skip:
                backupOutcome = .skipped
                backupVerification = .skipped
            case .resolved(let backupURL, let backupWasRenamed):
                do {
                    let backupCopy = try await streamCopy(source: job.source, dest: backupURL)
                    backupOutcome = .copied(backupURL, wasRenamed: backupWasRenamed, hash: backupCopy.hash)

                    if verificationMode == .on && verifyBackup {
                        let v = await verify(url: backupURL, expected: backupCopy.hash)
                        backupVerification = v
                        if case .mismatch = v {
                            try? FileManager.default.removeItem(at: backupURL)
                        }
                    } else {
                        backupVerification = .skipped
                    }
                } catch is CancellationError {
                    backupOutcome = .failed("Cancelled.")
                    backupVerification = .skipped
                } catch {
                    copyLog.warning("Backup copy failed for \(job.source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    backupOutcome = .failed(error.localizedDescription)
                    backupVerification = .skipped
                }
            }
        }

        // Build final primary outcome.
        let finalPrimary: DestinationOutcome
        switch primaryVerification {
        case .mismatch:
            finalPrimary = .failed("Verification mismatch — destination differs from source.")
        default:
            finalPrimary = .copied(primaryURL, wasRenamed: wasRenamed, hash: primaryCopyResult.hash)
        }

        return CopyResult(
            id: job.id,
            source: job.source,
            primary: finalPrimary,
            primaryVerification: primaryVerification,
            backup: backupOutcome,
            backupVerification: backupVerification
        )
    }

    // MARK: - Streaming Copy

    private struct CopyAndHashResult {
        let hash: Data
    }

    /// Copy `source` → `dest` one chunk at a time, hashing as bytes flow.
    /// Writes to `dest.partial` and atomically renames on success.
    /// Removes any partial on failure.
    private func streamCopy(source: URL, dest: URL) async throws -> CopyAndHashResult {
        let fm = FileManager.default
        let partialURL = dest.appendingPathExtension("partial")

        // Clean up any pre-existing partial from a previous crashed run.
        if fm.fileExists(atPath: partialURL.path) {
            try? fm.removeItem(at: partialURL)
        }

        // Ensure parent directory exists (defensive — caller should have created it).
        let parent = dest.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard fm.createFile(atPath: partialURL.path, contents: nil) else {
            throw NSError(
                domain: "ImportCopyService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create destination file at \(partialURL.path)."]
            )
        }

        let readHandle: FileHandle
        let writeHandle: FileHandle
        do {
            readHandle = try FileHandle(forReadingFrom: source)
        } catch {
            try? fm.removeItem(at: partialURL)
            throw error
        }
        do {
            writeHandle = try FileHandle(forWritingTo: partialURL)
        } catch {
            try? readHandle.close()
            try? fm.removeItem(at: partialURL)
            throw error
        }

        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        var hasher = HashStream()
        let chunkSize = 1 << 20  // 1 MB

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try readHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(chunk)
                try writeHandle.write(contentsOf: chunk)
            }
            try writeHandle.synchronize()
        } catch is CancellationError {
            try? writeHandle.close()
            try? readHandle.close()
            try? fm.removeItem(at: partialURL)
            throw CancellationError()
        } catch {
            try? writeHandle.close()
            try? readHandle.close()
            try? fm.removeItem(at: partialURL)
            throw error
        }

        let hash = hasher.finalize()

        // Atomic rename of .partial → final.
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.moveItem(at: partialURL, to: dest)
        } catch {
            try? fm.removeItem(at: partialURL)
            throw error
        }

        return CopyAndHashResult(hash: hash)
    }

    // MARK: - Verification

    private func verify(url: URL, expected: Data) async -> VerificationOutcome {
        do {
            try Task.checkCancellation()
            let actual = try HashStream.hashFile(at: url)
            if actual == expected {
                return .verified
            }
            copyLog.error("Verification mismatch for \(url.lastPathComponent, privacy: .public): expected \(expected.shortHex, privacy: .public), got \(actual.shortHex, privacy: .public)")
            return .mismatch(expected: expected, got: actual)
        } catch is CancellationError {
            return .skipped
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Conflict Resolution

    private enum ResolvedDestination {
        case skip
        case resolved(URL, wasRenamed: Bool)
    }

    nonisolated private static func resolveDestination(
        desired: URL,
        policy: ImportConflictPolicy
    ) throws -> ResolvedDestination {
        let fm = FileManager.default
        guard fm.fileExists(atPath: desired.path) else {
            return .resolved(desired, wasRenamed: false)
        }
        switch policy {
        case .skipExisting:
            return .skip
        case .overwrite:
            try fm.removeItem(at: desired)
            return .resolved(desired, wasRenamed: false)
        case .renameWithSuffix:
            let directory = desired.deletingLastPathComponent()
            let basename = desired.deletingPathExtension().lastPathComponent
            let ext = desired.pathExtension
            let maxAttempts = 10_000
            for index in 1...maxAttempts {
                let candidateName = ext.isEmpty
                    ? "\(basename)-\(index)"
                    : "\(basename)-\(index).\(ext)"
                let candidate = directory.appendingPathComponent(candidateName)
                if !fm.fileExists(atPath: candidate.path) {
                    return .resolved(candidate, wasRenamed: true)
                }
            }
            throw CopyError.renameSuffixExhausted(desired)
        }
    }
}

// MARK: - Convenience extensions on CopyResult

nonisolated extension ImportCopyService.CopyResult {
    /// `true` only if the primary file was successfully copied AND verified
    /// (or verification was off). False on skip, failure, or mismatch.
    var isPrimaryGood: Bool {
        switch primary {
        case .copied:
            switch primaryVerification {
            case .verified, .skipped: return true
            case .mismatch, .failed: return false
            }
        case .skipped, .failed:
            return false
        }
    }

    /// The destination URL for a successfully copied primary, or nil otherwise.
    /// Used by metadata application step to know which files are eligible.
    var primaryURL: URL? {
        guard isPrimaryGood, case let .copied(url, _, _) = primary else { return nil }
        return url
    }

    var wasRenamed: Bool {
        if case let .copied(_, renamed, _) = primary { return renamed }
        return false
    }

    var hasMismatch: Bool {
        if case .mismatch = primaryVerification { return true }
        if let bv = backupVerification, case .mismatch = bv { return true }
        return false
    }
}
