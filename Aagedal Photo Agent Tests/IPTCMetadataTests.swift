import Testing
import Foundation
import Metal
@testable import Aagedal_Photo_Agent



@Suite("IPTCMetadata.toWriteFields")
struct ToWriteFieldsTests {

    @Test("empty metadata produces empty dict")
    func emptyMetadataProducesEmptyDict() {
        let metadata = IPTCMetadata()
        #expect(metadata.toWriteFields().isEmpty)
    }

    @Test("title maps to headline tag")
    func titleMapsToHeadline() {
        let metadata = IPTCMetadata(title: "My Photo")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.headline] == "My Photo")
    }

    @Test("description maps to XMP description tag")
    func descriptionMapsToDescription() {
        let metadata = IPTCMetadata(description: "A beautiful sunset")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.description] == "A beautiful sunset")
    }

    @Test("keywords joined with comma-space")
    func keywordsJoinedWithCommaSpace() {
        let metadata = IPTCMetadata(keywords: ["nature", "landscape", "sunset"])
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.subject] == "nature, landscape, sunset")
    }

    @Test("single keyword not joined")
    func singleKeywordNotJoined() {
        let metadata = IPTCMetadata(keywords: ["nature"])
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.subject] == "nature")
    }

    @Test("empty keywords not included")
    func emptyKeywordsNotIncluded() {
        let metadata = IPTCMetadata(keywords: [])
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.subject] == nil)
    }

    @Test("personShown maps to PersonInImage tag")
    func personShownMapsToPersonInImage() {
        let metadata = IPTCMetadata(personShown: ["Alice", "Bob"])
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.personInImage] == "Alice, Bob")
    }

    @Test("copyright maps to XMP rights tag")
    func copyrightMapsToRights() {
        let metadata = IPTCMetadata(copyright: "© 2026 Photographer")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.rights] == "© 2026 Photographer")
    }

    @Test("creator maps to XMP creator tag")
    func creatorMapsToCreator() {
        let metadata = IPTCMetadata(creator: "Jane Doe")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.creator] == "Jane Doe")
    }

    @Test("credit maps to credit tag")
    func creditMapsToCredit() {
        let metadata = IPTCMetadata(credit: "Wire Service")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.credit] == "Wire Service")
    }

    @Test("jobId maps to transmission reference tag")
    func jobIdMapsToTransmissionReference() {
        let metadata = IPTCMetadata(jobId: "JOB-001")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.transmissionReference] == "JOB-001")
    }

    @Test("city maps to city tag")
    func cityMapsToCity() {
        let metadata = IPTCMetadata(city: "Oslo")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.city] == "Oslo")
    }

    @Test("country maps to country tag")
    func countryMapsToCountry() {
        let metadata = IPTCMetadata(country: "Norway")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.country] == "Norway")
    }

    @Test("event maps to event tag")
    func eventMapsToEvent() {
        let metadata = IPTCMetadata(event: "World Cup 2026")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.event] == "World Cup 2026")
    }

    @Test("digitalSourceType maps to raw value")
    func digitalSourceTypeMapsToRawValue() {
        let metadata = IPTCMetadata(digitalSourceType: .digitalCapture)
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.digitalSourceType] == "digitalCapture")
    }

    @Test("northern GPS coordinates use N/E refs")
    func northernGPSCoordinatesUseNE() {
        let metadata = IPTCMetadata(latitude: 59.913, longitude: 10.752)
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.gpsLatitudeRef] == "N")
        #expect(fields[MetadataFieldKey.gpsLongitudeRef] == "E")
        #expect(fields[MetadataFieldKey.gpsLatitude] == "59.913")
        #expect(fields[MetadataFieldKey.gpsLongitude] == "10.752")
    }

    @Test("southern GPS coordinates use S/W refs with positive absolute value")
    func southernGPSCoordinatesUseSW() {
        let metadata = IPTCMetadata(latitude: -33.865, longitude: -70.649)
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.gpsLatitudeRef] == "S")
        #expect(fields[MetadataFieldKey.gpsLongitudeRef] == "W")
        #expect(fields[MetadataFieldKey.gpsLatitude] == "33.865")
        #expect(fields[MetadataFieldKey.gpsLongitude] == "70.649")
    }

    @Test("GPS only included when both lat and lon are set")
    func gpsRequiresBothCoordinates() {
        let onlyLat = IPTCMetadata(latitude: 59.913, longitude: nil)
        let onlyLon = IPTCMetadata(latitude: nil, longitude: 10.752)
        #expect(onlyLat.toWriteFields()[MetadataFieldKey.gpsLatitude] == nil)
        #expect(onlyLon.toWriteFields()[MetadataFieldKey.gpsLongitude] == nil)
    }

    @Test("rating not included in write fields (managed separately)")
    func ratingNotIncluded() {
        let metadata = IPTCMetadata(rating: 5)
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.rating] == nil)
    }

    @Test("label not included in write fields (managed separately)")
    func labelNotIncluded() {
        let metadata = IPTCMetadata(label: "Red")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.label] == nil)
    }
}

// MARK: - hasIPTCDifferences

@Suite("IPTCMetadata.hasIPTCDifferences")
struct HasIPTCDifferencesTests {

    @Test("identical metadata has no differences")
    func identicalHasNoDifferences() {
        let a = IPTCMetadata(title: "Test", keywords: ["a", "b"], creator: "Alice")
        #expect(a.hasIPTCDifferences(from: a) == false)
    }

    @Test("different title detected")
    func differentTitleDetected() {
        let a = IPTCMetadata(title: "Title A")
        let b = IPTCMetadata(title: "Title B")
        #expect(a.hasIPTCDifferences(from: b) == true)
    }

    @Test("different description detected")
    func differentDescriptionDetected() {
        let a = IPTCMetadata(description: "Desc A")
        let b = IPTCMetadata(description: "Desc B")
        #expect(a.hasIPTCDifferences(from: b) == true)
    }

    @Test("different keywords detected")
    func differentKeywordsDetected() {
        let a = IPTCMetadata(keywords: ["cat"])
        let b = IPTCMetadata(keywords: ["dog"])
        #expect(a.hasIPTCDifferences(from: b) == true)
    }

    @Test("different persons detected")
    func differentPersonsDetected() {
        let a = IPTCMetadata(personShown: ["Alice"])
        let b = IPTCMetadata(personShown: ["Bob"])
        #expect(a.hasIPTCDifferences(from: b) == true)
    }

    @Test("rating difference alone not detected by hasIPTCDifferences")
    func ratingDifferenceNotDetected() {
        let a = IPTCMetadata(rating: 3)
        let b = IPTCMetadata(rating: 5)
        #expect(a.hasIPTCDifferences(from: b) == false)
    }

    @Test("label difference alone not detected by hasIPTCDifferences")
    func labelDifferenceNotDetected() {
        let a = IPTCMetadata(label: "Red")
        let b = IPTCMetadata(label: "Blue")
        #expect(a.hasIPTCDifferences(from: b) == false)
    }

    @Test("nil vs nil title has no difference")
    func nilVsNilTitleNoDifference() {
        let a = IPTCMetadata(title: nil)
        let b = IPTCMetadata(title: nil)
        #expect(a.hasIPTCDifferences(from: b) == false)
    }
}

// MARK: - merged

@Suite("IPTCMetadata.merged")
struct MergedTests {

    @Test("override non-empty title wins")
    func overrideTitleWins() {
        let base = IPTCMetadata(title: "Base Title")
        let override = IPTCMetadata(title: "Override Title")
        let result = base.merged(preferring: override)
        #expect(result.title == "Override Title")
    }

    @Test("base title kept when override is nil")
    func baseTitleKeptWhenOverrideNil() {
        let base = IPTCMetadata(title: "Base Title")
        let override = IPTCMetadata(title: nil)
        let result = base.merged(preferring: override)
        #expect(result.title == "Base Title")
    }

    @Test("base title kept when override is empty string")
    func baseTitleKeptWhenOverrideEmpty() {
        let base = IPTCMetadata(title: "Base Title")
        let override = IPTCMetadata(title: "")
        let result = base.merged(preferring: override)
        #expect(result.title == "Base Title")
    }

    @Test("override keywords win when non-empty")
    func overrideKeywordsWin() {
        let base = IPTCMetadata(keywords: ["nature"])
        let override = IPTCMetadata(keywords: ["city", "travel"])
        let result = base.merged(preferring: override)
        #expect(result.keywords == ["city", "travel"])
    }

    @Test("base keywords kept when override empty")
    func baseKeywordsKeptWhenOverrideEmpty() {
        let base = IPTCMetadata(keywords: ["nature"])
        let override = IPTCMetadata(keywords: [])
        let result = base.merged(preferring: override)
        #expect(result.keywords == ["nature"])
    }

    @Test("override rating wins when set")
    func overrideRatingWins() {
        let base = IPTCMetadata(rating: 3)
        let override = IPTCMetadata(rating: 5)
        let result = base.merged(preferring: override)
        #expect(result.rating == 5)
    }

    @Test("base rating kept when override is nil")
    func baseRatingKeptWhenOverrideNil() {
        let base = IPTCMetadata(rating: 3)
        let override = IPTCMetadata(rating: nil)
        let result = base.merged(preferring: override)
        #expect(result.rating == 3)
    }

    @Test("merging two empty metadata produces empty")
    func mergingEmptyProducesEmpty() {
        let base = IPTCMetadata()
        let override = IPTCMetadata()
        let result = base.merged(preferring: override)
        #expect(result.title == nil)
        #expect(result.keywords.isEmpty)
        #expect(result.rating == nil)
    }

    @Test("GPS coordinates merged when override has both")
    func gpsCoordinatesMerged() {
        let base = IPTCMetadata(latitude: 1.0, longitude: 2.0)
        let override = IPTCMetadata(latitude: 59.913, longitude: 10.752)
        let result = base.merged(preferring: override)
        #expect(result.latitude == 59.913)
        #expect(result.longitude == 10.752)
    }

    @Test("digitalSourceType merged from override")
    func digitalSourceTypeMerged() {
        let base = IPTCMetadata(digitalSourceType: .digitalCapture)
        let override = IPTCMetadata(digitalSourceType: .trainedAlgorithmicMedia)
        let result = base.merged(preferring: override)
        #expect(result.digitalSourceType == .trainedAlgorithmicMedia)
    }
}

// MARK: - descriptive record (Photo Mechanic semantics)

@Suite("IPTCMetadata descriptive record")
struct DescriptiveRecordTests {

    @Test("hasDescriptiveContent is false for empty, GPS-only, rating-only, and CRS-only metadata")
    func noDescriptiveContent() {
        #expect(!IPTCMetadata().hasDescriptiveContent)
        #expect(!IPTCMetadata(latitude: 59.9, longitude: 10.7).hasDescriptiveContent)
        #expect(!IPTCMetadata(rating: 5).hasDescriptiveContent)
        var crs = CameraRawSettings()
        crs.exposure2012 = 0.5
        var crsOnly = IPTCMetadata()
        crsOnly.cameraRaw = crs
        #expect(!crsOnly.hasDescriptiveContent)
    }

    @Test("hasDescriptiveContent is true for any descriptive field")
    func descriptiveContent() {
        #expect(IPTCMetadata(title: "T").hasDescriptiveContent)
        #expect(IPTCMetadata(keywords: ["k"]).hasDescriptiveContent)
        #expect(IPTCMetadata(personShown: ["P"]).hasDescriptiveContent)
        #expect(IPTCMetadata(creator: "C").hasDescriptiveContent)
        #expect(IPTCMetadata(city: "Oslo").hasDescriptiveContent)
        #expect(!IPTCMetadata(title: "").hasDescriptiveContent)
    }

    @Test("replacingDescriptiveFields: a field absent from the record stays cleared")
    func clearsStick() {
        let embedded = IPTCMetadata(title: "Old title",
                                    description: "Old caption",
                                    keywords: ["old1", "old2"],
                                    creator: "Old creator")
        // The record keeps the creator but the user cleared title/caption/keywords.
        let record = IPTCMetadata(creator: "Old creator")
        let result = embedded.replacingDescriptiveFields(from: record)
        #expect(result.title == nil)
        #expect(result.description == nil)
        #expect(result.keywords.isEmpty)
        #expect(result.creator == "Old creator")
    }

    @Test("replacingDescriptiveFields keeps GPS, rating, and label additive")
    func nonDescriptiveStaysAdditive() {
        let embedded = IPTCMetadata(latitude: 59.9, longitude: 10.7, rating: 3)
        let record = IPTCMetadata(title: "New title")
        let result = embedded.replacingDescriptiveFields(from: record)
        #expect(result.title == "New title")
        #expect(result.rating == 3)
        #expect(result.latitude == 59.9)
        #expect(result.longitude == 10.7)

        let recordWithRating = IPTCMetadata(title: "T", rating: 5)
        #expect(embedded.replacingDescriptiveFields(from: recordWithRating).rating == 5)
    }

    @Test("replacingDescriptiveFields differs from merged for cleared fields")
    func contrastWithMerged() {
        let embedded = IPTCMetadata(title: "Resurrected?")
        let record = IPTCMetadata(keywords: ["kept"])
        // merged() lets the embedded title show through the record's empty field…
        #expect(embedded.merged(preferring: record).title == "Resurrected?")
        // …the record read does not: the clear sticks.
        #expect(embedded.replacingDescriptiveFields(from: record).title == nil)
    }
}

// MARK: - Codable

@Suite("IPTCMetadata Codable")
struct IPTCMetadataCodableTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()

    @Test("all IPTC fields survive encode/decode roundtrip")
    func allFieldsRoundtrip() throws {
        let original = IPTCMetadata(
            title: "Test Title",
            description: "A description",
            extendedDescription: "Extended",
            keywords: ["kw1", "kw2"],
            personShown: ["Alice"],
            digitalSourceType: .digitalCapture,
            latitude: 59.913,
            longitude: 10.752,
            creator: "Creator Name",
            credit: "Credit Line",
            copyright: "© 2026",
            jobId: "JOB123",
            dateCreated: "2026-01-01",
            captureDate: "2026-01-01T12:00:00",
            city: "Oslo",
            country: "Norway",
            event: "Test Event",
            rating: 4,
            label: "Red"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(IPTCMetadata.self, from: data)

        #expect(decoded.title == "Test Title")
        #expect(decoded.description == "A description")
        #expect(decoded.extendedDescription == "Extended")
        #expect(decoded.keywords == ["kw1", "kw2"])
        #expect(decoded.personShown == ["Alice"])
        #expect(decoded.digitalSourceType == .digitalCapture)
        #expect(decoded.latitude == 59.913)
        #expect(decoded.longitude == 10.752)
        #expect(decoded.creator == "Creator Name")
        #expect(decoded.credit == "Credit Line")
        #expect(decoded.copyright == "© 2026")
        #expect(decoded.jobId == "JOB123")
        #expect(decoded.dateCreated == "2026-01-01")
        #expect(decoded.captureDate == "2026-01-01T12:00:00")
        #expect(decoded.city == "Oslo")
        #expect(decoded.country == "Norway")
        #expect(decoded.event == "Test Event")
        #expect(decoded.rating == 4)
        #expect(decoded.label == "Red")
    }

    @Test("cameraRaw excluded from JSON serialization")
    func cameraRawExcludedFromJSON() throws {
        var crs = CameraRawSettings()
        crs.exposure2012 = 1.5
        crs.temperature = 5500
        let metadata = IPTCMetadata(cameraRaw: crs)
        let data = try encoder.encode(metadata)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(!jsonString.contains("cameraRaw"))
        #expect(!jsonString.contains("exposure"))
        #expect(!jsonString.contains("temperature"))
    }

    @Test("exifOrientation excluded from JSON serialization")
    func exifOrientationExcludedFromJSON() throws {
        let metadata = IPTCMetadata(exifOrientation: 6)
        let data = try encoder.encode(metadata)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(!jsonString.contains("exifOrientation"))
    }

    @Test("cameraRaw is nil after decoding (sourced from XMP only)")
    func cameraRawNilAfterDecode() throws {
        let original = IPTCMetadata(cameraRaw: CameraRawSettings())
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(IPTCMetadata.self, from: data)
        #expect(decoded.cameraRaw == nil)
    }

    @Test("duplicate keywords deduplicated on decode")
    func duplicateKeywordsDeduplicated() throws {
        let json = """
        {"keywords": ["nature", "travel", "nature", "city", "travel"]}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(IPTCMetadata.self, from: json)
        #expect(decoded.keywords == ["nature", "travel", "city"])
    }

    @Test("duplicate personShown deduplicated on decode")
    func duplicatePersonsDeduplicated() throws {
        let json = """
        {"keywords": [], "personShown": ["Alice", "Bob", "Alice"]}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(IPTCMetadata.self, from: json)
        #expect(decoded.personShown.count == 2)
        #expect(decoded.personShown.contains("Alice"))
        #expect(decoded.personShown.contains("Bob"))
    }

    @Test("missing optional fields decode to nil/empty")
    func missingOptionalFieldsDecodeToNilOrEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(IPTCMetadata.self, from: json)
        #expect(decoded.title == nil)
        #expect(decoded.keywords.isEmpty)
        #expect(decoded.personShown.isEmpty)
        #expect(decoded.rating == nil)
    }
}

// MARK: - FieldKey

@Suite("IPTCMetadata.FieldKey")
struct FieldKeyTests {

    @Test("isEmpty returns true for nil string fields")
    func isEmptyForNilStringFields() {
        let metadata = IPTCMetadata()
        #expect(IPTCMetadata.FieldKey.title.isEmpty(in: metadata))
        #expect(IPTCMetadata.FieldKey.description.isEmpty(in: metadata))
        #expect(IPTCMetadata.FieldKey.creator.isEmpty(in: metadata))
        #expect(IPTCMetadata.FieldKey.copyright.isEmpty(in: metadata))
    }

    @Test("isEmpty returns false when fields have values")
    func isEmptyFalseWhenFieldsHaveValues() {
        let metadata = IPTCMetadata(
            title: "T", description: "D", keywords: ["k"],
            creator: "C", copyright: "©"
        )
        #expect(IPTCMetadata.FieldKey.title.isEmpty(in: metadata) == false)
        #expect(IPTCMetadata.FieldKey.keywords.isEmpty(in: metadata) == false)
    }

    @Test("isEmpty true for empty string")
    func isEmptyTrueForEmptyString() {
        let metadata = IPTCMetadata(title: "")
        #expect(IPTCMetadata.FieldKey.title.isEmpty(in: metadata))
    }

    @Test("defaultCheckedFields contains expected fields")
    func defaultCheckedFieldsContainExpectedFields() {
        let defaults = IPTCMetadata.FieldKey.defaultCheckedFields
        #expect(defaults.contains(.title))
        #expect(defaults.contains(.description))
        #expect(defaults.contains(.creator))
        #expect(defaults.contains(.copyright))
    }
}

/// Regression tests for crashes triggered by malformed numeric metadata fields.
/// A corrupt EXIF exposure time of `0/n` (→ 0.0) or an `inf`/`nan` value used to
/// trap in `Int(_:)` when building the technical-metadata inspector or parsing
/// Camera-Raw mask corrections, crashing the app on opening an arbitrary file.
@Suite("Malformed metadata numeric parsing")
struct MalformedMetadataNumericTests {

    // MARK: TechnicalMetadata shutter speed / ISO

    @Test("zero exposure time does not crash and yields no shutter speed")
    func zeroExposureTimeIsSafe() {
        let meta = TechnicalMetadata(from: ["ExposureTime": 0.0])
        #expect(meta.shutterSpeed == nil)
    }

    @Test("non-finite exposure times do not crash")
    func nonFiniteExposureTimesAreSafe() {
        #expect(TechnicalMetadata(from: ["ExposureTime": Double.infinity]).shutterSpeed == nil)
        #expect(TechnicalMetadata(from: ["ExposureTime": Double.nan]).shutterSpeed == nil)
        #expect(TechnicalMetadata(from: ["ExposureTime": -0.01]).shutterSpeed == nil)
        // Subnormal would overflow 1/et to infinity — must not trap.
        #expect(TechnicalMetadata(from: ["ExposureTime": Double.leastNonzeroMagnitude]).shutterSpeed == nil)
    }

    @Test("valid exposure times still format correctly")
    func validExposureTimesFormat() {
        #expect(TechnicalMetadata(from: ["ExposureTime": 0.005]).shutterSpeed == "1/200 s")
        #expect(TechnicalMetadata(from: ["ExposureTime": 2.0]).shutterSpeed == "2.0 s")
    }

    @Test("non-finite ISO does not crash")
    func nonFiniteISOIsSafe() {
        #expect(TechnicalMetadata(from: ["ISO": Double.infinity]).iso == nil)
        #expect(TechnicalMetadata(from: ["ISO": Double.nan]).iso == nil)
        #expect(TechnicalMetadata(from: ["ISO": 800.0]).iso == "800")
        #expect(TechnicalMetadata(from: ["ISO": 100]).iso == "100")
    }

    // MARK: safeInt helper

    @Test("safeInt rejects non-finite and out-of-range values")
    func safeIntGuards() {
        #expect(safeInt(.infinity) == nil)
        #expect(safeInt(-.infinity) == nil)
        #expect(safeInt(.nan) == nil)
        #expect(safeInt(1e308) == nil)
        // safeInt truncates toward zero like Int(_:); callers round beforehand.
        #expect(safeInt(42.7) == 42)
        #expect(safeInt(-3.2) == -3)
    }

    // MARK: parseIntValue (shared helper; also used by the browser metadata path)

    @Test("parseIntValue guards non-finite and out-of-range Doubles")
    func parseIntValueGuardsDoubles() {
        // A crafted/corrupt metadata value of inf/nan/overflow must not trap Int(_:).
        // (Regression: a stale BrowserViewModel copy did an unguarded Int(doubleValue).)
        #expect(parseIntValue(Double.infinity) == nil)
        #expect(parseIntValue(-Double.infinity) == nil)
        #expect(parseIntValue(Double.nan) == nil)
        #expect(parseIntValue(1e308) == nil)
        // Valid values still parse across the supported representations.
        #expect(parseIntValue(42) == 42)
        #expect(parseIntValue(42.7) == 42)
        #expect(parseIntValue("17") == 17)
        #expect(parseIntValue("  9 ") == 9)
        #expect(parseIntValue(nil) == nil)
    }

    // MARK: Camera-Raw mask correction percentages

    @Test("parsePercentInt guards non-finite, scales valid values")
    func parsePercentIntGuards() {
        #expect(parsePercentInt("inf") == nil)
        #expect(parsePercentInt("nan") == nil)
        #expect(parsePercentInt("1e400") == nil)
        #expect(parsePercentInt(nil) == nil)
        #expect(parsePercentInt(0.25) == 25)
        #expect(parsePercentInt("0.5") == 50)
    }

    @Test("mask corrections with non-finite local adjustments do not crash")
    func maskCorrectionsWithNonFiniteAreSafe() {
        let corrections: [[String: Any]] = [[
            "CorrectionActive": true,
            "CorrectionAmount": 1.0,
            "LocalContrast2012": "inf",
            "LocalHighlights2012": "nan",
            "LocalShadows2012": 0.3,
            "CorrectionMasks": [[
                "What": "Mask/CircularGradient",
                "Top": 0.0, "Left": 0.0, "Bottom": 1.0, "Right": 1.0
            ]]
        ]]
        let masks = parseMaskGroupBasedCorrections(corrections)
        #expect(masks?.masks.count == 1)
    }

    /// SwiftExif keys structured XMP fields as `<namespaceURI><Property>`
    /// (`http://ns.adobe.com/camera-raw-settings/1.0/Top`), not the bare name.
    /// The parser used to look up only bare keys, so every mask read back from
    /// disk silently fell back to the DEFAULT geometry — the "mask turns into a
    /// generic ellipse after reopening the edit view" bug.
    @Test("mask corrections parse SwiftExif's namespace-URI-prefixed field keys")
    func maskCorrectionsParseURIPrefixedKeys() throws {
        let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let corrections: [[String: Any]] = [[
            "\(crs)CorrectionActive": "true",
            "\(crs)CorrectionAmount": "0.75",
            "\(crs)CorrectionName": "Sky",
            "\(crs)LocalExposure2012": "0.25",
            "\(crs)LocalContrast2012": "0.3",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/CircularGradient",
                "\(crs)Top": "0.3", "\(crs)Left": "0.35",
                "\(crs)Bottom": "0.5", "\(crs)Right": "0.85",
                "\(crs)Angle": "12.5", "\(crs)Feather": "40",
                "\(crs)Flipped": "false"
            ]]
        ]]
        let mask = try #require(parseMaskGroupBasedCorrections(corrections)?.masks.first)
        #expect(mask.name == "Sky")
        #expect(mask.amount == 0.75)
        #expect(abs(mask.geometry.centerX - 0.6) < 1e-9)
        #expect(abs(mask.geometry.centerY - 0.4) < 1e-9)
        #expect(abs(mask.geometry.radiusX - 0.25) < 1e-9)
        #expect(abs(mask.geometry.radiusY - 0.1) < 1e-9)
        #expect(mask.geometry.rotation == 12.5)
        #expect(mask.geometry.feather == 40)
        #expect(mask.inverted == true)
        #expect(mask.exposure.map { abs($0 - 1.0) < 1e-9 } == true)
        #expect(mask.contrast == 30)
    }

    /// Values lifted verbatim from a real ACR-authored mask (crs:LocalTemperature="0.2",
    /// crs:LocalTint="-0.12") to anchor the scale conversion against real-world data, not
    /// just hand-picked round numbers.
    @Test("mask Local Temperature/Tint parse and round-trip at ACR's real-world scale")
    func maskTemperatureTintRoundTrip() throws {
        let corrections: [[String: Any]] = [[
            "CorrectionActive": "true",
            "LocalTemperature": "0.2",
            "LocalTint": "-0.12",
            "CorrectionMasks": [[
                "What": "Mask/CircularGradient",
                "Top": "0.1", "Left": "0.1", "Bottom": "0.4", "Right": "0.4"
            ]]
        ]]
        let mask = try #require(parseMaskGroupBasedCorrections(corrections)?.masks.first)
        #expect(mask.temperature.map { abs($0 - 20) < 1e-9 } == true)
        #expect(mask.tint.map { abs($0 - (-12)) < 1e-9 } == true)

        let encoded = try #require(encodeMaskGroupBasedCorrections([mask]).first)
        #expect(encoded.correctionFields.contains { $0.name == "LocalTemperature" && $0.value == "0.2" })
        #expect(encoded.correctionFields.contains { $0.name == "LocalTint" && $0.value == "-0.12" })
    }

    /// A correction whose mask geometry can't be parsed (unsupported type or missing corner
    /// fields) must NOT be substituted with the default ellipse (which silently misrenders) —
    /// and, unlike before, it must be PRESERVED verbatim rather than dropped, so a develop save
    /// re-emits it instead of permanently deleting it.
    @Test("corrections with unparseable mask geometry are preserved verbatim, not defaulted")
    func unparseableMaskGeometryIsPreserved() {
        // Unsupported mask type (bare Mask/Paint, no Aggregate) alongside a valid radial mask
        // and a radial mask with a missing corner.
        let corrections: [[String: Any]] = [
            [
                "CorrectionActive": true,
                "CorrectionMasks": [["What": "Mask/Paint"]]
            ],
            [
                "CorrectionActive": true,
                "CorrectionMasks": [[
                    "What": "Mask/CircularGradient",
                    "Top": 0.1, "Left": 0.2, "Bottom": 0.5, "Right": 0.6
                ]]
            ],
            [
                // Radial mask with a missing corner — geometry incomplete.
                "CorrectionActive": true,
                "CorrectionMasks": [[
                    "What": "Mask/CircularGradient",
                    "Top": 0.1, "Left": 0.2, "Bottom": 0.5
                ]]
            ]
        ]
        let parsed = parseMaskGroupBasedCorrections(corrections)
        #expect(parsed?.masks.count == 1)
        #expect(parsed?.masks.first.map { abs($0.geometry.centerX - 0.4) < 1e-9 } == true)
        // The two unparseable corrections are kept, not lost.
        #expect(parsed?.preserved.count == 2)

        // All corrections unparseable → no modeled masks, but they're still preserved
        // (not silently dropped like before).
        let allBad: [[String: Any]] = [["CorrectionMasks": [["What": "Mask/Paint"]]]]
        let allBadParsed = parseMaskGroupBasedCorrections(allBad)
        #expect(allBadParsed?.masks.isEmpty == true)
        #expect(allBadParsed?.preserved.count == 1)
    }

    /// Gates whether a metadata save touches the file's crs block at all —
    /// a caption-only save on an ACR-edited file must not rewrite (and, with
    /// replaceCameraRawBlock, wipe) Adobe's develop settings.
    @Test("developSettingsChanged ignores render-time fields, detects real edits")
    func developSettingsChangedGating() {
        var a = CameraRawSettings()
        a.exposure2012 = 0.5
        a.contrast2012 = 18

        // Identical snapshots differing only in render-time-only fields → unchanged.
        var b = a
        b.asShotNeutralTemperature = 5204
        b.asShotNeutralTint = 11
        b.sourceHasHDRHeadroom = true
        #expect(MetadataViewModel.developSettingsChanged(a, b) == false)

        // A real slider change → changed.
        b.exposure2012 = 0.75
        #expect(MetadataViewModel.developSettingsChanged(a, b) == true)

        // nil vs nil → unchanged; nil vs settings (reset / first edit) → changed.
        #expect(MetadataViewModel.developSettingsChanged(nil, nil) == false)
        #expect(MetadataViewModel.developSettingsChanged(a, nil) == true)
        #expect(MetadataViewModel.developSettingsChanged(nil, a) == true)

        // Mask edits count as develop changes.
        var c = a
        c.localAdjustments = [MaskAdjustment(name: "Sky")]
        #expect(MetadataViewModel.developSettingsChanged(a, c) == true)
    }

    // MARK: Tone-curve serialization

    @Test("serializing a tone curve with non-finite points does not crash and clamps to 0...255")
    func serializeToneCurveNonFiniteIsSafe() {
        // A corrupt sidecar parsed to non-finite x/y used to trap `Int(round(...))`
        // on re-serialization, crashing on save. Clamp instead of trapping.
        let points = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: .infinity, y: -.infinity),
            ToneCurvePoint(x: .nan, y: .nan),
            ToneCurvePoint(x: 2.0, y: -1.0),
            ToneCurvePoint(x: 1, y: 1),
        ]
        let strings = serializeToneCurvePoints(points)
        #expect(strings == ["0, 0", "255, 0", "0, 0", "255, 0", "255, 255"])
    }

    @Test("serializing valid normalized tone-curve points scales to the 0–255 ACR grid")
    func serializeToneCurveValidScales() {
        let strings = serializeToneCurvePoints([
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.25),
            ToneCurvePoint(x: 1, y: 1),
        ])
        #expect(strings == ["0, 0", "128, 64", "255, 255"])
    }

    @Test("ToneCurvePoint(acr255:) clamps non-finite/out-of-range input to 0...1")
    func toneCurvePointACR255Clamps() {
        #expect(ToneCurvePoint(acr255: .infinity, .infinity) == ToneCurvePoint(x: 1, y: 1))
        #expect(ToneCurvePoint(acr255: -.infinity, .nan) == ToneCurvePoint(x: 0, y: 0))
        #expect(ToneCurvePoint(acr255: 510, -255) == ToneCurvePoint(x: 1, y: 0))
        #expect(ToneCurvePoint(acr255: 128, 64) == ToneCurvePoint(x: 128.0 / 255, y: 64.0 / 255))
    }

    @Test("parsing then re-serializing a corrupt tone curve does not crash")
    func parseThenSerializeCorruptToneCurveIsSafe() throws {
        // Mirrors the reported crash: load a sidecar with inf/nan coordinates,
        // then re-save. Parsing sanitizes at the boundary, serialization clamps.
        let parsed = parseToneCurveArray(["inf, nan", "0, 0", "255, 255", "nan, inf"])
        let points = try #require(parsed)
        // No non-finite coordinate survives the parse boundary.
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let strings = serializeToneCurvePoints(points)
        #expect(strings.count == points.count)
    }
}

@Suite("MetadataWriteMode preset resolution", .serialized)
struct MetadataWriteModePresetTests {
    /// Runs `body` with the given preset set, restoring the previous value after.
    private func withPreset(_ preset: MetadataWritePreset, _ body: () -> Void) {
        let key = UserDefaultsKeys.metadataWritePreset
        let saved = AppDefaults.store.string(forKey: key)
        AppDefaults.store.set(preset.rawValue, forKey: key)
        defer {
            if let saved { AppDefaults.store.set(saved, forKey: key) }
            else { AppDefaults.store.removeObject(forKey: key) }
        }
        body()
    }

    @Test("Simple embeds for every file incl. C2PA, except RAW which uses an XMP sidecar")
    func simple() {
        withPreset(.simple) {
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: false) == .writeToFile)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: false) == .writeToFile)
            // RAW never embeds (embedding corrupts maker-private data) — always a sidecar.
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: true) == .writeToXMPSidecar)
        }
    }

    @Test("Professional: sidecar for RAW/C2PA, embed for plain files (Photo Mechanic)")
    func professional() {
        withPreset(.professional) {
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: false) == .writeToFile)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: false) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: true) == .writeToXMPSidecar)
        }
    }

    @Test("Custom RAW picker drives RAW resolution")
    func customRaw() {
        withPreset(.custom) {
            let key = UserDefaultsKeys.metadataWriteModeRaw
            let saved = AppDefaults.store.string(forKey: key)
            AppDefaults.store.set(MetadataWriteMode.writeToFile.rawValue, forKey: key)
            defer {
                if let saved { AppDefaults.store.set(saved, forKey: key) }
                else { AppDefaults.store.removeObject(forKey: key) }
            }
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToFile)
        }
    }

    @Test("dual-write mode reports both embedded and sidecar")
    func flags() {
        #expect(MetadataWriteMode.writeToFileAndXMPSidecar.writesEmbedded)
        #expect(MetadataWriteMode.writeToFileAndXMPSidecar.writesXMPSidecar)
        #expect(MetadataWriteMode.writeToFile.writesEmbedded)
        #expect(!MetadataWriteMode.writeToFile.writesXMPSidecar)
        #expect(MetadataWriteMode.writeToXMPSidecar.writesXMPSidecar)
        #expect(!MetadataWriteMode.writeToXMPSidecar.writesEmbedded)
    }

    @Test("Custom never routes C2PA to a file-writing mode")
    func customC2PASafety() {
        withPreset(.custom) {
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: false).writesEmbedded == false)
        }
    }
}

// MARK: - Crop rotation geometry

/// Regression coverage for the crop straighten geometry. The stored `NormalizedCropRegion`
/// is the *upright* crop rectangle, so the visible crop aspect ratio is `(width·ar)/height`
/// and must stay constant as the straighten angle changes. A prior rotated-AABB encoding
/// drifted the aspect ratio and collapsed catastrophically near `angle = -atan(h/w)`.
@MainActor
@Suite("NormalizedCropRegion rotation geometry")
struct CropRotationGeometryTests {
    /// Image aspect ratio (3:2 landscape) used throughout.
    let ar = 1.5

    /// Visible crop aspect ratio = (width · imageAR) / height.
    func visibleAspect(_ r: NormalizedCropRegion) -> Double {
        (r.width * ar) / r.height
    }

    /// Replicates the editor's angle-change pipeline (updateCropAngle / onAngleChange).
    func rotated(_ r: NormalizedCropRegion, to angle: Double) -> NormalizedCropRegion {
        r.centerClampedForRotation(angleDegrees: angle, aspectRatio: ar)
         .fittingRotated(angleDegrees: angle, aspectRatio: ar)
    }

    /// A full-frame "Original"-locked crop: square in normalized coords (visible aspect == ar).
    var originalLockedCrop: NormalizedCropRegion {
        NormalizedCropRegion.full.resizedToActualAspectRatio(ar, imageAspectRatio: ar)
    }

    @Test("Original-locked aspect is preserved across the full angle range")
    func originalAspectPreservedAcrossAngles() {
        let start = originalLockedCrop
        #expect(abs(visibleAspect(start) - ar) < 0.001)
        for angle in stride(from: -45.0, through: 45.0, by: 1.5) {
            let r = rotated(start, to: angle)
            #expect(abs(visibleAspect(r) - ar) < 0.01,
                    "aspect drifted to \(visibleAspect(r)) at \(angle)°")
        }
    }

    @Test("Reported singular angle (-32.87°) does not collapse the crop")
    func singularAngleDoesNotCollapse() {
        let r = rotated(originalLockedCrop, to: -32.87)
        #expect(abs(visibleAspect(r) - ar) < 0.01)
        // Must remain a substantial, non-degenerate rectangle (no near-zero dimension).
        #expect(r.width > 0.2)
        #expect(r.height > 0.2)
    }

    @Test("A locked non-Original ratio is preserved across rotation")
    func lockedRatioPreservedAcrossRotation() {
        // 16:9 locked crop.
        let target = 16.0 / 9.0
        let start = NormalizedCropRegion.full.resizedToActualAspectRatio(target, imageAspectRatio: ar)
        #expect(abs(visibleAspect(start) - target) < 0.001)
        for angle in [-40.0, -20.0, -5.0, 10.0, 30.0, 44.0] {
            let r = rotated(start, to: angle)
            #expect(abs(visibleAspect(r) - target) < 0.01,
                    "16:9 drifted to \(visibleAspect(r)) at \(angle)°")
        }
    }

    @Test("fittingRotated scales uniformly (preserves aspect) and keeps the crop in bounds")
    func fittingRotatedIsUniform() {
        // Off-center, non-square crop.
        let crop = NormalizedCropRegion(top: 0.1, left: 0.1, bottom: 0.7, right: 0.9)
        let before = crop.width / crop.height
        let fitted = crop.fittingRotated(angleDegrees: 25, aspectRatio: ar)
        #expect(abs(fitted.width / fitted.height - before) < 0.001)
        // All four straightened corners stay within [0,1]².
        let rad = 25.0 * Double.pi / 180.0
        let cosA = cos(rad), sinA = sin(rad)
        let px = fitted.width * 0.5 * ar, py = fitted.height * 0.5
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let nx = (sx * px * cosA - sy * py * sinA) / ar + fitted.centerX
            let ny = (sx * px * sinA + sy * py * cosA) + fitted.centerY
            #expect(nx >= -0.001 && nx <= 1.001, "corner x \(nx) out of bounds")
            #expect(ny >= -0.001 && ny <= 1.001, "corner y \(ny) out of bounds")
        }
    }
}

// MARK: - ACR crop XMP boundary conversion

/// Adobe's crs:CropLeft/Top/Right/Bottom are two opposite corners of the crop's
/// footprint in the UN-ROTATED original frame (same corner model as the radial
/// masks); the app stores the upright actual rect. `decodedFromACR`/`encodedForACR`
/// convert at the XMP boundary. Ground truth: Camera Raw 18.3.2 rendering of the
/// 2026-06-12 repro file (7008×4672, CropAngle −12.786738) — ACR's render aspect
/// 0.9498 matches the corner decode to 4 decimals.
@Suite("CameraRawCrop ACR boundary conversion")
struct CameraRawCropACRConversionTests {
    /// The repro file's stored crs values, written in the app's old (upright-rect)
    /// convention. Decoding them under Adobe's corner model must give the rect
    /// ACR actually renders: 4415.2 × 4648.9 px around the same center.
    @Test("repro-file values decode to ACR's rendered rect")
    func reproFileDecode() {
        let aspect = 7008.0 / 4672.0
        let stored = CameraRawCrop(
            top: 0.116878, left: 0.046737,
            bottom: 0.878094, right: 0.807953,
            angle: -12.786738, hasCrop: true
        )
        let decoded = stored.decodedFromACR(aspect: aspect)

        // Center is the corner midpoint in both conventions — unchanged.
        #expect(abs((decoded.left! + decoded.right!) / 2 - 0.427345) < 1e-9)
        #expect(abs((decoded.top! + decoded.bottom!) / 2 - 0.497486) < 1e-9)
        // Dims = the corner diagonal rotated by −CropAngle in pixel space.
        let widthPX = (decoded.right! - decoded.left!) * 7008
        let heightPX = (decoded.bottom! - decoded.top!) * 4672
        #expect(abs(widthPX - 4415.194) < 0.01)
        #expect(abs(heightPX - 4648.873) < 0.01)
        // ACR 18.3.2 rendered this crop at aspect 0.9498 (it auto-shrinks
        // out-of-bounds crops uniformly, preserving aspect).
        #expect(abs(widthPX / heightPX - 0.9497) < 0.001)
        // Angle and flags pass through untouched.
        #expect(decoded.angle == stored.angle)
        #expect(decoded.hasCrop == true)
    }

    @Test("encode is the exact inverse of decode", arguments: [-44.0, -12.786738, -0.5, 7.25, 44.9])
    func encodeDecodeRoundTrip(angle: Double) {
        for aspect in [1.5, 2.0 / 3.0, 1.0] {
            let internalCrop = CameraRawCrop(
                top: 0.21, left: 0.13, bottom: 0.78, right: 0.69,
                angle: angle, hasCrop: true
            )
            let roundTripped = internalCrop.encodedForACR(aspect: aspect).decodedFromACR(aspect: aspect)
            #expect(abs(roundTripped.top! - internalCrop.top!) < 1e-12)
            #expect(abs(roundTripped.left! - internalCrop.left!) < 1e-12)
            #expect(abs(roundTripped.bottom! - internalCrop.bottom!) < 1e-12)
            #expect(abs(roundTripped.right! - internalCrop.right!) < 1e-12)
        }
    }

    @Test("conversion is the identity at angle 0 and for missing angle")
    func identityAtZeroAngle() {
        let straight = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: 0, hasCrop: true)
        #expect(straight.decodedFromACR(aspect: 1.5) == straight)
        #expect(straight.encodedForACR(aspect: 1.5) == straight)
        let noAngle = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: nil, hasCrop: true)
        #expect(noAngle.decodedFromACR(aspect: 1.5) == noAngle)
    }

    @Test("conversion is the identity when the aspect is unknown")
    func identityWithoutAspect() {
        let angled = CameraRawCrop(top: 0.1, left: 0.2, bottom: 0.9, right: 0.8, angle: -10, hasCrop: true)
        #expect(angled.decodedFromACR(aspect: nil) == angled)
        #expect(angled.encodedForACR(aspect: nil) == angled)
    }

    /// A bounds-fitted upright crop encodes to corners inside [0,1] — Adobe
    /// rejects (auto-shrinks) crops whose footprint pokes outside the image,
    /// so our writes must stay inside for any crop the editor can produce.
    @Test("encoding a bounds-fitted crop stays inside the unit square")
    func encodedCornersInBounds() {
        let ar = 1.5
        for angle in [-40.0, -15.0, 20.0, 44.0] {
            let fitted = NormalizedCropRegion(top: 0.05, left: 0.05, bottom: 0.95, right: 0.95)
                .fittingRotated(angleDegrees: angle, aspectRatio: ar)
            let crop = CameraRawCrop(
                top: fitted.top, left: fitted.left,
                bottom: fitted.bottom, right: fitted.right,
                angle: angle, hasCrop: true
            )
            let encoded = crop.encodedForACR(aspect: ar)
            for value in [encoded.top!, encoded.left!, encoded.bottom!, encoded.right!] {
                #expect(value >= -0.001 && value <= 1.001, "encoded corner \(value) out of bounds at \(angle)°")
            }
        }
    }

    @Test("iptcMetadataFromDict decodes angled crs crops using the dict's EXIF dimensions")
    func dictParseDecodesWithDims() {
        let dict: [String: Any] = [
            MetadataDictKey.crsCropTop: "0.116878",
            MetadataDictKey.crsCropLeft: "0.046737",
            MetadataDictKey.crsCropBottom: "0.878094",
            MetadataDictKey.crsCropRight: "0.807953",
            MetadataDictKey.crsCropAngle: "-12.786738",
            MetadataDictKey.crsHasCrop: "True",
            MetadataDictKey.imageWidth: 7008,
            MetadataDictKey.imageHeight: 4672,
        ]
        let crop = iptcMetadataFromDict(dict).cameraRaw?.crop
        #expect(crop != nil)
        let widthPX = (crop!.right! - crop!.left!) * 7008
        #expect(abs(widthPX - 4415.194) < 0.01)
    }

    @Test("iptcMetadataFromDict leaves angled crops verbatim when dimensions are missing")
    func dictParseWithoutDimsIsVerbatim() {
        let dict: [String: Any] = [
            MetadataDictKey.crsCropTop: "0.116878",
            MetadataDictKey.crsCropLeft: "0.046737",
            MetadataDictKey.crsCropBottom: "0.878094",
            MetadataDictKey.crsCropRight: "0.807953",
            MetadataDictKey.crsCropAngle: "-12.786738",
            MetadataDictKey.crsHasCrop: "True",
        ]
        let crop = iptcMetadataFromDict(dict).cameraRaw?.crop
        #expect(crop?.left == 0.046737)
        #expect(crop?.right == 0.807953)
    }

    /// Embedded HSL crs documentation must surface through the full dict parser
    /// into `cameraRaw.hslAdjustments`, mapping the ACR `Aqua` (cyan) and custom
    /// `SkinTone` names back to their channels and leaving unset fields nil.
    @Test("iptcMetadataFromDict decodes HSL adjustments into cameraRaw")
    func dictParseDecodesHSL() throws {
        let dict: [String: Any] = [
            "HueAdjustmentRed": "+10",
            "SaturationAdjustmentRed": "+25",
            "LuminanceAdjustmentRed": "-15",
            "SaturationAdjustmentAqua": "-40",
            "LuminanceAdjustmentSkinTone": "+12",
        ]
        let hsl = try #require(iptcMetadataFromDict(dict).cameraRaw?.hslAdjustments)
        #expect(hsl.red == HSLColorAdjustment(saturation: 25, luminance: -15, hueShift: 10))
        #expect(hsl.cyan == HSLColorAdjustment(saturation: -40, luminance: nil, hueShift: nil))
        #expect(hsl.skinTone == HSLColorAdjustment(saturation: nil, luminance: 12, hueShift: nil))
        #expect(hsl.green == nil)
    }
}

@Suite("EllipseMaskGeometry ACR corner encoding")
struct EllipseMaskGeometryCornerTests {
    /// Camera Raw 18.3.2 ground truth: the same authored ellipse (center 0.5/0.5,
    /// true UV radii 0.4 × 0.2 on a 3:2 image) saved at two rotations. The stored
    /// box half-extents are the ellipse's oriented-corner vector, so un-rotating
    /// must recover the authored semi-axes.
    @Test("ACR rotated samples decode to the authored ellipse")
    func acrSamplesDecode() {
        let aspect = 1.5
        var geo = EllipseMaskGeometry()
        geo.centerX = 0.5
        geo.centerY = 0.5

        // Angle −6.337183°: Top 0.367451 Left 0.087725 Bottom 0.632549 Right 0.912275
        geo.radiusX = (0.912275 - 0.087725) / 2
        geo.radiusY = (0.632549 - 0.367451) / 2
        geo.rotation = -6.337183
        var radii = geo.trueRadii(aspect: aspect)
        #expect(abs(radii.x - 0.4) < 0.0005)
        #expect(abs(radii.y - 0.2) < 0.0005)

        // Angle 40.044639°: Top −0.08809 Left 0.655375 Bottom 1.08809 Right 0.344625.
        // Left > Right (corner crossed the center) — ACR stored the axes-swapped
        // representation of the same ellipse, so the decode yields (0.2/aspect, 0.6).
        geo.radiusX = (0.344625 - 0.655375) / 2
        geo.radiusY = (1.08809 - -0.08809) / 2
        geo.rotation = 40.044639
        radii = geo.trueRadii(aspect: aspect)
        #expect(abs(radii.x - 0.2 / aspect) < 0.0005)
        #expect(abs(radii.y - 0.6) < 0.0005)
    }

    @Test("setTrueRadii is the exact inverse of trueRadii")
    func encodeDecodeRoundTrip() {
        var geo = EllipseMaskGeometry()
        geo.rotation = 73.2
        geo.setTrueRadii(x: 0.31, y: 0.12, aspect: 1.5)
        let radii = geo.trueRadii(aspect: 1.5)
        #expect(abs(radii.x - 0.31) < 1e-9)
        #expect(abs(radii.y - 0.12) < 1e-9)
    }

    @Test("rotation 0 keeps box half-extents as the semi-axes")
    func angleZeroIdentity() {
        var geo = EllipseMaskGeometry()
        geo.radiusX = 0.4
        geo.radiusY = 0.2
        geo.rotation = 0
        let radii = geo.trueRadii(aspect: 1.5)
        #expect(abs(radii.x - 0.4) < 1e-12)
        #expect(abs(radii.y - 0.2) < 1e-12)
    }
}

@Suite("EllipseMaskGeometry EXIF orientation transform")
struct EllipseMaskGeometryOrientationTests {
    private let sensorAspect = 1.5

    private func makeGeometry() -> EllipseMaskGeometry {
        var geo = EllipseMaskGeometry()
        geo.centerX = 0.6
        geo.centerY = 0.4
        geo.rotation = 20
        geo.setTrueRadii(x: 0.2, y: 0.1, aspect: sensorAspect)
        geo.feather = 35
        return geo
    }

    /// The normalized-coordinate point map each EXIF orientation applies when
    /// pixels go from the sensor frame to the display frame — same maps as
    /// `CameraRawCrop.transformedForDisplay`.
    private func orientationPointMap(_ orientation: Int, _ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        switch orientation {
        case 2: return (1 - p.x, p.y)
        case 3: return (1 - p.x, 1 - p.y)
        case 4: return (p.x, 1 - p.y)
        case 5: return (p.y, p.x)
        case 6: return (1 - p.y, p.x)
        case 7: return (1 - p.y, 1 - p.x)
        case 8: return (p.y, 1 - p.x)
        default: return p
        }
    }

    /// Evaluate the ellipse implicit equation at a normalized point: 1 on the
    /// boundary, <1 inside. `aspect` is the frame's pixel width/height.
    private func ellipseValue(_ geo: EllipseMaskGeometry, point: (x: Double, y: Double), aspect: Double) -> Double {
        let radii = geo.trueRadii(aspect: aspect)
        let theta = geo.rotation * .pi / 180
        let dx = (point.x - geo.centerX) * aspect
        let dy = point.y - geo.centerY
        let ux = dx * cos(-theta) - dy * sin(-theta)
        let uy = dx * sin(-theta) + dy * cos(-theta)
        let nx = ux / (radii.x * aspect)
        let ny = uy / radii.y
        return nx * nx + ny * ny
    }

    /// Strongest invariant: every boundary point of the sensor-frame ellipse,
    /// mapped through the orientation's pixel transform, must land on the
    /// boundary of the display-frame ellipse.
    @Test("boundary points stay on the ellipse through every orientation", arguments: 2...8)
    func boundaryInvariant(orientation: Int) {
        let geo = makeGeometry()
        let display = geo.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        let displayAspect = orientation >= 5 ? 1 / sensorAspect : sensorAspect

        let radii = geo.trueRadii(aspect: sensorAspect)
        let theta = geo.rotation * .pi / 180
        for i in 0..<12 {
            let t = Double(i) / 12 * 2 * .pi
            // Boundary point in sensor aspect-corrected space, rotated to the
            // ellipse's orientation, then back to normalized coordinates.
            let ex = radii.x * sensorAspect * cos(t)
            let ey = radii.y * sin(t)
            let px = geo.centerX + (ex * cos(theta) - ey * sin(theta)) / sensorAspect
            let py = geo.centerY + (ex * sin(theta) + ey * cos(theta))
            let mapped = orientationPointMap(orientation, (px, py))
            let value = ellipseValue(display, point: mapped, aspect: displayAspect)
            #expect(abs(value - 1) < 1e-9, "orientation \(orientation), boundary point \(i): \(value)")
        }
        // The angle must stay in ACR's accepted (−45°, 45°] range.
        #expect(display.rotation > -45 && display.rotation <= 45)
        #expect(display.feather == geo.feather)
    }

    @Test("display→sensor round-trips to the same ellipse", arguments: 2...8)
    func roundTrip(orientation: Int) {
        let geo = makeGeometry()
        let displayAspect = orientation >= 5 ? 1 / sensorAspect : sensorAspect
        let display = geo.transformedForDisplay(orientation: orientation, sensorAspect: sensorAspect)
        let back = display.transformedForSensor(orientation: orientation, displayAspect: displayAspect)
        #expect(abs(back.centerX - geo.centerX) < 1e-9)
        #expect(abs(back.centerY - geo.centerY) < 1e-9)
        // Compare as ellipses: boundary points of the original must lie on the
        // round-tripped one (the encoding may legitimately come back with the
        // axis-swapped quarter-turn representation of the same ellipse).
        let radii = geo.trueRadii(aspect: sensorAspect)
        let theta = geo.rotation * .pi / 180
        for i in 0..<12 {
            let t = Double(i) / 12 * 2 * .pi
            let ex = radii.x * sensorAspect * cos(t)
            let ey = radii.y * sin(t)
            let px = geo.centerX + (ex * cos(theta) - ey * sin(theta)) / sensorAspect
            let py = geo.centerY + (ex * sin(theta) + ey * cos(theta))
            let value = ellipseValue(back, point: (px, py), aspect: sensorAspect)
            #expect(abs(value - 1) < 1e-9, "orientation \(orientation), boundary point \(i): \(value)")
        }
    }

    @Test("orientation 1 is the identity")
    func upIsIdentity() {
        let geo = makeGeometry()
        #expect(geo.transformedForDisplay(orientation: 1, sensorAspect: sensorAspect) == geo)
        #expect(geo.transformedForSensor(orientation: 1, displayAspect: sensorAspect) == geo)
    }

    @Test("90° CW maps center and swaps the frame-relative radii")
    func quarterTurnKnownValues() {
        var geo = EllipseMaskGeometry()
        geo.centerX = 0.6
        geo.centerY = 0.4
        geo.rotation = 0
        geo.radiusX = 0.2   // at angle 0 the box half-extents ARE the semi-axes
        geo.radiusY = 0.1
        let display = geo.transformedForDisplay(orientation: 6, sensorAspect: sensorAspect)
        #expect(abs(display.centerX - 0.6) < 1e-12)  // 1 − cy
        #expect(abs(display.centerY - 0.6) < 1e-12)  // cx
        let radii = display.trueRadii(aspect: 1 / sensorAspect)
        #expect(abs(radii.x - 0.1) < 1e-12)
        #expect(abs(radii.y - 0.2) < 1e-12)
    }
}

@Suite("EllipseMaskGeometry crop-straighten rotation")
struct EllipseMaskGeometryStraightenTests {
    private let aspect = 1.5

    private func makeGeometry() -> EllipseMaskGeometry {
        var geo = EllipseMaskGeometry()
        geo.centerX = 0.65
        geo.centerY = 0.35
        geo.rotation = 12
        geo.setTrueRadii(x: 0.22, y: 0.09, aspect: aspect)
        geo.feather = 40
        return geo
    }

    @Test("rotate then unrotate is the identity", arguments: [-30.0, -12.5, 7.0, 25.0, 44.0])
    func roundTrip(angle: Double) {
        let geo = makeGeometry()
        let display = geo.rotatedInDisplay(byDegrees: angle, aspect: aspect)
        let back = display.rotatedInDisplay(byDegrees: -angle, aspect: aspect)
        #expect(abs(back.centerX - geo.centerX) < 1e-9)
        #expect(abs(back.centerY - geo.centerY) < 1e-9)
        #expect(abs(back.rotation - geo.rotation) < 1e-9)
        let r0 = geo.trueRadii(aspect: aspect), r1 = back.trueRadii(aspect: aspect)
        #expect(abs(r1.x - r0.x) < 1e-9)
        #expect(abs(r1.y - r0.y) < 1e-9)
    }

    @Test("adds to the ellipse angle and preserves the true semi-axes")
    func anglePlusShapePreserved() {
        let geo = makeGeometry()
        let rotated = geo.rotatedInDisplay(byDegrees: 20, aspect: aspect)
        #expect(abs(rotated.rotation - 32) < 1e-9)  // 12 + 20
        let r0 = geo.trueRadii(aspect: aspect), r1 = rotated.trueRadii(aspect: aspect)
        #expect(abs(r1.x - r0.x) < 1e-9)
        #expect(abs(r1.y - r0.y) < 1e-9)
    }

    @Test("a centered mask only changes orientation, not position")
    func centeredMaskStaysCentered() {
        var geo = EllipseMaskGeometry()
        geo.centerX = 0.5
        geo.centerY = 0.5
        geo.rotation = 0
        let rotated = geo.rotatedInDisplay(byDegrees: -15, aspect: aspect)
        #expect(abs(rotated.centerX - 0.5) < 1e-12)
        #expect(abs(rotated.centerY - 0.5) < 1e-12)
        #expect(abs(rotated.rotation - (-15)) < 1e-12)
    }

    @Test("zero degrees is the identity")
    func zeroIsIdentity() {
        let geo = makeGeometry()
        #expect(geo.rotatedInDisplay(byDegrees: 0, aspect: aspect) == geo)
    }

    /// The center rotation must be a rigid SCREEN rotation once mapped through the
    /// anisotropic UV→pixel scale — i.e. a boundary point of the original ellipse,
    /// taken to pixel space and rigidly rotated about the center, must lie on the
    /// rotated ellipse. Guards against shearing from rotating in raw UV space.
    @Test("boundary points rigidly rotate in pixel space")
    func pixelSpaceRigidRotation() {
        let geo = makeGeometry()
        let deg = -18.0
        let rad = deg * .pi / 180
        let rotated = geo.rotatedInDisplay(byDegrees: deg, aspect: aspect)

        // Original boundary point in pixel space, rigidly rotated about center.
        let semi = geo.trueRadii(aspect: aspect)
        let th = geo.rotation * .pi / 180
        for i in 0..<10 {
            let t = Double(i) / 10 * 2 * .pi
            // boundary point (pixel space) of the original ellipse
            let ex = semi.x * aspect * cos(t)
            let ey = semi.y * sin(t)
            let bxp = ex * cos(th) - ey * sin(th)
            let byp = ex * sin(th) + ey * cos(th)
            // center in pixel space
            let cxp = geo.centerX * aspect, cyp = geo.centerY
            let px = cxp + bxp, py = cyp + byp
            // rigid rotation about the frame center (0.5*aspect, 0.5) in pixel space
            let ox = px - 0.5 * aspect, oy = py - 0.5
            let rxp = ox * cos(rad) - oy * sin(rad) + 0.5 * aspect
            let ryp = ox * sin(rad) + oy * cos(rad) + 0.5
            // evaluate the rotated ellipse implicit value at (rxp/aspect, ryp)
            let rsemi = rotated.trueRadii(aspect: aspect)
            let rth = rotated.rotation * .pi / 180
            let ddx = rxp - rotated.centerX * aspect
            let ddy = ryp - rotated.centerY
            let ux = ddx * cos(-rth) - ddy * sin(-rth)
            let uy = ddx * sin(-rth) + ddy * cos(-rth)
            let val = (ux / (rsemi.x * aspect)) * (ux / (rsemi.x * aspect)) + (uy / rsemi.y) * (uy / rsemi.y)
            #expect(abs(val - 1) < 1e-9, "boundary point \(i): \(val)")
        }
    }
}

@Suite("Layer order")
struct LayerOrderTests {
    private func mask(_ name: String) -> MaskAdjustment {
        MaskAdjustment(name: name, geometry: EllipseMaskGeometry())
    }

    @Test("nil order resolves to canonical [global, masks…]")
    func nilOrderIsCanonical() {
        let m1 = mask("Mask 1"); let m2 = mask("Mask 2")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1, m2]
        #expect(settings.resolvedLayerOrder() == [.global, .mask(m1.id), .mask(m2.id)])
    }

    @Test("no masks resolves to just [global]")
    func noMasksJustGlobal() {
        #expect(CameraRawSettings().resolvedLayerOrder() == [.global])
    }

    @Test("global can be reordered after a mask")
    func globalAfterMask() {
        let m1 = mask("Mask 1")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1]
        settings.layerOrder = [.mask(m1.id), .global]
        #expect(settings.resolvedLayerOrder() == [.mask(m1.id), .global])
    }

    @Test("resolver drops stale mask refs and appends new ones, keeping one global")
    func resolverSanitizes() {
        let m1 = mask("Mask 1"); let m2 = mask("Mask 2")
        let stale = UUID()
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1, m2]
        // Stored order references a deleted mask, omits m2, and duplicates global.
        settings.layerOrder = [.global, .mask(stale), .mask(m1.id), .global]
        let resolved = settings.resolvedLayerOrder()
        #expect(resolved == [.global, .mask(m1.id), .mask(m2.id)])
        #expect(resolved.filter { $0 == .global }.count == 1)
    }

    @Test("resolver inserts a missing global at the front")
    func resolverInsertsGlobal() {
        let m1 = mask("Mask 1")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1]
        settings.layerOrder = [.mask(m1.id)]   // no global stored
        #expect(settings.resolvedLayerOrder() == [.global, .mask(m1.id)])
    }

    @Test("LayerRef round-trips through Codable")
    func layerRefCodable() throws {
        let id = UUID()
        let refs: [LayerRef] = [.global, .mask(id)]
        let data = try JSONEncoder().encode(refs)
        let decoded = try JSONDecoder().decode([LayerRef].self, from: data)
        #expect(decoded == refs)
    }

    @Test("layerOrder is excluded from isEmpty (ordering alone is not an edit)")
    func orderingAloneIsEmpty() {
        var settings = CameraRawSettings()
        settings.layerOrder = [.global]
        #expect(settings.isEmpty)
    }

    @Test("masksInRenderOrder reorders to the resolved mask sub-order")
    func masksInRenderOrderReorders() {
        let m1 = mask("Mask 1"); let m2 = mask("Mask 2"); let m3 = mask("Mask 3")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1, m2, m3]
        settings.layerOrder = [.mask(m3.id), .global, .mask(m1.id), .mask(m2.id)]
        #expect(settings.masksInRenderOrder()?.map(\.id) == [m3.id, m1.id, m2.id])
    }

    @Test("globalLayerIndex counts masks before global")
    func globalLayerIndexCounts() {
        let m1 = mask("Mask 1"); let m2 = mask("Mask 2")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1, m2]
        settings.layerOrder = [.mask(m1.id), .mask(m2.id), .global]
        #expect(settings.globalLayerIndex() == 2)
        settings.layerOrder = nil
        #expect(settings.globalLayerIndex() == nil)
    }

    @Test("rewriting an existing sidecar that lacks the aaphoto namespace, adding a mask, does not corrupt the XML tree")
    func rewriteExistingSidecarAddingMask() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")
        let xmpURL = svc.sidecarURL(for: imageURL)

        // A pre-existing sidecar from before the aaphoto namespace existed: crs global
        // data, no masks, no aaphoto declaration.
        let existing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Aagedal Photo Agent">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:Version="15.4" crs:ProcessVersion="15.4" crs:Exposure2012="+1.00" crs:HasSettings="True"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try existing.data(using: .utf8)!.write(to: xmpURL)

        var settings = CameraRawSettings()
        settings.exposure2012 = 1.0
        settings.localAdjustments = [MaskAdjustment(name: "Mask 1", geometry: EllipseMaskGeometry())]

        // Loop with autorelease drains to provoke the reported dealloc crash.
        for _ in 0..<100 {
            autoreleasepool {
                try? svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
                _ = svc.loadSidecar(for: imageURL)
            }
        }
        // Round-trips cleanly and the reload still sees the mask.
        #expect(svc.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.count == 1)
    }

    @Test("unknown third-party XMP (foreign namespace + unmodeled crs prop) survives sidecar writes")
    func unknownXMPSurvivesSidecarWrites() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")
        let xmpURL = svc.sidecarURL(for: imageURL)

        // A sidecar carrying data the app doesn't model: a foreign Lightroom namespace
        // (lr:hierarchicalSubject) and an unmodeled crs property (crs:Texture).
        let existing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
           xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:Texture="+40" crs:Exposure2012="+0.50" crs:HasSettings="True">
           <lr:hierarchicalSubject><rdf:Bag><rdf:li>Sport|Football</rdf:li></rdf:Bag></lr:hierarchicalSubject>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try existing.data(using: .utf8)!.write(to: xmpURL)

        // A descriptive-only write (cameraRaw=nil) must NOT wipe the foreign namespace. The modeled
        // crs block is cleared, but the unmodeled crs:Texture is left intact (removeCRSBlock clears
        // only the fields we manage — matching the prior NSXML behavior).
        try svc.saveSidecar(metadata: IPTCMetadata(title: "Caption"), for: imageURL)
        let afterDescriptive = svc.prettyPrintedSidecarXML(for: imageURL) ?? ""
        #expect(afterDescriptive.contains("hierarchicalSubject"))
        #expect(afterDescriptive.contains("Sport|Football"))
        #expect(afterDescriptive.contains("Texture"))

        // A develop write that carries settings still preserves the foreign namespace.
        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let afterDevelop = svc.prettyPrintedSidecarXML(for: imageURL) ?? ""
        #expect(afterDevelop.contains("hierarchicalSubject"))
        #expect(afterDevelop.contains("Exposure2012"))
    }

    @Test("re-saving a complex existing sidecar (nested Alt/Bag/Seq + MaskGroupBasedCorrections) repeatedly does not corrupt the XML tree")
    func resaveComplexSidecarRepeatedly() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")
        let xmpURL = svc.sidecarURL(for: imageURL)

        // Faithful copy of a real already-edited sidecar: many namespaces (incl. aaphoto),
        // nested descriptive Alt/Bag/Seq elements, and an existing MaskGroupBasedCorrections.
        let existing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Aagedal Photo Agent">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:aaphoto="http://aagedal.me/ns/photo/1.0/" rdf:about="" photoshop:Headline="Headline" xmp:Rating="5" xmp:Label="Select" Iptc4xmpExt:DigitalSourceType="digitalCapture" photoshop:Credit="TV 2" photoshop:City="Oslo" photoshop:Country="Norway" tiff:Orientation="1" exif:Orientation="1" crs:ProcessVersion="15.4" crs:Temperature="5069" crs:Exposure2012="+0.38" crs:Contrast2012="-15" crs:Highlights2012="+10" crs:Shadows2012="+16" crs:Whites2012="+9" crs:Blacks2012="-24" crs:HasSettings="True" crs:CropTop="0.062056" crs:CropLeft="0.174746" crs:CropBottom="0.705758" crs:CropRight="0.818448" crs:CropAngle="0.000000" crs:HasCrop="True" crs:AlreadyApplied="False" crs:CompatibleVersion="234881024">
                    <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Headline</rdf:li></rdf:Alt></dc:title>
                    <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Norway, Oslo.</rdf:li></rdf:Alt></dc:description>
                    <Iptc4xmpCore:ExtDescrAccessibility><rdf:Alt><rdf:li xml:lang="x-default">Norway, Oslo.</rdf:li></rdf:Alt></Iptc4xmpCore:ExtDescrAccessibility>
                    <dc:subject><rdf:Bag><rdf:li>kjendiser</rdf:li><rdf:li>underholdning</rdf:li><rdf:li>TV serie</rdf:li></rdf:Bag></dc:subject>
                    <Iptc4xmpExt:PersonInImage><rdf:Bag><rdf:li>Tonje Brenna</rdf:li><rdf:li>Jane Smith</rdf:li></rdf:Bag></Iptc4xmpExt:PersonInImage>
                    <dc:creator><rdf:Seq><rdf:li>Truls Aagedal</rdf:li></rdf:Seq></dc:creator>
                    <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">Truls Aagedal / TV 2</rdf:li></rdf:Alt></dc:rights>
                    <crs:MaskGroupBasedCorrections><rdf:Seq><rdf:li>
                        <rdf:Description crs:CorrectionActive="true" crs:CorrectionAmount="1" crs:CorrectionName="Mask 1" crs:CorrectionSyncID="ACF2BFE8FD5D46329471E2FA3B909912" crs:What="Correction" crs:LocalExposure2012="0">
                            <crs:CorrectionMasks><rdf:Seq><rdf:li crs:What="Mask/CircularGradient" crs:Top="0.27507" crs:Left="0.35" crs:Bottom="0.72493" crs:Right="0.65" crs:Angle="0" crs:Feather="50" crs:Flipped="true" crs:MaskActive="true" crs:MaskInverted="false" crs:MaskName="Radial Gradient 1" crs:MaskValue="1" crs:Version="2"></rdf:li></rdf:Seq></crs:CorrectionMasks>
                        </rdf:Description>
                    </rdf:li></rdf:Seq></crs:MaskGroupBasedCorrections>
                </rdf:Description>
            </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try existing.data(using: .utf8)!.write(to: xmpURL)

        // Mimic the edit loop: load the sidecar, add/modify a mask, save — repeatedly.
        // NO explicit autoreleasepool here, mirroring the app's write Task: autoreleased
        // NSXML child arrays must not outlive the document built inside saveSidecar.
        for i in 0..<200 {
            guard var meta = svc.loadSidecar(for: imageURL) else { continue }
            var crs = meta.cameraRaw ?? CameraRawSettings()
            var masks = crs.localAdjustments ?? []
            masks.append(MaskAdjustment(name: "Mask \(i + 2)", geometry: EllipseMaskGeometry()))
            crs.localAdjustments = masks
            meta.cameraRaw = crs
            try? svc.saveSidecar(metadata: meta, for: imageURL)
        }
        #expect(svc.loadSidecar(for: imageURL)?.cameraRaw != nil)
    }

    @Test("saveCameraRawOnly(nil) clears global develop + mask from an existing sidecar")
    func clearDevelopFromSidecar() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")
        let xmpURL = svc.sidecarURL(for: imageURL)
        let existing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" rdf:about=""
                    crs:Exposure2012="+0.38" crs:Contrast2012="-15" crs:Temperature="5069"
                    crs:HasSettings="True" crs:CropTop="0.06" crs:HasCrop="True"/>
            </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try existing.data(using: .utf8)!.write(to: xmpURL)
        #expect(svc.loadSidecar(for: imageURL)?.cameraRaw != nil)

        try svc.saveCameraRawOnly(nil, orientation: nil, for: imageURL)

        #expect(svc.loadSidecar(for: imageURL)?.cameraRaw == nil, "develop must be cleared after reset")
    }

    @Test("persistence round-trips: settings → (render-order masks, index) → resolved order")
    func persistenceRoundTrip() {
        let m1 = mask("Mask 1"); let m2 = mask("Mask 2")
        var settings = CameraRawSettings()
        settings.localAdjustments = [m1, m2]
        settings.layerOrder = [.mask(m2.id), .global, .mask(m1.id)]

        // Simulate write → read: masks stored in render order, global index persisted.
        let storedMasks = settings.masksInRenderOrder()
        let storedIndex = settings.globalLayerIndex()
        let restored = CameraRawSettings.layerOrder(masks: storedMasks, globalIndex: storedIndex)

        var reread = CameraRawSettings()
        reread.localAdjustments = storedMasks
        reread.layerOrder = restored
        #expect(reread.resolvedLayerOrder() == [.mask(m2.id), .global, .mask(m1.id)])
    }
}

@Suite("Anonymizer")
struct AnonymizerSettingsTests {
    @Test("AnonymizerSettings.isEmpty")
    func isEmpty() {
        #expect(AnonymizerSettings().isEmpty)
        #expect(AnonymizerSettings(amount: 0, blackOut: false).isEmpty)
        #expect(AnonymizerSettings(amount: nil, blackOut: nil).isEmpty)
        #expect(!AnonymizerSettings(amount: 40, blackOut: nil).isEmpty)
        #expect(!AnonymizerSettings(amount: nil, blackOut: true).isEmpty)
    }

    @Test("CameraRawSettings.isEmpty reflects the global anonymizer")
    func cameraRawIsEmptyReflectsAnonymizer() {
        var settings = CameraRawSettings()
        #expect(settings.isEmpty)
        settings.anonymizer = AnonymizerSettings(amount: 60, blackOut: nil)
        #expect(!settings.isEmpty)
    }

    @Test("MaskAdjustment.hasAdjustments reflects the per-mask anonymizer")
    func maskHasAdjustmentsReflectsAnonymizer() {
        var mask = MaskAdjustment(name: "Face", geometry: EllipseMaskGeometry())
        #expect(!mask.hasAdjustments)
        mask.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        #expect(mask.hasAdjustments)
    }

    @Test("per-mask anonymizer round-trips through MaskGroupBasedCorrections encode/decode")
    func perMaskAnonymizerRoundTrips() throws {
        var amountMask = MaskAdjustment(name: "Crowd", geometry: EllipseMaskGeometry())
        amountMask.anonymizer = AnonymizerSettings(amount: 72.5, blackOut: nil)
        var blackOutMask = MaskAdjustment(name: "Plate", geometry: EllipseMaskGeometry())
        blackOutMask.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        let plainMask = MaskAdjustment(name: "Sky", geometry: EllipseMaskGeometry())

        let encoded = encodeMaskGroupBasedCorrections([amountMask, blackOutMask, plainMask])
        #expect(encoded.count == 3)
        #expect(encoded[0].appPrivateFields.contains { $0.name == "AnonymizerAmount" && $0.value == "72.5" })
        #expect(encoded[1].appPrivateFields.contains { $0.name == "AnonymizerBlackOut" && $0.value == "True" })
        #expect(encoded[2].appPrivateFields.isEmpty)

        // Round-trip through the bare-name dict shape (as a hand-built/JSON-sourced dict would carry it).
        let corrections: [[String: Any]] = encoded.map { corr in
            var dict: [String: Any] = [:]
            for field in corr.correctionFields { dict[field.name] = field.value }
            for field in corr.appPrivateFields { dict[field.name] = field.value }
            dict["CorrectionMasks"] = [Dictionary(uniqueKeysWithValues: corr.maskFields.map { ($0.name, $0.value as Any) })]
            return dict
        }
        let decoded = try #require(parseMaskGroupBasedCorrections(corrections)).masks
        #expect(decoded.count == 3)
        #expect(decoded[0].anonymizer?.amount.map { abs($0 - 72.5) < 1e-9 } == true)
        #expect(decoded[0].anonymizer?.blackOut != true)
        #expect(decoded[1].anonymizer?.blackOut == true)
        #expect(decoded[2].anonymizer == nil)
    }

    @Test("per-mask anonymizer round-trips through SwiftExif's namespace-URI-prefixed keys")
    func perMaskAnonymizerRoundTripsURIPrefixedKeys() throws {
        let aaphoto = "http://aagedal.me/ns/photo/1.0/"
        let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let corrections: [[String: Any]] = [[
            "\(crs)CorrectionActive": "true",
            "\(aaphoto)AnonymizerAmount": "55.0",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/CircularGradient",
                "\(crs)Top": "0.1", "\(crs)Left": "0.1", "\(crs)Bottom": "0.4", "\(crs)Right": "0.4"
            ]]
        ]]
        let mask = try #require(parseMaskGroupBasedCorrections(corrections)?.masks.first)
        #expect(mask.anonymizer?.amount.map { abs($0 - 55.0) < 1e-9 } == true)
    }

    @Test("global anonymizer round-trips through an XMP sidecar save/load cycle")
    func globalAnonymizerRoundTripsThroughSidecar() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")

        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        settings.anonymizer = AnonymizerSettings(amount: 80, blackOut: nil)
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        let reloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(reloaded.anonymizer?.amount.map { abs($0 - 80) < 1e-9 } == true)
        #expect(reloaded.anonymizer?.blackOut != true)

        // Turning Black Out on (amount cleared) must replace, not merge with, the prior amount.
        settings.anonymizer = AnonymizerSettings(amount: nil, blackOut: true)
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let reloadedBlackOut = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(reloadedBlackOut.anonymizer?.blackOut == true)
        #expect(reloadedBlackOut.anonymizer?.amount == nil)

        // A full develop reset clears the anonymizer along with everything else.
        try svc.saveCameraRawOnly(nil, orientation: nil, for: imageURL)
        #expect(svc.loadSidecar(for: imageURL)?.cameraRaw == nil)
    }

    @Test("per-mask anonymizer round-trips through an XMP sidecar save/load cycle")
    func perMaskAnonymizerRoundTripsThroughSidecar() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")

        var maskedFace = MaskAdjustment(name: "Face", geometry: EllipseMaskGeometry())
        maskedFace.anonymizer = AnonymizerSettings(amount: 65, blackOut: nil)
        var settings = CameraRawSettings()
        settings.localAdjustments = [maskedFace]
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        let reloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first)
        #expect(reloaded.anonymizer?.amount.map { abs($0 - 65) < 1e-9 } == true)
    }
}

/// Phase 1 of the brush-mask feature: the model + XMP read/write for additive `Mask/Paint`
/// `Dabs` strokes, plus the "preserve unrecognized correction verbatim" fallback. Values are
/// anchored to the real ACR-authored sample `Vixen 2026 05.jpg` (a single additive stroke).
@Suite("Brush mask XMP round-trip")
struct BrushMaskTests {
    private let crs = "http://ns.adobe.com/camera-raw-settings/1.0/"

    /// The exact nested shape SwiftExif produces for the real `Vixen 2026 05.jpg` sample:
    /// Correction → CorrectionMasks[Mask/Aggregate] → Masks[Mask/Paint] → Dabs.
    private func sampleCorrections(dabs: [String] = ["f 0.5000", "d 0.533385 0.323619", "d 0.527716 0.442002"],
                                   radius: String = "0.395627", flow: String = "0.5",
                                   centerWeight: String = "0", maskValue: String = "1") -> [[String: Any]] {
        [[
            "\(crs)CorrectionActive": "true",
            "\(crs)CorrectionAmount": "1",
            "\(crs)CorrectionName": "Mask 1",
            "\(crs)LocalExposure2012": "0.1",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/Aggregate",
                "\(crs)MaskName": "Brush 1",
                "\(crs)MaskValue": "1",
                "\(crs)Masks": [[
                    "\(crs)What": "Mask/Paint",
                    "\(crs)Radius": radius,
                    "\(crs)Flow": flow,
                    "\(crs)CenterWeight": centerWeight,
                    "\(crs)MaskValue": maskValue,
                    "\(crs)Dabs": dabs,
                ]],
            ]],
        ]]
    }

    @Test("parses a real additive Mask/Aggregate into brush geometry")
    func parsesBrushGeometry() throws {
        let parsed = try #require(parseMaskGroupBasedCorrections(sampleCorrections()))
        #expect(parsed.preserved.isEmpty)
        let mask = try #require(parsed.masks.first)
        #expect(mask.name == "Mask 1")
        #expect(mask.layerKind == .brushMask)
        let brush = try #require(mask.brush)
        #expect(brush.strokes.count == 1)
        let stroke = try #require(brush.strokes.first)
        #expect(abs(stroke.radius - 0.395627) < 1e-6)
        #expect(abs(stroke.density - 1.0) < 1e-9)
        #expect(stroke.erase == false)
        // Two `d` records → two dabs; the `f` record set flow for both.
        #expect(stroke.dabs.count == 2)
        #expect(abs(stroke.dabs[0].x - 0.533385) < 1e-6)
        #expect(abs(stroke.dabs[0].y - 0.323619) < 1e-6)
        #expect(abs(stroke.dabs[0].flow - 0.5) < 1e-9)
        #expect(stroke.dabs[0].hardness == 0)
        // The exposure lives on the correction, shared with the ellipse path.
        #expect(mask.exposure.map { abs($0 - 0.4) < 1e-9 } == true)  // 0.1 × 4 EV
    }

    @Test("Dabs inline f/h records set per-dab flow and hardness")
    func parsesInlineFlowHardness() throws {
        let dabs = ["f 0.5", "d 0.1 0.2", "h 0.196", "f 0.8", "d 0.3 0.4"]
        let parsed = try #require(parseMaskGroupBasedCorrections(sampleCorrections(dabs: dabs)))
        let stroke = try #require(parsed.masks.first?.brush?.strokes.first)
        #expect(stroke.dabs.count == 2)
        #expect(abs(stroke.dabs[0].flow - 0.5) < 1e-9)
        #expect(stroke.dabs[0].hardness == 0)
        #expect(abs(stroke.dabs[1].flow - 0.8) < 1e-9)
        #expect(abs(stroke.dabs[1].hardness - 0.196) < 1e-9)
    }

    @Test("an opaque erase-brush MaskBrushTable aggregate is preserved, not parsed as brush")
    func eraseBrushTableIsPreserved() throws {
        let corrections: [[String: Any]] = [[
            "\(crs)CorrectionActive": "true",
            "\(crs)CorrectionName": "Erase test",
            "\(crs)LocalExposure2012": "0.2",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/Aggregate",
                "\(crs)MaskName": "Brush 1",
                "\(crs)MaskValue": "1",
                "\(crs)MaskBrushTable": "9F8737DEECAFF5C8FE6BB4B9D438EAF2",
                "\(crs)MaskBrushUncompressedBytes": "13258",
            ]],
        ]]
        let parsed = try #require(parseMaskGroupBasedCorrections(corrections))
        #expect(parsed.masks.isEmpty)
        #expect(parsed.preserved.count == 1)
    }

    @Test("encodes a brush mask into a nested Mask/Aggregate → Masks → Dabs node tree")
    func encodesBrushMask() throws {
        var mask = MaskAdjustment(name: "Painted")
        mask.brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [
                BrushDab(x: 0.1, y: 0.2, flow: 0.5, hardness: 0),
                BrushDab(x: 0.3, y: 0.4, flow: 0.5, hardness: 0.196),
            ], radius: 0.25, density: 0.674528, erase: false)
        ])
        let corr = try #require(encodeMaskGroupBasedCorrections([mask]).first)
        let nodes = try #require(corr.correctionMasks)
        #expect(nodes.count == 1)
        let aggregate = nodes[0]
        #expect(aggregate.fields.contains { $0.name == "What" && $0.value == "Mask/Aggregate" })
        let paints = try #require(aggregate.children.first { $0.name == "Masks" }?.nodes)
        #expect(paints.count == 1)
        let paint = paints[0]
        #expect(paint.fields.contains { $0.name == "What" && $0.value == "Mask/Paint" })
        #expect(paint.fields.contains { $0.name == "Radius" && $0.value == "0.25" })
        #expect(paint.fields.contains { $0.name == "MaskValue" && $0.value == "0.674528" })
        let dabs = try #require(paint.arrays.first { $0.name == "Dabs" }?.values)
        // Flow emitted once up front; hardness only when it changes to non-zero.
        #expect(dabs == ["f 0.5000", "d 0.100000 0.200000", "h 0.1960", "d 0.300000 0.400000"])
    }

    @Test("a brush mask round-trips through an XMP sidecar save/load cycle")
    func brushMaskRoundTripsThroughSidecar() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")

        var mask = MaskAdjustment(name: "Painted")
        mask.exposure = 0.8
        mask.brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [
                BrushDab(x: 0.533385, y: 0.323619, flow: 0.5, hardness: 0),
                BrushDab(x: 0.527716, y: 0.442002, flow: 0.5, hardness: 0),
            ], radius: 0.395627, density: 1.0, erase: false)
        ])
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        let reloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first)
        #expect(reloaded.layerKind == .brushMask)
        let stroke = try #require(reloaded.brush?.strokes.first)
        #expect(abs(stroke.radius - 0.395627) < 1e-6)
        #expect(stroke.dabs.count == 2)
        #expect(abs(stroke.dabs[0].x - 0.533385) < 1e-6)
        #expect(abs(stroke.dabs[1].y - 0.442002) < 1e-6)
        #expect(reloaded.exposure.map { abs($0 - 0.8) < 1e-6 } == true)
    }

    /// The core data-loss fix: an unmodeled (erase-brush) correction must survive a develop
    /// save/reload cycle byte-for-byte, instead of vanishing on the next crs-block rewrite.
    @Test("an unparseable mask correction survives a save/reload/edit/re-save cycle")
    func preservedCorrectionSurvivesReSave() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("test.jpg")
        let sidecarURL = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        let hash = "9F8737DEECAFF5C8FE6BB4B9D438EAF2"

        let corrections: [[String: Any]] = [[
            "\(crs)CorrectionActive": "true",
            "\(crs)CorrectionName": "Erase",
            "\(crs)LocalExposure2012": "0.2",
            "\(crs)CorrectionMasks": [[
                "\(crs)What": "Mask/Aggregate",
                "\(crs)MaskName": "Brush 1",
                "\(crs)MaskValue": "1",
                "\(crs)MaskBrushTable": hash,
                "\(crs)MaskBrushUncompressedBytes": "13258",
            ]],
        ]]
        let preserved = try #require(parseMaskGroupBasedCorrections(corrections)).preserved
        #expect(preserved.count == 1)

        var settings = CameraRawSettings()
        settings.exposure2012 = 0.5
        settings.unparsedMaskCorrections = preserved
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        // The opaque blob is present in the written XMP verbatim.
        let firstXML = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(firstXML.contains("MaskBrushTable"))
        #expect(firstXML.contains(hash))

        // Reload: the preserved correction comes back.
        let reloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(reloaded.unparsedMaskCorrections?.count == 1)

        // Simulate a later develop edit that rewrites the whole crs block — the wipe scenario.
        var edited = reloaded
        edited.exposure2012 = 0.9
        try svc.saveCameraRawOnly(edited, orientation: nil, for: imageURL)
        let finalXML = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(finalXML.contains(hash))
        let reReloaded = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw)
        #expect(reReloaded.unparsedMaskCorrections?.count == 1)
    }
}

/// Phase 2 — GPU rasterization of brush masks into the alpha texture array. Verifies the
/// `stampBrush`/`clearBrushAlpha` kernels + `rebuildBrushAlpha` against hardcoded stroke lists
/// (no compositing wiring yet — that's Phase 3). Skipped when no Metal device is available
/// (headless runners without a GPU).
@Suite("Brush mask rasterization")
struct BrushRasterizationTests {

    /// Builds a pipeline over the system default Metal device, or nil if none is available.
    private func makePipeline() -> MetalEditPipeline? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        return MetalEditPipeline(device: device, commandQueue: queue)
    }

    /// IEEE 754 half → Float (values produced here are all normal, in [0,1]).
    private func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32(h & 0x7C00) >> 10
        let mant = UInt32(h & 0x03FF)
        let bits: UInt32
        if exp == 0 {
            if mant == 0 { bits = sign }
            else {
                var e: UInt32 = 0
                var m = mant
                while (m & 0x0400) == 0 { m <<= 1; e += 1 }
                m &= 0x03FF
                bits = sign | ((127 - 15 - e) << 23) | (m << 13)
            }
        } else if exp == 0x1F {
            bits = sign | 0x7F80_0000 | (mant << 13)
        } else {
            bits = sign | ((exp + (127 - 15)) << 23) | (mant << 13)
        }
        return Float(bitPattern: bits)
    }

    /// Reads back one R16Float array slice as Floats, row-major.
    private func readSlice(_ tex: MTLTexture, slice: Int) -> [Float] {
        let w = tex.width, h = tex.height
        var raw = [UInt16](repeating: 0, count: w * h)
        raw.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!,
                         bytesPerRow: w * MemoryLayout<UInt16>.size,
                         bytesPerImage: w * h * MemoryLayout<UInt16>.size,
                         from: MTLRegionMake2D(0, 0, w, h),
                         mipmapLevel: 0, slice: slice)
        }
        return raw.map { halfToFloat($0) }
    }

    @Test("a centered additive dab is opaque at its center and empty outside its radius")
    func centeredDabCoverage() throws {
        guard let pipeline = makePipeline() else { return }
        #expect(pipeline.hasBrushPipeline)
        let size = MTLSize(width: 64, height: 64, depth: 1)
        // radius 0.25 of long edge (64) = 16px, centered soft dab at full flow.
        let brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 0.0)],
                        radius: 0.25, density: 1.0, erase: false)
        ])
        let tex = try #require(pipeline.rebuildBrushAlpha([brush], size: size))
        #expect(tex.arrayLength == 1)
        let px = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { px[y * 64 + x] }
        #expect(at(32, 32) > 0.5)          // center ~fully covered
        #expect(at(0, 0) == 0)             // corner well outside the 16px radius
        #expect(at(32, 55) == 0)           // 22px below center, outside radius
    }

    @Test("passing no brush masks frees the alpha texture")
    func emptyFreesTexture() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 32, height: 32, depth: 1)
        let brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 0.5)],
                        radius: 0.3, density: 1.0, erase: false)
        ])
        _ = pipeline.rebuildBrushAlpha([brush], size: size)
        #expect(pipeline.brushAlphaTexture != nil)
        let none = pipeline.rebuildBrushAlpha([], size: size)
        #expect(none == nil)
        #expect(pipeline.brushAlphaTexture == nil)
    }

    @Test("an erase stroke subtracts a prior additive stroke's coverage")
    func eraseSubtracts() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 64, height: 64, depth: 1)
        // Add a hard opaque dab, then erase the same spot: center returns to ~0.
        let brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.25, density: 1.0, erase: false),
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.25, density: 1.0, erase: true),
        ])
        let tex = try #require(pipeline.rebuildBrushAlpha([brush], size: size))
        let px = readSlice(tex, slice: 0)
        #expect(px[32 * 64 + 32] < 0.01)   // added then fully erased
    }

    @Test("each brush mask rasterizes into its own independent array slice")
    func multipleMasksIndependentSlices() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 64, height: 64, depth: 1)
        let maskA = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.25, y: 0.25, flow: 1.0, hardness: 1.0)],
                        radius: 0.15, density: 1.0, erase: false)
        ])
        let maskB = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.75, y: 0.75, flow: 1.0, hardness: 1.0)],
                        radius: 0.15, density: 1.0, erase: false)
        ])
        let tex = try #require(pipeline.rebuildBrushAlpha([maskA, maskB], size: size))
        #expect(tex.arrayLength == 2)
        let s0 = readSlice(tex, slice: 0)
        let s1 = readSlice(tex, slice: 1)
        func at(_ px: [Float], _ x: Int, _ y: Int) -> Float { px[y * 64 + x] }
        // Slice 0 painted top-left, empty bottom-right; slice 1 the reverse.
        #expect(at(s0, 16, 16) > 0.5)
        #expect(at(s0, 48, 48) == 0)
        #expect(at(s1, 48, 48) > 0.5)
        #expect(at(s1, 16, 16) == 0)
    }
}
