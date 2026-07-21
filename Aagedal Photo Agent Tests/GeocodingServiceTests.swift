import Testing
import Foundation
@testable import Aagedal_Photo_Agent

// MARK: - ReverseGeocodeLanguage (pure)

@Suite("ReverseGeocodeLanguage")
struct ReverseGeocodeLanguageTests {

    @Test("storageValue tokens are stable")
    func storageValues() {
        #expect(ReverseGeocodeLanguage.system.storageValue == "system")
        #expect(ReverseGeocodeLanguage.language("nb").storageValue == "nb")
        #expect(ReverseGeocodeLanguage.language("de").storageValue == "de")
    }

    @Test("init(storageValue:) decodes the system token and language codes")
    func initFromStorage() {
        #expect(ReverseGeocodeLanguage(storageValue: "system") == .system)
        #expect(ReverseGeocodeLanguage(storageValue: "nb") == .language("nb"))
        // Any non-"system" token is treated as a language code verbatim.
        #expect(ReverseGeocodeLanguage(storageValue: "pt") == .language("pt"))
    }

    @Test("storageValue round-trips through init for every case, and id mirrors it")
    func roundTrip() {
        for language in ReverseGeocodeLanguage.allCases {
            #expect(ReverseGeocodeLanguage(storageValue: language.storageValue) == language)
            #expect(language.id == language.storageValue)
        }
    }

    @Test("allCases leads with .system and covers every curated code, in order")
    func allCases() {
        let cases = ReverseGeocodeLanguage.allCases
        #expect(cases.first == .system)
        #expect(cases.count == 1 + ReverseGeocodeLanguage.curatedCodes.count)
        #expect(Array(cases.dropFirst()) == ReverseGeocodeLanguage.curatedCodes.map { .language($0) })
        // No accidental duplicates.
        #expect(Set(cases).count == cases.count)
    }

    @Test("locale resolves system to the auto-updating locale and a code to a fixed locale")
    func localeMapping() {
        #expect(ReverseGeocodeLanguage.system.locale == Locale.autoupdatingCurrent)
        #expect(ReverseGeocodeLanguage.language("nb").locale == Locale(identifier: "nb"))
    }

    @Test("Online geocoder locale is nil for system, concrete for a language")
    func onlineGeocoderLocale() {
        // nil tells MapKit to use the device locale; a code pins the output language.
        #expect(ReverseGeocodeLanguage.system.preferredLocaleForOnlineGeocoder == nil)
        #expect(ReverseGeocodeLanguage.language("de").preferredLocaleForOnlineGeocoder == Locale(identifier: "de"))
    }

    @Test("displayName is non-empty for every case and labels system")
    func displayNames() {
        #expect(ReverseGeocodeLanguage.system.displayName.hasPrefix("System"))
        for language in ReverseGeocodeLanguage.allCases {
            #expect(!language.displayName.isEmpty)
        }
    }
}

// MARK: - GeocodingService coordinate validation (pure)

@Suite("GeocodingService coordinates")
struct GeocodingServiceCoordinateTests {

    @Test("Out-of-range or non-finite coordinates throw .invalidCoordinates before any lookup")
    func invalidCoordinatesThrow() async {
        // Every input is rejected by the guard, so this never reaches the engine
        // (no network, no defaults access) — it's a pure crash-hardening check.
        let service = GeocodingService()
        let bad: [(Double, Double)] = [
            (91, 10), (-91, 10), (59, 181), (59, -181),
            (.nan, 10), (59, .nan), (.infinity, 10), (59, -.infinity),
        ]
        for (lat, lon) in bad {
            do {
                _ = try await service.reverseGeocode(latitude: lat, longitude: lon)
                Issue.record("Expected .invalidCoordinates for (\(lat), \(lon))")
            } catch let error as GeocodingError {
                guard case .invalidCoordinates = error else {
                    Issue.record("Expected .invalidCoordinates, got \(error) for (\(lat), \(lon))")
                    continue
                }
            } catch {
                Issue.record("Unexpected error \(error) for (\(lat), \(lon))")
            }
        }
    }
}

// MARK: - GeocodingService engine selection (reads/writes AppDefaults.store)

/// These tests mutate the two reverse-geocode defaults keys, so they must run
/// serialized (and against `AppDefaults.store`, the throwaway test suite, never
/// the user's live `UserDefaults.standard`). Keeping every defaults-touching test
/// in one serialized suite prevents cross-test races on the shared keys.
@Suite("GeocodingService engine selection", .serialized)
struct GeocodingServiceEngineTests {

    private func clearKeys() {
        AppDefaults.store.removeObject(forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        AppDefaults.store.removeObject(forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)
    }

    @Test("Defaults: system language, online engine, uses network")
    func defaultsAreSystemAndOnline() {
        clearKeys()
        defer { clearKeys() }
        #expect(GeocodingService.currentLanguage() == .system)
        #expect(GeocodingService.isOfflineEnabled() == false)
        #expect(GeocodingService().usesNetwork == true)
    }

    @Test("Offline flag flips isOfflineEnabled and usesNetwork")
    func offlineFlagFlipsUsesNetwork() {
        clearKeys()
        defer { clearKeys() }
        AppDefaults.store.set(true, forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)
        #expect(GeocodingService.isOfflineEnabled() == true)
        #expect(GeocodingService().usesNetwork == false)
    }

    @Test("Language token is read fresh from the store")
    func languageReadBack() {
        clearKeys()
        defer { clearKeys() }
        AppDefaults.store.set("nb", forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        #expect(GeocodingService.currentLanguage() == .language("nb"))
        AppDefaults.store.set("system", forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        #expect(GeocodingService.currentLanguage() == .system)
    }

    @Test("Offline engine resolves Oslo to an English city/country with no network")
    func offlineLookupOsloEnglish() async throws {
        clearKeys()
        defer { clearKeys() }
        AppDefaults.store.set(true, forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)
        AppDefaults.store.set("en", forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        let result = try await GeocodingService().reverseGeocode(latitude: 59.9139, longitude: 10.7522)
        #expect(result.city == "Oslo")
        #expect(result.country == "Norway")
    }

    @Test("Offline engine localizes the country via the chosen language (no network)")
    func offlineLookupOsloLocalized() async throws {
        clearKeys()
        defer { clearKeys() }
        AppDefaults.store.set(true, forKey: UserDefaultsKeys.reverseGeocodeOfflineEnabled)
        AppDefaults.store.set("nb", forKey: UserDefaultsKeys.reverseGeocodeLanguage)
        // Offline localizes the country from its ISO alpha-2 code ("NO" → "Norge"),
        // while GeoNames city names stay English ("Oslo").
        let result = try await GeocodingService().reverseGeocode(latitude: 59.9139, longitude: 10.7522)
        #expect(result.city == "Oslo")
        #expect(result.country == "Norge")
    }
}
