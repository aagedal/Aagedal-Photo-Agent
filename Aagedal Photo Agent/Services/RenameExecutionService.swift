import Foundation

nonisolated protocol RenameExecutionFileSystem: Sendable {
    func itemExists(at url: URL) -> Bool
    func directoryAllowsChanges(at directoryURL: URL) -> Bool
    func itemsReferToSameFile(_ firstURL: URL, _ secondURL: URL) throws -> Bool
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func data(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
}

nonisolated struct FoundationRenameExecutionFileSystem: RenameExecutionFileSystem {
    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func directoryAllowsChanges(at directoryURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: directoryURL.path)
    }

    func itemsReferToSameFile(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        if firstURL.standardizedFileURL.path == secondURL.standardizedFileURL.path {
            return true
        }
        guard itemExists(at: firstURL), itemExists(at: secondURL) else { return false }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        let first = try firstURL.resourceValues(forKeys: keys).fileResourceIdentifier
        let second = try secondURL.resourceValues(forKeys: keys).fileResourceIdentifier
        guard let first, let second else { return false }
        return (first as AnyObject).isEqual(second)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

nonisolated enum RenameExecutionStatus: String, Equatable, Sendable {
    case succeeded
    case cancelled
    case preflightFailed
    case failed
}

nonisolated enum RenameExecutionRollbackStatus: String, Equatable, Sendable {
    case notNeeded
    case succeeded
    case failed
}

nonisolated enum RenameExecutionArtifactLocation: String, Equatable, Sendable {
    case source
    case temporary
    case destination
    case missing
}

nonisolated struct RenameExecutionIssue: Equatable, Sendable {
    enum Code: String, Equatable, Sendable {
        case planNotExecutable
        case malformedPlan
        case sourceMissing
        case duplicateSource
        case duplicateDestination
        case destinationOccupied
        case directoryNotWritable
        case destinationNotReserved
        case temporaryPathUnavailable
        case invalidMetadataSidecar
        case invalidOriginalFilenameMetadata
        case cancelled
        case moveFailed
        case injectedFailure
        case metadataUpdateFailed
        case rollbackMoveFailed
        case rollbackMetadataRestoreFailed
    }

    let code: Code
    let itemIndex: Int?
    let artifactIdentifier: String?
    let sourceURL: URL?
    let destinationURL: URL?
    let detail: String
}

nonisolated struct RenameExecutionMove: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case stage
        case commit
        case rollbackStage
        case rollbackRestore
    }

    let ordinal: Int
    let phase: Phase
    let itemIndex: Int
    let artifactIdentifier: String
    let sourceURL: URL
    let destinationURL: URL
}

nonisolated struct RenameExecutionResidual: Equatable, Sendable {
    let itemIndex: Int
    let artifactIdentifier: String
    let location: RenameExecutionArtifactLocation
    let currentURL: URL?
    let expectedSourceURL: URL
    let intendedDestinationURL: URL
    let temporaryURL: URL
    /// True means the executor could not prove that the original JSON bytes were restored.
    let metadataMayContainUpdatedSourceFile: Bool
}

nonisolated struct RenameExecutionBundleResult: Equatable, Sendable {
    let itemIndex: Int
    let sourceImageURL: URL
    let destinationImageURL: URL?
    let artifactIdentifiers: [String]
    let completedArtifactIdentifiers: [String]
}

nonisolated struct RenameExecutionResult: Equatable, Sendable {
    let status: RenameExecutionStatus
    let rollbackStatus: RenameExecutionRollbackStatus
    let bundles: [RenameExecutionBundleResult]
    let moves: [RenameExecutionMove]
    let issues: [RenameExecutionIssue]
    let residuals: [RenameExecutionResidual]

    var succeeded: Bool { status == .succeeded }
}

/// Executes a previously generated immutable plan. It never re-renders a recipe or discovers new
/// artifacts: the plan is the complete authority for which paths belong to each bundle.
nonisolated struct RenameExecutionService: Sendable {
    typealias CancellationCheck = @Sendable () -> Bool
    typealias MoveCompletionHook = @Sendable (RenameExecutionMove) -> String?

    private let fileSystem: any RenameExecutionFileSystem
    private let temporaryNameToken: @Sendable () -> String
    private let cancellationRequested: CancellationCheck
    private let afterMove: MoveCompletionHook
    private let originalFilenameMetadataCodec: any RenameOriginalFilenameMetadataCodec

    init(
        fileSystem: any RenameExecutionFileSystem = FoundationRenameExecutionFileSystem(),
        temporaryNameToken: @escaping @Sendable () -> String = { UUID().uuidString },
        cancellationRequested: @escaping CancellationCheck = { false },
        afterMove: @escaping MoveCompletionHook = { _ in nil },
        originalFilenameMetadataCodec: any RenameOriginalFilenameMetadataCodec =
            SwiftExifRenameOriginalFilenameMetadataCodec()
    ) {
        self.fileSystem = fileSystem
        self.temporaryNameToken = temporaryNameToken
        self.cancellationRequested = cancellationRequested
        self.afterMove = afterMove
        self.originalFilenameMetadataCodec = originalFilenameMetadataCodec
    }

    func execute(_ plan: RenamePlan) async -> RenameExecutionResult {
        switch prepare(plan) {
        case let .failure(failure):
            return RenameExecutionResult(
                status: .preflightFailed,
                rollbackStatus: .notNeeded,
                bundles: Self.bundleResults(plan: plan, states: []),
                moves: [],
                issues: failure.issues,
                residuals: []
            )
        case let .success(prepared):
            return await executePrepared(plan: plan, actions: prepared)
        }
    }

    private func executePrepared(
        plan: RenamePlan,
        actions: [PreparedAction]
    ) async -> RenameExecutionResult {
        guard !isCancellationRequested else {
            return RenameExecutionResult(
                status: .cancelled,
                rollbackStatus: .notNeeded,
                bundles: Self.bundleResults(plan: plan, states: []),
                moves: [],
                issues: [Self.cancellationIssue()],
                residuals: []
            )
        }
        guard !actions.isEmpty else {
            return RenameExecutionResult(
                status: .succeeded,
                rollbackStatus: .notNeeded,
                bundles: Self.bundleResults(plan: plan, states: []),
                moves: [],
                issues: [],
                residuals: []
            )
        }

        var states = actions.map { ActionState(action: $0) }
        var moves: [RenameExecutionMove] = []
        var moveOrdinal = 0

        func completedMove(
            phase: RenameExecutionMove.Phase,
            stateIndex: Int,
            source: URL,
            destination: URL
        ) -> RenameExecutionMove {
            moveOrdinal += 1
            let action = states[stateIndex].action
            return RenameExecutionMove(
                ordinal: moveOrdinal,
                phase: phase,
                itemIndex: action.itemIndex,
                artifactIdentifier: action.artifact.identifier,
                sourceURL: source,
                destinationURL: destination
            )
        }

        for index in states.indices {
            let action = states[index].action
            if isCancellationRequested {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .cancelled,
                    triggeringIssue: Self.cancellationIssue()
                )
            }
            do {
                guard !fileSystem.itemExists(at: action.temporaryURL) else {
                    throw ExecutionError("Temporary path became occupied")
                }
                try fileSystem.moveItem(at: action.artifact.sourceURL, to: action.temporaryURL)
                states[index].location = .temporary
                let event = completedMove(
                    phase: .stage,
                    stateIndex: index,
                    source: action.artifact.sourceURL,
                    destination: action.temporaryURL
                )
                moves.append(event)
                if let detail = afterMove(event) {
                    return rollback(
                        plan: plan,
                        states: &states,
                        moves: &moves,
                        triggeringStatus: .failed,
                        triggeringIssue: Self.issue(.injectedFailure, action: action, detail: detail)
                    )
                }
                if isCancellationRequested {
                    return rollback(
                        plan: plan,
                        states: &states,
                        moves: &moves,
                        triggeringStatus: .cancelled,
                        triggeringIssue: Self.cancellationIssue()
                    )
                }
            } catch {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .failed,
                    triggeringIssue: Self.issue(.moveFailed, action: action, detail: error.localizedDescription)
                )
            }
            await Task.yield()
        }

        // Metadata is changed only after every source is safely staged. Original bytes remain in
        // memory and are restored before rollback puts the file back at its source path. This
        // applies equally to JSON sourceFile updates, embedded JPEG XMP, and RAW XMP sidecars.
        for index in states.indices {
            guard let updatedData = states[index].action.updatedMetadataData else { continue }
            if isCancellationRequested {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .cancelled,
                    triggeringIssue: Self.cancellationIssue()
                )
            }
            do {
                try fileSystem.writeDataAtomically(updatedData, to: states[index].action.temporaryURL)
                states[index].metadataWasUpdated = true
            } catch {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .failed,
                    triggeringIssue: Self.issue(
                        .metadataUpdateFailed,
                        action: states[index].action,
                        detail: error.localizedDescription
                    )
                )
            }
            await Task.yield()
        }

        for index in states.indices {
            let action = states[index].action
            if isCancellationRequested {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .cancelled,
                    triggeringIssue: Self.cancellationIssue()
                )
            }
            do {
                guard !fileSystem.itemExists(at: action.artifact.destinationURL) else {
                    throw ExecutionError("Destination became occupied after preflight")
                }
                try fileSystem.moveItem(at: action.temporaryURL, to: action.artifact.destinationURL)
                states[index].location = .destination
                let event = completedMove(
                    phase: .commit,
                    stateIndex: index,
                    source: action.temporaryURL,
                    destination: action.artifact.destinationURL
                )
                moves.append(event)
                if let detail = afterMove(event) {
                    return rollback(
                        plan: plan,
                        states: &states,
                        moves: &moves,
                        triggeringStatus: .failed,
                        triggeringIssue: Self.issue(.injectedFailure, action: action, detail: detail)
                    )
                }
                if isCancellationRequested {
                    return rollback(
                        plan: plan,
                        states: &states,
                        moves: &moves,
                        triggeringStatus: .cancelled,
                        triggeringIssue: Self.cancellationIssue()
                    )
                }
            } catch {
                return rollback(
                    plan: plan,
                    states: &states,
                    moves: &moves,
                    triggeringStatus: .failed,
                    triggeringIssue: Self.issue(.moveFailed, action: action, detail: error.localizedDescription)
                )
            }
            await Task.yield()
        }

        return RenameExecutionResult(
            status: .succeeded,
            rollbackStatus: .notNeeded,
            bundles: Self.bundleResults(plan: plan, states: states),
            moves: moves,
            issues: [],
            residuals: []
        )
    }

    private func prepare(_ plan: RenamePlan) -> Result<[PreparedAction], PreflightFailure> {
        var issues: [RenameExecutionIssue] = []
        guard plan.canExecute else {
            return .failure(PreflightFailure(issues: [RenameExecutionIssue(
                code: .planNotExecutable,
                itemIndex: nil,
                artifactIdentifier: nil,
                sourceURL: nil,
                destinationURL: nil,
                detail: "The plan contains blocking issues"
            )]))
        }

        let reservedPaths = Set(plan.reservedDestinationURLs.map(Self.path))
        var moving: [(entry: RenamePlanEntry, artifact: RenameArtifactAction)] = []
        for entry in plan.entries where entry.disposition == .blocked {
            issues.append(Self.issue(
                .planNotExecutable,
                entry: entry,
                artifact: nil,
                detail: "A blocked entry cannot appear in an executable plan"
            ))
        }
        for entry in plan.entries where entry.disposition == .rename {
            let imageActions = entry.plannedArtifactActions.filter { $0.role == .image }
            if imageActions.count != 1
                || imageActions.first?.sourceURL.standardizedFileURL != entry.sourceImageURL.standardizedFileURL
                || imageActions.first?.destinationURL.standardizedFileURL != entry.plannedDestinationImageURL?.standardizedFileURL {
                issues.append(Self.issue(
                    .malformedPlan,
                    entry: entry,
                    artifact: imageActions.first,
                    detail: "A rename entry must contain exactly one matching image action"
                ))
            }
            for artifact in entry.plannedArtifactActions where artifact.changesPath {
                moving.append((entry, artifact))
                if Self.path(artifact.sourceURL.deletingLastPathComponent())
                    != Self.path(artifact.destinationURL.deletingLastPathComponent()) {
                    issues.append(Self.issue(
                        .malformedPlan,
                        entry: entry,
                        artifact: artifact,
                        detail: "Execution requires each artifact to remain in its source directory"
                    ))
                }
                if !reservedPaths.contains(Self.path(artifact.destinationURL)) {
                    issues.append(Self.issue(
                        .destinationNotReserved,
                        entry: entry,
                        artifact: artifact,
                        detail: "The planned destination is absent from the reservation set"
                    ))
                }
            }
        }

        for index in moving.indices {
            let candidate = moving[index]
            guard fileSystem.itemExists(at: candidate.artifact.sourceURL) else {
                issues.append(Self.issue(
                    .sourceMissing,
                    entry: candidate.entry,
                    artifact: candidate.artifact,
                    detail: "The planned source no longer exists"
                ))
                continue
            }
            for otherIndex in moving.indices where otherIndex < index {
                let other = moving[otherIndex]
                do {
                    if try fileSystem.itemsReferToSameFile(candidate.artifact.sourceURL, other.artifact.sourceURL) {
                        issues.append(Self.issue(
                            .duplicateSource,
                            entry: candidate.entry,
                            artifact: candidate.artifact,
                            detail: "Two actions refer to the same live source"
                        ))
                    }
                } catch {
                    issues.append(Self.issue(
                        .malformedPlan,
                        entry: candidate.entry,
                        artifact: candidate.artifact,
                        detail: "Could not compare source identities: \(error.localizedDescription)"
                    ))
                }
                if Self.path(candidate.artifact.destinationURL) == Self.path(other.artifact.destinationURL) {
                    issues.append(Self.issue(
                        .duplicateDestination,
                        entry: candidate.entry,
                        artifact: candidate.artifact,
                        detail: "Two actions have the same destination path"
                    ))
                }
            }
        }

        for candidate in moving where fileSystem.itemExists(at: candidate.artifact.destinationURL) {
            var destinationIsMovingSource = false
            for source in moving {
                do {
                    if try fileSystem.itemsReferToSameFile(candidate.artifact.destinationURL, source.artifact.sourceURL) {
                        destinationIsMovingSource = true
                        break
                    }
                } catch {
                    issues.append(Self.issue(
                        .malformedPlan,
                        entry: candidate.entry,
                        artifact: candidate.artifact,
                        detail: "Could not inspect an occupied destination: \(error.localizedDescription)"
                    ))
                }
            }
            if !destinationIsMovingSource {
                issues.append(Self.issue(
                    .destinationOccupied,
                    entry: candidate.entry,
                    artifact: candidate.artifact,
                    detail: "The destination is occupied by an item outside this plan"
                ))
            }
        }


        let requiredDirectories = Set(moving.flatMap {
            [$0.artifact.sourceURL.deletingLastPathComponent(), $0.artifact.destinationURL.deletingLastPathComponent()]
        })
        for directory in requiredDirectories where !fileSystem.directoryAllowsChanges(at: directory) {
            issues.append(RenameExecutionIssue(
                code: .directoryNotWritable,
                itemIndex: nil,
                artifactIdentifier: nil,
                sourceURL: directory,
                destinationURL: nil,
                detail: "A source or destination directory does not allow filesystem changes"
            ))
        }

        guard issues.isEmpty else { return .failure(PreflightFailure(issues: issues)) }

        var prepared: [PreparedAction] = []
        var unavailableTemporaryPaths = Set(moving.flatMap {
            [Self.path($0.artifact.sourceURL), Self.path($0.artifact.destinationURL)]
        })
        for candidate in moving {
            guard let temporaryURL = makeTemporaryURL(
                nextTo: candidate.artifact.sourceURL,
                unavailablePaths: &unavailableTemporaryPaths
            ) else {
                issues.append(Self.issue(
                    .temporaryPathUnavailable,
                    entry: candidate.entry,
                    artifact: candidate.artifact,
                    detail: "Could not reserve a unique temporary path after 256 attempts"
                ))
                continue
            }
            do {
                let metadata = try preparedMetadataUpdate(
                    entry: candidate.entry,
                    artifact: candidate.artifact
                )
                prepared.append(PreparedAction(
                    itemIndex: candidate.entry.itemIndex,
                    artifact: candidate.artifact,
                    temporaryURL: temporaryURL,
                    originalMetadataData: metadata?.original,
                    updatedMetadataData: metadata?.updated
                ))
            } catch {
                issues.append(Self.issue(
                    candidate.artifact.originalFilenameMetadataMutation == nil
                        ? .invalidMetadataSidecar
                        : .invalidOriginalFilenameMetadata,
                    entry: candidate.entry,
                    artifact: candidate.artifact,
                    detail: error.localizedDescription
                ))
            }
        }
        return issues.isEmpty ? .success(prepared) : .failure(PreflightFailure(issues: issues))
    }

    private func preparedMetadataUpdate(
        entry: RenamePlanEntry,
        artifact: RenameArtifactAction
    ) throws -> (original: Data, updated: Data)? {
        if let mutation = artifact.originalFilenameMetadataMutation {
            let expectedStorage: RenameOriginalFilenameMetadataMutation.Storage =
                artifact.role == .image ? .embeddedImageXMP : .xmpSidecar
            guard mutation.storage == expectedStorage else {
                throw ExecutionError("The planned XMP storage does not match its target artifact")
            }
            let original = try fileSystem.data(at: artifact.sourceURL)
            return (
                original,
                try originalFilenameMetadataCodec.applying(mutation, to: original)
            )
        }

        guard artifact.identifier == "photo-metadata-current"
                || artifact.identifier == "photo-metadata-legacy" else { return nil }
        guard let destinationImageURL = entry.plannedDestinationImageURL else {
            throw ExecutionError("A metadata sidecar has no destination image")
        }
        let original = try fileSystem.data(at: artifact.sourceURL)
        guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              object["sourceFile"] is String else {
            throw ExecutionError("Metadata sidecar is not a JSON object with a sourceFile string")
        }
        object["sourceFile"] = destinationImageURL.lastPathComponent
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return (original, updated)
    }

    private func makeTemporaryURL(nextTo sourceURL: URL, unavailablePaths: inout Set<String>) -> URL? {
        let directory = sourceURL.deletingLastPathComponent()
        for attempt in 1...256 {
            let token = temporaryNameToken()
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let candidate = directory.appendingPathComponent(
                ".aagedal-rename-\(token)-\(attempt)-\(sourceURL.lastPathComponent)"
            )
            let candidatePath = Self.path(candidate)
            if unavailablePaths.insert(candidatePath).inserted,
               !fileSystem.itemExists(at: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func rollback(
        plan: RenamePlan,
        states: inout [ActionState],
        moves: inout [RenameExecutionMove],
        triggeringStatus: RenameExecutionStatus,
        triggeringIssue: RenameExecutionIssue
    ) -> RenameExecutionResult {
        var rollbackIssues: [RenameExecutionIssue] = []
        var moveOrdinal = moves.count

        // Re-stage committed destinations first. This vacates every cycle destination before any
        // action attempts to reclaim its original source path.
        for index in states.indices.reversed() where states[index].location == .destination {
            let action = states[index].action
            do {
                guard !fileSystem.itemExists(at: action.temporaryURL) else {
                    throw ExecutionError("Rollback temporary path is occupied")
                }
                try fileSystem.moveItem(at: action.artifact.destinationURL, to: action.temporaryURL)
                states[index].location = .temporary
                moveOrdinal += 1
                moves.append(RenameExecutionMove(
                    ordinal: moveOrdinal,
                    phase: .rollbackStage,
                    itemIndex: action.itemIndex,
                    artifactIdentifier: action.artifact.identifier,
                    sourceURL: action.artifact.destinationURL,
                    destinationURL: action.temporaryURL
                ))
            } catch {
                rollbackIssues.append(Self.issue(
                    .rollbackMoveFailed,
                    action: action,
                    detail: error.localizedDescription
                ))
            }
        }

        // Put byte-for-byte original JSON back before returning sidecars to their original names.
        for index in states.indices where states[index].metadataWasUpdated {
            let action = states[index].action
            guard let original = action.originalMetadataData else { continue }
            let currentURL: URL
            switch states[index].location {
            case .temporary: currentURL = action.temporaryURL
            case .destination: currentURL = action.artifact.destinationURL
            case .source: currentURL = action.artifact.sourceURL
            }
            do {
                try fileSystem.writeDataAtomically(original, to: currentURL)
                states[index].metadataWasUpdated = false
            } catch {
                rollbackIssues.append(Self.issue(
                    .rollbackMetadataRestoreFailed,
                    action: action,
                    detail: error.localizedDescription
                ))
            }
        }

        for index in states.indices where states[index].location == .temporary {
            let action = states[index].action
            do {
                guard !fileSystem.itemExists(at: action.artifact.sourceURL) else {
                    throw ExecutionError("Original source path is occupied during rollback")
                }
                try fileSystem.moveItem(at: action.temporaryURL, to: action.artifact.sourceURL)
                states[index].location = .source
                moveOrdinal += 1
                moves.append(RenameExecutionMove(
                    ordinal: moveOrdinal,
                    phase: .rollbackRestore,
                    itemIndex: action.itemIndex,
                    artifactIdentifier: action.artifact.identifier,
                    sourceURL: action.temporaryURL,
                    destinationURL: action.artifact.sourceURL
                ))
            } catch {
                rollbackIssues.append(Self.issue(
                    .rollbackMoveFailed,
                    action: action,
                    detail: error.localizedDescription
                ))
            }
        }

        let residuals = states.compactMap { state -> RenameExecutionResidual? in
            guard state.location != .source || state.metadataWasUpdated else { return nil }
            let expected: (location: RenameExecutionArtifactLocation, url: URL)
            switch state.location {
            case .source: expected = (.source, state.action.artifact.sourceURL)
            case .temporary: expected = (.temporary, state.action.temporaryURL)
            case .destination: expected = (.destination, state.action.artifact.destinationURL)
            }
            // Failed filesystem operations are not assumed to be atomic. Report missing when no
            // candidate path exists, and otherwise prefer the state transition we last observed.
            let candidates: [(RenameExecutionArtifactLocation, URL)] = [
                expected,
                (.source, state.action.artifact.sourceURL),
                (.temporary, state.action.temporaryURL),
                (.destination, state.action.artifact.destinationURL),
            ]
            let observed = candidates.first { fileSystem.itemExists(at: $0.1) }
            return RenameExecutionResidual(
                itemIndex: state.action.itemIndex,
                artifactIdentifier: state.action.artifact.identifier,
                location: observed?.0 ?? .missing,
                currentURL: observed?.1,
                expectedSourceURL: state.action.artifact.sourceURL,
                intendedDestinationURL: state.action.artifact.destinationURL,
                temporaryURL: state.action.temporaryURL,
                metadataMayContainUpdatedSourceFile: state.metadataWasUpdated
            )
        }
        let rollbackSucceeded = rollbackIssues.isEmpty && residuals.isEmpty
        return RenameExecutionResult(
            status: triggeringStatus,
            rollbackStatus: rollbackSucceeded ? .succeeded : .failed,
            bundles: Self.bundleResults(plan: plan, states: states),
            moves: moves,
            issues: [triggeringIssue] + rollbackIssues,
            residuals: residuals
        )
    }

    private var isCancellationRequested: Bool {
        Task.isCancelled || cancellationRequested()
    }

    private static func bundleResults(
        plan: RenamePlan,
        states: [ActionState]
    ) -> [RenameExecutionBundleResult] {
        plan.entries.filter { $0.disposition == .rename || $0.disposition == .unchanged }.map { entry in
            let entryStates = states.filter { $0.action.itemIndex == entry.itemIndex }
            return RenameExecutionBundleResult(
                itemIndex: entry.itemIndex,
                sourceImageURL: entry.sourceImageURL,
                destinationImageURL: entry.plannedDestinationImageURL,
                artifactIdentifiers: entry.plannedArtifactActions.map(\.identifier),
                completedArtifactIdentifiers: entryStates.compactMap {
                    $0.location == .destination ? $0.action.artifact.identifier : nil
                }
            )
        }
    }

    private static func cancellationIssue() -> RenameExecutionIssue {
        RenameExecutionIssue(
            code: .cancelled,
            itemIndex: nil,
            artifactIdentifier: nil,
            sourceURL: nil,
            destinationURL: nil,
            detail: "Cancellation was observed at a filesystem-safe boundary"
        )
    }

    private static func issue(
        _ code: RenameExecutionIssue.Code,
        entry: RenamePlanEntry,
        artifact: RenameArtifactAction?,
        detail: String
    ) -> RenameExecutionIssue {
        RenameExecutionIssue(
            code: code,
            itemIndex: entry.itemIndex,
            artifactIdentifier: artifact?.identifier,
            sourceURL: artifact?.sourceURL ?? entry.sourceImageURL,
            destinationURL: artifact?.destinationURL ?? entry.plannedDestinationImageURL,
            detail: detail
        )
    }

    private static func issue(
        _ code: RenameExecutionIssue.Code,
        action: PreparedAction,
        detail: String
    ) -> RenameExecutionIssue {
        RenameExecutionIssue(
            code: code,
            itemIndex: action.itemIndex,
            artifactIdentifier: action.artifact.identifier,
            sourceURL: action.artifact.sourceURL,
            destinationURL: action.artifact.destinationURL,
            detail: detail
        )
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private struct PreparedAction: Sendable {
        let itemIndex: Int
        let artifact: RenameArtifactAction
        let temporaryURL: URL
        let originalMetadataData: Data?
        let updatedMetadataData: Data?
    }

    private struct ActionState: Sendable {
        enum Location: Sendable {
            case source
            case temporary
            case destination

            var publicLocation: RenameExecutionArtifactLocation {
                switch self {
                case .source: return .source
                case .temporary: return .temporary
                case .destination: return .destination
                }
            }
        }

        let action: PreparedAction
        var location: Location = .source
        var metadataWasUpdated = false
    }

    private struct ExecutionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct PreflightFailure: Error {
        let issues: [RenameExecutionIssue]
    }
}
