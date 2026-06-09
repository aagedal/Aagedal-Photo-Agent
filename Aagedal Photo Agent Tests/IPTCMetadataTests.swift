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

@Suite("MetadataComparison per-field diff + merge")
struct MetadataComparisonTests {
    @Test("differences lists only fields that differ; keywords order-insensitive")
    func differences() {
        let embedded = IPTCMetadata(
            title: "Embedded headline",
            description: "Same caption",
            keywords: ["a", "b"],
            creator: "Embedded creator")
        let sidecar = IPTCMetadata(
            title: "Sidecar headline",
            description: "Same caption",
            keywords: ["b", "a"],            // reordered → not a difference
            creator: "Sidecar creator")

        let diffs = MetadataComparison.differences(embedded: embedded, sidecar: sidecar)
        let fields = Set(diffs.map(\.field))
        #expect(fields == [.title, .creator])
        let titleDiff = try? #require(diffs.first { $0.field == .title })
        #expect(titleDiff?.embeddedValue == "Embedded headline")
        #expect(titleDiff?.sidecarValue == "Sidecar headline")
    }

    @Test("merge applies per-field choices and preserves untouched fields (CRS/GPS)")
    func merge() {
        var base = IPTCMetadata(title: "Sidecar headline", description: "Sidecar caption",
                                latitude: 12.34, longitude: 56.78)
        base.cameraRaw = CameraRawSettings()
        let embedded = IPTCMetadata(title: "Embedded headline", description: "Embedded caption")
        let sidecar = IPTCMetadata(title: "Sidecar headline", description: "Sidecar caption")

        // Keep the embedded headline, keep the sidecar caption.
        let merged = MetadataComparison.merge(
            base: base, embedded: embedded, sidecar: sidecar,
            choices: [.title: .embedded, .description: .sidecar])

        #expect(merged.title == "Embedded headline")
        #expect(merged.description == "Sidecar caption")
        // Untouched technical fields survive.
        #expect(merged.latitude == 12.34)
        #expect(merged.longitude == 56.78)
        #expect(merged.cameraRaw != nil)
    }

    @Test("an empty sidecar field is not a conflict — the sidecar owns only what it sets")
    func emptySidecarFieldIsNotAConflict() {
        // Photo-Mechanic model: a field the sidecar leaves empty inherits the embedded
        // value, so it must not be flagged (this is what kept the overlay popping on every
        // partial sidecar). Only a non-empty sidecar value that differs is a conflict.
        let embedded = IPTCMetadata(title: "Has headline", creator: "Embedded creator")
        let sidecar = IPTCMetadata()  // sidecar set nothing
        #expect(MetadataComparison.differences(embedded: embedded, sidecar: sidecar).isEmpty)
    }

    @Test("a non-empty sidecar value the embedded file lacks is a conflict")
    func sidecarSetsFieldEmbeddedLacks() {
        let embedded = IPTCMetadata()
        let sidecar = IPTCMetadata(title: "Sidecar headline")
        let diffs = MetadataComparison.differences(embedded: embedded, sidecar: sidecar)
        #expect(diffs.map(\.field) == [.title])
        #expect(diffs.first?.embeddedValue == "")
        #expect(diffs.first?.sidecarValue == "Sidecar headline")
    }
}

@Suite("MetadataWriteMode preset resolution", .serialized)
struct MetadataWriteModePresetTests {
    /// Runs `body` with the given preset set, restoring the previous value after.
    private func withPreset(_ preset: MetadataWritePreset, _ body: () -> Void) {
        let key = UserDefaultsKeys.metadataWritePreset
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(preset.rawValue, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
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

    @Test("Professional: sidecar for RAW/C2PA, dual-write for plain files")
    func professional() {
        withPreset(.professional) {
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: false) == .writeToFileAndXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: false) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.current(forC2PA: true, isRaw: true) == .writeToXMPSidecar)
        }
    }

    @Test("Custom RAW picker drives RAW resolution")
    func customRaw() {
        withPreset(.custom) {
            let key = UserDefaultsKeys.metadataWriteModeRaw
            let saved = UserDefaults.standard.string(forKey: key)
            UserDefaults.standard.set(MetadataWriteMode.writeToFile.rawValue, forKey: key)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
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
