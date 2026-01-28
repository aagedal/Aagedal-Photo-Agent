import Foundation
import CoreLocation

struct GeocodingResult: Sendable {
    let city: String?
    let country: String?
}

enum GeocodingError: LocalizedError, Sendable {
    case noCoordinates
    case noResults
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noCoordinates:
            return "No GPS coordinates available"
        case .noResults:
            return "No location found for these coordinates"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

struct GeocodingService: Sendable {
    @MainActor
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeocodingResult {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                throw GeocodingError.noResults
            }
            return GeocodingResult(
                city: placemark.locality,
                country: placemark.country
            )
        } catch let error as GeocodingError {
            throw error
        } catch {
            throw GeocodingError.networkError(error.localizedDescription)
        }
    }
}
