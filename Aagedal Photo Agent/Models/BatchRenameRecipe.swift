import Foundation

/// A persisted, reusable description of how one filename is produced.
///
/// Recipes contain no filesystem or UI state. Callers supply a ``BatchRenameContext`` for each
/// file and may therefore use the same recipe during browser rename, import, or export.
nonisolated struct BatchRenameRecipe: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var name: String
    var components: [BatchRenameComponent]
    var substitutions: [BatchRenameSubstitution]
    var caseConversion: BatchRenameCaseConversion
    var whitespace: BatchRenameWhitespaceRule
    var sanitization: BatchRenameSanitization
    var missingValuePolicy: BatchRenameMissingValuePolicy
    var unicodeNormalization: BatchRenameUnicodeNormalization
    /// Explicitly opts a rename into preserving the pre-rename filename in interoperable XMP.
    /// Existing recipes decode to `doNotWrite`, so importing a legacy preset never starts a new
    /// metadata mutation implicitly.
    var originalFilenameMetadata: BatchRenameOriginalFilenameMetadataPolicy
    /// An IANA timezone identifier used for every date token. UTC makes a recipe portable by
    /// default, while callers can explicitly choose a newsroom-local timezone when appropriate.
    var timeZoneIdentifier: String

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        name: String,
        components: [BatchRenameComponent],
        substitutions: [BatchRenameSubstitution] = [],
        caseConversion: BatchRenameCaseConversion = .unchanged,
        whitespace: BatchRenameWhitespaceRule = .preserve,
        sanitization: BatchRenameSanitization = .filesystemSafe(),
        missingValuePolicy: BatchRenameMissingValuePolicy = .block,
        unicodeNormalization: BatchRenameUnicodeNormalization = .canonicalComposed,
        originalFilenameMetadata: BatchRenameOriginalFilenameMetadataPolicy = .doNotWrite,
        timeZoneIdentifier: String = "UTC"
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.components = components
        self.substitutions = substitutions
        self.caseConversion = caseConversion
        self.whitespace = whitespace
        self.sanitization = sanitization
        self.missingValuePolicy = missingValuePolicy
        self.unicodeNormalization = unicodeNormalization
        self.originalFilenameMetadata = originalFilenameMetadata
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case name
        case components
        case substitutions
        case caseConversion
        case whitespace
        case sanitization
        case missingValuePolicy
        case unicodeNormalization
        case originalFilenameMetadata
        case timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported batch rename recipe schema version \(version)"
            )
        }

        schemaVersion = version
        name = try container.decode(String.self, forKey: .name)
        components = try container.decode([BatchRenameComponent].self, forKey: .components)
        substitutions = try container.decodeIfPresent(
            [BatchRenameSubstitution].self,
            forKey: .substitutions
        ) ?? []
        caseConversion = try container.decodeIfPresent(
            BatchRenameCaseConversion.self,
            forKey: .caseConversion
        ) ?? .unchanged
        whitespace = try container.decodeIfPresent(
            BatchRenameWhitespaceRule.self,
            forKey: .whitespace
        ) ?? .preserve
        sanitization = try container.decodeIfPresent(
            BatchRenameSanitization.self,
            forKey: .sanitization
        ) ?? .filesystemSafe()
        missingValuePolicy = try container.decodeIfPresent(
            BatchRenameMissingValuePolicy.self,
            forKey: .missingValuePolicy
        ) ?? .block
        unicodeNormalization = try container.decodeIfPresent(
            BatchRenameUnicodeNormalization.self,
            forKey: .unicodeNormalization
        ) ?? .canonicalComposed
        originalFilenameMetadata = try container.decodeIfPresent(
            BatchRenameOriginalFilenameMetadataPolicy.self,
            forKey: .originalFilenameMetadata
        ) ?? .doNotWrite
        timeZoneIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .timeZoneIdentifier
        ) ?? "UTC"
    }
}

nonisolated enum BatchRenameOriginalFilenameMetadataPolicy: String, Codable, Equatable, Sendable {
    case doNotWrite
    case preserveInXMP
}

nonisolated enum BatchRenameComponent: Codable, Equatable, Sendable {
    case literal(String)
    case token(BatchRenameToken)
}

nonisolated enum BatchRenameToken: Codable, Equatable, Sendable {
    /// Original filename including its extension.
    case originalFilename
    /// Original filename without its final extension.
    case originalStem
    /// Final extension without a leading period.
    case originalExtension
    case sequence(BatchRenameSequence)
    case date(BatchRenameDateToken)
    case metadata(BatchRenameMetadataField)
    /// Workflow-level job title, distinct from IPTC Creator Job Title.
    case jobTitle
    /// Title assigned to the current import session.
    case importTitle
}

nonisolated struct BatchRenameSequence: Codable, Equatable, Sendable {
    var start: Int
    var step: Int
    var padding: Int

    init(start: Int = 1, step: Int = 1, padding: Int = 0) {
        self.start = start
        self.step = step
        self.padding = max(0, padding)
    }
}

nonisolated struct BatchRenameDateToken: Codable, Equatable, Sendable {
    var source: BatchRenameDateSource
    var format: String

    init(source: BatchRenameDateSource, format: String = "yyyyMMdd") {
        self.source = source
        self.format = format
    }
}

nonisolated enum BatchRenameDateSource: Codable, Equatable, Sendable {
    /// Capture time, optionally falling back to one of the stable file dates supplied by the
    /// caller. A missing fallback remains a missing token and follows the recipe policy.
    case capture(fallback: BatchRenameCaptureDateFallback = .none)
    case fileCreation
    case fileModification
}

nonisolated enum BatchRenameCaptureDateFallback: String, Codable, Equatable, Sendable {
    case none
    case fileCreation
    case fileModification
}

/// Typed names prevent caption-template spelling aliases from leaking into persisted recipes.
nonisolated enum BatchRenameMetadataField: String, Codable, CaseIterable, Equatable, Sendable {
    case title
    case creator
    case creatorJobTitle
    case jobID
    case event
    case city
    case country
    case countryCode
    case cameraMake
    case cameraModel
    case cameraSerial
    case rating
    case colorLabel
}

/// Substitutions run in array order after component interpolation and before text transforms.
nonisolated enum BatchRenameSubstitution: Codable, Equatable, Sendable {
    case literal(find: String, replacement: String, caseSensitive: Bool = true)
    case regularExpression(
        pattern: String,
        replacement: String,
        caseInsensitive: Bool = false,
        anchorsMatchLines: Bool = false
    )
}

nonisolated enum BatchRenameCaseConversion: String, Codable, Equatable, Sendable {
    case unchanged
    case lowercase
    case uppercase
    case titleCase
}

nonisolated enum BatchRenameWhitespaceRule: Codable, Equatable, Sendable {
    case preserve
    case replace(with: String, collapseRuns: Bool = true)
}

nonisolated struct BatchRenameSanitization: Codable, Equatable, Sendable {
    var enabled: Bool
    var replacement: String
    var collapseReplacementRuns: Bool
    var allowHiddenFiles: Bool
    var emptyFilenameFallback: String

    init(
        enabled: Bool,
        replacement: String = "_",
        collapseReplacementRuns: Bool = true,
        allowHiddenFiles: Bool = false,
        emptyFilenameFallback: String = "untitled"
    ) {
        self.enabled = enabled
        self.replacement = replacement
        self.collapseReplacementRuns = collapseReplacementRuns
        self.allowHiddenFiles = allowHiddenFiles
        self.emptyFilenameFallback = emptyFilenameFallback
    }

    static func filesystemSafe(
        replacement: String = "_",
        collapseReplacementRuns: Bool = true,
        allowHiddenFiles: Bool = false,
        emptyFilenameFallback: String = "untitled"
    ) -> Self {
        Self(
            enabled: true,
            replacement: replacement,
            collapseReplacementRuns: collapseReplacementRuns,
            allowHiddenFiles: allowHiddenFiles,
            emptyFilenameFallback: emptyFilenameFallback
        )
    }

    static let disabled = Self(enabled: false)
}

nonisolated enum BatchRenameMissingValuePolicy: Codable, Equatable, Sendable {
    case empty
    case fallback(String)
    case preserveOriginal
    case skip
    case block
}

nonisolated enum BatchRenameUnicodeNormalization: String, Codable, Equatable, Sendable {
    case none
    case canonicalComposed
    case canonicalDecomposed
    case compatibilityComposed
    case compatibilityDecomposed
}

/// Pure input values for one recipe evaluation. Services translate their own richer models into
/// this context, keeping the recipe engine independent from caption templates and filesystem APIs.
nonisolated struct BatchRenameContext: Equatable, Sendable {
    var originalFilename: String
    var sequenceIndex: Int
    var captureDate: Date?
    var fileCreationDate: Date?
    var fileModificationDate: Date?
    var metadata: [BatchRenameMetadataField: String]
    var jobTitle: String?
    var importTitle: String?

    init(
        originalFilename: String,
        sequenceIndex: Int = 0,
        captureDate: Date? = nil,
        fileCreationDate: Date? = nil,
        fileModificationDate: Date? = nil,
        metadata: [BatchRenameMetadataField: String] = [:],
        jobTitle: String? = nil,
        importTitle: String? = nil
    ) {
        self.originalFilename = originalFilename
        self.sequenceIndex = sequenceIndex
        self.captureDate = captureDate
        self.fileCreationDate = fileCreationDate
        self.fileModificationDate = fileModificationDate
        self.metadata = metadata
        self.jobTitle = jobTitle
        self.importTitle = importTitle
    }
}

nonisolated struct BatchRenameMissingValue: Codable, Equatable, Sendable {
    let componentIndex: Int
    let token: BatchRenameToken
}

nonisolated struct BatchRenameEvaluation: Codable, Equatable, Sendable {
    enum Disposition: Codable, Equatable, Sendable {
        case rename
        case preserveOriginal
        case skip
        case block
    }

    enum Problem: Codable, Equatable, Sendable {
        case invalidRegularExpression(stageIndex: Int, pattern: String)
    }

    let disposition: Disposition
    let proposedFilename: String?
    let missingValues: [BatchRenameMissingValue]
    let problems: [Problem]
}
