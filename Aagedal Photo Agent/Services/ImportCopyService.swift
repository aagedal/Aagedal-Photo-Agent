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
    /// Keep blocking volume reads and writes on a Dispatch worker while retaining the caller's task
    /// locals, priority, and cancellation state across the actor boundary.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    typealias VerificationHasher = @Sendable (URL) throws -> Data
    private let verificationHasher: VerificationHasher

    init(
        verificationHasher: @escaping VerificationHasher = { url in
            try HashStream.hashFileSynchronously(at: url, bypassingCache: true)
        },
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.import-copy", qos: .utility
        )
    ) {
        self.filesystemQueue = filesystemQueue
        self.verificationHasher = verificationHasher
    }

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
        /// Frozen by overwrite preflight. When present, `run` verifies the complete
        /// collision set before processing the first job so confirmation cannot be
        /// reused after a destination appears or disappears.
        var expectedPrimaryCollision: Bool? = nil
        var expectedBackupCollision: Bool? = nil
        /// Set by import preflight, which resolves every file of an exposure together (one
        /// suffix for RAW, JPEG, voice memo and their sidecars). A frozen destination is used
        /// exactly as planned: the copy never re-resolves it per file, and a file that appeared
        /// there after preflight fails the job instead of splitting the exposure.
        var frozenDestination: Bool = false
        /// Reported as `wasRenamed` for a frozen destination.
        var plannedRename: Bool = false
        /// Skips only the backup leg (its frozen backup file already exists).
        var backupSkipReason: SkipReason? = nil
        /// Skip Existing found a *different* file under this name, so the job was renamed
        /// instead of skipped. Surfaced to the user as a warning.
        var renamedAwayFromDifferentFile: Bool = false
    }

    enum SkipReason: String, Sendable, Equatable {
        case destinationExists
        case previouslyImported
        case associatedImageFailed
    }

    enum DestinationOutcome: Sendable, Equatable {
        case copied(URL, wasRenamed: Bool, wasReplaced: Bool, hash: Data)
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
        /// Skip Existing met a different file with the same name and copied under a new name.
        var renamedAwayFromDifferentFile: Bool = false
    }

    enum CopyError: Error, LocalizedError {
        case renameSuffixExhausted(URL)
        case overwritePreflightChanged
        var errorDescription: String? {
            switch self {
            case .renameSuffixExhausted(let url):
                return "Could not resolve filename conflict for \(url.lastPathComponent) after 10000 attempts."
            case .overwritePreflightChanged:
                return "Destination files changed after overwrite confirmation. Review the updated preflight before importing."
            }
        }
    }

    // MARK: - Run

    /// Execute all jobs sequentially, calling `progress` after each file completes.
    /// Throws `CancellationError` if the surrounding `Task` is cancelled, after publishing
    /// any committed primary copy through `progress`, including when its backup was cancelled.
    func run(
        jobs: [CopyJob],
        conflictPolicy: ImportConflictPolicy,
        verificationMode: CopyVerificationMode,
        verifyBackup: Bool,
        progress: @Sendable (CopyResult) async -> Void
    ) async throws -> [CopyResult] {
        try Task.checkCancellation()
        if conflictPolicy == .overwrite {
            try Self.validateOverwritePreflight(jobs: jobs)
        }

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
                try Task.checkCancellation()
                continue
            }
            let result = try processJob(
                job,
                conflictPolicy: conflictPolicy,
                verificationMode: verificationMode,
                verifyBackup: verifyBackup
            )
            results.append(result)
            // A committed primary must reach the caller even if cancellation stopped its backup.
            await progress(result)
            try Task.checkCancellation()
        }
        return results
    }

    /// Validates the complete frozen collision set as one operation. The importer
    /// calls this immediately before creating destination folders; `run` repeats it
    /// defensively immediately before the first staged file is opened.
    nonisolated static func validateOverwritePreflight(jobs: [CopyJob]) throws {
        let fm = FileManager.default
        var plannedPrimaryPaths = Set<String>()
        var plannedBackupPaths = Set<String>()
        for job in jobs where job.preflightSkipReason == nil {
            let primaryPath = job.desiredPrimaryDest.standardizedFileURL.path
            let primaryWillReplace = fm.fileExists(atPath: primaryPath)
                || !plannedPrimaryPaths.insert(primaryPath).inserted
            if let expected = job.expectedPrimaryCollision,
               primaryWillReplace != expected {
                throw CopyError.overwritePreflightChanged
            }
            if let destination = job.desiredBackupDest,
               let expected = job.expectedBackupCollision {
                let backupPath = destination.standardizedFileURL.path
                let backupWillReplace = fm.fileExists(atPath: backupPath)
                    || !plannedBackupPaths.insert(backupPath).inserted
                if backupWillReplace != expected {
                    throw CopyError.overwritePreflightChanged
                }
            }
        }
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
    ) throws -> CopyResult {
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

        // Resolve primary destination (conflict policy). Import preflight freezes the
        // destination for the whole exposure; only unfrozen callers resolve per file.
        let primaryResolved: ResolvedDestination
        do {
            primaryResolved = job.frozenDestination
                ? .resolved(
                    job.desiredPrimaryDest,
                    wasRenamed: job.plannedRename,
                    differed: job.renamedAwayFromDifferentFile
                )
                : try Self.resolveDestination(
                    source: job.source,
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
        if case .skip(let reason) = primaryResolved {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .skipped(reason),
                primaryVerification: .skipped,
                backup: job.desiredBackupDest != nil ? .skipped(reason) : nil,
                backupVerification: job.desiredBackupDest != nil ? .skipped : nil
            )
        }
        guard case let .resolved(primaryURL, wasRenamed, renamedAwayFromDifferentFile) = primaryResolved else {
            return CopyResult(
                id: job.id,
                source: job.source,
                primary: .failed("Could not resolve destination."),
                primaryVerification: .skipped,
                backup: nil,
                backupVerification: nil
            )
        }

        let (primaryOutcome, primaryVerification) = try copyLeg(
            source: job.source,
            destination: primaryURL,
            wasRenamed: wasRenamed,
            shouldVerify: verificationMode == .on,
            allowOverwrite: conflictPolicy == .overwrite,
            wasReplaced: conflictPolicy == .overwrite
                && (job.expectedPrimaryCollision
                    ?? FileManager.default.fileExists(atPath: job.desiredPrimaryDest.path))
        )

        // Backup leg (best-effort, isolated from primary success).
        var backupOutcome: DestinationOutcome?
        var backupVerification: VerificationOutcome?
        if let desiredBackup = job.desiredBackupDest {
            // Don't fail backup if primary verification failed — still try backup so the user has redundancy.
            let backupResolved: ResolvedDestination
            do {
                if let reason = job.backupSkipReason {
                    backupResolved = .skip(reason)
                } else if job.frozenDestination {
                    backupResolved = .resolved(desiredBackup, wasRenamed: job.plannedRename, differed: false)
                } else {
                    backupResolved = try Self.resolveDestination(
                        source: job.source,
                        desired: desiredBackup,
                        policy: conflictPolicy
                    )
                }
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
                    backupVerification: backupVerification,
                    renamedAwayFromDifferentFile: renamedAwayFromDifferentFile
                )
            }

            switch backupResolved {
            case .skip(let reason):
                backupOutcome = .skipped(reason)
                backupVerification = .skipped
            case .resolved(let backupURL, let backupWasRenamed, _):
                // Read the card once: a verified primary is byte-identical to the source, so the
                // backup is copied from it, and its staged bytes must still hash to the hash
                // streamed from the card. Without a verified primary, read the source again.
                var backupSource = job.source
                var expectedBackupHash: Data?
                if primaryVerification == .verified,
                   case let .copied(copiedPrimary, _, _, primaryHash) = primaryOutcome {
                    backupSource = copiedPrimary
                    expectedBackupHash = primaryHash
                }
                do {
                    (backupOutcome, backupVerification) = try copyLeg(
                        source: backupSource,
                        expectedSourceHash: expectedBackupHash,
                        destination: backupURL,
                        wasRenamed: backupWasRenamed,
                        shouldVerify: verificationMode == .on && verifyBackup,
                        allowOverwrite: conflictPolicy == .overwrite,
                        wasReplaced: conflictPolicy == .overwrite
                            && (job.expectedBackupCollision
                                ?? FileManager.default.fileExists(atPath: desiredBackup.path))
                    )
                } catch is CancellationError {
                    // Primary promotion is durable. Publish it before `run` propagates
                    // cancellation, so callers can reconcile files that already exist on disk.
                    backupOutcome = .failed("Backup cancelled.")
                    backupVerification = .failed("Backup cancelled.")
                } catch {
                    copyLog.warning("Backup copy failed for \(job.source.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
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
            backupVerification: backupVerification,
            renamedAwayFromDifferentFile: renamedAwayFromDifferentFile
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
        expectedSourceHash: Data? = nil,
        destination: URL,
        wasRenamed: Bool,
        shouldVerify: Bool,
        allowOverwrite: Bool,
        wasReplaced: Bool
    ) throws -> (DestinationOutcome, VerificationOutcome) {
        try Task.checkCancellation()
        if Self.filesReferToSameItem(source, destination) {
            return (
                .failed("Source and destination refer to the same file."),
                .skipped
            )
        }

        let staged: StagedCopy
        do {
            staged = try stageCopy(source: source, destination: destination, forVerification: shouldVerify)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (.failed(error.localizedDescription), .skipped)
        }

        // A leg copied from an earlier verified copy must carry the bytes streamed from the card.
        if let expectedSourceHash, staged.hash != expectedSourceHash {
            try? FileManager.default.removeItem(at: staged.temporaryURL)
            return (
                .failed("Verification mismatch — copy differs from the verified primary."),
                .mismatch(expected: expectedSourceHash, got: staged.hash)
            )
        }

        let verification: VerificationOutcome
        do {
            try Task.checkCancellation()
            verification = shouldVerify
                ? try verify(url: staged.temporaryURL, expected: staged.hash)
                : .skipped
            try Task.checkCancellation()
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
                return (.copied(
                    destination,
                    wasRenamed: wasRenamed,
                    wasReplaced: wasReplaced,
                    hash: staged.hash
                ), verification)
            } catch {
                try? FileManager.default.removeItem(at: staged.temporaryURL)
                return (.failed(error.localizedDescription), verification)
            }
        }
    }

    /// Copy `source` into a unique hidden sibling of `destination`, hashing as bytes flow.
    /// The caller owns promotion and cleanup after this method succeeds.
    ///
    /// When the copy will be verified, the staged file is written uncached (`F_NOCACHE`) and
    /// flushed with `F_FULLFSYNC`, so the verification read-back (also uncached) hashes bytes
    /// from the device itself rather than kernel pages or the drive's volatile write cache.
    private func stageCopy(source: URL, destination: URL, forVerification: Bool) throws -> StagedCopy {
        let fm = FileManager.default
        let partialURL = destination.deletingLastPathComponent().appendingPathComponent(
            Self.stagingFileName(for: destination.lastPathComponent)
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
        if forVerification {
            _ = fcntl(writeHandle.fileDescriptor, F_NOCACHE, 1)
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
            // F_FULLFSYNC also drains the drive's write cache; volumes that don't support it
            // (network shares, some FAT/exFAT drivers) fall back to a plain fsync.
            if !forVerification || fcntl(writeHandle.fileDescriptor, F_FULLFSYNC) == -1 {
                try writeHandle.synchronize()
            }
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

    private func verify(url: URL, expected: Data) throws -> VerificationOutcome {
        do {
            let actual = try verificationHasher(url)
            if actual == expected {
                return .verified
            }
            copyLog.error("Verification mismatch for \(url.lastPathComponent, privacy: .private(mask: .hash)): expected \(expected.shortHex, privacy: .private(mask: .hash)), got \(actual.shortHex, privacy: .private(mask: .hash))")
            return .mismatch(expected: expected, got: actual)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Conflict Resolution

    private enum ResolvedDestination {
        case skip(SkipReason)
        case resolved(URL, wasRenamed: Bool, differed: Bool)
    }

    nonisolated private static func resolveDestination(
        source: URL,
        desired: URL,
        policy: ImportConflictPolicy
    ) throws -> ResolvedDestination {
        let fm = FileManager.default
        guard fm.fileExists(atPath: desired.path) else {
            return .resolved(desired, wasRenamed: false, differed: false)
        }
        switch policy {
        case .skipExisting:
            // Skip only a true duplicate. A different file that merely shares the name (two
            // bodies with the same frame counter) is kept under a new name, never dropped.
            if filesHaveSameIdentity(source, desired) {
                return .skip(.destinationExists)
            }
            return .resolved(try renamedDestination(for: desired), wasRenamed: true, differed: true)
        case .overwrite:
            return .resolved(desired, wasRenamed: false, differed: false)
        case .renameWithSuffix:
            return .resolved(try renamedDestination(for: desired), wasRenamed: true, differed: false)
        }
    }

    nonisolated private static func renamedDestination(for desired: URL) throws -> URL {
        let fm = FileManager.default
        do {
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
                    return candidate
                }
            }
            throw CopyError.renameSuffixExhausted(desired)
        }
    }

    /// True when two files have the same size and the same sampled checksum — the identity
    /// the importer uses for "this exact photo is already there".
    nonisolated static func filesHaveSameIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let leftSize = try? lhs.resourceValues(forKeys: keys).fileSize,
              let rightSize = try? rhs.resourceValues(forKeys: keys).fileSize,
              leftSize == rightSize,
              let leftHash = try? HashStream.quickHashFile(at: lhs),
              let rightHash = try? HashStream.quickHashFile(at: rhs) else {
            return false
        }
        return leftHash == rightHash
    }

    // MARK: - Staging Files

    nonisolated static let stagingFileSuffix = ".partial"

    /// `.<name>.<UUID>.partial` beside the destination: hidden, unique, same directory.
    nonisolated static func stagingFileName(for destinationName: String) -> String {
        ".\(destinationName).\(UUID().uuidString)\(stagingFileSuffix)"
    }

    /// Matches exactly the staging names produced by `stagingFileName(for:)`: a leading dot,
    /// a non-empty destination name, a canonical UUID and the `.partial` suffix.
    nonisolated static func isStagingFileName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(stagingFileSuffix) else { return false }
        let body = name.dropFirst().dropLast(stagingFileSuffix.count)
        guard let dot = body.lastIndex(of: ".") else { return false }
        let destinationName = body[..<dot]
        let uuidText = String(body[body.index(after: dot)...])
        guard !destinationName.isEmpty, uuidText.count == 36,
              let uuid = UUID(uuidString: uuidText) else { return false }
        return uuid.uuidString == uuidText
    }

    /// Removes staging files a crashed or force-quit import left behind. Only regular files
    /// directly inside the given folders whose names match the app's exact staging pattern and
    /// that have not been modified for `minimumAge` are deleted; nothing else is touched.
    @discardableResult
    nonisolated static func sweepStaleStagingFiles(
        in folders: [URL],
        olderThan minimumAge: TimeInterval = 3600,
        now: Date = Date()
    ) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        var seen = Set<String>()
        for folder in folders where seen.insert(folder.standardizedFileURL.path).inserted {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where isStagingFileName(name) {
                let url = folder.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                ]), values.isRegularFile == true, values.isSymbolicLink != true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= minimumAge else { continue }
                do {
                    try fm.removeItem(at: url)
                    removed.append(url)
                } catch {
                    copyLog.warning("Could not remove stale staging file \(name, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        return removed
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
        guard isPrimaryGood, case let .copied(url, _, _, _) = primary else { return nil }
        return url
    }

    var wasRenamed: Bool {
        if case let .copied(_, renamed, _, _) = primary { return renamed }
        return false
    }

    var wasReplaced: Bool {
        if case let .copied(_, _, replaced, _) = primary { return replaced }
        return false
    }

    var hasMismatch: Bool {
        if case .mismatch = primaryVerification { return true }
        if let bv = backupVerification, case .mismatch = bv { return true }
        return false
    }
}
