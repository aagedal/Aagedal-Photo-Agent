import Foundation

nonisolated enum RenamePathCaseSensitivity: String, Codable, Equatable, Sendable {
    case caseSensitive
    case caseInsensitive
}

/// A deterministic snapshot of path state used during planning. No filesystem access occurs in
/// the planner; production callers take this snapshot before planning and tests construct it.
nonisolated struct RenamePlanningEnvironment: Equatable, Sendable {
    var caseSensitivity: RenamePathCaseSensitivity
    var existingURLs: Set<URL>
    /// False when the caller can still render a deterministic preview but has not captured the
    /// destination directory's real collision state. Preflight must not treat an empty set as
    /// proof that no external conflicts exist.
    var isComplete: Bool

    init(
        caseSensitivity: RenamePathCaseSensitivity,
        existingURLs: Set<URL> = [],
        isComplete: Bool = true
    ) {
        self.caseSensitivity = caseSensitivity
        self.existingURLs = existingURLs
        self.isComplete = isComplete
    }
}

nonisolated struct RenamePlanningItem: Equatable, Sendable {
    let sourceImageURL: URL
    var context: BatchRenameContext
    /// Explicitly associated files that must move as part of the image bundle. Unlike registry
    /// rules, these carry a concrete source URL, so the planner never has to infer a voice-memo
    /// relationship from a filename during a destructive operation.
    var associatedArtifacts: [RenamePlanningAssociatedArtifact]

    init(
        sourceImageURL: URL,
        context: BatchRenameContext? = nil,
        associatedArtifacts: [RenamePlanningAssociatedArtifact] = []
    ) {
        self.sourceImageURL = sourceImageURL
        self.context = context ?? BatchRenameContext(originalFilename: sourceImageURL.lastPathComponent)
        self.associatedArtifacts = associatedArtifacts
    }
}

/// A relationship proven before rename planning. `filenamePattern` describes how the companion's
/// destination follows the accepted image name; its source is never reconstructed from that rule.
nonisolated struct RenamePlanningAssociatedArtifact: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String
    let sourceURL: URL
    let filenamePattern: RenameArtifactFilenamePattern

    init(
        identifier: String,
        displayName: String,
        sourceURL: URL,
        filenamePattern: RenameArtifactFilenamePattern
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.filenamePattern = filenamePattern
    }
}

nonisolated enum RenameCollisionPolicy: Codable, Equatable, Sendable {
    case block
    case skip
    case appendDeterministicSuffix(separator: String = " ", startAt: Int = 2, maximumAttempts: Int = 10_000)
}

nonisolated enum RenameArtifactRole: String, Codable, Equatable, Sendable {
    case image
    case associated
}

nonisolated enum RenameArtifactPresence: String, Codable, Equatable, Sendable {
    case always
    case whenSourceExists
}

nonisolated enum RenameArtifactFilenameBasis: String, Codable, Equatable, Sendable {
    case fullFilename
    case stem
}

nonisolated struct RenameArtifactFilenamePattern: Codable, Equatable, Sendable {
    var basis: RenameArtifactFilenameBasis
    var prefix: String
    var suffix: String

    init(
        basis: RenameArtifactFilenameBasis,
        prefix: String = "",
        suffix: String = ""
    ) {
        self.basis = basis
        self.prefix = prefix
        self.suffix = suffix
    }
}

/// A registry rule for an artifact whose filename follows the image filename or stem.
/// `relativeDirectoryComponents` are resolved below the image's containing directory.
nonisolated struct RenameArtifactRule: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String
    let role: RenameArtifactRole
    let relativeDirectoryComponents: [String]
    let filenamePattern: RenameArtifactFilenamePattern
    let presence: RenameArtifactPresence

    init(
        identifier: String,
        displayName: String,
        role: RenameArtifactRole = .associated,
        relativeDirectoryComponents: [String] = [],
        filenamePattern: RenameArtifactFilenamePattern,
        presence: RenameArtifactPresence = .whenSourceExists
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.role = role
        self.relativeDirectoryComponents = relativeDirectoryComponents
        self.filenamePattern = filenamePattern
        self.presence = presence
    }
}

nonisolated struct RenameArtifactRegistry: Codable, Equatable, Sendable {
    var rules: [RenameArtifactRule]

    init(rules: [RenameArtifactRule]) {
        self.rules = rules
    }

    /// Image plus every filename-derived artifact currently known to the application.
    static let standard = Self(rules: [
        RenameArtifactRule(
            identifier: "image",
            displayName: "Image",
            role: .image,
            filenamePattern: RenameArtifactFilenamePattern(basis: .fullFilename),
            presence: .always
        ),
        RenameArtifactRule(
            identifier: "xmp",
            displayName: "XMP sidecar",
            filenamePattern: RenameArtifactFilenamePattern(basis: .stem, suffix: ".xmp")
        ),
        RenameArtifactRule(
            identifier: "photo-metadata-current",
            displayName: "Photo metadata sidecar",
            relativeDirectoryComponents: [".photo_metadata"],
            filenamePattern: RenameArtifactFilenamePattern(
                basis: .fullFilename,
                suffix: ".meta.json"
            )
        ),
        RenameArtifactRule(
            identifier: "photo-metadata-legacy",
            displayName: "Legacy photo metadata sidecar",
            relativeDirectoryComponents: [".photo_metadata"],
            filenamePattern: RenameArtifactFilenamePattern(
                basis: .stem,
                suffix: ".meta.json"
            )
        ),
    ])

    /// Returns a new registry. Re-registering an identifier replaces it at the new position.
    func registering(_ rule: RenameArtifactRule) -> Self {
        Self(rules: rules.filter { $0.identifier != rule.identifier } + [rule])
    }
}

nonisolated struct RenameArtifactAction: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String
    let role: RenameArtifactRole
    let sourceURL: URL
    let destinationURL: URL
    /// Frozen value-level metadata work. Execution must not infer either the property or filename
    /// again after the user accepts a plan.
    let originalFilenameMetadataMutation: RenameOriginalFilenameMetadataMutation?

    init(
        identifier: String,
        displayName: String,
        role: RenameArtifactRole,
        sourceURL: URL,
        destinationURL: URL,
        originalFilenameMetadataMutation: RenameOriginalFilenameMetadataMutation? = nil
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.role = role
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.originalFilenameMetadataMutation = originalFilenameMetadataMutation
    }

    var changesPath: Bool {
        sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path
    }
}

nonisolated struct RenameOriginalFilenameMetadataMutation: Codable, Equatable, Sendable {
    enum Storage: String, Codable, Equatable, Sendable {
        case embeddedImageXMP
        case xmpSidecar
    }

    /// Adobe XMP Media Management. This is intentionally not IPTC IIM 2:103 /
    /// photoshop:TransmissionReference, whose interoperable meaning is Job ID.
    static let namespaceURI = "http://ns.adobe.com/xap/1.0/mm/"
    static let propertyName = "PreservedFileName"

    let storage: Storage
    let namespaceURI: String
    let propertyName: String
    let value: String

    init(storage: Storage, value: String) {
        self.storage = storage
        self.namespaceURI = Self.namespaceURI
        self.propertyName = Self.propertyName
        self.value = value
    }
}

nonisolated enum RenamePlanEntryDisposition: String, Codable, Equatable, Sendable {
    case rename
    case unchanged
    case skipped
    case blocked
}

nonisolated enum RenameMissingValueResolution: Codable, Equatable, Sendable {
    case empty
    case fallback(String)
    case preserveOriginal
    case skip
    case block
}

nonisolated enum RenameInvalidFilenameReason: String, Codable, Equatable, Sendable {
    case empty
    case dotPathComponent
    case forbiddenCharacter
    case trailingSpaceOrPeriod
    case exceedsFilesystemByteLimit
}

nonisolated struct RenamePlanIssue: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Equatable, Sendable {
        case warning
        case blocking
    }

    enum Code: Codable, Equatable, Sendable {
        case missingValue(
            componentIndex: Int,
            token: BatchRenameToken,
            resolution: RenameMissingValueResolution
        )
        case recipeProblem(BatchRenameEvaluation.Problem)
        case invalidFilename(RenameInvalidFilenameReason)
        case duplicateTarget(otherItemIndex: Int, otherArtifactIdentifier: String)
        case existingDestination(existingURL: URL)
        case caseInsensitiveCollision(existingURL: URL)
        case caseOnlyRename
        case deterministicSuffixApplied(attempt: Int, requestedName: String, resolvedName: String)
        case deterministicSuffixExhausted(maximumAttempts: Int)
        case originalFilenameXMPSidecarMissing
        case unrecognizedImageExtension
    }

    /// Stable, presentation-independent categories for grouping and filtering preview issues.
    enum Kind: String, Codable, Equatable, Sendable {
        case missingValue
        case recipeProblem
        case invalidFilename
        case duplicateTarget
        case existingDestination
        case caseInsensitiveCollision
        case caseOnlyRename
        case deterministicSuffixApplied
        case deterministicSuffixExhausted
        case originalFilenameXMPSidecarMissing
        case unrecognizedImageExtension
    }

    let severity: Severity
    let itemIndex: Int
    let artifactIdentifier: String?
    let url: URL?
    let code: Code

    var kind: Kind {
        switch code {
        case .missingValue: return .missingValue
        case .recipeProblem: return .recipeProblem
        case .invalidFilename: return .invalidFilename
        case .duplicateTarget: return .duplicateTarget
        case .existingDestination: return .existingDestination
        case .caseInsensitiveCollision: return .caseInsensitiveCollision
        case .caseOnlyRename: return .caseOnlyRename
        case .deterministicSuffixApplied: return .deterministicSuffixApplied
        case .deterministicSuffixExhausted: return .deterministicSuffixExhausted
        case .unrecognizedImageExtension: return .unrecognizedImageExtension
        case .originalFilenameXMPSidecarMissing: return .originalFilenameXMPSidecarMissing
        }
    }
}

/// One immutable preview row. The requested path is always the direct recipe result when one
/// exists. The planned path is non-nil only when that destination has been reserved in the plan.
nonisolated struct RenamePlanEntry: Codable, Equatable, Sendable {
    let itemIndex: Int
    let sourceImageURL: URL
    let requestedDestinationImageURL: URL?
    let plannedDestinationImageURL: URL?
    let disposition: RenamePlanEntryDisposition
    let recipeEvaluation: BatchRenameEvaluation
    let requestedArtifactActions: [RenameArtifactAction]
    let plannedArtifactActions: [RenameArtifactAction]
    let issues: [RenamePlanIssue]
}

nonisolated struct RenameArtifactSummary: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String
    let presentCount: Int
    let renamedCount: Int
    let unchangedCount: Int
}

nonisolated struct RenamePlan: Codable, Equatable, Sendable {
    let entries: [RenamePlanEntry]
    /// Every image and artifact destination accepted by the plan, in deterministic reservation
    /// order. Execution can reserve/stage this complete set before changing any source path.
    let reservedDestinationURLs: [URL]
    let issues: [RenamePlanIssue]
    let associatedArtifactSummary: [RenameArtifactSummary]

    var canExecute: Bool {
        !issues.contains { $0.severity == .blocking }
    }
}
