import Testing
import Foundation
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
        #expect(masks?.count == 1)
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
        let mask = try #require(parseMaskGroupBasedCorrections(corrections)?.first)
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

    /// A correction whose mask geometry can't be parsed (unsupported type or
    /// missing corner fields) must be DROPPED, not substituted with the default
    /// ellipse — a generic mask silently misrenders the image.
    @Test("corrections with unparseable mask geometry are dropped, not defaulted")
    func unparseableMaskGeometryIsDropped() {
        // Unsupported mask type (ACR brush) alongside a valid radial mask.
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
        let masks = parseMaskGroupBasedCorrections(corrections)
        #expect(masks?.count == 1)
        #expect(masks?.first.map { abs($0.geometry.centerX - 0.4) < 1e-9 } == true)

        // All corrections unparseable → nil, same as no masks at all.
        let allBad: [[String: Any]] = [["CorrectionMasks": [["What": "Mask/Paint"]]]]
        #expect(parseMaskGroupBasedCorrections(allBad) == nil)
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

    @Test("Simple writes embedded for every file (incl. RAW and C2PA)")
    func simple() {
        withPreset(.simple) {
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: false) == .writeToFile)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: false) == .writeToFile)
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToFile)
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
