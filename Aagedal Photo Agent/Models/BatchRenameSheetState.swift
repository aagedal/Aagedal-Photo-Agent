import Foundation

nonisolated struct BatchRenameSheetRequest: Identifiable, Sendable {
    let id: UUID
    let folderURL: URL
    let items: [RenamePlanningItem]

    init(
        id: UUID = UUID(),
        folderURL: URL,
        items: [RenamePlanningItem]
    ) {
        self.id = id
        self.folderURL = folderURL
        self.items = items
    }
}

nonisolated enum BatchRenameEditorComponentKind: String, CaseIterable, Sendable {
    case literal
    case originalFilename
    case originalStem
    case originalExtension
    case sequence
    case captureDate
    case fileCreationDate
    case fileModificationDate
    case metadata
    case jobTitle
    case importTitle

    var displayName: String {
        switch self {
        case .literal: return "Text"
        case .originalFilename: return "Original filename"
        case .originalStem: return "Original name"
        case .originalExtension: return "Extension"
        case .sequence: return "Sequence"
        case .captureDate: return "Capture date"
        case .fileCreationDate: return "File creation date"
        case .fileModificationDate: return "File modification date"
        case .metadata: return "Metadata"
        case .jobTitle: return "Job title"
        case .importTitle: return "Import title"
        }
    }
}

nonisolated struct BatchRenameEditorComponent: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: BatchRenameEditorComponentKind
    var literal: String
    var sequenceStart: Int
    var sequenceStep: Int
    var sequencePadding: Int
    var dateFormat: String
    var captureDateFallback: BatchRenameCaptureDateFallback
    var metadataField: BatchRenameMetadataField

    init(
        id: UUID = UUID(),
        kind: BatchRenameEditorComponentKind,
        literal: String = "",
        sequenceStart: Int = 1,
        sequenceStep: Int = 1,
        sequencePadding: Int = 3,
        dateFormat: String = "yyyyMMdd",
        captureDateFallback: BatchRenameCaptureDateFallback = .fileModification,
        metadataField: BatchRenameMetadataField = .title
    ) {
        self.id = id
        self.kind = kind
        self.literal = literal
        self.sequenceStart = sequenceStart
        self.sequenceStep = sequenceStep
        self.sequencePadding = sequencePadding
        self.dateFormat = dateFormat
        self.captureDateFallback = captureDateFallback
        self.metadataField = metadataField
    }

    var recipeComponent: BatchRenameComponent {
        switch kind {
        case .literal:
            return .literal(literal)
        case .originalFilename:
            return .token(.originalFilename)
        case .originalStem:
            return .token(.originalStem)
        case .originalExtension:
            return .token(.originalExtension)
        case .sequence:
            return .token(.sequence(BatchRenameSequence(
                start: sequenceStart,
                step: sequenceStep,
                padding: sequencePadding
            )))
        case .captureDate:
            return .token(.date(BatchRenameDateToken(
                source: .capture(fallback: captureDateFallback),
                format: dateFormat
            )))
        case .fileCreationDate:
            return .token(.date(BatchRenameDateToken(source: .fileCreation, format: dateFormat)))
        case .fileModificationDate:
            return .token(.date(BatchRenameDateToken(source: .fileModification, format: dateFormat)))
        case .metadata:
            return .token(.metadata(metadataField))
        case .jobTitle:
            return .token(.jobTitle)
        case .importTitle:
            return .token(.importTitle)
        }
    }

    init(recipeComponent: BatchRenameComponent) {
        switch recipeComponent {
        case let .literal(value):
            self.init(kind: .literal, literal: value)
        case .token(.originalFilename):
            self.init(kind: .originalFilename)
        case .token(.originalStem):
            self.init(kind: .originalStem)
        case .token(.originalExtension):
            self.init(kind: .originalExtension)
        case let .token(.sequence(sequence)):
            self.init(
                kind: .sequence,
                sequenceStart: sequence.start,
                sequenceStep: sequence.step,
                sequencePadding: sequence.padding
            )
        case let .token(.date(date)):
            switch date.source {
            case let .capture(fallback):
                self.init(
                    kind: .captureDate,
                    dateFormat: date.format,
                    captureDateFallback: fallback
                )
            case .fileCreation:
                self.init(kind: .fileCreationDate, dateFormat: date.format)
            case .fileModification:
                self.init(kind: .fileModificationDate, dateFormat: date.format)
            }
        case let .token(.metadata(field)):
            self.init(kind: .metadata, metadataField: field)
        case .token(.jobTitle):
            self.init(kind: .jobTitle)
        case .token(.importTitle):
            self.init(kind: .importTitle)
        }
    }
}

nonisolated enum BatchRenameCollisionChoice: String, CaseIterable, Codable, Equatable, Sendable {
    case block
    case skip
    case deterministicSuffix

    var displayName: String {
        switch self {
        case .block: return "Block rename"
        case .skip: return "Skip conflicts"
        case .deterministicSuffix: return "Append number"
        }
    }

    var policy: RenameCollisionPolicy {
        switch self {
        case .block: return .block
        case .skip: return .skip
        case .deterministicSuffix: return .appendDeterministicSuffix()
        }
    }
}

/// UI-editable recipe state kept independent from SwiftUI so recipe assembly and default behavior
/// can be tested without presenting a sheet.
nonisolated struct BatchRenameEditorState: Equatable, Sendable {
    var components: [BatchRenameEditorComponent]
    var collisionChoice: BatchRenameCollisionChoice
    private var recipeTemplate: BatchRenameRecipe

    init(
        components: [BatchRenameEditorComponent],
        collisionChoice: BatchRenameCollisionChoice = .block
    ) {
        self.components = components
        self.collisionChoice = collisionChoice
        recipeTemplate = BatchRenameRecipe(
            name: "Browser rename",
            components: components.map(\.recipeComponent),
            missingValuePolicy: .block
        )
    }

    init(sourceFilenames: [String]) {
        if sourceFilenames.count == 1, let filename = sourceFilenames.first {
            components = [BatchRenameEditorComponent(kind: .literal, literal: filename)]
        } else {
            components = [
                BatchRenameEditorComponent(kind: .originalStem),
                BatchRenameEditorComponent(kind: .literal, literal: "-"),
                BatchRenameEditorComponent(kind: .sequence),
                BatchRenameEditorComponent(kind: .literal, literal: "."),
                BatchRenameEditorComponent(kind: .originalExtension),
            ]
        }
        collisionChoice = .block
        recipeTemplate = BatchRenameRecipe(
            name: "Browser rename",
            components: components.map(\.recipeComponent),
            missingValuePolicy: .block
        )
    }

    init(recipe: BatchRenameRecipe, collisionChoice: BatchRenameCollisionChoice) {
        components = recipe.components.map(BatchRenameEditorComponent.init(recipeComponent:))
        self.collisionChoice = collisionChoice
        recipeTemplate = recipe
    }

    var recipe: BatchRenameRecipe {
        var result = recipeTemplate
        result.components = components.map(\.recipeComponent)
        return result
    }

    func recipe(named name: String) -> BatchRenameRecipe {
        var result = recipe
        result.name = name
        return result
    }

    mutating func setRecipeName(_ name: String) {
        recipeTemplate.name = name
    }
}

nonisolated struct BatchRenamePreviewRow: Identifiable, Equatable, Sendable {
    let id: Int
    let oldName: String
    let requestedName: String
    let plannedName: String
    let disposition: RenamePlanEntryDisposition
    let blockingIssueCount: Int
    let warningIssueCount: Int
    let issueText: String

    init(entry: RenamePlanEntry) {
        id = entry.itemIndex
        oldName = entry.sourceImageURL.lastPathComponent
        requestedName = entry.requestedDestinationImageURL?.lastPathComponent ?? "—"
        plannedName = entry.plannedDestinationImageURL?.lastPathComponent ?? "—"
        disposition = entry.disposition
        blockingIssueCount = entry.issues.count { $0.severity == .blocking }
        warningIssueCount = entry.issues.count { $0.severity == .warning }
        issueText = entry.issues.map(Self.describe).joined(separator: "; ")
    }

    private static func describe(_ issue: RenamePlanIssue) -> String {
        switch issue.code {
        case .missingValue(_, let token, let resolution):
            return "Missing \(tokenName(token)) (\(resolutionName(resolution)))"
        case .recipeProblem(.invalidRegularExpression(_, let pattern)):
            return "Invalid regular expression: \(pattern)"
        case .invalidFilename(let reason):
            switch reason {
            case .empty: return "Filename is empty"
            case .dotPathComponent: return "Filename cannot be . or .."
            case .forbiddenCharacter: return "Filename contains a forbidden character"
            case .trailingSpaceOrPeriod: return "Filename ends in a space or period"
            case .exceedsFilesystemByteLimit: return "Filename is too long"
            }
        case .duplicateTarget(let otherIndex, _):
            return "Duplicates row \(otherIndex + 1)"
        case .existingDestination(let existingURL):
            return "Already exists: \(existingURL.lastPathComponent)"
        case .caseInsensitiveCollision(let existingURL):
            return "Case-insensitive conflict: \(existingURL.lastPathComponent)"
        case .caseOnlyRename:
            return "Case-only rename"
        case .deterministicSuffixApplied(_, let requestedName, let resolvedName):
            return "Conflict resolved: \(requestedName) → \(resolvedName)"
        case .deterministicSuffixExhausted(let maximumAttempts):
            return "Could not find a free suffix in \(maximumAttempts) attempts"
        case .originalFilenameXMPSidecarMissing:
            return "Original-filename preservation requires an existing XMP sidecar for RAW"
        }
    }

    private static func resolutionName(_ resolution: RenameMissingValueResolution) -> String {
        switch resolution {
        case .empty: return "empty"
        case .fallback: return "fallback"
        case .preserveOriginal: return "preserve original"
        case .skip: return "skip"
        case .block: return "blocked"
        }
    }

    private static func tokenName(_ token: BatchRenameToken) -> String {
        switch token {
        case .originalFilename: return "original filename"
        case .originalStem: return "original name"
        case .originalExtension: return "extension"
        case .sequence: return "sequence"
        case .date: return "date"
        case .metadata(let field): return field.rawValue
        case .jobTitle: return "job title"
        case .importTitle: return "import title"
        }
    }
}

nonisolated struct BatchRenameIssueSummary: Equatable, Sendable {
    let blockingCount: Int
    let warningCount: Int
    let missingValueCount: Int
    let invalidFilenameCount: Int
    let conflictCount: Int
    let caseWarningCount: Int

    init(plan: RenamePlan) {
        blockingCount = plan.issues.count { $0.severity == .blocking }
        warningCount = plan.issues.count { $0.severity == .warning }
        missingValueCount = plan.issues.count { $0.kind == .missingValue }
        invalidFilenameCount = plan.issues.count { $0.kind == .invalidFilename || $0.kind == .recipeProblem }
        conflictCount = plan.issues.count {
            $0.kind == .duplicateTarget
                || $0.kind == .existingDestination
                || $0.kind == .caseInsensitiveCollision
                || $0.kind == .deterministicSuffixApplied
                || $0.kind == .deterministicSuffixExhausted
        }
        caseWarningCount = plan.issues.count { $0.kind == .caseOnlyRename }
    }
}

nonisolated struct BatchRenameExecutionPresentation: Equatable, Sendable {
    struct Mapping: Equatable, Sendable {
        let sourceURL: URL
        let destinationURL: URL
    }

    let status: RenameExecutionStatus
    let rollbackStatus: RenameExecutionRollbackStatus
    let mappings: [Mapping]
    let headline: String
    let recoveryMessage: String
    let issueDetails: [String]
    let residualDetails: [String]
    /// The original request may be planned again only when rollback proved every source path was
    /// restored. Residual/incomplete cases must close and reopen from the reloaded browser state.
    let canRefreshOriginalRequest: Bool

    init(result: RenameExecutionResult) {
        status = result.status
        rollbackStatus = result.rollbackStatus
        canRefreshOriginalRequest = !result.succeeded
            && result.status != .preflightFailed
            && result.rollbackStatus == .succeeded
            && result.residuals.isEmpty
        mappings = result.succeeded ? result.bundles.compactMap { bundle in
            guard let destination = bundle.destinationImageURL else { return nil }
            return Mapping(sourceURL: bundle.sourceImageURL, destinationURL: destination)
        } : []

        switch result.status {
        case .succeeded:
            headline = "Rename complete"
            recoveryMessage = "All planned image and associated-file moves completed."
        case .cancelled:
            headline = "Rename cancelled"
            recoveryMessage = Self.recoveryMessage(result: result)
        case .preflightFailed:
            headline = "Rename could not start"
            recoveryMessage = "No planned move was trusted. The folder was reloaded from disk."
        case .failed:
            headline = "Rename failed"
            recoveryMessage = Self.recoveryMessage(result: result)
        }

        issueDetails = result.issues.map { issue in
            var parts = [issue.code.rawValue, issue.detail]
            if let source = issue.sourceURL?.lastPathComponent { parts.append("source: \(source)") }
            if let destination = issue.destinationURL?.lastPathComponent { parts.append("destination: \(destination)") }
            return parts.joined(separator: " · ")
        }
        residualDetails = result.residuals.map { residual in
            let current = residual.currentURL?.path ?? "missing"
            let metadataWarning = residual.metadataMayContainUpdatedSourceFile
                ? " · metadata sourceFile may require repair"
                : ""
            return "\(residual.artifactIdentifier): \(residual.location.rawValue) at \(current) · expected \(residual.expectedSourceURL.path) · intended \(residual.intendedDestinationURL.path)\(metadataWarning)"
        }
    }

    private static func recoveryMessage(result: RenameExecutionResult) -> String {
        if result.rollbackStatus == .succeeded && result.residuals.isEmpty {
            return "The executor restored the original paths. The folder was reloaded from disk to verify the result."
        }
        if result.rollbackStatus == .failed || !result.residuals.isEmpty {
            return "Automatic rollback was incomplete. Review the residual paths below before changing these files again; the folder was reloaded from disk."
        }
        return "No completed paths were assumed. The folder was reloaded from disk."
    }
}

nonisolated struct BatchRenameBrowserURLState: Equatable, Sendable {
    var selectedURLs: Set<URL>
    var lastClickedURL: URL?
    var manualOrder: [URL]

    func applying(_ mappings: [BatchRenameExecutionPresentation.Mapping]) -> Self {
        let destinations = Dictionary(uniqueKeysWithValues: mappings.map {
            ($0.sourceURL.standardizedFileURL, $0.destinationURL.standardizedFileURL)
        })
        func mapped(_ url: URL) -> URL {
            destinations[url.standardizedFileURL] ?? url
        }
        return Self(
            selectedURLs: Set(selectedURLs.map(mapped)),
            lastClickedURL: lastClickedURL.map(mapped),
            manualOrder: manualOrder.map(mapped)
        )
    }
}

nonisolated enum BatchRenameSnapshotError: LocalizedError {
    case folderUnavailable(URL)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let url): return "Could not inspect \(url.path) before planning."
        }
    }
}

/// Captures every path the standard artifact registry can consult on a serialized executor.
/// Planning receives only this immutable snapshot and therefore cannot race ad-hoc filesystem
/// reads while the recipe changes or block a caller isolated to the main actor.
actor BatchRenamePlanningSnapshotService {
    typealias DirectoryExists = @Sendable (URL) -> Bool
    typealias DirectoryContents = @Sendable (URL) throws -> [URL]
    typealias VolumeIsCaseSensitive = @Sendable (URL) -> Bool

    private let directoryExists: DirectoryExists
    private let directoryContents: DirectoryContents
    private let volumeIsCaseSensitive: VolumeIsCaseSensitive

    init(
        directoryExists: @escaping DirectoryExists = { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        directoryContents: @escaping DirectoryContents = { url in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        },
        volumeIsCaseSensitive: @escaping VolumeIsCaseSensitive = { url in
            (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
                .volumeSupportsCaseSensitiveNames == true
        }
    ) {
        self.directoryExists = directoryExists
        self.directoryContents = directoryContents
        self.volumeIsCaseSensitive = volumeIsCaseSensitive
    }

    func snapshot(
        folderURL: URL,
        artifactRegistry: RenameArtifactRegistry = .standard
    ) throws -> RenamePlanningEnvironment {
        try Task.checkCancellation()
        let folderExists = directoryExists(folderURL)
        try Task.checkCancellation()
        guard folderExists else {
            throw BatchRenameSnapshotError.folderUnavailable(folderURL)
        }

        var existingURLs = Set(try directoryContents(folderURL).map(\.standardizedFileURL))
        try Task.checkCancellation()

        let relativeDirectories = Set(artifactRegistry.rules.compactMap { rule -> String? in
            guard !rule.relativeDirectoryComponents.isEmpty else { return nil }
            return rule.relativeDirectoryComponents.joined(separator: "/")
        })
        for relativeDirectory in relativeDirectories.sorted() {
            try Task.checkCancellation()
            let directoryURL = folderURL.appendingPathComponent(relativeDirectory, isDirectory: true)
            let companionDirectoryExists = directoryExists(directoryURL)
            try Task.checkCancellation()
            guard companionDirectoryExists else { continue }
            let children = try directoryContents(directoryURL)
            try Task.checkCancellation()
            existingURLs.formUnion(children.map(\.standardizedFileURL))
        }

        try Task.checkCancellation()
        let isCaseSensitive = volumeIsCaseSensitive(folderURL)
        try Task.checkCancellation()
        let caseSensitivity: RenamePathCaseSensitivity = isCaseSensitive
            ? .caseSensitive
            : .caseInsensitive
        return RenamePlanningEnvironment(
            caseSensitivity: caseSensitivity,
            existingURLs: existingURLs
        )
    }
}
