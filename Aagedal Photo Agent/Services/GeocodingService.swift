import Foundation
import MapKit

struct GeocodingResult: Sendable {
    let city: String?
    let country: String?
}

enum GeocodingError: LocalizedError, Sendable {
    case noCoordinates
    case noResults
    case invalidCoordinates
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noCoordinates:
            return "No GPS coordinates available"
        case .noResults:
            return "No location found for these coordinates"
        case .invalidCoordinates:
            return "Invalid GPS coordinates"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

struct GeocodingService: Sendable {
    @MainActor
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeocodingResult {
        let location = CLLocation(latitude: latitude, longitude: longitude)

        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw GeocodingError.invalidCoordinates
        }

        do {
            let mapItems = try await request.mapItems
            guard let mapItem = mapItems.first else {
                throw GeocodingError.noResults
            }
            // Use addressRepresentations.cityName for city (non-deprecated)
            // Fall back to placemark.country for country as MKAddressRepresentations
            // doesn't expose a country property
            let city = mapItem.addressRepresentations?.cityName
            let country = mapItem.placemark.country

            return GeocodingResult(city: city, country: country)
        } catch let error as GeocodingError {
            throw error
        } catch {
            throw GeocodingError.networkError(error.localizedDescription)
        }
    }
}
