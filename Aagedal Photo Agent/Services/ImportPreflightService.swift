import Foundation

/// Serialized filesystem boundary for the import plan's duplicate discovery and overwrite probes.
///
/// The returned jobs are immutable at the actor boundary. Duplicate skips and expected overwrite
/// collisions are frozen together so the main actor can present the exact plan that execution
/// later revalidates before its first destination mutation.
actor ImportPreflightService {
    typealias DuplicateSourceFinder = @Sendable (
        [PreviousImportDetector.Candidate],
        URL
    ) throws -> Set<URL>
    typealias FileExistenceProbe = @Sendable (String) -> Bool

    struct Request: Sendable {
        let jobs: [ImportCopyService.CopyJob]
        let previousImportCandidates: [PreviousImportDetector.Candidate]
        let companionParentBySource: [URL: URL]
        let destinationBaseURL: URL
        let skipPreviouslyImported: Bool
        let freezeOverwriteCollisions: Bool
    }

    struct OverwriteEvidence: Sendable {
        let primaryCollisionCount: Int
        let backupCollisionCount: Int
        let signature: [ImportOverwriteExpectation]
    }

    struct Result: Sendable {
        let jobs: [ImportCopyService.CopyJob]
        let overwrite: OverwriteEvidence?
    }

    struct BundleDestinationRequest: Sendable, Equatable, Identifiable {
        let id: UUID
        let image: URL
        let memo: URL
        let imageBackup: URL?
        let memoBackup: URL?

        init(
            id: UUID = UUID(),
            image: URL,
            memo: URL,
            imageBackup: URL?,
            memoBackup: URL?
        ) {
            self.id = id
            self.image = image
            self.memo = memo
            self.imageBackup = imageBackup
            self.memoBackup = memoBackup
        }
    }

    struct BundleDestination: Sendable, Equatable, Identifiable {
        let id: UUID
        let image: URL
        let memo: URL
        let imageBackup: URL?
        let memoBackup: URL?
        let skipReason: ImportCopyService.SkipReason?
    }

    /// Immutable evidence returned even when cancellation interrupts a multi-bundle plan. Callers
    /// must publish only `.complete` evidence belonging to their current operation.
    struct BundlePlanningEvidence: Sendable, Equatable {
        let requestedBundleCount: Int
        let destinations: [BundleDestination]

        var completedBundleCount: Int { destinations.count }
    }

    enum BundlePlanningResult: Sendable, Equatable {
        case complete(BundlePlanningEvidence)
        case cancelled(BundlePlanningEvidence)
    }

    private let findDuplicateSources: DuplicateSourceFinder
    private let fileExists: FileExistenceProbe

    init(
        findDuplicateSources: @escaping DuplicateSourceFinder = { candidates, destinationBaseURL in
            try PreviousImportDetector.duplicateSources(
                among: candidates,
                destinationBaseURL: destinationBaseURL
            )
        },
        fileExists: @escaping FileExistenceProbe = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.findDuplicateSources = findDuplicateSources
        self.fileExists = fileExists
    }

    func prepare(_ request: Request) async throws -> Result {
        try Task.checkCancellation()
        var jobs = request.jobs

        if request.skipPreviouslyImported {
            let duplicateSources = try findDuplicateSources(
                request.previousImportCandidates,
                request.destinationBaseURL
            )
            try Task.checkCancellation()
            if !duplicateSources.isEmpty {
                jobs = jobs.map { job in
                    var updated = job
                    if duplicateSources.contains(job.source)
                        || request.companionParentBySource[job.source].map(duplicateSources.contains) == true {
                        updated.preflightSkipReason = .previouslyImported
                    }
                    return updated
                }
            }
        }

        guard request.freezeOverwriteCollisions else {
            return Result(jobs: jobs, overwrite: nil)
        }

        var plannedPrimaryPaths = Set<String>()
        var plannedBackupPaths = Set<String>()
        var primaryCollisionCount = 0
        var backupCollisionCount = 0

        for index in jobs.indices {
            try Task.checkCancellation()
            guard jobs[index].preflightSkipReason == nil else { continue }

            let primaryPath = jobs[index].desiredPrimaryDest.standardizedFileURL.path
            let primaryExists = fileExists(primaryPath)
                || !plannedPrimaryPaths.insert(primaryPath).inserted
            jobs[index].expectedPrimaryCollision = primaryExists
            if primaryExists {
                primaryCollisionCount += 1
            }

            if let backup = jobs[index].desiredBackupDest {
                try Task.checkCancellation()
                let backupPath = backup.standardizedFileURL.path
                let backupExists = fileExists(backupPath)
                    || !plannedBackupPaths.insert(backupPath).inserted
                jobs[index].expectedBackupCollision = backupExists
                if backupExists {
                    backupCollisionCount += 1
                }
            }
        }

        let signature = jobs.map { job in
            ImportOverwriteExpectation(
                primaryPath: job.desiredPrimaryDest.standardizedFileURL.path,
                primaryExists: job.expectedPrimaryCollision ?? false,
                backupPath: job.desiredBackupDest?.standardizedFileURL.path,
                backupExists: job.expectedBackupCollision,
                isSkipped: job.preflightSkipReason != nil
            )
        }
        return Result(
            jobs: jobs,
            overwrite: OverwriteEvidence(
                primaryCollisionCount: primaryCollisionCount,
                backupCollisionCount: backupCollisionCount,
                signature: signature
            )
        )
    }

    /// Resolves image/voice-memo bundles as one collision unit on the actor executor. Every file in
    /// a renamed bundle receives the same suffix, including its optional backup destinations.
    func resolveBundleDestinations(
        _ requests: [BundleDestinationRequest],
        policy: ImportConflictPolicy
    ) -> BundlePlanningResult {
        var destinations: [BundleDestination] = []
        destinations.reserveCapacity(requests.count)

        for request in requests {
            guard !Task.isCancelled else {
                return .cancelled(BundlePlanningEvidence(
                    requestedBundleCount: requests.count,
                    destinations: destinations
                ))
            }

            switch policy {
            case .overwrite:
                destinations.append(directDestination(for: request))

            case .skipExisting:
                let primaryExists = fileExists(request.image.path)
                    || fileExists(request.memo.path)
                guard !Task.isCancelled else {
                    return .cancelled(BundlePlanningEvidence(
                        requestedBundleCount: requests.count,
                        destinations: destinations
                    ))
                }
                destinations.append(BundleDestination(
                    id: request.id,
                    image: request.image,
                    memo: request.memo,
                    imageBackup: request.imageBackup,
                    memoBackup: request.memoBackup,
                    skipReason: primaryExists ? .destinationExists : nil
                ))

            case .renameWithSuffix:
                var resolved: BundleDestination?
                for suffix in 0...10_000 {
                    guard !Task.isCancelled else {
                        return .cancelled(BundlePlanningEvidence(
                            requestedBundleCount: requests.count,
                            destinations: destinations
                        ))
                    }
                    let candidateImage = Self.suffixedURL(request.image, suffix: suffix)
                    let candidateMemo = Self.suffixedURL(request.memo, suffix: suffix)
                    let candidateImageBackup = request.imageBackup.map {
                        Self.suffixedURL($0, suffix: suffix)
                    }
                    let candidateMemoBackup = request.memoBackup.map {
                        Self.suffixedURL($0, suffix: suffix)
                    }
                    let candidates = [
                        candidateImage,
                        candidateMemo,
                        candidateImageBackup,
                        candidateMemoBackup,
                    ].compactMap { $0 }
                    if candidates.allSatisfy({ !fileExists($0.path) }) {
                        resolved = BundleDestination(
                            id: request.id,
                            image: candidateImage,
                            memo: candidateMemo,
                            imageBackup: candidateImageBackup,
                            memoBackup: candidateMemoBackup,
                            skipReason: nil
                        )
                        break
                    }
                }
                // Never let the copy service resolve the image and memo independently when the
                // shared suffix space is exhausted; skipping the complete bundle preserves identity.
                destinations.append(resolved ?? BundleDestination(
                    id: request.id,
                    image: request.image,
                    memo: request.memo,
                    imageBackup: request.imageBackup,
                    memoBackup: request.memoBackup,
                    skipReason: .destinationExists
                ))
            }
        }

        return .complete(BundlePlanningEvidence(
            requestedBundleCount: requests.count,
            destinations: destinations
        ))
    }

    private func directDestination(for request: BundleDestinationRequest) -> BundleDestination {
        BundleDestination(
            id: request.id,
            image: request.image,
            memo: request.memo,
            imageBackup: request.imageBackup,
            memoBackup: request.memoBackup,
            skipReason: nil
        )
    }

    private static func suffixedURL(_ url: URL, suffix: Int) -> URL {
        guard suffix > 0 else { return url }
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let filename = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
        return directory.appendingPathComponent(filename)
    }
}
