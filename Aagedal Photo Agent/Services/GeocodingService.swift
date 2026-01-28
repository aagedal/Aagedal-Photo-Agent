import Foundation
@preconcurrency import MapKit

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
    private static let countryNames: Set<String> = {
        var names = Set<String>()
        let locales = [Locale.current, Locale(identifier: "en_US")]
        for region in Locale.Region.isoRegions {
            for locale in locales {
                if let name = locale.localizedString(forRegionCode: region.identifier) {
                    names.insert(name)
                }
            }
        }
        return names
    }()

    private static func countryFromAddress(_ address: String?) -> String? {
        guard let address, !address.isEmpty else {
            return nil
        }

        let separators = CharacterSet(charactersIn: ",\n")
        let parts = address
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for part in parts.reversed() {
            if countryNames.contains(part) {
                return part
            }
        }

        for part in parts.reversed() {
            for name in countryNames where part.hasSuffix(name) {
                return name
            }
        }

        return nil
    }

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
            let city = mapItem.addressRepresentations?.cityName
            let country = mapItem.addressRepresentations?.regionName
                ?? Self.countryFromAddress(mapItem.address?.fullAddress)
                ?? Self.countryFromAddress(mapItem.address?.shortAddress)

            return GeocodingResult(city: city, country: country)
        } catch let error as GeocodingError {
            throw error
        } catch {
            throw GeocodingError.networkError(error.localizedDescription)
        }
    }
}
