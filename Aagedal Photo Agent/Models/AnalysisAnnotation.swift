import CoreGraphics
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
    case invalidCalibration
    case invalidTimestamps
    case invalidFindingReferences
}

nonisolated enum AnalysisMeasurementUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case millimeters
    case centimeters
    case meters
    case inches
    case feet

    var id: Self { self }

    var displayName: String {
        switch self {
        case .millimeters: "Millimeters"
        case .centimeters: "Centimeters"
        case .meters: "Meters"
        case .inches: "Inches"
        case .feet: "Feet"
        }
    }

    var symbol: String {
        switch self {
        case .millimeters: "mm"
        case .centimeters: "cm"
        case .meters: "m"
        case .inches: "in"
        case .feet: "ft"
        }
    }

    fileprivate var metersPerUnit: Double {
        switch self {
        case .millimeters: 0.001
        case .centimeters: 0.01
        case .meters: 1
        case .inches: 0.0254
        case .feet: 0.3048
        }
    }
}

/// A known real-world length assigned to one distance annotation.
///
/// The segment geometry remains the source of its pixel length. Persisting only the known length
/// and unit prevents calibration from becoming stale when the source transform is re-resolved.
nonisolated struct AnalysisMeasurementCalibration: Codable, Equatable, Sendable {
    var knownLength: Double
    var unit: AnalysisMeasurementUnit

    var isValid: Bool {
        knownLength.isFinite && knownLength > 0
    }

    var formattedKnownLength: String {
        Self.formatted(knownLength, unit: unit)
    }

    fileprivate static func formatted(_ value: Double, unit: AnalysisMeasurementUnit) -> String {
        let magnitude = abs(value)
        let formattedNumber: String
        switch magnitude {
        case 100...:
            formattedNumber = value.formatted(
                .number.precision(.fractionLength(0...1)).grouping(.automatic)
            )
        case 10..<100:
            formattedNumber = value.formatted(
                .number.precision(.fractionLength(0...2)).grouping(.automatic)
            )
        default:
            formattedNumber = value.formatted(
                .number.precision(.fractionLength(0...3)).grouping(.automatic)
            )
        }
        return formattedNumber + " " + unit.symbol
    }
}

nonisolated struct AnalysisAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: AnalysisAnnotationKind
    var geometry: AnalysisAnnotationGeometry
    var text: String?
    var style: AnalysisAnnotationStyle
    var isVisible: Bool
    var findingIDs: [String]
    var measurementCalibration: AnalysisMeasurementCalibration?
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
        measurementCalibration: AnalysisMeasurementCalibration? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.text = text
        self.style = style
        self.isVisible = isVisible
        self.findingIDs = findingIDs
        self.measurementCalibration = measurementCalibration
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

        if let measurementCalibration {
            guard kind == .distance, measurementCalibration.isValid else {
                throw AnalysisAnnotationValidationError.invalidCalibration
            }
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

/// Converts between the case's stable full-image annotation frame and the representation that is
/// currently visible. The two transforms deliberately meet in source-pixel normalized space.
nonisolated struct AnalysisAnnotationCoordinateMapper: Sendable {
    let annotationTransform: DisplayImageTransform
    let displayTransform: DisplayImageTransform

    func displayPoint(from annotationPoint: AnalysisNormalizedPoint) -> CGPoint {
        let sourcePoint = annotationTransform.sourceNormalizedPoint(
            fromDisplayNormalized: CGPoint(x: annotationPoint.x, y: annotationPoint.y)
        )
        return displayTransform.displayNormalizedPoint(fromSourceNormalized: sourcePoint)
    }

    func annotationPoint(from displayPoint: CGPoint) -> AnalysisNormalizedPoint {
        let sourcePoint = displayTransform.sourceNormalizedPoint(
            fromDisplayNormalized: displayPoint
        )
        let annotationPoint = annotationTransform.displayNormalizedPoint(
            fromSourceNormalized: sourcePoint
        )
        return AnalysisNormalizedPoint(
            x: Self.clampUnit(annotationPoint.x),
            y: Self.clampUnit(annotationPoint.y)
        )
    }

    private static func clampUnit(_ value: CGFloat) -> Double {
        Double(min(1, max(0, value)))
    }
}

nonisolated enum AnalysisAnnotationGeometryBuilder {
    static func geometry(
        for kind: AnalysisAnnotationKind,
        start: AnalysisNormalizedPoint,
        end: AnalysisNormalizedPoint
    ) -> AnalysisAnnotationGeometry? {
        switch kind {
        case .line, .arrow, .distance:
            guard start != end else { return nil }
            return .segment(start: start, end: end)
        case .rectangle, .ellipse:
            let bounds = AnalysisNormalizedBounds(
                minimum: AnalysisNormalizedPoint(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y)
                ),
                maximum: AnalysisNormalizedPoint(
                    x: max(start.x, end.x),
                    y: max(start.y, end.y)
                )
            )
            guard bounds.isValid else { return nil }
            return .bounds(bounds)
        case .label:
            return .anchor(start)
        }
    }
}

/// A distance annotation resolved in the original source's pixel-storage frame.
///
/// The persisted annotation remains normalized and display-oriented. Resolving both endpoints
/// through `DisplayImageTransform` prevents preview points, zoom, crop, or EXIF orientation from
/// being mistaken for source pixels.
nonisolated struct AnalysisSourcePixelMeasurement: Equatable, Sendable {
    let start: CGPoint
    let end: CGPoint

    var deltaX: CGFloat { end.x - start.x }
    var deltaY: CGFloat { end.y - start.y }
    var length: CGFloat { hypot(deltaX, deltaY) }

    var formattedLength: String {
        let formattedNumber: String
        switch length {
        case 100...:
            formattedNumber = Double(length).formatted(
                .number.precision(.fractionLength(0)).grouping(.automatic)
            )
        case 10..<100:
            formattedNumber = Double(length).formatted(
                .number.precision(.fractionLength(1)).grouping(.automatic)
            )
        default:
            formattedNumber = Double(length).formatted(
                .number.precision(.fractionLength(2)).grouping(.automatic)
            )
        }
        return formattedNumber + " px"
    }

    func formattedLength(calibratedBy scale: AnalysisMeasurementScale?) -> String {
        guard let scale else { return formattedLength }
        return scale.formattedLength(forPixelLength: length) + " · " + formattedLength
    }

    init?(
        annotation: AnalysisAnnotation,
        annotationTransform: DisplayImageTransform
    ) {
        guard annotation.kind == .distance,
              case .segment(let normalizedStart, let normalizedEnd) = annotation.geometry else {
            return nil
        }
        start = annotationTransform.sourcePixelPoint(
            fromDisplayNormalized: CGPoint(x: normalizedStart.x, y: normalizedStart.y)
        )
        end = annotationTransform.sourcePixelPoint(
            fromDisplayNormalized: CGPoint(x: normalizedEnd.x, y: normalizedEnd.y)
        )
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              length.isFinite else {
            return nil
        }
    }
}

/// Resolves the case's single calibrated distance into a reusable physical scale.
nonisolated struct AnalysisMeasurementScale: Equatable, Sendable {
    let metersPerPixel: Double
    let preferredUnit: AnalysisMeasurementUnit

    init?(
        annotations: [AnalysisAnnotation],
        annotationTransform: DisplayImageTransform
    ) {
        let calibrationAnnotations = annotations.filter {
            $0.measurementCalibration != nil
        }
        guard calibrationAnnotations.count == 1,
        let calibrationAnnotation = calibrationAnnotations.first,
        let calibration = calibrationAnnotation.measurementCalibration,
        calibration.isValid,
        let pixelMeasurement = AnalysisSourcePixelMeasurement(
            annotation: calibrationAnnotation,
            annotationTransform: annotationTransform
        ),
        pixelMeasurement.length > 0 else {
            return nil
        }
        metersPerPixel = calibration.knownLength * calibration.unit.metersPerUnit
            / Double(pixelMeasurement.length)
        preferredUnit = calibration.unit
        guard metersPerPixel.isFinite, metersPerPixel > 0 else { return nil }
    }

    func length(
        forPixelLength pixelLength: CGFloat,
        in unit: AnalysisMeasurementUnit? = nil
    ) -> Double {
        let resolvedUnit = unit ?? preferredUnit
        return Double(pixelLength) * metersPerPixel / resolvedUnit.metersPerUnit
    }

    func formattedLength(
        forPixelLength pixelLength: CGFloat,
        in unit: AnalysisMeasurementUnit? = nil
    ) -> String {
        let resolvedUnit = unit ?? preferredUnit
        return AnalysisMeasurementCalibration.formatted(
            length(forPixelLength: pixelLength, in: resolvedUnit),
            unit: resolvedUnit
        )
    }
}

/// A bounded transaction history for the photo-annotation surface.
///
/// Transactions retain complete before/after collections so undo restores ordering as well as
/// content. The map surface will own a separate history when its distinct annotation model is
/// introduced; photo markup must not share the Develop workspace's global undo stack.
nonisolated struct AnalysisAnnotationUndoHistory: Sendable {
    nonisolated struct Transaction: Equatable, Sendable {
        let before: [AnalysisAnnotation]
        let after: [AnalysisAnnotation]
        let actionName: String
    }

    private let maximumTransactionCount: Int
    private(set) var undoTransactions: [Transaction] = []
    private(set) var redoTransactions: [Transaction] = []

    init(maximumTransactionCount: Int = 100) {
        self.maximumTransactionCount = max(1, maximumTransactionCount)
    }

    var canUndo: Bool { !undoTransactions.isEmpty }
    var canRedo: Bool { !redoTransactions.isEmpty }
    var undoActionName: String? { undoTransactions.last?.actionName }
    var redoActionName: String? { redoTransactions.last?.actionName }

    mutating func record(
        before: [AnalysisAnnotation],
        after: [AnalysisAnnotation],
        actionName: String
    ) {
        guard before != after else { return }
        undoTransactions.append(Transaction(
            before: before,
            after: after,
            actionName: actionName
        ))
        if undoTransactions.count > maximumTransactionCount {
            undoTransactions.removeFirst(undoTransactions.count - maximumTransactionCount)
        }
        redoTransactions.removeAll(keepingCapacity: true)
    }

    mutating func undo() -> [AnalysisAnnotation]? {
        guard let transaction = undoTransactions.popLast() else { return nil }
        redoTransactions.append(transaction)
        return transaction.before
    }

    mutating func redo() -> [AnalysisAnnotation]? {
        guard let transaction = redoTransactions.popLast() else { return nil }
        undoTransactions.append(transaction)
        return transaction.after
    }

    mutating func removeAll() {
        undoTransactions.removeAll(keepingCapacity: false)
        redoTransactions.removeAll(keepingCapacity: false)
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
