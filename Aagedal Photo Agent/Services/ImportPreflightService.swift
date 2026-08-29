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
}
