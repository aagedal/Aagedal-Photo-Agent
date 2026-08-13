import Foundation

nonisolated enum AnalysisMapStyle: String, Codable, CaseIterable, Sendable {
    case standard
    case muted
    case hybrid
    case satellite
    case openStreetMap

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .muted: "Muted"
        case .hybrid: "Hybrid"
        case .satellite: "Satellite"
        case .openStreetMap: "OpenStreetMap"
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "map"
        case .muted: "map.fill"
        case .hybrid: "square.2.layers.3d"
        case .satellite: "globe.americas.fill"
        case .openStreetMap: "map.circle"
        }
    }
}

nonisolated struct AnalysisGeoCoordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }
}

nonisolated struct AnalysisMapViewport: Codable, Equatable, Sendable {
    var center: AnalysisGeoCoordinate
    var latitudeDelta: Double
    var longitudeDelta: Double
    var cameraDistance: Double?
    var heading: Double
    var pitch: Double

    init(
        center: AnalysisGeoCoordinate,
        latitudeDelta: Double,
        longitudeDelta: Double,
        cameraDistance: Double? = nil,
        heading: Double = 0,
        pitch: Double = 0
    ) {
        self.center = center
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
        self.cameraDistance = cameraDistance
        self.heading = heading
        self.pitch = pitch
    }

    var isValid: Bool {
        center.isValid
            && latitudeDelta.isFinite
            && longitudeDelta.isFinite
            && latitudeDelta > 0
            && latitudeDelta <= 180
            && longitudeDelta > 0
            && longitudeDelta <= 360
            && (cameraDistance.map { $0.isFinite && $0 > 0 } ?? true)
            && heading.isFinite
            && (0..<360).contains(heading)
            && pitch.isFinite
            && (0...90).contains(pitch)
    }

    private enum CodingKeys: String, CodingKey {
        case center
        case latitudeDelta
        case longitudeDelta
        case cameraDistance
        case heading
        case pitch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decode(AnalysisGeoCoordinate.self, forKey: .center)
        latitudeDelta = try container.decode(Double.self, forKey: .latitudeDelta)
        longitudeDelta = try container.decode(Double.self, forKey: .longitudeDelta)
        cameraDistance = try container.decodeIfPresent(Double.self, forKey: .cameraDistance)
        heading = try container.decodeIfPresent(Double.self, forKey: .heading) ?? 0
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
    }
}

/// The provenance of a case-only location pin.
///
/// Embedded GPS is rendered directly from source facts. An investigator may explicitly promote
/// it to the case photo location; that action is persisted with its embedded-GPS provenance.
nonisolated enum AnalysisLocationEvidenceSource: String, Codable, CaseIterable, Sendable {
    case embeddedGPS
    case manualCoordinates
    case placeSearch
    case mapCenter

    var displayName: String {
        switch self {
        case .embeddedGPS: "Embedded GPS"
        case .manualCoordinates: "Entered coordinates"
        case .placeSearch: "Place search"
        case .mapCenter: "Selected on map"
        }
    }
}

nonisolated enum AnalysisPlaceNameSource: String, Codable, Sendable {
    case placeSearch
    case reverseGeocoded

    var displayName: String {
        switch self {
        case .placeSearch: "Place-search result"
        case .reverseGeocoded: "Reverse-geocoded name"
        }
    }
}

nonisolated struct AnalysisLocationEvidence: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var coordinate: AnalysisGeoCoordinate
    var source: AnalysisLocationEvidenceSource
    var sourceDetail: String
    var placeName: String?
    var placeNameSource: AnalysisPlaceNameSource?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        coordinate: AnalysisGeoCoordinate,
        source: AnalysisLocationEvidenceSource,
        sourceDetail: String,
        placeName: String? = nil,
        placeNameSource: AnalysisPlaceNameSource? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.coordinate = coordinate
        self.source = source
        self.sourceDetail = sourceDetail
        self.placeName = placeName
        self.placeNameSource = placeNameSource
        updatedAt = now
    }

    mutating func markUpdated(now: Date = Date()) {
        updatedAt = now
    }

    func validate() -> Bool {
        let trimmedDetail = sourceDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlace = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return coordinate.isValid
            && !trimmedDetail.isEmpty
            && (trimmedPlace == nil || !(trimmedPlace?.isEmpty ?? true))
            && ((trimmedPlace == nil) == (placeNameSource == nil))
    }
}

nonisolated enum AnalysisMapAnnotationKind: String, Codable, CaseIterable, Sendable {
    case marker
    case line
    case shape
    case distance
    case label

    var displayName: String {
        switch self {
        case .marker: "Marker"
        case .line: "Line"
        case .shape: "Shape"
        case .distance: "Distance"
        case .label: "Label"
        }
    }
}

nonisolated enum AnalysisMapAnnotationGeometry: Codable, Equatable, Sendable {
    case point(AnalysisGeoCoordinate)
    case segment(start: AnalysisGeoCoordinate, end: AnalysisGeoCoordinate)
    case polygon([AnalysisGeoCoordinate])

    fileprivate var isValid: Bool {
        switch self {
        case .point(let coordinate):
            coordinate.isValid
        case .segment(let start, let end):
            start.isValid && end.isValid && start != end
        case .polygon(let coordinates):
            coordinates.count >= 3
                && coordinates.count <= 1_000
                && coordinates.allSatisfy(\.isValid)
                && Set(coordinates.map { "\($0.latitude),\($0.longitude)" }).count >= 3
        }
    }
}

nonisolated struct AnalysisMapAnnotationStyle: Codable, Equatable, Sendable {
    var color: AnalysisAnnotationColor
    var lineWidthPoints: Double
    var fillOpacity: Double

    static let `default` = AnalysisMapAnnotationStyle(
        color: .palette(.orange),
        lineWidthPoints: 3,
        fillOpacity: 0.16
    )

    fileprivate var isValid: Bool {
        let colorIsValid: Bool
        switch color {
        case .palette:
            colorIsValid = true
        case .custom(let custom):
            colorIsValid = custom.isValid
        }
        return colorIsValid
            && lineWidthPoints.isFinite
            && (0.5...32).contains(lineWidthPoints)
            && fillOpacity.isFinite
            && (0...1).contains(fillOpacity)
    }
}

nonisolated enum AnalysisMapAnnotationValidationError: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidStyle
    case invalidText
    case invalidTimestamps
}

/// Case-only markup in geographic coordinates.
///
/// `linkedPhotoLabelID` stores the stable UUID of any photo annotation. The persisted key
/// keeps its original name for document compatibility. The reference remains valid across label
/// edits and is deliberately preserved if a label is temporarily unavailable,
/// matching the case's existing analyzer-finding reference behavior.
nonisolated struct AnalysisMapAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: AnalysisMapAnnotationKind
    var geometry: AnalysisMapAnnotationGeometry
    var text: String?
    var style: AnalysisMapAnnotationStyle
    var isVisible: Bool
    var linkedPhotoLabelID: UUID?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: AnalysisMapAnnotationKind,
        geometry: AnalysisMapAnnotationGeometry,
        text: String? = nil,
        style: AnalysisMapAnnotationStyle = .default,
        isVisible: Bool = true,
        linkedPhotoLabelID: UUID? = nil,
        now: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.text = text
        self.style = style
        self.isVisible = isVisible
        self.linkedPhotoLabelID = linkedPhotoLabelID
        createdAt = now
        updatedAt = now
    }

    mutating func markUpdated(now: Date = Date()) {
        updatedAt = max(now, createdAt)
    }

    /// Creates an independent annotation for a different map owner.
    ///
    /// A copied annotation deliberately receives a new identity and timestamps so editing or
    /// deleting either copy cannot affect the source annotation.
    func copied(
        linkedPhotoLabelID: UUID? = nil,
        now: Date = Date()
    ) -> AnalysisMapAnnotation {
        AnalysisMapAnnotation(
            kind: kind,
            geometry: geometry,
            text: text,
            style: style,
            isVisible: isVisible,
            linkedPhotoLabelID: linkedPhotoLabelID,
            now: now
        )
    }

    func validate() throws {
        guard geometry.isValid, geometry.matches(kind) else {
            throw AnalysisMapAnnotationValidationError.invalidGeometry
        }
        guard style.isValid else {
            throw AnalysisMapAnnotationValidationError.invalidStyle
        }
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .label {
            guard let trimmedText, !trimmedText.isEmpty else {
                throw AnalysisMapAnnotationValidationError.invalidText
            }
        } else if text != nil, trimmedText?.isEmpty != false {
            throw AnalysisMapAnnotationValidationError.invalidText
        }
        guard updatedAt >= createdAt else {
            throw AnalysisMapAnnotationValidationError.invalidTimestamps
        }
    }

    var representativeCoordinate: AnalysisGeoCoordinate {
        switch geometry {
        case .point(let coordinate):
            coordinate
        case .segment(let start, let end):
            AnalysisGeoCoordinate(
                latitude: (start.latitude + end.latitude) / 2,
                longitude: AnalysisMapDistanceMeasurement.midpointLongitude(
                    start.longitude,
                    end.longitude
                )
            )
        case .polygon(let coordinates):
            AnalysisGeoCoordinate(
                latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                longitude: AnalysisMapDistanceMeasurement.circularMeanLongitude(
                    coordinates.map(\.longitude)
                )
            )
        }
    }
}

/// Keeps photo-local map markers named after the photo annotations they identify.
///
/// Map order is the stable tie-breaker when several markers identify the same photo annotation:
/// the first uses the photo annotation's name and later markers receive a numeric suffix.
nonisolated enum AnalysisLinkedMapMarkerNaming {
    @discardableResult
    static func normalize(
        _ mapAnnotations: inout [AnalysisMapAnnotation],
        using photoAnnotations: [AnalysisAnnotation],
        now: Date = Date()
    ) -> Bool {
        let photoNames = Dictionary(uniqueKeysWithValues: photoAnnotations.enumerated().map {
            ($0.element.id, photoAnnotationName($0.element, index: $0.offset))
        })
        var markerCounts: [UUID: Int] = [:]
        var changed = false

        for index in mapAnnotations.indices {
            guard mapAnnotations[index].kind == .marker,
                  let photoAnnotationID = mapAnnotations[index].linkedPhotoLabelID,
                  let baseName = photoNames[photoAnnotationID] else { continue }

            let count = markerCounts[photoAnnotationID, default: 0] + 1
            markerCounts[photoAnnotationID] = count
            let expectedName = count == 1 ? baseName : "\(baseName) \(count)"
            guard mapAnnotations[index].text != expectedName else { continue }
            mapAnnotations[index].text = expectedName
            mapAnnotations[index].markUpdated(now: now)
            changed = true
        }

        return changed
    }

    private static func photoAnnotationName(
        _ annotation: AnalysisAnnotation,
        index: Int
    ) -> String {
        if let text = annotation.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        let kindName: String = switch annotation.kind {
        case .line: "Line"
        case .arrow: "Arrow"
        case .distance: "Distance"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .label: "Label"
        }
        return "\(kindName) \(index + 1)"
    }
}

nonisolated struct AnalysisMapDistanceMeasurement: Equatable, Sendable {
    let meters: Double

    init?(annotation: AnalysisMapAnnotation) {
        guard annotation.kind == .distance,
              case .segment(let start, let end) = annotation.geometry,
              start.isValid, end.isValid else { return nil }
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let deltaLatitude = (end.latitude - start.latitude) * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let a = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude1) * cos(latitude2) * pow(sin(deltaLongitude / 2), 2)
        meters = 6_371_008.8 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        guard meters.isFinite else { return nil }
    }

    var formatted: String {
        if meters >= 1_000 {
            return (meters / 1_000).formatted(.number.precision(.fractionLength(0...2))) + " km"
        }
        return meters.formatted(.number.precision(.fractionLength(0...1))) + " m"
    }

    fileprivate static func midpointLongitude(_ first: Double, _ second: Double) -> Double {
        circularMeanLongitude([first, second])
    }

    fileprivate static func circularMeanLongitude(_ longitudes: [Double]) -> Double {
        let x = longitudes.map { cos($0 * .pi / 180) }.reduce(0, +)
        let y = longitudes.map { sin($0 * .pi / 180) }.reduce(0, +)
        return atan2(y, x) * 180 / .pi
    }
}

nonisolated struct AnalysisMapState: Codable, Equatable, Sendable {
    var style: AnalysisMapStyle
    var showsTraffic: Bool
    var shows3DContent: Bool
    var viewport: AnalysisMapViewport?
    var investigationLocation: AnalysisLocationEvidence?
    var annotations: [AnalysisMapAnnotation]

    init(
        style: AnalysisMapStyle = .hybrid,
        showsTraffic: Bool = false,
        shows3DContent: Bool = false,
        viewport: AnalysisMapViewport? = nil,
        investigationLocation: AnalysisLocationEvidence? = nil,
        annotations: [AnalysisMapAnnotation] = []
    ) {
        self.style = style
        self.showsTraffic = showsTraffic
        self.shows3DContent = shows3DContent
        self.viewport = viewport
        self.investigationLocation = investigationLocation
        self.annotations = annotations
    }

    func validate() -> Bool {
        (viewport?.isValid ?? true)
            && (investigationLocation?.validate() ?? true)
            && annotations.count <= 500
            && Set(annotations.map(\.id)).count == annotations.count
            && annotations.allSatisfy { (try? $0.validate()) != nil }
    }

    private enum CodingKeys: String, CodingKey {
        case style
        case showsTraffic
        case shows3DContent
        case viewport
        case investigationLocation
        case annotations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(AnalysisMapStyle.self, forKey: .style)
        showsTraffic = try container.decodeIfPresent(Bool.self, forKey: .showsTraffic) ?? false
        shows3DContent = try container.decodeIfPresent(Bool.self, forKey: .shows3DContent) ?? false
        viewport = try container.decodeIfPresent(AnalysisMapViewport.self, forKey: .viewport)
        investigationLocation = try container.decodeIfPresent(
            AnalysisLocationEvidence.self,
            forKey: .investigationLocation
        )
        annotations = try container.decodeIfPresent(
            [AnalysisMapAnnotation].self,
            forKey: .annotations
        ) ?? []
    }
}

nonisolated struct AnalysisMapAnnotationUndoHistory: Sendable {
    nonisolated struct Transaction: Equatable, Sendable {
        let before: [AnalysisMapAnnotation]
        let after: [AnalysisMapAnnotation]
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
        before: [AnalysisMapAnnotation],
        after: [AnalysisMapAnnotation],
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

    mutating func undo() -> [AnalysisMapAnnotation]? {
        guard let transaction = undoTransactions.popLast() else { return nil }
        redoTransactions.append(transaction)
        return transaction.before
    }

    mutating func redo() -> [AnalysisMapAnnotation]? {
        guard let transaction = redoTransactions.popLast() else { return nil }
        undoTransactions.append(transaction)
        return transaction.after
    }

    mutating func removeAll() {
        undoTransactions.removeAll(keepingCapacity: false)
        redoTransactions.removeAll(keepingCapacity: false)
    }
}

private extension AnalysisMapAnnotationGeometry {
    nonisolated func matches(_ kind: AnalysisMapAnnotationKind) -> Bool {
        switch (kind, self) {
        case (.marker, .point), (.label, .point), (.line, .segment),
             (.distance, .segment), (.shape, .polygon):
            true
        default:
            false
        }
    }
}
