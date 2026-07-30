import Foundation

enum AnalysisWorkspaceMode: String, Codable, CaseIterable, Sendable {
    case pixelAnalysis
    case osint

    var displayName: String {
        switch self {
        case .pixelAnalysis: "Pixel Analysis"
        case .osint: "OSINT"
        }
    }
}

enum AnalysisSourceRepresentation: String, Codable, CaseIterable, Sendable {
    case original
    case developed

    var displayName: String {
        switch self {
        case .original: "Original Source"
        case .developed: "Developed Preview"
        }
    }
}

enum AnalysisCaseValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSourceHash
    case invalidTimestamps
    case invalidAnalyzerRuns

    var errorDescription: String? {
        switch self {
        case .invalidSourceHash:
            "The analysis case does not contain a valid SHA-256 source hash."
        case .invalidTimestamps:
            "The analysis case update time is earlier than its creation time."
        case .invalidAnalyzerRuns:
            "The analysis case contains duplicate or invalid analyzer runs."
        }
    }
}

/// The persisted owner document for one image-analysis investigation.
///
/// Analyzer results and report selections share this owner with the workspace preferences.
/// Annotations and map/report state will join the same source-bound document in later slices,
/// rather than creating separate Pixel Analysis and OSINT sessions.
nonisolated struct AnalysisCase: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let id: UUID
    var title: String
    let source: SourceImageRevision
    let createdAt: Date
    var updatedAt: Date
    let createdByAppBuild: String
    var workspaceMode: AnalysisWorkspaceMode
    var displayPreference: AnalysisSourceRepresentation
    var analyzerRuns: [AnalysisAnalyzerRun]

    static func create(
        for source: SourceImageRevision,
        appBuild: String = AnalysisCase.currentAppBuild,
        now: Date = Date()
    ) -> AnalysisCase {
        AnalysisCase(
            schemaVersion: currentSchemaVersion,
            id: UUID(),
            title: source.filenameAtCreation,
            source: source,
            createdAt: now,
            updatedAt: now,
            createdByAppBuild: appBuild,
            workspaceMode: .pixelAnalysis,
            displayPreference: .original,
            analyzerRuns: []
        )
    }

    mutating func setWorkspaceMode(_ mode: AnalysisWorkspaceMode, now: Date = Date()) {
        workspaceMode = mode
        updatedAt = max(now, createdAt)
    }

    mutating func setDisplayPreference(
        _ representation: AnalysisSourceRepresentation,
        now: Date = Date()
    ) {
        displayPreference = representation
        updatedAt = max(now, createdAt)
    }

    mutating func setAnalyzerRun(_ run: AnalysisAnalyzerRun, now: Date = Date()) {
        if let index = analyzerRuns.firstIndex(where: { $0.analyzerID == run.analyzerID }) {
            analyzerRuns[index] = run
        } else {
            analyzerRuns.append(run)
        }
        updatedAt = max(now, createdAt)
    }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> AnalysisCase {
        switch schemaVersion {
        case currentSchemaVersion:
            return try decoder.decode(AnalysisCase.self, from: data)
        case 1:
            let legacy = try decoder.decode(LegacyAnalysisCase.self, from: data)
            return AnalysisCase(
                schemaVersion: currentSchemaVersion,
                id: legacy.id,
                title: legacy.title,
                source: legacy.source,
                createdAt: legacy.createdAt,
                updatedAt: legacy.updatedAt,
                createdByAppBuild: legacy.createdByAppBuild,
                workspaceMode: legacy.workspaceMode,
                displayPreference: legacy.displayPreference,
                analyzerRuns: []
            )
        default:
            throw AtomicJSONDocumentStoreError.unsupportedOlderSchema(
                found: schemaVersion,
                supported: currentSchemaVersion
            )
        }
    }

    func validateForPersistence() throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard source.sha256.count == 64,
              source.sha256.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw AnalysisCaseValidationError.invalidSourceHash
        }
        guard updatedAt >= createdAt else {
            throw AnalysisCaseValidationError.invalidTimestamps
        }
        guard Set(analyzerRuns.map(\.analyzerID)).count == analyzerRuns.count,
              analyzerRuns.allSatisfy({
                  !$0.analyzerID.isEmpty
                      && $0.analyzerVersion > 0
                      && !$0.cacheKey.isEmpty
                      && (0...1).contains($0.progress)
              }) else {
            throw AnalysisCaseValidationError.invalidAnalyzerRuns
        }
    }

    private static var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

nonisolated private struct LegacyAnalysisCase: Codable {
    let schemaVersion: Int
    let id: UUID
    var title: String
    let source: SourceImageRevision
    let createdAt: Date
    var updatedAt: Date
    let createdByAppBuild: String
    var workspaceMode: AnalysisWorkspaceMode
    var displayPreference: AnalysisSourceRepresentation
}
