import Foundation

/// Shared spherical geometry for case-only map presentation.
///
/// Distances produced here are display geometry, not evidence measurements. In particular, solar
/// ray length is derived from the current viewport and is never persisted or presented as a real
/// shadow length.
nonisolated enum AnalysisMapGeometry {
    private static let earthRadiusMeters = 6_371_008.8

    static func destinationCoordinate(
        from origin: AnalysisGeoCoordinate,
        bearingDegrees: Double,
        distanceMeters: Double
    ) -> AnalysisGeoCoordinate {
        guard origin.isValid,
              bearingDegrees.isFinite,
              distanceMeters.isFinite,
              distanceMeters >= 0 else { return origin }

        let angularDistance = distanceMeters / earthRadiusMeters
        let bearing = bearingDegrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
        )
        var longitudeDegrees = destinationLongitude * 180 / .pi
        longitudeDegrees = (longitudeDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
        return AnalysisGeoCoordinate(
            latitude: destinationLatitude * 180 / .pi,
            longitude: longitudeDegrees
        )
    }

    static func greatCircleDistanceMeters(
        from start: AnalysisGeoCoordinate,
        to end: AnalysisGeoCoordinate
    ) -> Double {
        guard start.isValid, end.isValid else { return .nan }
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let deltaLatitude = (end.latitude - start.latitude) * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let haversine = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude1) * cos(latitude2) * pow(sin(deltaLongitude / 2), 2)
        return earthRadiusMeters * 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }

    /// Returns a ray that occupies roughly one quarter of the viewport's shorter ground span.
    static func solarRayLengthMeters(
        latitudeDelta: Double,
        longitudeDelta: Double,
        at origin: AnalysisGeoCoordinate
    ) -> Double? {
        guard origin.isValid,
              latitudeDelta.isFinite,
              longitudeDelta.isFinite,
              latitudeDelta > 0,
              longitudeDelta > 0 else { return nil }

        let northSouth = earthRadiusMeters * min(latitudeDelta, 180) * .pi / 180
        let eastWest = earthRadiusMeters
            * abs(cos(origin.latitude * .pi / 180))
            * min(longitudeDelta, 360)
            * .pi / 180
        let spans = [northSouth, eastWest].filter { $0.isFinite && $0 > 0.01 }
        guard let shorterSpan = spans.min() else { return nil }
        return min(5_000_000, max(1, shorterSpan * 0.28))
    }
}

nonisolated enum AnalysisSolarMapRayKind: String, CaseIterable, Identifiable, Sendable {
    case sun
    case shadow
    case sunrise
    case sunset

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sun: "Sun direction"
        case .shadow: "Expected shadow direction"
        case .sunrise: "Sunrise direction"
        case .sunset: "Sunset direction"
        }
    }
}

nonisolated struct AnalysisSolarMapRay: Identifiable, Equatable, Sendable {
    let kind: AnalysisSolarMapRayKind
    let origin: AnalysisGeoCoordinate
    let destination: AnalysisGeoCoordinate
    let bearingDegrees: Double

    var id: AnalysisSolarMapRayKind { kind }
}

/// Ephemeral solar geometry consumed equally by SwiftUI Map and the OpenStreetMap MKMapView.
nonisolated struct AnalysisSolarMapRenderModel: Equatable, Sendable {
    let rays: [AnalysisSolarMapRay]
    let isBelowHorizon: Bool
    let polarCondition: AnalysisSolarPolarCondition?
    let rayLengthMeters: Double

    init?(
        overlay: AnalysisSolarOverlayState,
        origin: AnalysisGeoCoordinate,
        latitudeDelta: Double,
        longitudeDelta: Double,
        day: AnalysisSolarDay
    ) {
        guard overlay.isVisible,
              overlay.validate(),
              day.method == overlay.calculationMethod,
              origin.isValid,
              let rayLengthMeters = AnalysisMapGeometry.solarRayLengthMeters(
                  latitudeDelta: latitudeDelta,
                  longitudeDelta: longitudeDelta,
                  at: origin
              ) else { return nil }

        self.rayLengthMeters = rayLengthMeters
        isBelowHorizon = day.position.isBelowHorizon
        polarCondition = day.polarCondition

        var rays: [AnalysisSolarMapRay] = []
        if !day.position.isBelowHorizon {
            if overlay.showsSunDirection {
                rays.append(Self.ray(
                    kind: .sun,
                    bearingDegrees: day.position.azimuthDegrees,
                    origin: origin,
                    lengthMeters: rayLengthMeters
                ))
            }
            if overlay.showsShadowDirection {
                rays.append(Self.ray(
                    kind: .shadow,
                    bearingDegrees: day.position.expectedShadowAzimuthDegrees,
                    origin: origin,
                    lengthMeters: rayLengthMeters
                ))
            }
        }
        if overlay.showsSunriseDirection, let sunrise = day.sunrise {
            rays.append(Self.ray(
                kind: .sunrise,
                bearingDegrees: sunrise.azimuthDegrees,
                origin: origin,
                lengthMeters: rayLengthMeters
            ))
        }
        if overlay.showsSunsetDirection, let sunset = day.sunset {
            rays.append(Self.ray(
                kind: .sunset,
                bearingDegrees: sunset.azimuthDegrees,
                origin: origin,
                lengthMeters: rayLengthMeters
            ))
        }
        self.rays = rays
    }

    private static func ray(
        kind: AnalysisSolarMapRayKind,
        bearingDegrees: Double,
        origin: AnalysisGeoCoordinate,
        lengthMeters: Double
    ) -> AnalysisSolarMapRay {
        AnalysisSolarMapRay(
            kind: kind,
            origin: origin,
            destination: AnalysisMapGeometry.destinationCoordinate(
                from: origin,
                bearingDegrees: bearingDegrees,
                distanceMeters: lengthMeters
            ),
            bearingDegrees: bearingDegrees
        )
    }
}
