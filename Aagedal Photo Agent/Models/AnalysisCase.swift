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

    var errorDescription: String? {
        switch self {
        case .invalidSourceHash:
            "The analysis case does not contain a valid SHA-256 source hash."
        case .invalidTimestamps:
            "The analysis case update time is earlier than its creation time."
        }
    }
}

/// The persisted owner document for one image-analysis investigation.
///
/// Analyzer results, annotations, and report selections will be added as their Phase 2–6
/// slices land. Keeping navigation preferences here establishes one source-bound document
/// rather than separate Pixel Analysis and OSINT sessions.
nonisolated struct AnalysisCase: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    var title: String
    let source: SourceImageRevision
    let createdAt: Date
    var updatedAt: Date
    let createdByAppBuild: String
    var workspaceMode: AnalysisWorkspaceMode
    var displayPreference: AnalysisSourceRepresentation

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
            displayPreference: .original
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

    func validateForPersistence() throws {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard source.sha256.count == 64,
              source.sha256.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw AnalysisCaseValidationError.invalidSourceHash
        }
        guard updatedAt >= createdAt else {
            throw AnalysisCaseValidationError.invalidTimestamps
        }
    }

    private static var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
