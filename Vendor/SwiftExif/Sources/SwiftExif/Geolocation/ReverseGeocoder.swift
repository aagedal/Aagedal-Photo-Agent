import Foundation

/// A resolved location from reverse geocoding.
public struct GeoLocation: Sendable, CustomStringConvertible {
    /// City name.
    public let city: String
    /// State, province, or administrative region.
    public let region: String
    /// Full country name.
    public let country: String
    /// ISO 3166-1 alpha-3 country code (for IPTC Country-PrimaryLocationCode).
    public let countryCode: String
    /// ISO 3166-1 alpha-2 country code (e.g. "FR"), suitable for
    /// `Locale.localizedString(forRegionCode:)` offline country-name localization.
    public let countryCodeAlpha2: String
    /// IANA timezone identifier (e.g. "Europe/Oslo").
    public let timezone: String
    /// City population.
    public let population: Int
    /// Distance in kilometers from the query point.
    public let distance: Double

    public var description: String {
        "\(city), \(region), \(country) (\(countryCode)) [\(String(format: "%.1f", distance)) km]"
    }

    /// The country name localized into the given locale, resolved offline via
    /// Foundation from ``countryCodeAlpha2``. Falls back to the English ``country``
    /// when the locale cannot name the region (e.g. an unknown code).
    /// - Parameter locale: Target locale. Defaults to the user's current locale.
    public func localizedCountry(_ locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: countryCodeAlpha2) ?? country
    }
}

/// Offline reverse geocoder using an embedded GeoNames city database.
/// Converts GPS coordinates to city/region/country names without network access.
///
/// Uses a k-d tree over ECEF-converted coordinates for O(log n) nearest-neighbor lookup.
public final class ReverseGeocoder: @unchecked Sendable {
    /// Shared singleton instance. The k-d tree is built lazily on first use.
    public static let shared = ReverseGeocoder()

    private let tree: KDTree

    /// Initialize with the built-in GeoNames database.
    public init() {
        let db = GeoLocationDatabase.self
        var points: [KDTree.ECEF] = []
        points.reserveCapacity(db.cityCount)

        for i in 0..<db.cityCount {
            points.append(.fromLatLon(
                latitude: db.latitudes[i],
                longitude: db.longitudes[i],
                index: Int32(i)
            ))
        }

        self.tree = KDTree(points: points)
    }

    /// Look up the nearest city to the given coordinates.
    /// - Parameters:
    ///   - latitude: Latitude in decimal degrees.
    ///   - longitude: Longitude in decimal degrees.
    ///   - maxDistance: Maximum distance in kilometers. Returns nil if no city is within this range. Default 50 km.
    /// - Returns: The nearest city, or nil if none within maxDistance.
    public func lookup(latitude: Double, longitude: Double, maxDistance: Double = 50.0) -> GeoLocation? {
        let query = KDTree.ECEF.fromLatLon(
            latitude: Float(latitude),
            longitude: Float(longitude),
            index: -1
        )
        guard let result = tree.nearest(to: query) else { return nil }

        let cityIndex = Int(result.point.index)
        let dist = haversineDistance(
            lat1: latitude, lon1: longitude,
            lat2: Double(GeoLocationDatabase.latitudes[cityIndex]),
            lon2: Double(GeoLocationDatabase.longitudes[cityIndex])
        )

        guard dist <= maxDistance else { return nil }
        return buildGeoLocation(index: cityIndex, distance: dist)
    }

    /// Find the nearest cities to the given coordinates.
    /// - Parameters:
    ///   - latitude: Latitude in decimal degrees.
    ///   - longitude: Longitude in decimal degrees.
    ///   - count: Number of results to return. Default 1.
    ///   - maxDistance: Maximum distance in kilometers. Default 100 km.
    /// - Returns: Array of nearest cities sorted by distance, filtered by maxDistance.
    public func nearest(latitude: Double, longitude: Double, count: Int = 1, maxDistance: Double = 100.0) -> [GeoLocation] {
        let query = KDTree.ECEF.fromLatLon(
            latitude: Float(latitude),
            longitude: Float(longitude),
            index: -1
        )
        let results = tree.nearestK(count, to: query)

        return results.compactMap { result in
            let cityIndex = Int(result.point.index)
            let dist = haversineDistance(
                lat1: latitude, lon1: longitude,
                lat2: Double(GeoLocationDatabase.latitudes[cityIndex]),
                lon2: Double(GeoLocationDatabase.longitudes[cityIndex])
            )
            guard dist <= maxDistance else { return nil }
            return buildGeoLocation(index: cityIndex, distance: dist)
        }.sorted { $0.distance < $1.distance }
    }

    // MARK: - Private

    private func buildGeoLocation(index: Int, distance: Double) -> GeoLocation {
        let db = GeoLocationDatabase.self
        let regionIdx = Int(db.regionIndices[index])
        let countryIdx = Int(db.countryIndices[index])
        let tzIdx = Int(db.timezoneIndices[index])
        let cc2Idx = Int(db.countryCodeIndices[index])

        let cc2 = db.countryCode2s[cc2Idx]
        let cc3 = db.alpha2ToAlpha3[cc2] ?? cc2

        return GeoLocation(
            city: db.cityNames[index],
            region: db.regionNames[regionIdx],
            country: db.countryNames[countryIdx],
            countryCode: cc3,
            countryCodeAlpha2: cc2,
            timezone: db.timezoneNames[tzIdx],
            population: Int(db.populations[index]),
            distance: distance
        )
    }

    /// Haversine distance in kilometers between two points.
    private func haversineDistance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0 // Earth radius in km
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let lat1Rad = lat1 * .pi / 180.0
        let lat2Rad = lat2 * .pi / 180.0

        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1Rad) * cos(lat2Rad) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
}
