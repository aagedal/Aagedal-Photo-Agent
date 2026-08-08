import CoreGraphics
import Foundation

nonisolated enum AnalysisReportSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case invalidCase
    case sourceRevisionChanged

    var errorDescription: String? {
        switch self {
        case .invalidCase:
            "The analysis case is not valid and cannot be frozen for a report."
        case .sourceRevisionChanged:
            "The source bytes no longer match the revision used by this analysis case."
        }
    }
}

/// The map content policy applied when an immutable report snapshot is created.
///
/// Apple map tiles and imagery remain live MapKit content. The report freezes geographic evidence
/// in WGS 84 and renders it over an app-generated schematic instead of persisting or redistributing
/// MapKit content. A Maps URL lets the reader reopen the captured viewport in the live service.
nonisolated enum AnalysisReportMapRendering: String, Codable, Sendable {
    case schematicWGS84
}

nonisolated struct AnalysisReportMapEvidence: Codable, Equatable, Sendable {
    static let coordinateReferenceSystem = "WGS 84 (EPSG:4326)"
    static let imageryDisclosure =
        "Schematic map generated from case coordinates. No Apple Maps tiles or imagery are embedded."

    let rendering: AnalysisReportMapRendering
    let viewport: AnalysisMapViewport
    let liveMapStyle: AnalysisMapStyle
    let investigationLocation: AnalysisLocationEvidence?
    let visibleAnnotations: [AnalysisMapAnnotation]
    let liveMapReference: URL
    let coordinateSystem: String
    let disclosure: String
    let capturedAt: Date

    init?(
        state: AnalysisMapState,
        capturedAt: Date
    ) {
        guard let viewport = state.viewport, viewport.isValid else { return nil }
        self.rendering = .schematicWGS84
        self.viewport = viewport
        self.liveMapStyle = state.style
        self.investigationLocation = state.investigationLocation
        self.visibleAnnotations = state.annotations
            .filter(\.isVisible)
        self.liveMapReference = Self.makeLiveMapReference(
            viewport: viewport,
            style: state.style
        )
        self.coordinateSystem = Self.coordinateReferenceSystem
        self.disclosure = Self.imageryDisclosure
        self.capturedAt = capturedAt
    }

    private static func makeLiveMapReference(
        viewport: AnalysisMapViewport,
        style: AnalysisMapStyle
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "ll", value: coordinatePair(
                viewport.center.latitude,
                viewport.center.longitude
            )),
            URLQueryItem(name: "spn", value: coordinatePair(
                viewport.latitudeDelta,
                viewport.longitudeDelta
            )),
            URLQueryItem(name: "t", value: mapTypeQueryValue(for: style)),
        ]
        // Every input has already passed finite/range validation, and these components are fixed.
        return components.url!
    }

    private static func coordinatePair(_ first: Double, _ second: Double) -> String {
        String(
            format: "%.8f,%.8f",
            locale: Locale(identifier: "en_US_POSIX"),
            first,
            second
        )
    }

    private static func mapTypeQueryValue(for style: AnalysisMapStyle) -> String {
        switch style {
        case .standard, .muted: "m"
        case .hybrid: "h"
        case .satellite: "k"
        case .openStreetMap: "m"
        }
    }
}

/// Analyzer execution metadata without a second, unfiltered copy of its findings.
nonisolated struct AnalysisReportAnalyzerRun: Codable, Equatable, Sendable {
    let analyzerID: String
    let analyzerVersion: Int
    let cacheKey: String
    let sourceRepresentation: AnalysisInputRepresentation
    let status: AnalysisAnalyzerRunStatus
    let startedAt: Date?
    let completedAt: Date?
    let errorMessage: String?

    init(run: AnalysisAnalyzerRun) {
        analyzerID = run.analyzerID
        analyzerVersion = run.analyzerVersion
        cacheKey = run.cacheKey
        sourceRepresentation = run.sourceRepresentation
        status = run.status
        startedAt = run.startedAt
        completedAt = run.completedAt
        errorMessage = run.errorMessage
    }
}

/// Integer pixel bounds captured for a report figure.
///
/// Coordinates use a top-left origin. Keeping the rounded bounds in the snapshot makes the crop
/// reproducible and prevents the renderer from making a different floating-point rounding choice.
nonisolated struct AnalysisReportPixelRect: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// One investigator-selected crop of the original, upright source representation.
///
/// The crop is extracted at one decoded source pixel per crop pixel. Report layout may visually
/// scale the embedded raster to fit the paper, but the extraction itself never interpolates.
nonisolated struct AnalysisReportEvidenceCrop: Codable, Equatable, Sendable {
    static let scaleLabel = "1:1 source-pixel extraction"
    static let interpolationLabel = "No interpolation"

    let displayPixelRect: AnalysisReportPixelRect
    let sourcePixelRect: AnalysisReportPixelRect
    let displayedSourceWidth: Int
    let displayedSourceHeight: Int
    let scaleLabel: String
    let interpolationLabel: String

    init?(originalDisplayNormalizedRect: CGRect, source: SourceImageRevision) {
        guard let sourceWidth = source.pixelWidth,
              let sourceHeight = source.pixelHeight,
              let transform = try? DisplayImageTransform(
                  sourcePixelWidth: sourceWidth,
                  sourcePixelHeight: sourceHeight,
                  exifOrientation: source.exifOrientation
              ) else {
            return nil
        }

        let displayedSize = transform.fullDisplayedPixelSize
        guard let displayedBounds = AnalysisScopeSelection.pixelRect(
            for: originalDisplayNormalizedRect,
            imageWidth: Int(displayedSize.width),
            imageHeight: Int(displayedSize.height)
        ) else {
            return nil
        }
        let normalizedDisplayedBounds = CGRect(
            x: displayedBounds.minX / displayedSize.width,
            y: displayedBounds.minY / displayedSize.height,
            width: displayedBounds.width / displayedSize.width,
            height: displayedBounds.height / displayedSize.height
        )
        let sourceBounds = transform.sourcePixelRect(
            fromDisplayNormalized: normalizedDisplayedBounds
        ).standardized
        guard let sourcePixelBounds = Self.outwardPixelRect(
            sourceBounds,
            pixelWidth: sourceWidth,
            pixelHeight: sourceHeight
        ) else {
            return nil
        }

        displayPixelRect = AnalysisReportPixelRect(
            x: Int(displayedBounds.minX),
            y: Int(displayedBounds.minY),
            width: Int(displayedBounds.width),
            height: Int(displayedBounds.height)
        )
        sourcePixelRect = sourcePixelBounds
        displayedSourceWidth = Int(displayedSize.width)
        displayedSourceHeight = Int(displayedSize.height)
        scaleLabel = Self.scaleLabel
        interpolationLabel = Self.interpolationLabel
    }

    var normalizedDisplayRect: CGRect {
        CGRect(
            x: CGFloat(displayPixelRect.x) / CGFloat(displayedSourceWidth),
            y: CGFloat(displayPixelRect.y) / CGFloat(displayedSourceHeight),
            width: CGFloat(displayPixelRect.width) / CGFloat(displayedSourceWidth),
            height: CGFloat(displayPixelRect.height) / CGFloat(displayedSourceHeight)
        )
    }

    private static func outwardPixelRect(
        _ rect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> AnalysisReportPixelRect? {
        let bounds = rect.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
        let minX = max(0, Int(floor(bounds.minX)))
        let minY = max(0, Int(floor(bounds.minY)))
        let maxX = min(pixelWidth, Int(ceil(bounds.maxX)))
        let maxY = min(pixelHeight, Int(ceil(bounds.maxY)))
        guard maxX > minX, maxY > minY else { return nil }
        return AnalysisReportPixelRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}

/// A deep value snapshot used as the sole input to report rendering.
///
/// Report generators must not retain an `AnalysisCase` or workspace model. Creating this value
/// validates a freshly captured source revision, copies all report inputs, filters user-excluded
/// findings, and establishes deterministic ordering. Edits made after creation cannot mix with an
/// export already in progress.
nonisolated struct AnalysisReportSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let caseID: UUID
    let caseTitle: String
    let caseUpdatedAt: Date
    let source: SourceImageRevision
    let representation: AnalysisSourceRepresentation
    let analyzerRuns: [AnalysisReportAnalyzerRun]
    let sourceFacts: AnalysisSourceFacts?
    let rawMetadata: [AnalysisRawMetadataEntry]
    let includedFindings: [AnalysisFinding]
    let evidenceCrop: AnalysisReportEvidenceCrop?
    let photoAnnotations: [AnalysisAnnotation]
    let timestampEvidence: [AnalysisTimestampEvidence]
    let observations: [AnalysisObservation]
    let mapEvidence: AnalysisReportMapEvidence?

    /// Re-hashes the current source bytes immediately before freezing report inputs.
    static func capture(
        from analysisCase: AnalysisCase,
        sourceURL: URL,
        appVersion: String,
        appBuild: String,
        originalDisplayEvidenceCrop: CGRect? = nil,
        id: UUID = UUID(),
        now: Date = Date()
    ) async throws -> AnalysisReportSnapshot {
        let revision = try await SourceImageRevision.capture(
            at: sourceURL,
            pixelWidth: analysisCase.source.pixelWidth,
            pixelHeight: analysisCase.source.pixelHeight,
            exifOrientation: analysisCase.source.exifOrientation
        )
        return try create(
            from: analysisCase,
            validatedSource: revision,
            appVersion: appVersion,
            appBuild: appBuild,
            originalDisplayEvidenceCrop: originalDisplayEvidenceCrop,
            id: id,
            now: now
        )
    }

    private static func create(
        from analysisCase: AnalysisCase,
        validatedSource: SourceImageRevision,
        appVersion: String,
        appBuild: String,
        originalDisplayEvidenceCrop: CGRect? = nil,
        id: UUID = UUID(),
        now: Date = Date()
    ) throws -> AnalysisReportSnapshot {
        do {
            try analysisCase.validateForPersistence()
        } catch {
            throw AnalysisReportSnapshotError.invalidCase
        }
        guard analysisCase.source.relationship(to: validatedSource) == .exactRevision else {
            throw AnalysisReportSnapshotError.sourceRevisionChanged
        }

        let orderedRuns = analysisCase.analyzerRuns.sorted {
            if $0.analyzerID != $1.analyzerID { return $0.analyzerID < $1.analyzerID }
            return $0.analyzerVersion < $1.analyzerVersion
        }
        let findings = orderedRuns
            .flatMap { $0.output?.findings ?? [] }
            .filter(\.includeInReport)
            .sorted {
                if $0.category.rawValue != $1.category.rawValue {
                    return $0.category.rawValue < $1.category.rawValue
                }
                if $0.analyzerID != $1.analyzerID { return $0.analyzerID < $1.analyzerID }
                return $0.id < $1.id
            }

        return AnalysisReportSnapshot(
            schemaVersion: currentSchemaVersion,
            id: id,
            createdAt: now,
            appVersion: appVersion,
            appBuild: appBuild,
            caseID: analysisCase.id,
            caseTitle: analysisCase.title,
            caseUpdatedAt: analysisCase.updatedAt,
            source: validatedSource,
            representation: analysisCase.displayPreference,
            analyzerRuns: orderedRuns.map(AnalysisReportAnalyzerRun.init),
            sourceFacts: orderedRuns.lazy.compactMap { $0.output?.sourceFacts }.first,
            rawMetadata: orderedRuns
                .flatMap { $0.output?.rawMetadata ?? [] }
                .sorted {
                    if $0.origin.rawValue != $1.origin.rawValue {
                        return $0.origin.rawValue < $1.origin.rawValue
                    }
                    if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
                    if $0.key != $1.key { return $0.key < $1.key }
                    if $0.id != $1.id { return $0.id < $1.id }
                    return $0.value < $1.value
                },
            includedFindings: findings,
            evidenceCrop: originalDisplayEvidenceCrop.flatMap {
                AnalysisReportEvidenceCrop(
                    originalDisplayNormalizedRect: $0,
                    source: validatedSource
                )
            },
            // Annotation order is user-authored layer order and must not be normalized away.
            photoAnnotations: analysisCase.annotations,
            timestampEvidence: analysisCase.timestampEvidence.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            observations: analysisCase.observations.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            },
            mapEvidence: AnalysisReportMapEvidence(
                state: analysisCase.mapState,
                capturedAt: now
            )
        )
    }
}
