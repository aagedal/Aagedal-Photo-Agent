import Foundation

nonisolated enum AnalysisExternalMapLinks {
    static func appleLookAroundURL(for coordinate: AnalysisGeoCoordinate) -> URL? {
        guard coordinate.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/look-around"
        components.queryItems = [
            URLQueryItem(
                name: "coordinate",
                value: String(
                    format: "%.8f,%.8f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    coordinate.latitude,
                    coordinate.longitude
                )
            ),
        ]
        return components.url
    }

    static func googleMapsURL(for coordinate: AnalysisGeoCoordinate) -> URL? {
        guard coordinate.isValid else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/maps/search/"
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(
                name: "query",
                value: String(
                    format: "%.8f,%.8f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    coordinate.latitude,
                    coordinate.longitude
                )
            ),
        ]
        return components.url
    }
}
