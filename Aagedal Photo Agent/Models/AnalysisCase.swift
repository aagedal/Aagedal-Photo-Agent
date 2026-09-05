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
    case invalidAnnotations
    case invalidTimestampEvidence
    case invalidObservations
    case invalidMapState

    var errorDescription: String? {
        switch self {
        case .invalidSourceHash:
            "The analysis case does not contain a valid SHA-256 source hash."
        case .invalidTimestamps:
            "The analysis case or one of its annotations contains invalid update times."
        case .invalidAnalyzerRuns:
            "The analysis case contains duplicate or invalid analyzer runs."
        case .invalidAnnotations:
            "The analysis case contains duplicate or invalid photo annotations."
        case .invalidTimestampEvidence:
            "The analysis case contains duplicate or invalid user-entered timestamp evidence."
        case .invalidObservations:
            "The analysis case contains duplicate or invalid investigator observations."
        case .invalidMapState:
            "The analysis case contains an invalid map viewport, location, or annotation."
        }
    }
}

/// The persisted owner document for one image-analysis investigation.
///
/// Analyzer results and report selections share this owner with the workspace preferences.
/// Map state shares this source-bound document; report state will join it in a later slice rather
/// than creating separate Pixel Analysis and OSINT sessions.
nonisolated struct AnalysisCase: VersionedJSONDocument, Equatable, Sendable {
    static let currentSchemaVersion = 9

    let schemaVersion: Int
    let id: UUID
    var title: String
    private(set) var source: SourceImageRevision
    let createdAt: Date
    var updatedAt: Date
    let createdByAppBuild: String
    var workspaceMode: AnalysisWorkspaceMode
    var displayPreference: AnalysisSourceRepresentation
    var analyzerRuns: [AnalysisAnalyzerRun]
    var annotations: [AnalysisAnnotation]
    var timestampEvidence: [AnalysisTimestampEvidence]
    var observations: [AnalysisObservation]
    var mapState: AnalysisMapState

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
            analyzerRuns: [],
            annotations: [],
            timestampEvidence: [],
            observations: [],
            mapState: AnalysisMapState()
        )
    }

    /// Refreshes only the non-authoritative path hint after a verified project import.
    /// This is not an evidence edit, so case timestamps and analyzer results stay unchanged.
    mutating func relocateSource(to url: URL) {
        source = source.relocated(to: url)
    }

    mutating func relocateSource(toPreparedCanonicalURL url: URL) {
        source = source.relocated(toPreparedCanonicalURL: url)
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

    mutating func setAnnotation(_ annotation: AnalysisAnnotation, now: Date = Date()) {
        var updatedAnnotation = annotation
        updatedAnnotation.markUpdated(now: now)
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = updatedAnnotation
        } else {
            annotations.append(updatedAnnotation)
        }
        updatedAt = max(max(now, createdAt), updatedAnnotation.updatedAt)
    }

    @discardableResult
    mutating func removeAnnotation(id: UUID, now: Date = Date()) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            return false
        }
        annotations.remove(at: index)
        updatedAt = max(now, createdAt)
        return true
    }

    mutating func replaceAnnotations(
        _ replacements: [AnalysisAnnotation],
        now: Date = Date()
    ) {
        annotations = replacements
        updatedAt = max(
            max(now, createdAt),
            replacements.map(\.updatedAt).max() ?? createdAt
        )
    }

    mutating func setTimestampEvidence(
        _ evidence: AnalysisTimestampEvidence,
        now: Date = Date()
    ) {
        var updatedEvidence = evidence
        updatedEvidence.markUpdated(now: now)
        if let index = timestampEvidence.firstIndex(where: { $0.id == evidence.id }) {
            timestampEvidence[index] = updatedEvidence
        } else {
            timestampEvidence.append(updatedEvidence)
        }
        updatedAt = max(max(now, createdAt), updatedEvidence.updatedAt)
    }

    mutating func setObservation(_ observation: AnalysisObservation, now: Date = Date()) {
        var updatedObservation = observation
        updatedObservation.markUpdated(now: now)
        if let index = observations.firstIndex(where: { $0.id == observation.id }) {
            observations[index] = updatedObservation
        } else {
            observations.append(updatedObservation)
        }
        updatedAt = max(max(now, createdAt), updatedObservation.updatedAt)
    }

    @discardableResult
    mutating func removeObservation(id: UUID, now: Date = Date()) -> Bool {
        guard let index = observations.firstIndex(where: { $0.id == id }) else { return false }
        observations.remove(at: index)
        updatedAt = max(now, createdAt)
        return true
    }

    @discardableResult
    mutating func removeTimestampEvidence(id: UUID, now: Date = Date()) -> Bool {
        guard let index = timestampEvidence.firstIndex(where: { $0.id == id }) else {
            return false
        }
        timestampEvidence.remove(at: index)
        updatedAt = max(now, createdAt)
        return true
    }

    mutating func setMapStyle(_ style: AnalysisMapStyle, now: Date = Date()) {
        mapState.style = style
        updatedAt = max(now, createdAt)
    }

    mutating func setMapTrafficVisible(_ isVisible: Bool, now: Date = Date()) {
        mapState.showsTraffic = isVisible
        updatedAt = max(now, createdAt)
    }

    mutating func setMap3DContentVisible(_ isVisible: Bool, now: Date = Date()) {
        mapState.shows3DContent = isVisible
        updatedAt = max(now, createdAt)
    }

    mutating func setMapViewport(_ viewport: AnalysisMapViewport, now: Date = Date()) {
        mapState.viewport = viewport
        updatedAt = max(now, createdAt)
    }

    mutating func setInvestigationLocation(
        _ location: AnalysisLocationEvidence?,
        now: Date = Date()
    ) {
        var updatedLocation = location
        updatedLocation?.markUpdated(now: now)
        mapState.investigationLocation = updatedLocation
        updatedAt = max(max(now, createdAt), updatedLocation?.updatedAt ?? createdAt)
    }

    mutating func setSolarOverlay(
        _ overlay: AnalysisSolarOverlayState,
        now: Date = Date()
    ) {
        mapState.solarOverlay = overlay
        updatedAt = max(now, createdAt)
    }

    @discardableResult
    mutating func clearSolarOverlay(now: Date = Date()) -> Bool {
        guard mapState.solarOverlay != nil else { return false }
        mapState.solarOverlay = nil
        updatedAt = max(now, createdAt)
        return true
    }

    mutating func setMapAnnotation(
        _ annotation: AnalysisMapAnnotation,
        now: Date = Date()
    ) {
        var updatedAnnotation = annotation
        updatedAnnotation.markUpdated(now: now)
        if let index = mapState.annotations.firstIndex(where: { $0.id == annotation.id }) {
            mapState.annotations[index] = updatedAnnotation
        } else {
            mapState.annotations.append(updatedAnnotation)
        }
        updatedAt = max(max(now, createdAt), updatedAnnotation.updatedAt)
    }

    @discardableResult
    mutating func removeMapAnnotation(id: UUID, now: Date = Date()) -> Bool {
        guard let index = mapState.annotations.firstIndex(where: { $0.id == id }) else {
            return false
        }
        mapState.annotations.remove(at: index)
        updatedAt = max(now, createdAt)
        return true
    }

    mutating func replaceMapAnnotations(
        _ replacements: [AnalysisMapAnnotation],
        now: Date = Date()
    ) {
        mapState.annotations = replacements
        updatedAt = max(
            max(now, createdAt),
            replacements.map(\.updatedAt).max() ?? createdAt
        )
    }

    static func decodeVersion(
        from data: Data,
        schemaVersion: Int,
        using decoder: JSONDecoder
    ) throws -> AnalysisCase {
        switch schemaVersion {
        case currentSchemaVersion:
            return try decoder.decode(AnalysisCase.self, from: data)
        case 8:
            let legacy = try decoder.decode(LegacyAnalysisCaseV8.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: legacy.timestampEvidence,
                observations: legacy.observations,
                mapState: AnalysisMapState(
                    style: legacy.mapState.style,
                    showsTraffic: legacy.mapState.showsTraffic,
                    shows3DContent: legacy.mapState.shows3DContent,
                    viewport: legacy.mapState.viewport,
                    investigationLocation: legacy.mapState.investigationLocation,
                    annotations: legacy.mapState.annotations,
                    solarOverlay: nil
                )
            )
        case 7:
            let legacy = try decoder.decode(LegacyAnalysisCaseV7.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: legacy.timestampEvidence,
                observations: [],
                mapState: legacy.mapState
            )
        case 6:
            let legacy = try decoder.decode(LegacyAnalysisCaseV6.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: legacy.timestampEvidence,
                observations: [],
                mapState: legacy.mapState
            )
        case 5:
            let legacy = try decoder.decode(LegacyAnalysisCaseV5.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: legacy.timestampEvidence,
                observations: [],
                mapState: AnalysisMapState()
            )
        case 4:
            let legacy = try decoder.decode(LegacyAnalysisCaseV4.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: [],
                observations: [],
                mapState: AnalysisMapState()
            )
        case 3:
            let legacy = try decoder.decode(LegacyAnalysisCaseV3.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: legacy.annotations,
                timestampEvidence: [],
                observations: [],
                mapState: AnalysisMapState()
            )
        case 2:
            let legacy = try decoder.decode(LegacyAnalysisCaseV2.self, from: data)
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
                analyzerRuns: legacy.analyzerRuns,
                annotations: [],
                timestampEvidence: [],
                observations: [],
                mapState: AnalysisMapState()
            )
        case 1:
            let legacy = try decoder.decode(LegacyAnalysisCaseV1.self, from: data)
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
                analyzerRuns: [],
                annotations: [],
                timestampEvidence: [],
                observations: [],
                mapState: AnalysisMapState()
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
        guard updatedAt >= createdAt,
              annotations.allSatisfy({ $0.updatedAt <= updatedAt }) else {
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
        guard Set(annotations.map(\.id)).count == annotations.count,
              annotations.filter({ $0.measurementCalibration != nil }).count <= 1,
              annotations.allSatisfy({ (try? $0.validate()) != nil }) else {
            throw AnalysisCaseValidationError.invalidAnnotations
        }
        guard Set(timestampEvidence.map(\.id)).count == timestampEvidence.count,
              timestampEvidence.allSatisfy({ $0.source == .userEntered && $0.validate() }),
              timestampEvidence.allSatisfy({ $0.updatedAt <= updatedAt }) else {
            throw AnalysisCaseValidationError.invalidTimestampEvidence
        }
        guard Set(observations.map(\.id)).count == observations.count,
              observations.allSatisfy({ $0.validate() && $0.updatedAt <= updatedAt }) else {
            throw AnalysisCaseValidationError.invalidObservations
        }
        guard mapState.validate(),
              mapState.investigationLocation.map({ $0.updatedAt <= updatedAt }) ?? true,
              mapState.annotations.allSatisfy({ $0.updatedAt <= updatedAt }) else {
            throw AnalysisCaseValidationError.invalidMapState
        }
    }

    private static var currentAppBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

nonisolated private struct LegacyAnalysisCaseV8: Codable {
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
    var annotations: [AnalysisAnnotation]
    var timestampEvidence: [AnalysisTimestampEvidence]
    var observations: [AnalysisObservation]
    var mapState: LegacyAnalysisMapStateV8
}

nonisolated private struct LegacyAnalysisMapStateV8: Codable {
    var style: AnalysisMapStyle
    var showsTraffic: Bool
    var shows3DContent: Bool
    var viewport: AnalysisMapViewport?
    var investigationLocation: AnalysisLocationEvidence?
    var annotations: [AnalysisMapAnnotation]
}

nonisolated private struct LegacyAnalysisCaseV7: Codable {
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
    var annotations: [AnalysisAnnotation]
    var timestampEvidence: [AnalysisTimestampEvidence]
    var mapState: AnalysisMapState
}

nonisolated private struct LegacyAnalysisCaseV6: Codable {
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
    var annotations: [AnalysisAnnotation]
    var timestampEvidence: [AnalysisTimestampEvidence]
    var mapState: AnalysisMapState
}

nonisolated private struct LegacyAnalysisCaseV5: Codable {
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
    var annotations: [AnalysisAnnotation]
    var timestampEvidence: [AnalysisTimestampEvidence]
}

nonisolated private struct LegacyAnalysisCaseV4: Codable {
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
    var annotations: [AnalysisAnnotation]
}

nonisolated private struct LegacyAnalysisCaseV3: Codable {
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
    var annotations: [AnalysisAnnotation]
}

nonisolated private struct LegacyAnalysisCaseV1: Codable {
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

nonisolated private struct LegacyAnalysisCaseV2: Codable {
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
}
