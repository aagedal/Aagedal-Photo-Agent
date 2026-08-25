import Foundation
import Darwin
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
        /// When set, the job is intentionally not copied and returns a skipped result.
        var preflightSkipReason: SkipReason? = nil
        /// Companion jobs run only after this job completed successfully. This keeps an audio
        /// companion from being copied by itself when its image copy or verification failed.
        var prerequisiteJobID: UUID? = nil
    }

    enum SkipReason: String, Sendable, Equatable {
        case destinationExists
        case previouslyImported
        case associatedImageFailed
    }

    enum DestinationOutcome: Sendable, Equatable {
        case copied(URL, wasRenamed: Bool, hash: Data)
        case skipped(SkipReason)
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
            if let prerequisiteID = job.prerequisiteJobID,
               let prerequisite = results.first(where: { $0.id == prerequisiteID }),
               !prerequisite.isPrimaryGood {
                let reason: SkipReason
                if case let .skipped(prerequisiteReason) = prerequisite.primary {
                    reason = prerequisiteReason
                } else {
                    reason = .associatedImageFailed
                }
                let result = Self.skippedResult(for: job, reason: reason)
                results.append(result)
                await progress(result)
                continue
            }
            let result = try await processJob(
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

    nonisolated private static func skippedResult(
        for job: CopyJob,
        reason: SkipReason
    ) -> CopyResult {
        CopyResult(
            id: job.id,
            source: job.source,
            primary: .skipped(reason),
            primaryVerification: .skipped,
            backup: job.desiredBackupDest != nil ? .skipped(reason) : nil,
            backupVerification: job.desiredBackupDest != nil ? .skipped : nil
        )
    }

    // MARK: - Per-Job Processing

    private func processJob(
        _ job: CopyJob,
        conflictPolicy: ImportConflictPolicy,
        verificationMode: CopyVerificationMode,
        verifyBackup: Bool
    ) async throws -> CopyResult {
        if let reason = job.preflightSkipReason {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .skipped(reason),
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped(reason) : nil,
                backupVerification: job.desiredBackupDest != nil ? .skipped : nil
            )
        }

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
                primary: .skipped(.destinationExists),
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped(.destinationExists) : nil,
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

        let (primaryOutcome, primaryVerification) = try await copyLeg(
            source: job.source,
            destination: primaryURL,
            wasRenamed: wasRenamed,
            shouldVerify: verificationMode == .on,
            allowOverwrite: conflictPolicy == .overwrite
        )

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
                        ? primaryOutcome
                        : .failed("Verification failed."),
                    primaryVerification: primaryVerification,
                    backup: backupOutcome,
                    backupVerification: backupVerification
                )
            }

            switch backupResolved {
            case .skip:
                backupOutcome = .skipped(.destinationExists)
                backupVerification = .skipped
            case .resolved(let backupURL, let backupWasRenamed):
                do {
                    (backupOutcome, backupVerification) = try await copyLeg(
                        source: job.source,
                        destination: backupURL,
                        wasRenamed: backupWasRenamed,
                        shouldVerify: verificationMode == .on && verifyBackup,
                        allowOverwrite: conflictPolicy == .overwrite
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    copyLog.warning("Backup copy failed for \(job.source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    backupOutcome = .failed(error.localizedDescription)
                    backupVerification = .skipped
                }
            }
        }

        return CopyResult(
            id: job.id,
            source: job.source,
            primary: primaryOutcome,
            primaryVerification: primaryVerification,
            backup: backupOutcome,
            backupVerification: backupVerification
        )
    }

    // MARK: - Streaming Copy

    private struct StagedCopy {
        let hash: Data
        let temporaryURL: URL
    }

    /// Copies one leg into a unique same-directory staging file, verifies that staging
    /// file, and only then promotes it to the live destination. Cancellation always
    /// propagates to `run`; it is never represented as a successful skipped verification.
    private func copyLeg(
        source: URL,
        destination: URL,
        wasRenamed: Bool,
        shouldVerify: Bool,
        allowOverwrite: Bool
    ) async throws -> (DestinationOutcome, VerificationOutcome) {
        if Self.filesReferToSameItem(source, destination) {
            return (
                .failed("Source and destination refer to the same file."),
                .skipped
            )
        }

        let staged: StagedCopy
        do {
            staged = try await stageCopy(source: source, destination: destination)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (.failed(error.localizedDescription), .skipped)
        }

        let verification: VerificationOutcome
        do {
            verification = shouldVerify
                ? try await verify(url: staged.temporaryURL, expected: staged.hash)
                : .skipped
        } catch {
            try? FileManager.default.removeItem(at: staged.temporaryURL)
            throw error
        }

        switch verification {
        case .mismatch:
            try? FileManager.default.removeItem(at: staged.temporaryURL)
            return (.failed("Verification mismatch — staged copy differs from source."), verification)
        case .failed(let detail):
            try? FileManager.default.removeItem(at: staged.temporaryURL)
            return (.failed("Verification failed: \(detail)"), verification)
        case .verified, .skipped:
            do {
                try Self.promote(
                    staged.temporaryURL,
                    to: destination,
                    allowOverwrite: allowOverwrite
                )
                return (.copied(destination, wasRenamed: wasRenamed, hash: staged.hash), verification)
            } catch {
                try? FileManager.default.removeItem(at: staged.temporaryURL)
                return (.failed(error.localizedDescription), verification)
            }
        }
    }

    /// Copy `source` into a unique hidden sibling of `destination`, hashing as bytes flow.
    /// The caller owns promotion and cleanup after this method succeeds.
    private func stageCopy(source: URL, destination: URL) async throws -> StagedCopy {
        let fm = FileManager.default
        let partialURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
        )

        // Ensure parent directory exists (defensive — caller should have created it).
        let parent = destination.deletingLastPathComponent()
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

        return StagedCopy(hash: hasher.finalize(), temporaryURL: partialURL)
    }

    // MARK: - Verification

    private func verify(url: URL, expected: Data) async throws -> VerificationOutcome {
        do {
            let actual = try await HashStream.hashFile(at: url)
            if actual == expected {
                return .verified
            }
            copyLog.error("Verification mismatch for \(url.lastPathComponent, privacy: .public): expected \(expected.shortHex, privacy: .public), got \(actual.shortHex, privacy: .public)")
            return .mismatch(expected: expected, got: actual)
        } catch is CancellationError {
            throw CancellationError()
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

    nonisolated private static func filesReferToSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL
        let right = rhs.standardizedFileURL
        if left == right { return true }
        guard FileManager.default.fileExists(atPath: right.path) else { return false }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let leftID = try? left.resourceValues(forKeys: keys).fileResourceIdentifier
        let rightID = try? right.resourceValues(forKeys: keys).fileResourceIdentifier
        guard let leftID, let rightID else { return false }
        return String(describing: leftID) == String(describing: rightID)
    }

    /// POSIX rename is atomic within a directory and replaces an existing file without
    /// first unlinking it. If rename fails, the previous destination remains in place.
    nonisolated private static func promote(
        _ staged: URL,
        to destination: URL,
        allowOverwrite: Bool
    ) throws {
        if !allowOverwrite {
            try FileManager.default.moveItem(at: staged, to: destination)
            return
        }

        var failureCode: Int32 = 0
        let status: Int32 = staged.withUnsafeFileSystemRepresentation { stagedPath -> Int32 in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let stagedPath, let destinationPath else {
                    failureCode = EINVAL
                    return -1
                }
                let result = Darwin.rename(stagedPath, destinationPath)
                if result != 0 { failureCode = errno }
                return result
            }
        }
        guard status == 0 else {
            let code = failureCode == 0 ? EIO : failureCode
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not atomically replace \(destination.lastPathComponent): \(String(cString: strerror(code)))"]
            )
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
        case .skipped(_), .failed:
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
