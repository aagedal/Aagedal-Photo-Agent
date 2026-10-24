import Foundation

/// Serialized filesystem boundary for the import plan's duplicate discovery and overwrite probes.
///
/// The returned jobs are immutable at the actor boundary. Duplicate skips and expected overwrite
/// collisions are frozen together so the main actor can present the exact plan that execution
/// later revalidates before its first destination mutation.
actor ImportPreflightService {
    /// Keep blocking volume reads on a Dispatch worker while retaining the caller's task
    /// locals, priority, and cancellation state across the actor boundary.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

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

    /// One exposure — every file that must share a destination stem: RAW, JPEG and the voice
    /// memo(s) of one shot, in primary and backup folders. The batch planner already chose a
    /// stem unique within the import (`stem` + `plannedSuffix`); preflight resolves it against
    /// what is already on disk as one unit.
    struct BundleDestinationRequest: Sendable, Equatable, Identifiable {
        struct File: Sendable, Equatable {
            enum Role: Sendable, Equatable { case image, memo }
            let source: URL
            let role: Role
            let primaryFolder: URL
            let backupFolder: URL?
            let pathExtension: String

            init(source: URL, role: Role, primaryFolder: URL, backupFolder: URL?, pathExtension: String? = nil) {
                self.source = source
                self.role = role
                self.primaryFolder = primaryFolder
                self.backupFolder = backupFolder
                self.pathExtension = pathExtension ?? source.pathExtension
            }
        }

        let id: UUID
        /// Source stem every destination name is built from (`<stem>` or `<stem>-<n>`).
        let stem: String
        /// Suffix the batch planner assigned (0 = the source name).
        let plannedSuffix: Int
        let files: [File]

        init(id: UUID = UUID(), stem: String, plannedSuffix: Int = 0, files: [File]) {
            self.id = id
            self.stem = stem
            self.plannedSuffix = plannedSuffix
            self.files = files
        }
    }

    struct BundleDestination: Sendable, Equatable, Identifiable {
        struct File: Sendable, Equatable {
            let source: URL
            let role: BundleDestinationRequest.File.Role
            let primary: URL
            let backup: URL?
            let skipReason: ImportCopyService.SkipReason?
            /// Skip Existing: this file's backup copy is already there; only its backup leg skips.
            let backupSkipReason: ImportCopyService.SkipReason?
        }

        let id: UUID
        /// Final suffix shared by every file of the exposure.
        let suffix: Int
        let files: [File]
        /// Skip Existing found a *different* photo under the planned name, so the exposure was
        /// renamed rather than skipped. Reported to the user as a warning.
        let renamedAwayFromDifferentPhoto: Bool
        /// Overwrite: at least one file of the exposure replaces a destination file, and none of
        /// the replaced files was byte-identical to its source, so a destination sidecar left
        /// at that stem described a different photo.
        let replacesDifferentPhoto: Bool

        var wasRenamed: Bool { suffix > 0 }
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

    typealias DirectoryStemProbe = @Sendable (URL) -> Set<String>
    typealias FileIdentityProbe = @Sendable (URL, URL) -> Bool

    private let findDuplicateSources: DuplicateSourceFinder
    private let fileExists: FileExistenceProbe
    private let directoryStems: DirectoryStemProbe
    private let filesHaveSameIdentity: FileIdentityProbe

    init(
        findDuplicateSources: @escaping DuplicateSourceFinder = { candidates, destinationBaseURL in
            try PreviousImportDetector.duplicateSources(
                among: candidates,
                destinationBaseURL: destinationBaseURL
            )
        },
        fileExists: @escaping FileExistenceProbe = { path in
            FileManager.default.fileExists(atPath: path)
        },
        directoryStems: @escaping DirectoryStemProbe = { folder in
            ImportPreflightService.visibleStems(in: folder)
        },
        filesHaveSameIdentity: @escaping FileIdentityProbe = { source, destination in
            ImportCopyService.filesHaveSameIdentity(source, destination)
        },
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.import-preflight", qos: .utility
        )
    ) {
        self.filesystemQueue = filesystemQueue
        self.findDuplicateSources = findDuplicateSources
        self.fileExists = fileExists
        self.directoryStems = directoryStems
        self.filesHaveSameIdentity = filesHaveSameIdentity
    }

    /// Lower-cased stems of the visible entries in `folder` (empty when it does not exist).
    /// A stem taken by *any* file — image, `.xmp`, `.wav` — is taken: a new exposure placed
    /// there would be paired with, or inherit the sidecar of, a different photo.
    nonisolated static func visibleStems(in folder: URL) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        var stems = Set<String>()
        for name in names where !name.hasPrefix(".") {
            stems.insert(stemKey((name as NSString).deletingPathExtension))
        }
        return stems
    }

    nonisolated private static func stemKey(_ stem: String) -> String {
        stem.precomposedStringWithCanonicalMapping.lowercased()
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

        try Task.checkCancellation()
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

    /// Resolves every exposure as one collision unit on the actor executor, so RAW, JPEG, voice
    /// memo and their `.xmp` sidecars always share one stem, in the primary and backup folders.
    /// The result is frozen into the copy jobs; the copy never re-resolves a file on its own.
    ///
    /// - Rename: the lowest suffix (from the planned one) whose stem is free in every folder of
    ///   the exposure — no file of any extension uses it on disk, and no other exposure of this
    ///   batch planned it.
    /// - Skip Existing: if any file of the exposure is already at its planned destination
    ///   byte-for-byte, the exposure is there: existing files skip and missing partners join
    ///   them. If the planned stem holds only *different* files, the exposure is renamed like
    ///   Rename and flagged, never skipped.
    /// - Overwrite: planned names are kept (the user confirmed the collisions); the result
    ///   records whether the replaced files belonged to a different photo.
    func resolveBundleDestinations(
        _ requests: [BundleDestinationRequest],
        policy: ImportConflictPolicy
    ) -> BundlePlanningResult {
        var destinations: [BundleDestination] = []
        destinations.reserveCapacity(requests.count)
        var stemCache: [String: Set<String>] = [:]
        let fileExistsProbe = fileExists

        func cancelled() -> BundlePlanningResult {
            .cancelled(BundlePlanningEvidence(
                requestedBundleCount: requests.count,
                destinations: destinations
            ))
        }
        guard !Task.isCancelled else { return cancelled() }

        // Every planned stem belongs to its exposure for the whole batch, so a rename can never
        // move one exposure onto a name a later exposure was planned to use.
        var stemOwners: [String: UUID] = [:]
        for request in requests {
            for folder in Self.folders(of: request) {
                let key = Self.claimKey(folder: folder, name: Self.name(request.stem, request.plannedSuffix))
                if stemOwners[key] == nil { stemOwners[key] = request.id }
            }
        }

        func diskStemTaken(_ folder: URL, _ name: String) -> Bool {
            let folderKey = folder.standardizedFileURL.path
            let stems: Set<String>
            if let cached = stemCache[folderKey] {
                stems = cached
            } else {
                stems = directoryStems(folder)
                stemCache[folderKey] = stems
            }
            return stems.contains(Self.stemKey(name))
        }

        /// Explicit paths a candidate would occupy: each file plus the stem's sidecar.
        func explicitPaths(_ request: BundleDestinationRequest, _ name: String) -> [URL] {
            var paths: [URL] = []
            for folder in Self.folders(of: request) {
                paths.append(folder.appendingPathComponent(name).appendingPathExtension("xmp"))
            }
            for file in request.files {
                paths.append(Self.url(file.primaryFolder, name, file.pathExtension))
                if let backupFolder = file.backupFolder {
                    paths.append(Self.url(backupFolder, name, file.pathExtension))
                }
            }
            return paths
        }

        func isFree(_ request: BundleDestinationRequest, suffix: Int) -> Bool {
            let name = Self.name(request.stem, suffix)
            for folder in Self.folders(of: request) {
                if let owner = stemOwners[Self.claimKey(folder: folder, name: name)], owner != request.id {
                    return false
                }
                if diskStemTaken(folder, name) { return false }
            }
            return explicitPaths(request, name).allSatisfy { !fileExists($0.path) }
        }

        func claim(_ request: BundleDestinationRequest, suffix: Int) {
            let name = Self.name(request.stem, suffix)
            for folder in Self.folders(of: request) {
                stemOwners[Self.claimKey(folder: folder, name: name)] = request.id
            }
        }

        func destination(
            _ request: BundleDestinationRequest,
            suffix: Int,
            renamedAwayFromDifferentPhoto: Bool = false,
            replacesDifferentPhoto: Bool = false,
            skip: (BundleDestinationRequest.File, URL) -> ImportCopyService.SkipReason? = { _, _ in nil },
            skipBackup: (BundleDestinationRequest.File, URL?) -> ImportCopyService.SkipReason? = { _, _ in nil }
        ) -> BundleDestination {
            let name = Self.name(request.stem, suffix)
            let files = request.files.map { file -> BundleDestination.File in
                let primary = Self.url(file.primaryFolder, name, file.pathExtension)
                let backup = file.backupFolder.map { Self.url($0, name, file.pathExtension) }
                return BundleDestination.File(
                    source: file.source,
                    role: file.role,
                    primary: primary,
                    backup: backup,
                    skipReason: skip(file, primary),
                    backupSkipReason: skipBackup(file, backup)
                )
            }
            return BundleDestination(
                id: request.id,
                suffix: suffix,
                files: files,
                renamedAwayFromDifferentPhoto: renamedAwayFromDifferentPhoto,
                replacesDifferentPhoto: replacesDifferentPhoto
            )
        }

        /// The lowest free suffix at or after `start`, or a whole-exposure skip when the suffix
        /// space is exhausted (never let the files of one exposure resolve independently).
        func renamed(_ request: BundleDestinationRequest, from start: Int, flagged: Bool) -> BundleDestination? {
            var suffix = start
            while suffix <= start + 10_000 {
                guard !Task.isCancelled else { return nil }
                if isFree(request, suffix: suffix) {
                    claim(request, suffix: suffix)
                    return destination(request, suffix: suffix, renamedAwayFromDifferentPhoto: flagged && suffix != request.plannedSuffix)
                }
                suffix += 1
            }
            return destination(
                request,
                suffix: request.plannedSuffix,
                skip: { _, _ in .destinationExists },
                skipBackup: { _, _ in .destinationExists }
            )
        }

        for request in requests {
            guard !Task.isCancelled else { return cancelled() }
            let planned = request.plannedSuffix
            let plannedName = Self.name(request.stem, planned)

            switch policy {
            case .overwrite:
                var replacesAny = false
                var replacesSamePhoto = false
                for file in request.files where file.role == .image {
                    let primary = Self.url(file.primaryFolder, plannedName, file.pathExtension)
                    guard fileExists(primary.path) else { continue }
                    replacesAny = true
                    if filesHaveSameIdentity(file.source, primary) { replacesSamePhoto = true }
                }
                guard !Task.isCancelled else { return cancelled() }
                claim(request, suffix: planned)
                destinations.append(destination(
                    request,
                    suffix: planned,
                    replacesDifferentPhoto: replacesAny && !replacesSamePhoto
                ))

            case .skipExisting:
                var existingPrimaries: Set<URL> = []
                var samePhotoIsThere = false
                for file in request.files {
                    let primary = Self.url(file.primaryFolder, plannedName, file.pathExtension)
                    guard fileExists(primary.path) else { continue }
                    existingPrimaries.insert(primary)
                    if file.role == .image, filesHaveSameIdentity(file.source, primary) {
                        samePhotoIsThere = true
                    }
                }
                guard !Task.isCancelled else { return cancelled() }
                if samePhotoIsThere {
                    // The exposure is already here. Its existing files (a JPEG may differ only by
                    // embedded metadata) are skipped; missing partners join them at this stem.
                    claim(request, suffix: planned)
                    destinations.append(destination(
                        request,
                        suffix: planned,
                        skip: { _, primary in existingPrimaries.contains(primary) ? .destinationExists : nil },
                        skipBackup: { _, backup in
                            backup.map { fileExistsProbe($0.path) } == true ? .destinationExists : nil
                        }
                    ))
                } else if isFree(request, suffix: planned) {
                    claim(request, suffix: planned)
                    destinations.append(destination(request, suffix: planned))
                } else {
                    // Only different files hold this name: keep the new photo under a new name.
                    guard let resolved = renamed(request, from: planned + 1, flagged: true) else {
                        return cancelled()
                    }
                    destinations.append(resolved)
                }

            case .renameWithSuffix:
                guard let resolved = renamed(request, from: planned, flagged: false) else {
                    return cancelled()
                }
                destinations.append(resolved)
            }
        }

        return .complete(BundlePlanningEvidence(
            requestedBundleCount: requests.count,
            destinations: destinations
        ))
    }

    private static func folders(of request: BundleDestinationRequest) -> [URL] {
        var seen = Set<String>()
        var folders: [URL] = []
        for file in request.files {
            for folder in [file.primaryFolder, file.backupFolder].compactMap({ $0 })
            where seen.insert(folder.standardizedFileURL.path.lowercased()).inserted {
                folders.append(folder)
            }
        }
        return folders
    }

    private static func claimKey(folder: URL, name: String) -> String {
        folder.standardizedFileURL.path.lowercased() + "|" + stemKey(name)
    }

    private static func name(_ stem: String, _ suffix: Int) -> String {
        suffix > 0 ? "\(stem)-\(suffix)" : stem
    }

    private static func url(_ folder: URL, _ name: String, _ pathExtension: String) -> URL {
        folder.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
    }
}
