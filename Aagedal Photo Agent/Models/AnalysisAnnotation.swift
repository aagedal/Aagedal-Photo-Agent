import Foundation

nonisolated enum AnalysisAnnotationKind: String, Codable, CaseIterable, Sendable {
    case line
    case arrow
    case distance
    case rectangle
    case ellipse
    case label
}

/// A point in the original image's display-oriented coordinate space.
///
/// Both axes use the closed `0...1` interval with a top-left origin. Keeping annotation
/// geometry in this space makes it independent of preview size and zoom while the shared
/// `DisplayImageTransform` remains responsible for source-pixel and report conversions.
nonisolated struct AnalysisNormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

nonisolated struct AnalysisNormalizedBounds: Codable, Equatable, Sendable {
    var minimum: AnalysisNormalizedPoint
    var maximum: AnalysisNormalizedPoint

    var isValid: Bool {
        minimum.isValid
            && maximum.isValid
            && minimum.x < maximum.x
            && minimum.y < maximum.y
    }
}

nonisolated enum AnalysisAnnotationGeometry: Codable, Equatable, Sendable {
    case segment(start: AnalysisNormalizedPoint, end: AnalysisNormalizedPoint)
    case bounds(AnalysisNormalizedBounds)
    case anchor(AnalysisNormalizedPoint)

    fileprivate var isValid: Bool {
        switch self {
        case .segment(let start, let end):
            start.isValid && end.isValid && start != end
        case .bounds(let bounds):
            bounds.isValid
        case .anchor(let point):
            point.isValid
        }
    }
}

/// Stable palette identifiers are persisted rather than platform color-space values.
///
/// The exact accessible rendering colors and custom-color picker are supplied by the markup UI
/// slice. Persisting the semantic choice here avoids baking display-profile conversions into a
/// source-bound case document.
nonisolated enum AnalysisAnnotationPaletteColor: String, Codable, CaseIterable, Sendable {
    case yellow
    case blue
    case orange
    case purple
    case white
    case black
}

nonisolated struct AnalysisAnnotationCustomColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double

    var isValid: Bool {
        [red, green, blue, opacity].allSatisfy {
            $0.isFinite && (0...1).contains($0)
        }
    }
}

nonisolated enum AnalysisAnnotationColor: Codable, Equatable, Sendable {
    case palette(AnalysisAnnotationPaletteColor)
    case custom(AnalysisAnnotationCustomColor)

    fileprivate var isValid: Bool {
        switch self {
        case .palette:
            true
        case .custom(let color):
            color.isValid
        }
    }
}

nonisolated struct AnalysisAnnotationStyle: Codable, Equatable, Sendable {
    var color: AnalysisAnnotationColor
    var lineWidthPoints: Double
    var fillOpacity: Double

    static let `default` = AnalysisAnnotationStyle(
        color: .palette(.yellow),
        lineWidthPoints: 2,
        fillOpacity: 0
    )

    fileprivate var isValid: Bool {
        color.isValid
            && lineWidthPoints.isFinite
            && (0.5...32).contains(lineWidthPoints)
            && fillOpacity.isFinite
            && (0...1).contains(fillOpacity)
    }
}

nonisolated enum AnalysisAnnotationValidationError: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidStyle
    case invalidText
    case invalidTimestamps
    case invalidFindingReferences
}

nonisolated struct AnalysisAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: AnalysisAnnotationKind
    var geometry: AnalysisAnnotationGeometry
    var text: String?
    var style: AnalysisAnnotationStyle
    var isVisible: Bool
    var findingIDs: [String]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: AnalysisAnnotationKind,
        geometry: AnalysisAnnotationGeometry,
        text: String? = nil,
        style: AnalysisAnnotationStyle = .default,
        isVisible: Bool = true,
        findingIDs: [String] = [],
        now: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.text = text
        self.style = style
        self.isVisible = isVisible
        self.findingIDs = findingIDs
        createdAt = now
        updatedAt = now
    }

    mutating func markUpdated(now: Date = Date()) {
        updatedAt = max(now, createdAt)
    }

    func validate() throws {
        guard geometry.isValid, geometry.matches(kind) else {
            throw AnalysisAnnotationValidationError.invalidGeometry
        }
        guard style.isValid else {
            throw AnalysisAnnotationValidationError.invalidStyle
        }

        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .label {
            guard let trimmedText, !trimmedText.isEmpty else {
                throw AnalysisAnnotationValidationError.invalidText
            }
        } else if text != nil, trimmedText?.isEmpty != false {
            throw AnalysisAnnotationValidationError.invalidText
        }

        guard updatedAt >= createdAt else {
            throw AnalysisAnnotationValidationError.invalidTimestamps
        }
        guard Set(findingIDs).count == findingIDs.count,
              findingIDs.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw AnalysisAnnotationValidationError.invalidFindingReferences
        }
    }
}

private extension AnalysisAnnotationGeometry {
    nonisolated func matches(_ kind: AnalysisAnnotationKind) -> Bool {
        switch (kind, self) {
        case (.line, .segment), (.arrow, .segment), (.distance, .segment),
             (.rectangle, .bounds), (.ellipse, .bounds), (.label, .anchor):
            true
        default:
            false
        }
    }
}
