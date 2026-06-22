import Foundation
@preconcurrency import CoreLocation
import SwiftExif

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

/// Output language for reverse-geocoded place names. Independent of the engine —
/// see the `reverseGeocodeOfflineEnabled` setting for offline vs. online.
nonisolated enum ReverseGeocodeLanguage: Hashable, Sendable, Identifiable {
    case system
    case language(String)   // BCP-47 language code, e.g. "nb", "de", "fr"

    /// Curated set of languages offered in the picker.
    static let curatedCodes = ["en", "nb", "nn", "sv", "da", "de", "fr", "es", "it", "nl", "pt", "fi"]

    static var allCases: [ReverseGeocodeLanguage] {
        [.system] + curatedCodes.map { .language($0) }
    }

    var id: String { storageValue }

    /// Stable token persisted to UserDefaults.
    var storageValue: String {
        switch self {
        case .system: return "system"
        case .language(let code): return code
        }
    }

    init(storageValue: String) {
        self = storageValue == "system" ? .system : .language(storageValue)
    }

    /// Concrete locale used to localize names (offline path needs a real locale, not nil).
    var locale: Locale {
        switch self {
        case .system: return Locale.autoupdatingCurrent
        case .language(let code): return Locale(identifier: code)
        }
    }

    /// Locale handed to `CLGeocoder` — nil for `.system` means "use the device locale".
    var preferredLocaleForCLGeocoder: Locale? {
        switch self {
        case .system: return nil
        case .language(let code): return Locale(identifier: code)
        }
    }

    var displayName: String {
        switch self {
        case .system:
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            let name = Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
            return "System (\(name))"
        case .language(let code):
            return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
        }
    }
}

/// Reverse geocodes GPS coordinates to City/Country. The engine (offline GeoNames
/// vs. online `CLGeocoder`) and output language are driven by user settings, read
/// fresh from UserDefaults on each call so they stay correct regardless of which
/// `SettingsViewModel` instance changed them.
///
/// - Online: `CLGeocoder` with a `preferredLocale` localizes **both** city and country.
/// - Offline: SwiftExif's embedded GeoNames database — instant and network-free; the
///   country name is localized via Foundation, but city names stay GeoNames-English.
struct GeocodingService: Sendable {
    nonisolated static func currentLanguage() -> ReverseGeocodeLanguage {
        let raw = AppDefaults.store.string(forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        return ReverseGeocodeLanguage(storageValue: raw ?? ReverseGeocodeLanguage.system.storageValue)
    }

    /// Whether the user has opted into the offline engine. Default false (online).
    nonisolated static func isOfflineEnabled() -> Bool {
        AppDefaults.store.bool(forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)
    }

    /// True when resolving hits Apple's online geocoder — callers (e.g. batch loops)
    /// use this to decide whether to throttle requests.
    nonisolated var usesNetwork: Bool { !Self.isOfflineEnabled() }

    /// Resolves the city/country for the given coordinates using the current settings.
    ///
    /// Marked `nonisolated async` so the work — the offline k-d tree lookup (incl. its
    /// one-time build) or the online request — runs off the main actor.
    nonisolated func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeocodingResult {
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            throw GeocodingError.invalidCoordinates
        }

        let language = Self.currentLanguage()
        if Self.isOfflineEnabled() {
            return try offlineLookup(latitude: latitude, longitude: longitude, locale: language.locale)
        } else {
            return try await onlineLookup(latitude: latitude, longitude: longitude, locale: language.preferredLocaleForCLGeocoder)
        }
    }

    // MARK: - Offline (SwiftExif GeoNames)

    private nonisolated func offlineLookup(latitude: Double, longitude: Double, locale: Locale) throws -> GeocodingResult {
        guard let location = ReverseGeocoder.shared.lookup(latitude: latitude, longitude: longitude) else {
            throw GeocodingError.noResults
        }
        // SwiftExif localizes the country offline via its alpha-2 code (e.g. "Frankrike"),
        // falling back to the English name when the locale can't name the region. City
        // names stay GeoNames-English.
        return GeocodingResult(city: location.city, country: location.localizedCountry(locale))
    }

    // MARK: - Online (CLGeocoder, localized)

    private nonisolated func onlineLookup(latitude: Double, longitude: Double, locale: Locale?) async throws -> GeocodingResult {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: locale)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            throw GeocodingError.noResults
        } catch {
            throw GeocodingError.networkError(error.localizedDescription)
        }

        guard let placemark = placemarks.first else {
            throw GeocodingError.noResults
        }
        let city = placemark.locality ?? placemark.subAdministrativeArea
        return GeocodingResult(city: city, country: placemark.country)
    }
}
