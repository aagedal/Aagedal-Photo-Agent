import Foundation

/// Persisted settings for Photo Mechanic-style code replacement.
///
/// The source reference contains only identity and resolution metadata. Security-scoped bookmark
/// bytes, credentials, and file contents belong in a separate secure store owned by the caller.
nonisolated struct CodeReplacementConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var isEnabled: Bool
    var startDelimiter: String
    var endDelimiter: String
    var source: CodeReplacementSourceReference?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        isEnabled: Bool = true,
        startDelimiter: String = "\\",
        endDelimiter: String = "\\",
        source: CodeReplacementSourceReference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.startDelimiter = startDelimiter
        self.endDelimiter = endDelimiter
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case startDelimiter
        case endDelimiter
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported code-replacement configuration schema version \(version)"
            )
        }

        schemaVersion = version
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        startDelimiter = try container.decode(String.self, forKey: .startDelimiter)
        endDelimiter = try container.decode(String.self, forKey: .endDelimiter)
        source = try container.decodeIfPresent(CodeReplacementSourceReference.self, forKey: .source)
    }
}

/// A stable reference to a code-replacement source, without embedding its contents or bookmark.
nonisolated struct CodeReplacementSourceReference: Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    /// A user-visible or last-known filesystem path. The pure engine never opens it.
    var path: String?
    /// Metadata that lets an external bookmark store resolve the opaque bookmark by identifier.
    var bookmark: CodeReplacementBookmarkReference?
    var fingerprint: CodeReplacementSourceFingerprint?

    init(
        id: UUID = UUID(),
        displayName: String,
        path: String? = nil,
        bookmark: CodeReplacementBookmarkReference? = nil,
        fingerprint: CodeReplacementSourceFingerprint? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmark = bookmark
        self.fingerprint = fingerprint
    }
}

/// Non-secret metadata about an externally stored security-scoped bookmark.
nonisolated struct CodeReplacementBookmarkReference: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date?
    var lastResolvedAt: Date?
    var wasStaleWhenLastResolved: Bool

    init(
        id: UUID,
        createdAt: Date? = nil,
        lastResolvedAt: Date? = nil,
        wasStaleWhenLastResolved: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastResolvedAt = lastResolvedAt
        self.wasStaleWhenLastResolved = wasStaleWhenLastResolved
    }
}

nonisolated struct CodeReplacementSourceFingerprint: Codable, Equatable, Sendable {
    var byteCount: Int64?
    var modificationDate: Date?

    init(byteCount: Int64? = nil, modificationDate: Date? = nil) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
    }
}

nonisolated struct CodeReplacementEntry: Equatable, Sendable {
    var code: String
    var replacement: String
    var sourceLine: Int
}

nonisolated enum CodeReplacementDiagnosticSeverity: String, Equatable, Sendable {
    case warning
    case error
}

nonisolated enum CodeReplacementDiagnosticKind: Equatable, Sendable {
    case invalidUTF8
    case malformedRow(columnCount: Int)
    case emptyCode
    case emptyValue(code: String)
    case duplicateCode(code: String, originalLine: Int)
    case ambiguousCode(code: String, originalLine: Int)
}

nonisolated struct CodeReplacementDiagnostic: Equatable, Sendable {
    var severity: CodeReplacementDiagnosticSeverity
    var kind: CodeReplacementDiagnosticKind
    /// One-based source line, or nil when the source could not be decoded.
    var line: Int?
}

/// Parsed source data. Only unique or same-value duplicate definitions become usable entries.
/// Conflicting definitions are retained in ``ambiguousCodes`` and are never expanded.
nonisolated struct CodeReplacementList: Equatable, Sendable {
    var source: CodeReplacementSourceReference?
    var entries: [CodeReplacementEntry]
    var ambiguousCodes: [String: [Int]]
    var diagnostics: [CodeReplacementDiagnostic]

    init(
        source: CodeReplacementSourceReference? = nil,
        entries: [CodeReplacementEntry] = [],
        ambiguousCodes: [String: [Int]] = [:],
        diagnostics: [CodeReplacementDiagnostic] = []
    ) {
        self.source = source
        self.entries = entries
        self.ambiguousCodes = ambiguousCodes
        self.diagnostics = diagnostics
    }

    var hasInvalidEncoding: Bool {
        diagnostics.contains { $0.kind == .invalidUTF8 }
    }
}

/// The editor reports composition state rather than exposing AppKit marked-text objects to the
/// pure replacement engine.
nonisolated enum CodeReplacementCompositionState: String, Equatable, Sendable {
    case committed
    case active
}

nonisolated enum CodeReplacementPreviewDisposition: String, Equatable, Sendable {
    case applied
    case unchanged
    case disabled
    case refusedActiveComposition
    case invalidConfiguration
    case invalidSourceEncoding
}

nonisolated struct CodeReplacementOccurrence: Equatable, Sendable {
    var code: String
    var replacement: String
    /// Half-open Character offsets in the original text, suitable for a deterministic preview.
    var sourceRange: Range<Int>
}

nonisolated enum CodeReplacementUnresolvedReason: String, Equatable, Sendable {
    case ambiguousCode
    case codeContainsDelimiter
}

nonisolated struct CodeReplacementUnresolvedOccurrence: Equatable, Sendable {
    var code: String
    var sourceRange: Range<Int>
    var reason: CodeReplacementUnresolvedReason
}

nonisolated struct CodeReplacementPreview: Equatable, Sendable {
    var originalText: String
    var proposedText: String
    var disposition: CodeReplacementPreviewDisposition
    var replacements: [CodeReplacementOccurrence]
    var unresolvedOccurrences: [CodeReplacementUnresolvedOccurrence]
    var sourceDiagnostics: [CodeReplacementDiagnostic]

    var changed: Bool { originalText != proposedText }
}
