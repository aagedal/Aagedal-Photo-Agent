import Foundation

nonisolated enum AnalysisMapStyle: String, Codable, CaseIterable, Sendable {
    case hybrid
    case satellite

    var displayName: String {
        switch self {
        case .hybrid: "Hybrid"
        case .satellite: "Satellite"
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

    var isValid: Bool {
        center.isValid
            && latitudeDelta.isFinite
            && longitudeDelta.isFinite
            && latitudeDelta > 0
            && latitudeDelta <= 180
            && longitudeDelta > 0
            && longitudeDelta <= 360
    }
}

/// The provenance of a case-only location pin.
///
/// Embedded GPS is rendered directly from source facts and is never copied into this persisted
/// collection. Every persisted value is an investigator action with an explicit origin.
nonisolated enum AnalysisLocationEvidenceSource: String, Codable, CaseIterable, Sendable {
    case manualCoordinates
    case placeSearch
    case mapCenter

    var displayName: String {
        switch self {
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

nonisolated struct AnalysisMapState: Codable, Equatable, Sendable {
    var style: AnalysisMapStyle
    var viewport: AnalysisMapViewport?
    var investigationLocation: AnalysisLocationEvidence?

    init(
        style: AnalysisMapStyle = .hybrid,
        viewport: AnalysisMapViewport? = nil,
        investigationLocation: AnalysisLocationEvidence? = nil
    ) {
        self.style = style
        self.viewport = viewport
        self.investigationLocation = investigationLocation
    }

    func validate() -> Bool {
        (viewport?.isValid ?? true)
            && (investigationLocation?.validate() ?? true)
    }
}
