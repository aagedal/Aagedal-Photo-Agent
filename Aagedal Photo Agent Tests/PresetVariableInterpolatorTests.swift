import Testing
import Foundation
@testable import Aagedal_Photo_Agent

@Suite("PresetVariableInterpolator")
struct PresetVariableInterpolatorTests {
    private let interpolator = PresetVariableInterpolator()

    @Test("{initials} is replaced with the passed value")
    func initialsReplaced() {
        let result = interpolator.resolve("{initials}", initials: "TA")
        #expect(result == "TA")
    }

    @Test("{initials} resolves to empty string when unset")
    func initialsEmptyWhenUnset() {
        let result = interpolator.resolve("{initials}")
        #expect(result == "")
    }

    @Test("{initials} combines with a date format into a single keyword")
    func initialsWithDate() {
        let result = interpolator.resolve("{initials}{date:yyMMdd}", initials: "TA")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        let expected = "TA" + formatter.string(from: Date())
        #expect(result == expected)
    }

    @Test("Existing variables still resolve alongside {initials}")
    func existingVariablesUnaffected() {
        var metadata = IPTCMetadata()
        metadata.city = "Oslo"
        let result = interpolator.resolve("{initials}-{field:city}", existingMetadata: metadata, initials: "TA")
        #expect(result == "TA-Oslo")
    }

    @Test("Editorial role fields resolve by key and IPTC display alias")
    func editorialRoleFieldAliases() {
        let metadata = IPTCMetadata(
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk",
            countryCode: "NOR"
        )

        let result = interpolator.resolve(
            "{field:creatorJobTitle}|{field:Authors Position}|{field:descriptionWriter}|{field:Caption Writer}|{field:Country Code}",
            existingMetadata: metadata
        )

        #expect(result == "Staff Photographer|Staff Photographer|Night Desk|Night Desk|NOR")
    }

    @Test("Organisation shown fields resolve by key and display label")
    func organisationShownFieldAliases() {
        let metadata = IPTCMetadata(
            organisationsShownNames: ["Example News", "Example Sport"],
            organisationsShownCodes: ["EXNEWS", "EXSPORT"]
        )

        let result = interpolator.resolve(
            "{field:organisationShownName}|{field:Organisation Shown Code}",
            existingMetadata: metadata
        )

        #expect(result == "Example News, Example Sport|EXNEWS, EXSPORT")
    }

    @Test("Rights fields resolve by key and display label")
    func rightsFieldAliases() {
        let metadata = IPTCMetadata(
            rightsUsageTerms: "Editorial use only",
            webStatementOfRights: "https://example.test/rights"
        )

        let result = interpolator.resolve(
            "{field:Usage Terms}|{field:Web Statement of Rights}",
            existingMetadata: metadata
        )

        #expect(result == "Editorial use only|https://example.test/rights")
    }

    @Test("Urgency resolves by field key")
    func urgencyFieldAlias() {
        let metadata = IPTCMetadata(urgency: 2)
        #expect(interpolator.resolve("{field:urgency}", existingMetadata: metadata) == "2")
    }

    @Test("Scene Codes resolve by key and display label")
    func sceneCodeFieldAliases() {
        let metadata = IPTCMetadata(sceneCodes: ["011200", "012400"])
        #expect(interpolator.resolve(
            "{field:scene}|{field:Scene Code}",
            existingMetadata: metadata
        ) == "011200, 012400|011200, 012400")
    }

    @Test("Metadata dates support friendly compact and dashed aliases")
    func metadataDateAliases() {
        var metadata = IPTCMetadata()
        metadata.dateCreated = "2026:07:08"
        metadata.captureDate = "2026:07:08 14:30:45"

        let result = interpolator.resolve(
            "{dateCreated:YYYYMMDD}|{dateCreated:DDMMYYYY}|{dateCreated:YYYY-MM-DD}|{dateCreated:DD-MM-YYYY}|{dateCaptured:YYYYMMDD}|{dateCaptured:DDMMYYYY}|{dateCaptured:YYYY-MM-DD}|{dateCaptured:DD-MM-YYYY}",
            existingMetadata: metadata
        )

        #expect(result == "20260708|08072026|2026-07-08|08-07-2026|20260708|08072026|2026-07-08|08-07-2026")
    }

    @Test("{field:…} expands variables inside the referenced field")
    func fieldReferenceExpandsNestedVariable() {
        var metadata = IPTCMetadata()
        metadata.event = "{date:yyyy}"
        let result = interpolator.resolve("{field:event}", existingMetadata: metadata)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        #expect(result == formatter.string(from: Date()))
    }

    @Test("{field:…} chains through nested field references")
    func fieldReferenceChains() {
        var metadata = IPTCMetadata()
        metadata.title = "{field:city}"
        metadata.city = "Bergen"
        let result = interpolator.resolve("{field:title}", existingMetadata: metadata)
        #expect(result == "Bergen")
    }

    @Test("A {field:…} reference cycle terminates instead of looping")
    func fieldReferenceCycleTerminates() {
        var metadata = IPTCMetadata()
        metadata.title = "{field:event}"
        metadata.event = "{field:title}"
        // Must terminate; the cycle is broken and an unresolvable token remains.
        let result = interpolator.resolve("{field:title}", existingMetadata: metadata)
        #expect(result.contains("{field:"))
    }

    @Test("Sibling {field:…} references both resolve (cycle guard is per-chain)")
    func siblingFieldReferencesBothResolve() {
        var metadata = IPTCMetadata()
        metadata.city = "Oslo"
        let result = interpolator.resolve("{field:city}/{field:city}", existingMetadata: metadata)
        #expect(result == "Oslo/Oslo")
    }

    @Test("GPS shortcut variables resolve map coordinates")
    func gpsShortcutVariables() {
        let metadata = IPTCMetadata(latitude: 59.9139, longitude: 10.7522)
        let result = interpolator.resolve(
            "{gps}|{latitude}|{longitude}",
            existingMetadata: metadata
        )
        #expect(result == "59.913900, 10.752200|59.913900|10.752200")
    }

    @Test("GPS field references accept GPS-prefixed aliases")
    func gpsFieldReferences() {
        let metadata = IPTCMetadata(latitude: -33.8688, longitude: 151.2093)
        let result = interpolator.resolve(
            "{field:gps}|{field:GPS Latitude}|{field:gps_longitude}",
            existingMetadata: metadata
        )
        #expect(result == "-33.868800, 151.209300|-33.868800|151.209300")
    }

    @Test("GPS variables are empty when coordinates are unavailable")
    func gpsVariablesEmptyWithoutCoordinates() {
        let result = interpolator.resolve(
            "{gps}|{latitude}|{longitude}|{field:gps}",
            existingMetadata: IPTCMetadata()
        )
        #expect(result == "|||")
    }

    @Test("GPS place variables become empty when coordinates are unavailable")
    func gpsPlaceVariablesEmptyWithoutCoordinates() async {
        var metadata = IPTCMetadata()
        metadata.city = "{gps:city}"
        metadata.country = "{gps:country}"
        let result = await interpolator.resolvingGPSPlaceVariables(in: metadata)
        #expect(result.city == "")
        #expect(result.country == "")
    }
}
