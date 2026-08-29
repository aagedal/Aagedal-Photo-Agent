import Testing
import Foundation
import AppKit
import Metal
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SwiftExif
@testable import Aagedal_Photo_Agent

@Suite("Ordered creators and typed Date Created")
struct OrderedCreatorDateIntegrationTests {
    @Test("legacy scalar creator migrates and the writable alias remains compatible")
    func creatorCodableMigration() throws {
        let legacy = Data(#"{"creator":"Legacy Reporter","dateCreated":"2026-08-21T10:15:30-00:00"}"#.utf8)
        var decoded = try JSONDecoder().decode(IPTCMetadata.self, from: legacy)
        #expect(decoded.creators == ["Legacy Reporter"])
        #expect(decoded.creator == "Legacy Reporter")
        #expect(decoded.editorialDateCreated?.timeZone == .unknown)

        decoded.creators = ["First Reporter", "Second Reporter"]
        let data = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["creator"] as? String == "First Reporter")
        #expect(object["creators"] as? [String] == ["First Reporter", "Second Reporter"])

        decoded.creator = "Compatibility Writer"
        #expect(decoded.creators == ["Compatibility Writer"])
    }

    @Test("XMP creator sequence and exact Date Created lexical value round trip")
    func xmpSequenceAndDate() {
        let expectedDate = "2026-08-21T10:15:30.120+02:30"
        var xmp = XMPData()
        XMPDataBuilder.applyDescriptive(
            IPTCMetadata(
                creator: nil,
                creators: ["First Reporter", "Second Reporter"],
                dateCreated: expectedDate
            ),
            into: &xmp
        )
        #expect(xmp.creator == ["First Reporter", "Second Reporter"])
        #expect(xmp.simpleValue(namespace: XMPNamespace.photoshop, property: "DateCreated") == expectedDate)

        var image = ImageMetadata()
        image.xmp = xmp
        let parsed = iptcMetadataFromDict(image.asMetadataDict())
        #expect(parsed.creators == ["First Reporter", "Second Reporter"])
        #expect(parsed.dateCreated == expectedDate)
        #expect(parsed.editorialDateCreated?.precision == .fractionalSecond)
        #expect(parsed.editorialDateCreated?.timeZoneOffsetMinutes == 150)
    }

    @Test("repeatable IIM By-line order and representable Date/Time reconstruct")
    func iimProjection() {
        var image = ImageMetadata()
        image.iptc.bylines = ["First Reporter", "Second Reporter"]
        image.iptc.dateCreated = "20260821"
        image.iptc.timeCreated = "101530+0230"

        let parsed = iptcMetadataFromDict(image.asMetadataDict())
        #expect(parsed.creators == ["First Reporter", "Second Reporter"])
        #expect(parsed.dateCreated == "2026-08-21T10:15:30+02:30")

        let minute = try? EditorialDateCreated(parsing: "2026-08-21T10:15+02:30")
        let second = try? EditorialDateCreated(parsing: "2026-08-21T10:15:30+02:30")
        let fractional = try? EditorialDateCreated(parsing: "2026-08-21T10:15:30.5+02:30")
        #expect(minute?.iimDateValue == "20260821")
        #expect(minute?.iimTimeValue == nil)
        #expect(second?.iimTimeValue == "101530+0230")
        #expect(fractional?.iimTimeValue == nil)
    }

    @Test("history and explicit mutations preserve creator order and validate Date Created")
    func historyAndMutations() throws {
        var metadata = IPTCMetadata(creators: ["First", "Second"])
        let history = MetadataFieldID.creator.historyValue(in: metadata)
        MetadataFieldID.creator.setHistoryValue(history, in: &metadata)
        #expect(metadata.creators == ["First", "Second"])

        try metadata.apply(.append(["Third", "First"]), to: .creator)
        #expect(metadata.creators == ["First", "Second", "Third"])
        try metadata.apply(.overwrite(.repeatable(["Third", "First"])), to: .creator)
        #expect(metadata.creators == ["Third", "First"])
        try metadata.apply(.clear, to: .creator)
        #expect(metadata.creators.isEmpty)

        #expect(throws: MetadataFieldMutationError.invalidCanonicalValue(
            .dateCreated,
            "2026-02-30"
        )) {
            try metadata.apply(.overwrite(.scalar("2026-02-30")), to: .dateCreated)
        }
        try metadata.apply(.overwrite(.scalar("2026-08-21T10:15:30-00:00")), to: .dateCreated)
        #expect(metadata.editorialDateCreated?.timeZone == .unknown)
        let dateHistory = MetadataFieldID.dateCreated.historyValue(in: metadata)
        var replayed = IPTCMetadata()
        MetadataFieldID.dateCreated.setHistoryValue(dateHistory, in: &replayed)
        #expect(replayed.dateCreated == "2026-08-21T10:15:30-00:00")
    }

    @Test("verification treats creator order as significant")
    func orderedVerification() {
        let expected = IPTCMetadata(creators: ["First", "Second"])
        let reversed = IPTCMetadata(creators: ["Second", "First"])
        let report = IPTCMetadataVerifier.compare(expected: expected, actual: reversed, fields: [.creator])
        #expect(!report.isMatch)
        #expect(report.differences.first?.rule == .orderedUniqueText)
    }
}

private func grayscalePNG(_ bytes: [UInt8], width: Int, height: Int) -> Data? {
    guard bytes.count == width * height,
          let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: width, height: height,
              bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
              space: CGColorSpaceCreateDeviceGray(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
          )
    else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

@Suite("App 2.x persistence migration fixtures")
struct App2PersistenceMigrationFixtureTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PersistenceMigration", isDirectory: true)
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test(
        "2.0, 2.1, and 2.2 metadata sidecars decode through the version-key migration",
        arguments: ["2.0", "2.1", "2.2"]
    )
    func metadataSidecarFixtures(release: String) throws {
        let sidecar = try iso8601Decoder().decode(
            MetadataSidecar.self,
            from: fixtureData("v\(release)-metadata-sidecar.json")
        )

        #expect(sidecar.schemaVersion == MetadataSidecar.currentSchemaVersion)
        #expect(sidecar.sourceFile.isEmpty == false)
        #expect(sidecar.metadata.title?.isEmpty == false)
        if release == "2.0" {
            #expect(sidecar.metadata.keywords == ["wire", "oslo"])
            #expect(sidecar.history.first?.fieldID == .headline)
            #expect(sidecar.history.first?.valueStorage == .exact)
        }
    }

    @Test(
        "2.0, 2.1, and 2.2 unversioned templates and version-key bundles migrate",
        arguments: ["2.0", "2.1", "2.2"]
    )
    func metadataTemplateFixtures(release: String) throws {
        let template = try JSONDecoder().decode(
            MetadataTemplate.self,
            from: fixtureData("v\(release)-metadata-template.json")
        )
        let bundle = try iso8601Decoder().decode(
            TemplateBundle.self,
            from: fixtureData("v\(release)-template-bundle.json")
        )

        #expect(template.schemaVersion == MetadataTemplate.currentSchemaVersion)
        #expect(template.name.isEmpty == false)
        #expect(bundle.schemaVersion == TemplateBundle.currentSchemaVersion)
        #expect(bundle.templates.map(\.id) == [template.id])
    }

    @Test(
        "2.0, 2.1, and 2.2 requirement maps remain readable",
        arguments: ["2.0", "2.1", "2.2"]
    )
    func metadataRequirementFixtures(release: String) throws {
        let suiteName = "MetadataRequirementFixtures.\(release).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            try fixtureData("v\(release)-requirement-levels.json"),
            forKey: UserDefaultsKeys.metadataRequirementLevels
        )
        let expected: MetadataRequirements.Levels = switch release {
        case "2.0": [.headline: .require, .description: .warnOnEmpty]
        case "2.1": [.headline: .warnOnEmpty, .copyright: .require]
        default: [.headline: .require, .countryCode: .warnOnEmpty]
        }
        #expect(MetadataRequirements.load(from: defaults) == expected)
    }

    @Test("2.0 legacy required-field array remains readable")
    func legacyRequiredFieldsV20Fixture() throws {
        let suiteName = "MetadataRequiredFieldsV20Fixture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try fixtureData("v2.0-required-fields.json"),
            forKey: UserDefaultsKeys.requiredMetadataFields
        )
        #expect(MetadataRequirements.load(from: defaults) == [
            .headline: .require,
            .copyright: .require,
        ])
    }

    @Test("2.2 minimum-length preference map remains readable")
    func minimumLengthsV22Fixture() throws {
        let suiteName = "MetadataMinimumLengthsV22Fixtures.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try fixtureData("v2.2-minimum-lengths.json"),
            forKey: UserDefaultsKeys.metadataMinimumLengths
        )

        #expect(MetadataRequirements.loadMinimumLengths(from: defaults) == [
            .headline: 12,
            .description: 40,
        ])
    }

    @Test(
        "2.0, 2.1, and 2.2 keyword archive manifests preserve their version and entries",
        arguments: ["2.0", "2.1", "2.2"]
    )
    func keywordArchiveFixtures(release: String) throws {
        let manifest = try iso8601Decoder().decode(
            KeywordListsArchive.Manifest.self,
            from: fixtureData("v\(release)-keyword-archive-manifest.json")
        )

        #expect(manifest.schemaVersion == KeywordListsArchive.currentSchemaVersion)
        #expect(manifest.files.isEmpty == false)
        #expect(manifest.files.allSatisfy { $0.path.hasPrefix("/") == false })
        #expect(manifest.files.allSatisfy { $0.kind.isEmpty == false && $0.entryCount > 0 })
    }

    @Test("tag evidence records preferences as individual keys, not an aggregate document")
    func preferenceReleaseMatrix() throws {
        // Compared directly with UserDefaultsKeys.swift in tags 2.0.0, 2.1.0, and 2.2.0.
        let baseMetadataAndListKeys: Set<String> = [
            "requiredMetadataFields",
            "metadataRequirementLevels",
            "approvedList.keywords.enabled",
            "approvedList.keywords.bookmark",
            "approvedList.keywords.mode",
            "approvedList.keywords.allowStructuredBypass",
            "keywordLists.iCloudEnabled",
            "keywordLists.migratedVersion",
        ]
        let releaseKeys: [String: Set<String>] = [
            "2.0": baseMetadataAndListKeys,
            "2.1": baseMetadataAndListKeys,
            "2.2": baseMetadataAndListKeys.union([
                "metadataMinimumLengths",
                "hiddenIPTCMetadataFields",
            ]),
        ]

        #expect(releaseKeys["2.0"] == releaseKeys["2.1"])
        #expect(releaseKeys["2.2"]?.subtracting(baseMetadataAndListKeys) == [
            UserDefaultsKeys.metadataMinimumLengths,
            UserDefaultsKeys.hiddenIPTCMetadataFields,
        ])
        #expect(UserDefaultsKeys.requiredMetadataFields == "requiredMetadataFields")
        #expect(UserDefaultsKeys.metadataRequirementLevels == "metadataRequirementLevels")
        #expect(UserDefaultsKeys.approvedKeywordsEnabled == "approvedList.keywords.enabled")
        #expect(UserDefaultsKeys.keywordListsICloudEnabled == "keywordLists.iCloudEnabled")
    }
}

@Suite("Chromaticity scope")
struct ChromaticityScopeTests {
    private let d65 = SIMD2<Float>(0.3127, 0.3290)

    private func chromaticity(
        for linearRGB: SIMD3<Float>,
        saturation: Float
    ) throws -> SIMD2<Float> {
        let luminance = 0.2126729 * linearRGB.x
            + 0.7151522 * linearRGB.y
            + 0.0721750 * linearRGB.z
        let saturated = SIMD3<Float>(repeating: luminance)
            + (linearRGB - SIMD3<Float>(repeating: luminance)) * saturation
        let X = 0.4124564 * saturated.x + 0.3575761 * saturated.y + 0.1804375 * saturated.z
        let Y = 0.2126729 * saturated.x + 0.7151522 * saturated.y + 0.0721750 * saturated.z
        let Z = 0.0193339 * saturated.x + 0.1191920 * saturated.y + 0.9503041 * saturated.z
        let result = try #require(ScopeRenderService.boundedChromaticity(X: X, Y: Y, Z: Z))
        return SIMD2<Float>(result.x, result.y)
    }

    @Test("hard saturation never folds a primary trajectory inward", arguments: [
        SIMD3<Float>(1, 0, 0),
        SIMD3<Float>(0, 1, 0),
        SIMD3<Float>(0, 0, 1),
    ])
    func hardSaturationDoesNotFoldInward(primary: SIMD3<Float>) throws {
        var previousDistance: Float = 0
        for saturation: Float in [1.0, 1.25, 1.5, 2.0] {
            let point = try chromaticity(for: primary, saturation: saturation)
            let delta = point - d65
            let distance = sqrt(delta.x * delta.x + delta.y * delta.y)
            #expect(distance + 1e-5 >= previousDistance)
            previousDistance = distance
        }
    }

    @Test("an imaginary oversaturated sample remains visible at the locus boundary")
    func imaginarySampleProjectsToLocus() throws {
        let primary = SIMD3<Float>(1, 0, 0)
        let normal = try chromaticity(for: primary, saturation: 1)
        let oversaturated = try chromaticity(for: primary, saturation: 2)

        #expect(oversaturated.x > normal.x)
        #expect(oversaturated.x < 0.85)
        #expect(oversaturated.y > 0)
    }

    @Test("Metal scope shaders initialize without blocking Develop")
    func metalScopePipelineInitializesPromptly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let commandQueue = try #require(device.makeCommandQueue())
        let started = ContinuousClock.now
        let pipeline = MetalScopePipeline(device: device, commandQueue: commandQueue)
        let elapsed = ContinuousClock.now - started

        #expect(pipeline != nil)
        #expect(elapsed < .seconds(3), "Metal scope pipeline initialization took \(elapsed)")
    }
}

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

    @Test("organisations shown map to the two IPTC Extension bags")
    func organisationsShownMapToXMPFields() {
        let metadata = IPTCMetadata(
            organisationsShownNames: ["Oslo City Council", "Harbor Authority"],
            organisationsShownCodes: ["OCC", "NO-HARBOR"]
        )
        let fields = metadata.toWriteFields()
        #expect(fields[.organisationInImageName] == "Oslo City Council, Harbor Authority")
        #expect(fields[.organisationInImageCode] == "OCC, NO-HARBOR")
    }

    @Test("copyright maps to XMP rights tag")
    func copyrightMapsToRights() {
        let metadata = IPTCMetadata(copyright: "© 2026 Photographer")
        let fields = metadata.toWriteFields()
        #expect(fields[MetadataFieldKey.rights] == "© 2026 Photographer")
    }

    @Test("rights statements map to their XMP-only fields")
    func rightsStatementsMapToXMPFields() {
        let metadata = IPTCMetadata(
            rightsUsageTerms: "Editorial use only",
            webStatementOfRights: "https://example.test/rights"
        )
        let fields = metadata.toWriteFields()
        #expect(fields[.rightsUsageTerms] == "Editorial use only")
        #expect(fields[.webStatementOfRights] == "https://example.test/rights")
    }

    @Test("digital image GUID maps without implicit generation")
    func digitalImageGUIDMapsToXMPField() {
        #expect(IPTCMetadata().toWriteFields()[.digitalImageGUID] == nil)
        let metadata = IPTCMetadata(digitalImageGUID: "urn:uuid:01234567-89ab-cdef-0123-456789abcdef")
        #expect(metadata.toWriteFields()[.digitalImageGUID] == metadata.digitalImageGUID)
    }

    @Test("image supplier image ID maps independently from the image GUID")
    func imageSupplierImageIDMapsToXMPField() {
        #expect(IPTCMetadata().toWriteFields()[.imageSupplierImageID] == nil)
        let metadata = IPTCMetadata(
            digitalImageGUID: "urn:uuid:01234567-89ab-cdef-0123-456789abcdef",
            imageSupplierImageID: "AGENCY-2026-0042"
        )
        #expect(metadata.toWriteFields()[.digitalImageGUID] == metadata.digitalImageGUID)
        #expect(metadata.toWriteFields()[.imageSupplierImageID] == metadata.imageSupplierImageID)
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

    @Test("additional location and editorial fields map to IPTC tags")
    func additionalFieldsMapToIPTCTags() {
        let metadata = IPTCMetadata(
            sublocation: "National Stadium",
            provinceState: "Oslo",
            instructions: "Hold until final whistle",
            source: "Aagedal News"
        )
        let fields = metadata.toWriteFields()
        #expect(fields[.sublocation] == "National Stadium")
        #expect(fields[.provinceState] == "Oslo")
        #expect(fields[.instructions] == "Hold until final whistle")
        #expect(fields[.source] == "Aagedal News")
    }

    @Test("additional fields decode from canonical IPTC and XMP dictionary names")
    func additionalFieldsDecodeFromDictionary() {
        let metadata = iptcMetadataFromDict([
            MetadataDictKey.location: "National Stadium",
            MetadataDictKey.state: "Oslo",
            MetadataDictKey.instructions: "Hold until final whistle",
            MetadataDictKey.source: "Aagedal News",
        ])
        #expect(metadata.sublocation == "National Stadium")
        #expect(metadata.provinceState == "Oslo")
        #expect(metadata.instructions == "Hold until final whistle")
        #expect(metadata.source == "Aagedal News")
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

    @Test("digitalSourceType maps to the canonical IPTC NewsCodes URI")
    func digitalSourceTypeMapsToNewsCodeURI() {
        let metadata = IPTCMetadata(digitalSourceType: .digitalCapture)
        let fields = metadata.toWriteFields()
        #expect(
            fields[MetadataFieldKey.digitalSourceType]
                == "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
        )
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

@Suite("Digital Source Type NewsCodes")
struct DigitalSourceTypeNewsCodeTests {
    @Test("every active value accepts legacy, URI, HTTPS, and QCode spellings")
    func allValuesRoundTrip() {
        for value in DigitalSourceType.allCases {
            #expect(DigitalSourceType(metadataValue: value.rawValue) == value)
            #expect(DigitalSourceType(metadataValue: value.newsCodeURI) == value)
            #expect(
                DigitalSourceType(
                    metadataValue: value.newsCodeURI.replacingOccurrences(
                        of: "http://",
                        with: "https://"
                    )
                ) == value
            )
            #expect(DigitalSourceType(metadataValue: "digsrctype:\(value.rawValue)") == value)
        }
    }

    @Test("unknown or malformed values are rejected")
    func unknownValuesAreRejected() {
        #expect(DigitalSourceType(metadataValue: "") == nil)
        #expect(DigitalSourceType(metadataValue: "digsrctype:notARealCode") == nil)
        #expect(
            DigitalSourceType(
                metadataValue: "https://example.com/digitalsourcetype/digitalCapture"
            ) == nil
        )
    }

    @Test("canonical URI decodes from an external metadata dictionary")
    func canonicalURIDecodesFromDictionary() {
        let metadata = iptcMetadataFromDict([
            MetadataDictKey.digitalSourceType:
                "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
        ])

        #expect(metadata.digitalSourceType == .trainedAlgorithmicMedia)
    }

    @Test("XMP builder emits the canonical URI")
    func xmpBuilderWritesCanonicalURI() {
        var xmp = XMPData()
        XMPDataBuilder.applyDescriptive(
            IPTCMetadata(digitalSourceType: .trainedAlgorithmicMedia),
            into: &xmp
        )

        #expect(
            xmp.digitalSourceType
                == "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
        )
    }
}

@Suite("Editorial metadata interoperability fixtures")
struct EditorialMetadataInteroperabilityTests {
    private let newsroomNamespace = "https://aagedal.example/ns/newsroom/1.0/"

    private struct LegacyBoundaryCorpus: Decodable {
        let schemaVersion: Int
        let license: String
        let iimTextBoundaries: [IIMTextBoundary]
        let iimUrgencyBoundary: IIMUrgencyBoundary
        let timestampVariants: [TimestampVariant]
    }

    private struct IIMTextBoundary: Decodable {
        let fieldID: MetadataFieldID
        let dataset: String
        let maxBytes: Int
        let unit: String
        let repetitions: Int

        var value: String { String(repeating: unit, count: repetitions) }
    }

    private struct IIMUrgencyBoundary: Decodable {
        let dataset: String
        let acceptedValues: [Int]
        let rejectedValues: [Int]
    }

    private struct TimestampVariant: Decodable {
        let id: String
        let xmpValue: String
        let iimDate: String
        let iimTime: String?
        let precision: String
        let timezoneState: String
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EditorialMetadata/preservation-complex.xmp")
    }

    private var legacyBoundaryFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EditorialMetadata/legacy-boundaries.json")
    }

    private var controlledVocabularyFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ControlledEditorial/controlled-vocabularies.json")
    }

    private func loadLegacyBoundaryCorpus() throws -> LegacyBoundaryCorpus {
        try JSONDecoder().decode(
            LegacyBoundaryCorpus.self,
            from: Data(contentsOf: legacyBoundaryFixtureURL)
        )
    }

    @Test("controlled-vocabulary fixture migrates aliases and preserves unknown concepts")
    func controlledVocabularyFixtureMigration() throws {
        let metadata = try JSONDecoder().decode(
            IPTCMetadata.self,
            from: Data(contentsOf: controlledVocabularyFixtureURL)
        )

        #expect(metadata.subjectCodes == [
            "01000000", "15000000", "newsroom:legacy-subject",
        ])
        #expect(metadata.mediaTopics.count == 2)
        #expect(metadata.mediaTopics[0].mediaTopicCode == "20000587")
        #expect(metadata.mediaTopics[0].name == "Photography")
        #expect(metadata.mediaTopics[0].refinedAbout == "https://example.test/topics/editorial-photography")
        #expect(metadata.mediaTopics[1].termIdentifier == "https://example.test/vocab/concept-42")
        #expect(metadata.genres.first?.genreCode == "Feature")

        let roundTripped = try JSONDecoder().decode(
            IPTCMetadata.self,
            from: JSONEncoder().encode(metadata)
        )
        #expect(roundTripped == metadata)
    }

    @Test("invalid CV-Term identifiers fail closed during decoding")
    func invalidControlledVocabularyTermFailsClosed() {
        let invalid = Data(#"{"termIdentifier":"not a URI"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPTCControlledVocabularyTerm.self, from: invalid)
        }
    }

    @Test("NewsCodes aliases normalize to canonical identifiers")
    func controlledVocabularyAliasesNormalize() throws {
        #expect(IPTCSubjectCode.normalizedValue("subj:01000000") == "01000000")
        #expect(IPTCSubjectCode.normalizedValue(
            "https://cv.iptc.org/newscodes/subjectcode/15000000"
        ) == "15000000")
        #expect(IPTCSubjectCode.iimValue("01000000") == "IPTC:01000000:::")

        let mediaTopic = try #require(IPTCControlledVocabularyTerm.mediaTopic(
            metadataValue: "medtop:20000587",
            name: "Photography"
        ))
        #expect(mediaTopic.vocabularyIdentifier == IPTCControlledVocabularyTerm.mediaTopicSchemeURI)
        #expect(mediaTopic.termIdentifier == "http://cv.iptc.org/newscodes/mediatopic/20000587")

        let genre = try #require(IPTCControlledVocabularyTerm.genre(
            metadataValue: "genre:Feature",
            name: "Feature"
        ))
        #expect(genre.vocabularyIdentifier == IPTCControlledVocabularyTerm.genreSchemeURI)
        #expect(genre.termIdentifier == "http://cv.iptc.org/newscodes/genre/Feature")
        #expect(IPTCGenreCode.entry(for: genre.termIdentifier)?.name == "Feature")
    }

    private func iimTag(for field: MetadataFieldID) -> IPTCTag? {
        switch field {
        case .headline: .headline
        case .description: .captionAbstract
        case .keywords: .keywords
        case .creator: .byline
        case .creatorJobTitle: .bylineTitle
        case .descriptionWriter: .writerEditor
        case .credit: .credit
        case .copyright: .copyrightNotice
        case .jobId: .originalTransmissionReference
        case .city: .city
        case .sublocation: .sublocation
        case .provinceState: .provinceState
        case .country: .countryPrimaryLocationName
        case .countryCode: .countryPrimaryLocationCode
        case .urgency: .urgency
        case .instructions: .specialInstructions
        case .source: .source
        case .subjectCode: .subjectReference
        case .extendedDescription, .personShown, .organisationShownName, .organisationShownCode, .sceneCode,
             .mediaTopic, .genre,
             .digitalSourceType, .rightsUsageTerms, .webStatementOfRights, .digitalImageGUID,
             .imageSupplierImageID, .imageSupplier,
             .dateCreated, .event: nil
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeJPEG(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("generated-no-metadata.jpg")
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let data = representation.representation(using: .jpeg, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
        return url
    }

    @Test("Headline XMP writes do not create or replace localized dc:title")
    func headlineIsIndependentFromLocalizedTitleInXMP() {
        var fresh = XMPData()
        XMPDataBuilder.applyDescriptive(IPTCMetadata(title: "Breaking headline"), into: &fresh)
        #expect(fresh.headline == "Breaking headline")
        #expect(fresh.value(namespace: XMPNamespace.dc, property: "title") == nil)

        var existing = XMPData()
        existing.title = "Localized title"
        XMPDataBuilder.applyDescriptive(IPTCMetadata(title: "Updated headline"), into: &existing)
        #expect(existing.headline == "Updated headline")
        #expect(existing.title == "Localized title")
    }

    @Test("SwiftExif fork preserves every ordered rdf:Alt language entry")
    func localizedTitlePacketRoundTrip() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" rdf:about="">
           <dc:title><rdf:Alt>
            <rdf:li xml:lang="x-default">Default title</rdf:li>
            <rdf:li xml:lang="nb-NO">Norsk tittel</rdf:li>
            <rdf:li xml:lang="nb-NO">Alternativ norsk tittel</rdf:li>
            <rdf:li xml:lang="nn"></rdf:li>
           </rdf:Alt></dc:title>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let expected = [
            XMPLanguageAlternative(language: "x-default", value: "Default title"),
            XMPLanguageAlternative(language: "nb-NO", value: "Norsk tittel"),
            XMPLanguageAlternative(language: "nb-NO", value: "Alternativ norsk tittel"),
            XMPLanguageAlternative(language: "nn", value: ""),
        ]

        let parsed = try XMPReader.readFromXML(Data(xml.utf8))
        #expect(parsed.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title") == expected)

        let rewritten = try XMPReader.readFromXML(Data(XMPWriter.generateXML(parsed).utf8))
        #expect(rewritten.languageAlternativeValue(namespace: XMPNamespace.dc, property: "title") == expected)
    }

    @Test("sidecar Headline edit preserves all localized dc:title entries")
    func sidecarHeadlineEditPreservesLocalizedTitles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)
        let service = XMPSidecarService()
        let expected = [
            LocalizedMetadataText(languageTag: "x-default", value: "Default title"),
            LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk tittel"),
            LocalizedMetadataText(languageTag: "nn", value: "Nynorsk tittel"),
        ]
        var metadata = IPTCMetadata(title: "Old headline", localizedTitles: expected)
        try service.saveSidecar(metadata: metadata, for: imageURL)

        let loaded = try #require(service.loadSidecar(for: imageURL))
        #expect(loaded.title == "Old headline")
        #expect(loaded.localizedTitles == expected)

        metadata = loaded
        metadata.title = "New headline"
        try service.saveSidecar(metadata: metadata, for: imageURL)

        let reread = try #require(service.loadSidecar(for: imageURL))
        #expect(reread.title == "New headline")
        #expect(reread.localizedTitles == expected)
    }

    @Test("sidecar localized Title clear survives save and reload as explicit intent")
    func sidecarLocalizedTitleClearTombstone() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)
        let service = XMPSidecarService()
        let expected = [
            LocalizedMetadataText(languageTag: "x-default", value: "Default title"),
            LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk tittel"),
        ]
        try service.saveSidecar(
            metadata: IPTCMetadata(title: "Headline", localizedTitles: expected),
            for: imageURL
        )
        try service.saveSidecar(
            metadata: IPTCMetadata(title: "Headline", localizedTitles: []),
            for: imageURL
        )

        let cleared = try #require(service.loadSidecar(for: imageURL))
        #expect(cleared.localizedTitles == [])
        let clearedXMP = try XMPReader.readFromXML(
            Data(contentsOf: service.sidecarURL(for: imageURL))
        )
        #expect(clearedXMP.value(namespace: XMPNamespace.dc, property: "title") == nil)
        #expect(clearedXMP.simpleValue(
            namespace: XMPDataBuilder.aaphotoNamespace,
            property: "LocalizedTitleCleared"
        ) == "True")

        // A legacy/unmodeled update is a no-op and retains the pending clear.
        try service.saveSidecar(metadata: IPTCMetadata(title: "Updated headline"), for: imageURL)
        #expect(service.loadSidecar(for: imageURL)?.localizedTitles == [])

        // A modeled value replaces the clear and removes the app-private marker.
        try service.saveSidecar(
            metadata: IPTCMetadata(title: "Updated headline", localizedTitles: expected),
            for: imageURL
        )
        #expect(service.loadSidecar(for: imageURL)?.localizedTitles == expected)
        let restoredXMP = try XMPReader.readFromXML(
            Data(contentsOf: service.sidecarURL(for: imageURL))
        )
        #expect(restoredXMP.simpleValue(
            namespace: XMPDataBuilder.aaphotoNamespace,
            property: "LocalizedTitleCleared"
        ) == nil)
    }

    @Test("stripping IPTC removes localized Title intent while preserving develop settings")
    func stripLocalizedTitleLeavesDevelopOnlySidecar() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)
        let service = XMPSidecarService()
        var cameraRaw = CameraRawSettings()
        cameraRaw.exposure2012 = 0.5
        try service.saveSidecar(
            metadata: IPTCMetadata(
                title: "Headline",
                localizedTitles: [
                    LocalizedMetadataText(languageTag: "x-default", value: "Title"),
                ],
                cameraRaw: cameraRaw
            ),
            for: imageURL
        )

        service.stripIPTCFromSidecar(for: imageURL)

        let stripped = try #require(service.loadSidecar(for: imageURL))
        #expect(stripped.localizedTitles == nil)
        #expect(!stripped.hasDescriptiveContent)
        #expect(stripped.cameraRaw?.exposure2012 == 0.5)
        let xmp = try XMPReader.readFromXML(Data(contentsOf: service.sidecarURL(for: imageURL)))
        #expect(xmp.value(namespace: XMPNamespace.dc, property: "title") == nil)
        #expect(xmp.simpleValue(
            namespace: XMPDataBuilder.aaphotoNamespace,
            property: "LocalizedTitleCleared"
        ) == nil)
    }

    @Test("embedded Headline edits preserve IIM Object Name and dc:title")
    func embeddedHeadlineEditPreservesDistinctTitles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)

        var planted = try SwiftExif.readMetadata(from: imageURL)
        planted.iptc.headline = "Old headline"
        planted.iptc.objectName = "Legacy object title"
        planted.xmp = XMPData()
        planted.xmp?.headline = "Old headline"
        planted.xmp?.title = "Localized XMP title"
        try planted.write(to: imageURL)

        try await SwiftExifWriteEngine().writeFields([.headline: "New headline"], to: [imageURL])

        let written = try SwiftExif.readMetadata(from: imageURL)
        #expect(written.iptc.headline == "New headline")
        #expect(written.iptc.objectName == "Legacy object title")
        #expect(written.xmp?.headline == "New headline")
        #expect(written.xmp?.title == "Localized XMP title")

        try await SwiftExifWriteEngine().writeFields([.headline: ""], to: [imageURL])

        let cleared = try SwiftExif.readMetadata(from: imageURL)
        #expect(cleared.iptc.headline == nil)
        #expect(cleared.iptc.objectName == "Legacy object title")
        #expect(cleared.xmp?.headline == nil)
        #expect(cleared.xmp?.title == "Localized XMP title")
    }

    @Test("embedded Headline edit preserves every localized dc:title entry")
    func embeddedHeadlineEditPreservesLocalizedTitles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)
        let expected = [
            XMPLanguageAlternative(language: "x-default", value: "Default title"),
            XMPLanguageAlternative(language: "nb-NO", value: "Norsk tittel"),
            XMPLanguageAlternative(language: "nn", value: "Nynorsk tittel"),
        ]

        var planted = try SwiftExif.readMetadata(from: imageURL)
        planted.xmp = XMPData()
        planted.xmp?.setValue(
            .languageAlternative(expected),
            namespace: XMPNamespace.dc,
            property: "title"
        )
        try planted.write(to: imageURL)

        let loaded = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(loaded.title == nil)
        #expect(loaded.localizedTitles == expected.map {
            LocalizedMetadataText(languageTag: $0.language, value: $0.value)
        })

        try await SwiftExifWriteEngine().writeFields([.headline: "New headline"], to: [imageURL])

        let rewritten = try SwiftExif.readMetadata(from: imageURL)
        #expect(rewritten.xmp?.languageAlternativeValue(
            namespace: XMPNamespace.dc,
            property: "title"
        ) == expected)
        #expect(try await SwiftExifReadService().readFullMetadata(url: imageURL).title == "New headline")
    }

    @Test("embedded Headline writes do not synthesize Title carriers")
    func embeddedHeadlineDoesNotCreateTitle() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)

        try await SwiftExifWriteEngine().writeFields([.headline: "New headline"], to: [imageURL])

        let written = try SwiftExif.readMetadata(from: imageURL)
        #expect(written.iptc.headline == "New headline")
        #expect(written.iptc.objectName == nil)
        #expect(written.xmp?.headline == "New headline")
        #expect(written.xmp?.value(namespace: XMPNamespace.dc, property: "title") == nil)
    }

    @Test("the complex XMP fixture is semantically stable through a no-op round trip")
    func complexFixtureNoOpRoundTrip() throws {
        let original = try XMPReader.readFromXML(Data(contentsOf: fixtureURL))
        let rewritten = try XMPReader.readFromXML(Data(XMPWriter.generateXML(original).utf8))

        #expect(Set(rewritten.allKeys) == Set(original.allKeys))
        for key in original.allKeys {
            #expect(
                rewritten.value(forKey: key) == original.value(forKey: key),
                "XMP property changed during no-op round trip: \(key)"
            )
        }
    }

    @Test("an unrelated caption edit preserves repeatable, structured, and unknown XMP")
    func unrelatedCaptionEditPreservesFixtureMetadata() throws {
        let service = XMPSidecarService()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("wire-photo.nef")
        let sidecarURL = service.sidecarURL(for: imageURL)
        try FileManager.default.copyItem(at: fixtureURL, to: sidecarURL)

        var edited = try #require(service.loadSidecar(for: imageURL))
        #expect(edited.creator == "Alex Example")
        #expect(edited.locationsShown == [
            EditorialLocation(sublocation: "City Hall", city: "Oslo", countryCode: "NOR"),
            EditorialLocation(sublocation: "Harbor", city: "Oslo", countryCode: "NOR"),
        ])
        #expect(edited.urgency == 2)
        #expect(edited.sceneCodes == ["011200", "012400"])
        edited.description = "Updated caption only"
        try service.saveSidecarPreservingDevelopSettings(metadata: edited, for: imageURL)

        let xmp = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))
        #expect(xmp.description == "Updated caption only")
        #expect(xmp.creator == ["Alex Example", "Sam Example"])
        #expect(xmp.personInImage == ["Kari Nordmann", "Ola Nordmann"])
        #expect(xmp.arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") == ["Oslo City Council", "Harbor Authority"])
        #expect(xmp.arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") == ["OCC", "NO-HARBOR"])
        #expect(xmp.arrayValue(namespace: XMPNamespace.iptcCore, property: "Scene") == ["011200", "012400"])
        #expect(xmp.simpleValue(namespace: XMPNamespace.photoshop, property: "CaptionWriter") == "Night Desk")
        #expect(xmp.simpleValue(namespace: XMPNamespace.photoshop, property: "Urgency") == "2")
        #expect(xmp.simpleValue(namespace: XMPNamespace.iptcCore, property: "CountryCode") == "NOR")
        #expect(xmp.simpleValue(namespace: newsroomNamespace, property: "Desk") == "International")
        #expect(xmp.arrayValue(namespace: newsroomNamespace, property: "WireIDs") == ["APA-2026-0001", "DESK-42"])
        #expect(
            xmp.structuredArrayValue(
                namespace: XMPNamespace.iptcExt,
                property: "LocationShown"
            )?.count == 2
        )
        #expect(xmp.simpleValue(namespace: "http://ns.adobe.com/camera-raw-settings/1.0/", property: "Texture") == "+18")
    }

    @Test("organisation shown bags round-trip and clear through sidecar and embedded JPEG writers")
    func organisationShownRoundTripAndClear() async throws {
        let service = XMPSidecarService()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("organisations.nef")
        let expectedNames = ["Oslo City Council", "Harbor Authority"]
        let expectedCodes = ["OCC", "NO-HARBOR"]
        let expected = IPTCMetadata(
            description: "Editorial organizations",
            organisationsShownNames: expectedNames,
            organisationsShownCodes: expectedCodes
        )

        try service.saveSidecar(metadata: expected, for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(Data(contentsOf: service.sidecarURL(for: rawURL)))
        #expect(sidecarXMP.arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageName") == expectedNames)
        #expect(sidecarXMP.arrayValue(namespace: XMPNamespace.iptcExt, property: "OrganisationInImageCode") == expectedCodes)
        let sidecarMetadata = try #require(service.loadSidecar(for: rawURL))
        #expect(sidecarMetadata.organisationsShownNames == expectedNames)
        #expect(sidecarMetadata.organisationsShownCodes == expectedCodes)

        let jpegURL = try makeJPEG(in: directory)
        let writer = SwiftExifWriteEngine()
        try await writer.writeFields(expected.toWriteFields(), to: [jpegURL])
        let embedded = try await SwiftExifReadService().readFullMetadata(url: jpegURL)
        #expect(embedded.organisationsShownNames == expectedNames)
        #expect(embedded.organisationsShownCodes == expectedCodes)

        try await writer.writeFields([
            .organisationInImageName: "",
            .organisationInImageCode: "",
        ], to: [jpegURL])
        let cleared = try await SwiftExifReadService().readFullMetadata(url: jpegURL)
        #expect(cleared.organisationsShownNames.isEmpty)
        #expect(cleared.organisationsShownCodes.isEmpty)
    }

    @Test("scene code bags normalize aliases, preserve unknown values, and clear through sidecar and embedded writers")
    func sceneCodeRoundTripAndClear() async throws {
        #expect(IPTCSceneCode.all.count == 24)
        #expect(IPTCSceneCode.entry(for: "scn:011200")?.name == "Aerial view")
        #expect(IPTCSceneCode.normalizedEditorValue("011200 — Aerial view") == "011200")
        #expect(IPTCSceneCode.normalizedValue("011200-not-a-code") == "011200-not-a-code")

        let expectedCodes = ["011200", "012400", "099999"]
        let expected = IPTCMetadata(
            description: "Editorial scenes",
            sceneCodes: [
                "scn:011200",
                "https://cv.iptc.org/newscodes/scene/012400",
                "099999",
                "011200",
            ]
        )
        #expect(expected.sceneCodes == expectedCodes)

        let service = XMPSidecarService()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("scenes.nef")

        try service.saveSidecar(metadata: expected, for: rawURL)
        let sidecarURL = service.sidecarURL(for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))
        #expect(sidecarXMP.arrayValue(namespace: XMPNamespace.iptcCore, property: "Scene") == expectedCodes)
        #expect(service.loadSidecar(for: rawURL)?.sceneCodes == expectedCodes)

        let jpegURL = try makeJPEG(in: directory)
        let writer = SwiftExifWriteEngine()
        try await writer.writeFields(expected.toWriteFields(), to: [jpegURL])
        let embedded = try await SwiftExifReadService().readFullMetadata(url: jpegURL)
        #expect(embedded.sceneCodes == expectedCodes)

        try await writer.writeFields([.scene: ""], to: [jpegURL])
        let cleared = try await SwiftExifReadService().readFullMetadata(url: jpegURL)
        #expect(cleared.sceneCodes.isEmpty)
    }

    @Test("creator contact and created/shown locations round-trip through standards-shaped XMP")
    func structuredEditorialXMPRoundTrip() throws {
        let service = XMPSidecarService()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("structured.nef")
        let expected = IPTCMetadata(
            description: "Structured editorial record",
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["News House", "1 Example Street"],
                city: "Oslo",
                region: "Oslo",
                postalCode: "0001",
                country: "Norway",
                emails: ["photo@example.test", "desk@example.test"],
                phoneNumbers: ["+47 22 00 00 00"],
                webURLs: ["https://example.test/contact"]
            ),
            locationsCreated: [EditorialLocation(
                identifiers: ["https://example.test/places/city-hall"],
                name: "Oslo City Hall",
                sublocation: "Council chamber",
                city: "Oslo",
                provinceState: "Oslo",
                countryName: "Norway",
                countryCode: "NOR",
                worldRegion: "Europe",
                latitude: 59.9111,
                longitude: 10.7339,
                altitudeMeters: 12.5
            )],
            locationsShown: [
                EditorialLocation(name: "Harbor", city: "Oslo", countryCode: "NOR"),
                EditorialLocation(name: "News House", city: "Bergen", altitudeMeters: -4.25),
            ]
        )

        try service.saveSidecar(metadata: expected, for: imageURL)
        let sidecarURL = service.sidecarURL(for: imageURL)
        let xmp = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))

        guard case .structure(let contactFields)? = xmp.value(
            forKey: XMPNamespace.iptcCore + "CreatorContactInfo"
        ) else {
            Issue.record("CreatorContactInfo should be a single XMP structure")
            return
        }
        #expect(contactFields[XMPNamespace.iptcCore + "CiEmailWork"] == .array([
            "photo@example.test", "desk@example.test",
        ]))

        let created = try #require(xmp.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "LocationCreated"
        )?.first)
        #expect(created[XMPNamespace.iptcExt + "LocationName"] == .langAlternative("Oslo City Hall"))
        #expect(created[XMPNamespace.iptcExt + "LocationId"] == .array([
            "https://example.test/places/city-hall",
        ]))
        #expect(created[XMPNamespace.exif + "GPSAltitude"] == .simple("25/2"))
        #expect(created[XMPNamespace.exif + "GPSAltitudeRef"] == .simple("0"))

        let shown = try #require(xmp.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        ))
        #expect(shown[1][XMPNamespace.exif + "GPSAltitude"] == .simple("17/4"))
        #expect(shown[1][XMPNamespace.exif + "GPSAltitudeRef"] == .simple("1"))

        let loaded = try #require(service.loadSidecar(for: imageURL))
        #expect(loaded.creatorContactInfo == expected.creatorContactInfo)
        #expect(loaded.locationsCreated.count == 1)
        #expect(abs((loaded.locationsCreated[0].latitude ?? 0) - 59.9111) < 0.000_001)
        #expect(abs((loaded.locationsCreated[0].longitude ?? 0) - 10.7339) < 0.000_001)
        #expect(loaded.locationsCreated[0].altitudeMeters == 12.5)
        #expect(loaded.locationsShown == expected.locationsShown)
    }

    @Test("Subject Code, Media Topic, and Genre use their independent standards mappings")
    func controlledEditorialXMPMappings() throws {
        let mediaTopic = try #require(IPTCControlledVocabularyTerm.mediaTopic(
            metadataValue: "20000587",
            name: "Photography"
        ))
        let genre = try #require(IPTCControlledVocabularyTerm.genre(
            metadataValue: "Feature",
            name: "Feature"
        ))
        var xmp = XMPData()
        xmp.setValue(
            .simple("legacy-intellectual-genre"),
            namespace: XMPNamespace.iptcCore,
            property: "IntellectualGenre"
        )
        xmp.setValue(
            .structuredArray([[
                XMPNamespace.iptcExt + "CvTermId": .simple(mediaTopic.termIdentifier),
                newsroomNamespace + "Confidence": .simple("confirmed"),
            ]]),
            namespace: XMPNamespace.iptcExt,
            property: "AboutCvTerm"
        )

        XMPDataBuilder.applyDescriptive(
            IPTCMetadata(
                subjectCodes: ["subj:01000000"],
                mediaTopics: [mediaTopic],
                genres: [genre]
            ),
            into: &xmp
        )

        #expect(xmp.arrayValue(
            namespace: XMPNamespace.iptcCore,
            property: "SubjectCode"
        ) == ["01000000"])
        let writtenMediaTopic = try #require(xmp.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "AboutCvTerm"
        )?.first)
        #expect(writtenMediaTopic[XMPNamespace.iptcExt + "CvId"] == .simple(
            IPTCControlledVocabularyTerm.mediaTopicSchemeURI
        ))
        #expect(writtenMediaTopic[XMPNamespace.iptcExt + "CvTermName"] == .langAlternative(
            "Photography"
        ))
        #expect(writtenMediaTopic[newsroomNamespace + "Confidence"] == .simple("confirmed"))

        let writtenGenre = try #require(xmp.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "Genre"
        )?.first)
        #expect(writtenGenre[XMPNamespace.iptcExt + "CvTermId"] == .simple(
            "http://cv.iptc.org/newscodes/genre/Feature"
        ))
        #expect(xmp.simpleValue(
            namespace: XMPNamespace.iptcCore,
            property: "IntellectualGenre"
        ) == "legacy-intellectual-genre")
    }

    @Test("structured CV-Term parser preserves labels, refinement, and unknown vocabularies")
    func controlledVocabularyParser() {
        let namespace = XMPNamespace.iptcExt
        let values: [[String: Any]] = [
            [
                namespace + "CvId": IPTCControlledVocabularyTerm.mediaTopicSchemeURI,
                namespace + "CvTermId": "http://cv.iptc.org/newscodes/mediatopic/20000587",
                namespace + "CvTermName": "Photography",
                namespace + "CvTermRefinedAbout": "https://example.test/topics/photojournalism",
            ],
            [
                namespace + "CvId": "https://example.test/vocab/",
                namespace + "CvTermId": "https://example.test/vocab/concept-42",
                namespace + "CvTermName": "Newsroom concept",
            ],
            [
                namespace + "CvTermId": "not a URI",
            ],
        ]

        let parsed = parseControlledVocabularyTerms(values)
        #expect(parsed.count == 2)
        #expect(parsed[0].name == "Photography")
        #expect(parsed[0].refinedAbout == "https://example.test/topics/photojournalism")
        #expect(parsed[1].vocabularyIdentifier == "https://example.test/vocab/")
        #expect(parsed[1].termIdentifier == "https://example.test/vocab/concept-42")
    }

    @Test("structured editorial rewrites preserve unknown member properties")
    func structuredEditorialUnknownMembersSurvive() throws {
        let service = XMPSidecarService()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("future-fields.nef")
        let sidecarURL = service.sidecarURL(for: imageURL)
        let metadata = IPTCMetadata(
            description: "Before",
            creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"]),
            locationsShown: [EditorialLocation(name: "Harbor", city: "Oslo")]
        )
        try service.saveSidecar(metadata: metadata, for: imageURL)

        var planted = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))
        if case .structure(var contact)? = planted.value(
            forKey: XMPNamespace.iptcCore + "CreatorContactInfo"
        ) {
            contact[newsroomNamespace + "ContactID"] = .simple("contact-42")
            planted.setValue(
                .structure(contact),
                namespace: XMPNamespace.iptcCore,
                property: "CreatorContactInfo"
            )
        }
        var shown = try #require(planted.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        ))
        shown[0][newsroomNamespace + "Confidence"] = .simple("confirmed")
        planted.setValue(
            .structuredArray(shown),
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        )
        try Data(XMPWriter.generateXML(planted).utf8).write(to: sidecarURL, options: .atomic)

        var edited = try #require(service.loadSidecar(for: imageURL))
        edited.description = "After"
        try service.saveSidecarPreservingDevelopSettings(metadata: edited, for: imageURL)

        let rewritten = try XMPReader.readFromXML(Data(contentsOf: sidecarURL))
        guard case .structure(let contact)? = rewritten.value(
            forKey: XMPNamespace.iptcCore + "CreatorContactInfo"
        ) else {
            Issue.record("CreatorContactInfo disappeared")
            return
        }
        #expect(contact[newsroomNamespace + "ContactID"] == .simple("contact-42"))
        #expect(rewritten.structuredArrayValue(
            namespace: XMPNamespace.iptcExt,
            property: "LocationShown"
        )?.first?[newsroomNamespace + "Confidence"] == .simple("confirmed"))
    }

    @Test("clearing structured editorial values removes their XMP properties")
    func structuredEditorialClear() {
        var xmp = XMPData()
        XMPDataBuilder.applyDescriptive(
            IPTCMetadata(
                creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"]),
                locationsCreated: [EditorialLocation(city: "Oslo")],
                locationsShown: [EditorialLocation(city: "Bergen")]
            ),
            into: &xmp
        )
        XMPDataBuilder.applyDescriptive(IPTCMetadata(), into: &xmp)

        #expect(xmp.value(forKey: XMPNamespace.iptcCore + "CreatorContactInfo") == nil)
        #expect(xmp.value(forKey: XMPNamespace.iptcExt + "LocationCreated") == nil)
        #expect(xmp.value(forKey: XMPNamespace.iptcExt + "LocationShown") == nil)
    }

    @Test("the embedded JPEG writer preserves a foreign XMP property")
    func embeddedJPEGPreservesForeignXMP() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)

        var planted = try SwiftExif.readMetadata(from: imageURL)
        if planted.xmp == nil { planted.xmp = XMPData() }
        planted.xmp?.setValue(
            .simple("Do not remove"),
            namespace: newsroomNamespace,
            property: "RoutingNote"
        )
        try planted.write(to: imageURL)

        try await SwiftExifWriteEngine().writeFields(
            [.description: "A new editorial caption"],
            to: [imageURL]
        )

        let rewritten = try SwiftExif.readMetadata(from: imageURL)
        #expect(rewritten.xmp?.description == "A new editorial caption")
        #expect(
            rewritten.xmp?.simpleValue(
                namespace: newsroomNamespace,
                property: "RoutingNote"
            ) == "Do not remove"
        )
    }

    @Test("creator job title and description writer round-trip through XMP and IPTC-IIM")
    func editorialRoleRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("roles.nef")
        let expected = IPTCMetadata(
            creator: "Alex Example",
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk"
        )
        try sidecarService.saveSidecar(metadata: expected, for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "AuthorsPosition"
        ) == "Staff Photographer")
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "CaptionWriter"
        ) == "Night Desk")
        let sidecarDecoded = try #require(sidecarService.loadSidecar(for: rawURL))
        #expect(sidecarDecoded.creatorJobTitle == "Staff Photographer")
        #expect(sidecarDecoded.descriptionWriter == "Night Desk")

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([
            .creatorJobTitle: "Staff Photographer",
            .descriptionWriter: "Night Desk",
        ], to: [imageURL])

        let embedded = try SwiftExif.readMetadata(from: imageURL)
        #expect(embedded.iptc.bylineTitle == "Staff Photographer")
        #expect(embedded.iptc.writerEditor == "Night Desk")
        #expect(embedded.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "AuthorsPosition"
        ) == "Staff Photographer")
        #expect(embedded.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "CaptionWriter"
        ) == "Night Desk")
        let embeddedDecoded = iptcMetadataFromDict(embedded.asMetadataDict(fileURL: imageURL))
        #expect(embeddedDecoded.creatorJobTitle == "Staff Photographer")
        #expect(embeddedDecoded.descriptionWriter == "Night Desk")

        var conflicting = embedded
        conflicting.iptc.bylineTitle = "IIM Photographer"
        conflicting.iptc.writerEditor = "IIM Desk"
        conflicting.xmp?.setValue(
            .simple("XMP Photographer"),
            namespace: XMPNamespace.photoshop,
            property: "AuthorsPosition"
        )
        conflicting.xmp?.setValue(
            .simple("XMP Desk"),
            namespace: XMPNamespace.photoshop,
            property: "CaptionWriter"
        )
        let preferred = iptcMetadataFromDict(conflicting.asMetadataDict(fileURL: imageURL))
        #expect(preferred.creatorJobTitle == "XMP Photographer")
        #expect(preferred.descriptionWriter == "XMP Desk")

        var iimOnly = conflicting
        iimOnly.xmp = nil
        let fallback = iptcMetadataFromDict(iimOnly.asMetadataDict(fileURL: imageURL))
        #expect(fallback.creatorJobTitle == "IIM Photographer")
        #expect(fallback.descriptionWriter == "IIM Desk")

        try await engine.writeFields([
            .creatorJobTitle: "",
            .descriptionWriter: "",
        ], to: [imageURL])
        let cleared = try SwiftExif.readMetadata(from: imageURL)
        #expect(cleared.iptc.bylineTitle == nil)
        #expect(cleared.iptc.writerEditor == nil)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "AuthorsPosition"
        ) == nil)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "CaptionWriter"
        ) == nil)
    }

    @Test("country code is canonical and round-trips through XMP and IPTC-IIM")
    func countryCodeRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("country.nef")
        try sidecarService.saveSidecar(metadata: IPTCMetadata(countryCode: "nor"), for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.iptcCore,
            property: "CountryCode"
        ) == "NOR")
        #expect(sidecarService.loadSidecar(for: rawURL)?.countryCode == "NOR")

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.countryCode: "NOR"], to: [imageURL])

        let embedded = try SwiftExif.readMetadata(from: imageURL)
        #expect(embedded.iptc.countryCode == "NOR")
        #expect(embedded.xmp?.simpleValue(
            namespace: XMPNamespace.iptcCore,
            property: "CountryCode"
        ) == "NOR")
        #expect(iptcMetadataFromDict(embedded.asMetadataDict(fileURL: imageURL)).countryCode == "NOR")

        var conflicting = embedded
        conflicting.iptc.countryCode = "SWE"
        conflicting.xmp?.setValue(
            .simple("DNK"),
            namespace: XMPNamespace.iptcCore,
            property: "CountryCode"
        )
        #expect(iptcMetadataFromDict(conflicting.asMetadataDict()).countryCode == "DNK")

        var iimOnly = conflicting
        iimOnly.xmp = nil
        #expect(iptcMetadataFromDict(iimOnly.asMetadataDict()).countryCode == "SWE")

        try await engine.writeFields([.countryCode: ""], to: [imageURL])
        let cleared = try SwiftExif.readMetadata(from: imageURL)
        #expect(cleared.iptc.countryCode == nil)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPNamespace.iptcCore,
            property: "CountryCode"
        ) == nil)
    }

    @Test("rights usage terms and web statement round-trip through XMP")
    func rightsStatementsRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("rights.nef")
        let expected = IPTCMetadata(
            rightsUsageTerms: "Editorial use only — contact the picture desk.",
            webStatementOfRights: "https://example.test/rights/photo-42"
        )
        try sidecarService.saveSidecar(metadata: expected, for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPDataBuilder.xmpRightsNamespace,
            property: "UsageTerms"
        ) == expected.rightsUsageTerms)
        #expect(sidecarXMP.simpleValue(
            namespace: XMPDataBuilder.xmpRightsNamespace,
            property: "WebStatement"
        ) == expected.webStatementOfRights)
        #expect(sidecarService.loadSidecar(for: rawURL)?.rightsUsageTerms == expected.rightsUsageTerms)
        #expect(sidecarService.loadSidecar(for: rawURL)?.webStatementOfRights == expected.webStatementOfRights)

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([
            .rightsUsageTerms: expected.rightsUsageTerms!,
            .webStatementOfRights: expected.webStatementOfRights!,
        ], to: [imageURL])
        let embedded = try SwiftExif.readMetadata(from: imageURL)
        let embeddedDecoded = iptcMetadataFromDict(embedded.asMetadataDict(fileURL: imageURL))
        #expect(embeddedDecoded.rightsUsageTerms == expected.rightsUsageTerms)
        #expect(embeddedDecoded.webStatementOfRights == expected.webStatementOfRights)

        try await engine.writeFields([
            .rightsUsageTerms: "",
            .webStatementOfRights: "",
        ], to: [imageURL])
        let cleared = try SwiftExif.readMetadata(from: imageURL)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPDataBuilder.xmpRightsNamespace,
            property: "UsageTerms"
        ) == nil)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPDataBuilder.xmpRightsNamespace,
            property: "WebStatement"
        ) == nil)
    }

    @Test("digital image GUID round-trips, survives unrelated edits, and clears explicitly")
    func digitalImageGUIDRoundTripAndPreservation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let expectedGUID = "urn:uuid:01234567-89ab-cdef-0123-456789abcdef"
        let expected = IPTCMetadata(
            description: "Original caption",
            digitalImageGUID: expectedGUID
        )
        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("identified.nef")
        try sidecarService.saveSidecar(metadata: expected, for: rawURL)

        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.iptcExt,
            property: "DigImageGUID"
        ) == expectedGUID)
        #expect(sidecarService.loadSidecar(for: rawURL)?.digitalImageGUID == expectedGUID)

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields(expected.toWriteFields(), to: [imageURL])
        #expect(try await SwiftExifReadService().readFullMetadata(url: imageURL).digitalImageGUID == expectedGUID)

        try await engine.writeFields([.description: "Updated caption"], to: [imageURL])
        let afterUnrelatedEdit = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(afterUnrelatedEdit.description == "Updated caption")
        #expect(afterUnrelatedEdit.digitalImageGUID == expectedGUID)

        try await engine.writeFields([.digitalImageGUID: ""], to: [imageURL])
        #expect(try await SwiftExifReadService().readFullMetadata(url: imageURL).digitalImageGUID == nil)
    }

    @Test("image supplier image ID round-trips independently, survives unrelated edits, and clears explicitly")
    func imageSupplierImageIDRoundTripAndPreservation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let supplierID = "AGENCY-2026-0042"
        let imageGUID = "urn:uuid:01234567-89ab-cdef-0123-456789abcdef"
        let expected = IPTCMetadata(
            description: "Original caption",
            digitalImageGUID: imageGUID,
            imageSupplierImageID: supplierID
        )
        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("supplied.nef")
        try sidecarService.saveSidecar(metadata: expected, for: rawURL)

        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.plus,
            property: "ImageSupplierImageID"
        ) == supplierID)
        #expect(sidecarXMP.value(
            forKey: XMPNamespace.iptcExt + "ImageSupplierImageID"
        ) == nil)
        let sidecarMetadata = sidecarService.loadSidecar(for: rawURL)
        #expect(sidecarMetadata?.imageSupplierImageID == supplierID)
        #expect(sidecarMetadata?.digitalImageGUID == imageGUID)

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields(expected.toWriteFields(), to: [imageURL])
        let embedded = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(embedded.imageSupplierImageID == supplierID)
        #expect(embedded.digitalImageGUID == imageGUID)

        try await engine.writeFields([.description: "Updated caption"], to: [imageURL])
        let afterUnrelatedEdit = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(afterUnrelatedEdit.description == "Updated caption")
        #expect(afterUnrelatedEdit.imageSupplierImageID == supplierID)
        #expect(afterUnrelatedEdit.digitalImageGUID == imageGUID)

        try await engine.writeFields([.imageSupplierImageID: ""], to: [imageURL])
        let afterClear = try await SwiftExifReadService().readFullMetadata(url: imageURL)
        #expect(afterClear.imageSupplierImageID == nil)
        #expect(afterClear.digitalImageGUID == imageGUID)
    }

    @Test("urgency round-trips through Photoshop XMP and IPTC-IIM with XMP precedence")
    func urgencyRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sidecarService = XMPSidecarService()
        let rawURL = directory.appendingPathComponent("urgency.nef")
        try sidecarService.saveSidecar(metadata: IPTCMetadata(urgency: 2), for: rawURL)
        let sidecarXMP = try XMPReader.readFromXML(
            Data(contentsOf: sidecarService.sidecarURL(for: rawURL))
        )
        #expect(sidecarXMP.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "Urgency"
        ) == "2")
        #expect(sidecarService.loadSidecar(for: rawURL)?.urgency == 2)

        let imageURL = try makeJPEG(in: directory)
        let engine = SwiftExifWriteEngine()
        try await engine.writeFields([.urgency: "3"], to: [imageURL])

        let embedded = try SwiftExif.readMetadata(from: imageURL)
        #expect(embedded.iptc.urgency == 3)
        #expect(embedded.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "Urgency"
        ) == "3")
        #expect(iptcMetadataFromDict(embedded.asMetadataDict()).urgency == 3)

        var conflicting = embedded
        conflicting.iptc.urgency = 5
        conflicting.xmp?.setValue(
            .simple("1"),
            namespace: XMPNamespace.photoshop,
            property: "Urgency"
        )
        #expect(iptcMetadataFromDict(conflicting.asMetadataDict()).urgency == 1)

        var iimOnly = conflicting
        iimOnly.xmp = nil
        #expect(iptcMetadataFromDict(iimOnly.asMetadataDict()).urgency == 5)

        try await engine.writeFields([.urgency: ""], to: [imageURL])
        let cleared = try SwiftExif.readMetadata(from: imageURL)
        #expect(cleared.iptc.urgency == nil)
        #expect(cleared.xmp?.simpleValue(
            namespace: XMPNamespace.photoshop,
            property: "Urgency"
        ) == nil)
    }

    @Test("the embedded raster writer carries structured editorial XMP")
    func embeddedJPEGStructuredEditorialRoundTrip() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = try makeJPEG(in: directory)
        let expected = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(
                emails: ["photo@example.test", "desk@example.test"]
            ),
            locationsCreated: [EditorialLocation(
                name: "City Hall", city: "Oslo", countryCode: "NOR"
            )],
            locationsShown: [EditorialLocation(
                name: "Harbor", latitude: -33.8688, longitude: 151.2093,
                altitudeMeters: -3.5
            )]
        )

        let engine = SwiftExifWriteEngine()
        try await engine.writeFields(
            [.description: "Embedded structured record"],
            to: [imageURL],
            structuredData: StructuredWriteData(
                editorial: EditorialStructuredWriteData(metadata: expected)
            )
        )

        let written = try SwiftExif.readMetadata(from: imageURL)
        let decoded = iptcMetadataFromDict(written.asMetadataDict(fileURL: imageURL))
        #expect(decoded.creatorContactInfo == expected.creatorContactInfo)
        #expect(decoded.locationsCreated == expected.locationsCreated)
        #expect(decoded.locationsShown == expected.locationsShown)

        // A later scalar-only edit has merge semantics and must not clear the structures.
        try await engine.writeFields([.headline: "Updated headline"], to: [imageURL])
        let rewritten = try SwiftExif.readMetadata(from: imageURL)
        let afterScalarEdit = iptcMetadataFromDict(rewritten.asMetadataDict(fileURL: imageURL))
        #expect(afterScalarEdit.creatorContactInfo == expected.creatorContactInfo)
        #expect(afterScalarEdit.locationsCreated == expected.locationsCreated)
        #expect(afterScalarEdit.locationsShown == expected.locationsShown)
    }

    @Test("XMP description is proposed while an XMP-IIM conflict remains visible")
    func descriptionConflictPolicy() throws {
        let dict: [String: Any] = [
            MetadataDictKey.description: "Modern XMP caption",
            MetadataDictKey.captionAbstract: "Legacy IIM caption",
        ]

        #expect(iptcMetadataFromDict(dict).description == "Modern XMP caption")
        let conflict = try #require(descriptionConflict(in: dict))
        #expect(conflict.xmpDescription == "Modern XMP caption")
        #expect(conflict.iptcCaptionAbstract == "Legacy IIM caption")
    }

    @Test("legacy text recipes reach exact UTF-8 limits and round-trip without truncation")
    func legacyTextBoundaries() throws {
        let corpus = try loadLegacyBoundaryCorpus()
        #expect(corpus.schemaVersion == 1)
        #expect(corpus.license == "CC0-1.0")
        #expect(corpus.iimTextBoundaries.count == 16)

        for boundary in corpus.iimTextBoundaries {
            let tag = try #require(iimTag(for: boundary.fieldID))
            let value = boundary.value
            #expect("\(tag.record):\(tag.dataSet)" == boundary.dataset)
            #expect(tag.maxLength == boundary.maxBytes)
            #expect(value.lengthOfBytes(using: .utf8) == boundary.maxBytes)

            let compatibilityRule = try #require(
                MetadataValidationProfile.iptcIIMCompatibility.rules.first {
                    $0.requirement.field == boundary.fieldID
                }
            )
            guard case let .maximumUTF8Bytes(ruleField, ruleLimit) = compatibilityRule.requirement else {
                Issue.record("Expected a UTF-8 byte rule for \(boundary.fieldID)")
                continue
            }
            #expect(ruleField == boundary.fieldID)
            #expect(ruleLimit == boundary.maxBytes)

            var exactMetadata = IPTCMetadata()
            boundary.fieldID.setTextValue(value, in: &exactMetadata)
            #expect(MetadataValidationEngine().validate(
                exactMetadata,
                imageURL: URL(fileURLWithPath: "/fixtures/exact.jpg"),
                profile: .iptcIIMCompatibility
            ).issues.allSatisfy { $0.field != boundary.fieldID })

            var overMetadata = IPTCMetadata()
            boundary.fieldID.setTextValue(value + "X", in: &overMetadata)
            #expect(MetadataValidationEngine().validate(
                overMetadata,
                imageURL: URL(fileURLWithPath: "/fixtures/over.jpg"),
                profile: .iptcIIMCompatibility
            ).issues.contains { $0.field == boundary.fieldID })

            var exact = IPTCData()
            try exact.setValue(value, for: tag)
            try exact.validate()
            var exactWarnings: [String] = []
            let encoded = try IPTCWriter.write(exact, warnings: &exactWarnings)
            let decoded = try IPTCReader.read(from: encoded)
            #expect(exactWarnings.isEmpty)
            #expect(decoded.value(for: tag) == value)

            var over = IPTCData()
            try over.setValue(value + "X", for: tag)
            var overWarnings: [String] = []
            let overEncoded = try IPTCWriter.write(over, warnings: &overWarnings)
            #expect(overWarnings.count == 1)
            #expect(try IPTCReader.read(from: overEncoded).value(for: tag) == value + "X")
        }
    }

    @Test("legacy urgency values use IIM 2:10 and the supported 1 through 8 range")
    func legacyUrgencyBoundary() throws {
        let boundary = try loadLegacyBoundaryCorpus().iimUrgencyBoundary
        let tag = IPTCTag.urgency
        #expect("\(tag.record):\(tag.dataSet)" == boundary.dataset)
        #expect(tag.maxLength == 1)
        #expect(boundary.acceptedValues == Array(1...8))
        #expect(boundary.rejectedValues == [0, 9])

        let validator = MetadataValidationEngine()
        let profile = MetadataValidationProfile.currentRequirements(
            levels: [:],
            minimumLengths: [:]
        )
        let imageURL = URL(fileURLWithPath: "/fixtures/urgency.jpg")
        for value in boundary.acceptedValues {
            let metadata = IPTCMetadata(urgency: value)
            #expect(validator.validate(
                metadata,
                imageURL: imageURL,
                profile: profile
            ).issues.allSatisfy { $0.field != .urgency })

            var iim = IPTCData()
            iim.urgency = value
            let decoded = try IPTCReader.read(from: IPTCWriter.write(iim))
            #expect(decoded.urgency == value)
        }

        for value in boundary.rejectedValues {
            let metadata = IPTCMetadata(urgency: value)
            #expect(validator.validate(
                metadata,
                imageURL: imageURL,
                profile: profile
            ).issues.contains { $0.field == .urgency })
        }
    }

    @Test("timezone and precision variants preserve XMP and paired IIM values")
    func timestampVariants() throws {
        let corpus = try loadLegacyBoundaryCorpus()
        #expect(corpus.timestampVariants.count == 7)

        for variant in corpus.timestampVariants {
            var iim = IPTCData()
            iim.dateCreated = variant.iimDate
            iim.timeCreated = variant.iimTime
            try iim.validate()
            let decodedIIM = try IPTCReader.read(from: IPTCWriter.write(iim))
            #expect(decodedIIM.dateCreated == variant.iimDate, Comment(rawValue: variant.id))
            #expect(decodedIIM.timeCreated == variant.iimTime, Comment(rawValue: variant.id))

            switch variant.timezoneState {
            case "absent":
                #expect(variant.iimTime == nil)
                #expect(variant.precision == "day")
            case "unknown":
                #expect(variant.iimTime?.count == 6)
            case "known":
                #expect(variant.iimTime?.count == 11)
            default:
                Issue.record("Unknown timezone state in fixture: \(variant.timezoneState)")
            }

            var xmp = XMPData()
            XMPDataBuilder.applyDescriptive(
                IPTCMetadata(dateCreated: variant.xmpValue),
                into: &xmp
            )
            let decodedXMP = try XMPReader.readFromXML(Data(XMPWriter.generateXML(xmp).utf8))
            #expect(
                decodedXMP.simpleValue(
                    namespace: XMPNamespace.photoshop,
                    property: "DateCreated"
                ) == variant.xmpValue,
                Comment(rawValue: variant.id)
            )
        }
    }
}

@Suite("CameraRawSettings white balance resolution")
struct CameraRawWhiteBalanceResolutionTests {
    @Test("absolute RAW tint-only edit keeps as-shot temperature")
    func rawTintOnlyDefaultsTemperatureToAsShot() {
        var settings = CameraRawSettings()
        settings.whiteBalance = "Custom"
        settings.tint = 3

        let target = settings.resolvedWhiteBalanceTarget(
            absoluteDefaultTemperature: 4480,
            absoluteDefaultTint: 3
        )

        #expect(target?.temperature == 4480)
        #expect(target?.tint == 3)
    }

    @Test("absolute RAW temperature-only edit keeps as-shot tint")
    func rawTemperatureOnlyDefaultsTintToAsShot() {
        var settings = CameraRawSettings()
        settings.whiteBalance = "Custom"
        settings.temperature = 4480

        let target = settings.resolvedWhiteBalanceTarget(
            absoluteDefaultTemperature: 4480,
            absoluteDefaultTint: 3
        )

        #expect(target?.temperature == 4480)
        #expect(target?.tint == 3)
    }

    @Test("incremental non-RAW tint-only edit keeps neutral temperature")
    func incrementalTintOnlyKeepsNeutralTemperature() {
        var settings = CameraRawSettings()
        settings.whiteBalance = "Custom"
        settings.incrementalTint = 3

        let target = settings.resolvedWhiteBalanceTarget(
            absoluteDefaultTemperature: 4480,
            absoluteDefaultTint: 3
        )

        #expect(target?.temperature == 6500)
        #expect(target?.tint == 3)
    }

    @Test("as-shot white balance resolves to no adjustment")
    func asShotWhiteBalanceIsNoAdjustment() {
        var settings = CameraRawSettings()
        settings.whiteBalance = "As Shot"
        settings.temperature = 4480
        settings.tint = 3

        #expect(settings.resolvedWhiteBalanceTarget() == nil)
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

    @Test("different organisations shown are detected")
    func differentOrganisationsDetected() {
        let names = IPTCMetadata(organisationsShownNames: ["Example News"])
        let changedNames = IPTCMetadata(organisationsShownNames: ["Example Sport"])
        let codes = IPTCMetadata(organisationsShownCodes: ["EXNEWS"])
        let changedCodes = IPTCMetadata(organisationsShownCodes: ["EXSPORT"])
        #expect(names.hasIPTCDifferences(from: changedNames))
        #expect(codes.hasIPTCDifferences(from: changedCodes))
    }

    @Test("different image supplier image IDs are detected")
    func differentImageSupplierImageIDsDetected() {
        let a = IPTCMetadata(imageSupplierImageID: "AGENCY-001")
        let b = IPTCMetadata(imageSupplierImageID: "AGENCY-002")
        #expect(a.hasIPTCDifferences(from: b))
    }

    @Test("structured editorial differences are detected without location bag ordering")
    func structuredEditorialDifferencesDetected() {
        let cityHall = EditorialLocation(name: "City Hall", city: "Oslo", countryCode: "NOR")
        let harbor = EditorialLocation(name: "Harbor", city: "Oslo", countryCode: "NOR")
        let contact = CreatorContactInfo(emails: ["desk@example.test"])

        let a = IPTCMetadata(
            creatorContactInfo: contact,
            locationsShown: [cityHall, harbor]
        )
        let reordered = IPTCMetadata(
            creatorContactInfo: contact,
            locationsShown: [harbor, cityHall]
        )
        let changed = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["newsroom@example.test"]),
            locationsShown: [cityHall, harbor]
        )

        #expect(!a.hasIPTCDifferences(from: reordered))
        #expect(a.hasIPTCDifferences(from: changed))
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

    @Test("localized titles merge atomically and preserve explicit clears")
    func localizedTitlesMergeWithNilVsEmptySemantics() {
        let baseTitles = [LocalizedMetadataText(languageTag: "nb-NO", value: "Basetittel")]
        let overrideTitles = [LocalizedMetadataText(languageTag: "nn", value: "Ny tittel")]
        let base = IPTCMetadata(localizedTitles: baseTitles)

        #expect(base.merged(preferring: IPTCMetadata()).localizedTitles == baseTitles)
        #expect(base.merged(preferring: IPTCMetadata(localizedTitles: overrideTitles)).localizedTitles == overrideTitles)
        #expect(base.merged(preferring: IPTCMetadata(localizedTitles: [])).localizedTitles == [])
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

    @Test("urgency merged from override")
    func urgencyMerged() {
        let base = IPTCMetadata(urgency: 5)
        let override = IPTCMetadata(urgency: 2)
        #expect(base.merged(preferring: override).urgency == 2)
        #expect(base.merged(preferring: IPTCMetadata()).urgency == 5)
    }

    @Test("non-empty image supplier image ID merges atomically")
    func imageSupplierImageIDMerged() {
        let base = IPTCMetadata(imageSupplierImageID: "AGENCY-001")
        let replacement = IPTCMetadata(imageSupplierImageID: "AGENCY-002")
        #expect(base.merged(preferring: replacement).imageSupplierImageID == "AGENCY-002")
        #expect(base.merged(preferring: IPTCMetadata()).imageSupplierImageID == "AGENCY-001")
    }

    @Test("non-empty structured metadata merges without flattening locations")
    func structuredMetadataMerged() {
        let base = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["old@example.test"]),
            locationsCreated: [EditorialLocation(city: "Bergen", countryCode: "NOR")]
        )
        let override = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(phoneNumbers: ["+47 22 00 00 00"]),
            locationsCreated: [EditorialLocation(city: "Oslo", countryCode: "NOR")]
        )
        let result = base.merged(preferring: override)

        #expect(result.creatorContactInfo?.emails.isEmpty == true)
        #expect(result.creatorContactInfo?.phoneNumbers == ["+47 22 00 00 00"])
        #expect(result.locationsCreated == [EditorialLocation(city: "Oslo", countryCode: "NOR")])
        #expect(result.city == nil)
        #expect(result.country == nil)
    }

    @Test("empty structured override does not erase base values")
    func emptyStructuredOverrideIgnored() {
        let base = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"]),
            locationsShown: [EditorialLocation(city: "Oslo")]
        )
        let result = base.merged(
            preferring: IPTCMetadata(
                creatorContactInfo: CreatorContactInfo(),
                locationsShown: [EditorialLocation()]
            )
        )

        #expect(result.creatorContactInfo == base.creatorContactInfo)
        #expect(result.locationsShown == base.locationsShown)
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
        #expect(IPTCMetadata(localizedTitles: []).hasDescriptiveContent)
        #expect(IPTCMetadata(keywords: ["k"]).hasDescriptiveContent)
        #expect(IPTCMetadata(personShown: ["P"]).hasDescriptiveContent)
        #expect(IPTCMetadata(organisationsShownNames: ["Example News"]).hasDescriptiveContent)
        #expect(IPTCMetadata(organisationsShownCodes: ["EXNEWS"]).hasDescriptiveContent)
        #expect(IPTCMetadata(creator: "C").hasDescriptiveContent)
        #expect(IPTCMetadata(imageSupplierImageID: "AGENCY-001").hasDescriptiveContent)
        #expect(IPTCMetadata(city: "Oslo").hasDescriptiveContent)
        #expect(IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"])
        ).hasDescriptiveContent)
        #expect(IPTCMetadata(
            locationsCreated: [EditorialLocation(city: "Oslo")]
        ).hasDescriptiveContent)
        #expect(IPTCMetadata(
            locationsShown: [EditorialLocation(latitude: 59.91, longitude: 10.75)]
        ).hasDescriptiveContent)
        #expect(!IPTCMetadata(creatorContactInfo: CreatorContactInfo()).hasDescriptiveContent)
        #expect(!IPTCMetadata(locationsShown: [EditorialLocation()]).hasDescriptiveContent)
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

    @Test("replacing descriptive fields preserves an explicit supplier-ID clear")
    func imageSupplierImageIDClearSticks() {
        let embedded = IPTCMetadata(imageSupplierImageID: "AGENCY-001")
        let record = IPTCMetadata(title: "Sidecar record")
        #expect(embedded.replacingDescriptiveFields(from: record).imageSupplierImageID == nil)
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

    @Test("descriptive replacement preserves legacy-unmodeled titles and honors explicit clears")
    func localizedTitleReplacement() {
        let embeddedTitles = [LocalizedMetadataText(languageTag: "nb-NO", value: "Innebygd")]
        let sidecarTitles = [LocalizedMetadataText(languageTag: "nn", value: "Sidevogn")]
        let embedded = IPTCMetadata(localizedTitles: embeddedTitles)

        #expect(embedded.replacingDescriptiveFields(
            from: IPTCMetadata(title: "Sidecar", localizedTitles: sidecarTitles)
        ).localizedTitles == sidecarTitles)
        #expect(embedded.replacingDescriptiveFields(
            from: IPTCMetadata(title: "Sidecar")
        ).localizedTitles == embeddedTitles)
        #expect(embedded.replacingDescriptiveFields(
            from: IPTCMetadata(title: "Sidecar", localizedTitles: [])
        ).localizedTitles == [])
    }

    @Test("replacing descriptive fields preserves explicit structured clears")
    func structuredClearsStick() {
        let embedded = IPTCMetadata(
            organisationsShownNames: ["Example News"],
            organisationsShownCodes: ["EXNEWS"],
            creatorContactInfo: CreatorContactInfo(emails: ["desk@example.test"]),
            locationsCreated: [EditorialLocation(city: "Oslo")],
            locationsShown: [EditorialLocation(city: "Bergen")]
        )
        let record = IPTCMetadata(title: "Sidecar record")
        let result = embedded.replacingDescriptiveFields(from: record)

        #expect(result.creatorContactInfo == nil)
        #expect(result.organisationsShownNames.isEmpty)
        #expect(result.organisationsShownCodes.isEmpty)
        #expect(result.locationsCreated.isEmpty)
        #expect(result.locationsShown.isEmpty)
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
        let contact = CreatorContactInfo(
            addressLines: ["News House", "1 Example Street"],
            city: "Oslo",
            region: "Oslo",
            postalCode: "0001",
            country: "Norway",
            emails: ["photo@example.test", "desk@example.test"],
            phoneNumbers: ["+47 22 00 00 00"],
            webURLs: ["https://example.test/contact"]
        )
        let createdLocation = EditorialLocation(
            identifiers: ["https://example.test/places/city-hall"],
            name: "Oslo City Hall",
            sublocation: "Council chamber",
            city: "Oslo",
            provinceState: "Oslo",
            countryName: "Norway",
            countryCode: "NOR",
            worldRegion: "Europe",
            latitude: 59.9111,
            longitude: 10.7339,
            altitudeMeters: 12
        )
        let shownLocation = EditorialLocation(
            name: "Oslo Harbor",
            city: "Oslo",
            countryName: "Norway",
            countryCode: "NOR"
        )
        let original = IPTCMetadata(
            title: "Test Title",
            localizedTitles: [
                LocalizedMetadataText(languageTag: "x-default", value: "Default title"),
                LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk tittel"),
                LocalizedMetadataText(languageTag: "nn", value: "Nynorsk tittel"),
            ],
            description: "A description",
            extendedDescription: "Extended",
            keywords: ["kw1", "kw2"],
            personShown: ["Alice"],
            organisationsShownNames: ["Example News", "Example Sport"],
            organisationsShownCodes: ["EXNEWS", "EXSPORT"],
            digitalSourceType: .digitalCapture,
            urgency: 2,
            latitude: 59.913,
            longitude: 10.752,
            creator: "Creator Name",
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk",
            credit: "Credit Line",
            copyright: "© 2026",
            rightsUsageTerms: "Editorial use only",
            webStatementOfRights: "https://example.test/rights",
            digitalImageGUID: "urn:uuid:01234567-89ab-cdef-0123-456789abcdef",
            imageSupplierImageID: "AGENCY-2026-0042",
            jobId: "JOB123",
            dateCreated: "2026-01-01",
            captureDate: "2026-01-01T12:00:00",
            city: "Oslo",
            sublocation: "Ullevaal Stadion",
            provinceState: "Oslo",
            country: "Norway",
            countryCode: "NOR",
            event: "Test Event",
            instructions: "Editorial use only",
            source: "Aagedal News",
            creatorContactInfo: contact,
            locationsCreated: [createdLocation],
            locationsShown: [shownLocation],
            rating: 4,
            label: "Red"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(IPTCMetadata.self, from: data)

        #expect(decoded.title == "Test Title")
        #expect(decoded.localizedTitles == original.localizedTitles)
        #expect(decoded.description == "A description")
        #expect(decoded.extendedDescription == "Extended")
        #expect(decoded.keywords == ["kw1", "kw2"])
        #expect(decoded.personShown == ["Alice"])
        #expect(decoded.organisationsShownNames == ["Example News", "Example Sport"])
        #expect(decoded.organisationsShownCodes == ["EXNEWS", "EXSPORT"])
        #expect(decoded.digitalSourceType == .digitalCapture)
        #expect(decoded.urgency == 2)
        #expect(decoded.latitude == 59.913)
        #expect(decoded.longitude == 10.752)
        #expect(decoded.creator == "Creator Name")
        #expect(decoded.creatorJobTitle == "Staff Photographer")
        #expect(decoded.descriptionWriter == "Night Desk")
        #expect(decoded.credit == "Credit Line")
        #expect(decoded.copyright == "© 2026")
        #expect(decoded.rightsUsageTerms == "Editorial use only")
        #expect(decoded.webStatementOfRights == "https://example.test/rights")
        #expect(decoded.digitalImageGUID == "urn:uuid:01234567-89ab-cdef-0123-456789abcdef")
        #expect(decoded.imageSupplierImageID == "AGENCY-2026-0042")
        #expect(decoded.jobId == "JOB123")
        #expect(decoded.dateCreated == "2026-01-01")
        #expect(decoded.captureDate == "2026-01-01T12:00:00")
        #expect(decoded.city == "Oslo")
        #expect(decoded.sublocation == "Ullevaal Stadion")
        #expect(decoded.provinceState == "Oslo")
        #expect(decoded.country == "Norway")
        #expect(decoded.countryCode == "NOR")
        #expect(decoded.event == "Test Event")
        #expect(decoded.instructions == "Editorial use only")
        #expect(decoded.source == "Aagedal News")
        #expect(decoded.creatorContactInfo == contact)
        #expect(decoded.locationsCreated == [createdLocation])
        #expect(decoded.locationsShown == [shownLocation])
        #expect(decoded.rating == 4)
        #expect(decoded.label == "Red")
    }

    @Test("legacy JSON without localizedTitles decodes as untouched")
    func legacyJSONDefaultsLocalizedTitlesToNil() throws {
        let decoded = try decoder.decode(
            IPTCMetadata.self,
            from: Data(#"{"title":"Legacy headline"}"#.utf8)
        )
        #expect(decoded.title == "Legacy headline")
        #expect(decoded.localizedTitles == nil)
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
        #expect(decoded.creatorContactInfo == nil)
        #expect(decoded.locationsCreated.isEmpty)
        #expect(decoded.locationsShown.isEmpty)
        #expect(decoded.rating == nil)
    }

    @Test("older structured shapes decode missing repeated values as empty arrays")
    func partialStructuredShapesDecodeDefaults() throws {
        let json = """
        {
          "creatorContactInfo": { "city": "Oslo" },
          "locationsCreated": [{ "city": "Oslo", "countryCode": "NOR" }],
          "locationsShown": [{ "name": "Harbor" }]
        }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(IPTCMetadata.self, from: json)

        #expect(decoded.creatorContactInfo?.city == "Oslo")
        #expect(decoded.creatorContactInfo?.addressLines.isEmpty == true)
        #expect(decoded.creatorContactInfo?.emails.isEmpty == true)
        #expect(decoded.locationsCreated.first?.identifiers.isEmpty == true)
        #expect(decoded.locationsCreated.first?.countryCode == "NOR")
        #expect(decoded.locationsShown.first?.name == "Harbor")
    }
}

// MARK: - FieldKey

@Suite("IPTCMetadata.FieldKey")
struct FieldKeyTests {

    @Test("legacy FieldKey spelling aliases the stable field ID")
    func legacyFieldKeySpellingRemainsCompatible() throws {
        let legacy: IPTCMetadata.FieldKey = .title
        #expect(legacy == MetadataFieldID.headline)
        #expect(MetadataFieldID.headline.rawValue == "title")

        let stored = Data(#"["title","description","provinceState"]"#.utf8)
        let decoded = try JSONDecoder().decode([MetadataFieldID].self, from: stored)
        #expect(decoded == [.headline, .description, .provinceState])
        #expect(try JSONEncoder().encode(decoded) == stored)
    }

    @Test("stored requirement maps load through stable field IDs")
    func storedRequirementMapsRemainCompatible() throws {
        let suiteName = "MetadataFieldIDTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let levels = #"{"title":"require","description":"warnOnEmpty","copyright":"futurePolicy","unknownFutureField":"require"}"#
        defaults.set(Data(levels.utf8), forKey: UserDefaultsKeys.metadataRequirementLevels)

        #expect(MetadataRequirements.load(from: defaults) == [
            .title: .require,
            .description: .warnOnEmpty,
        ])

        MetadataRequirements.save([.headline: .require], to: defaults)
        let saved = try #require(defaults.data(forKey: UserDefaultsKeys.metadataRequirementLevels))
        let savedMap = try JSONDecoder().decode([String: String].self, from: saved)
        #expect(savedMap == [
            "title": "require",
            "copyright": "futurePolicy",
            "unknownFutureField": "require",
        ])
    }

    @Test("saving minimum lengths preserves fields unknown to this build")
    func futureMinimumLengthFieldsRemainUntouched() throws {
        let suiteName = "MetadataMinimumLengthFutureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"description":20,"copyright":-1,"futureCaptionField":99}"#.utf8),
            forKey: UserDefaultsKeys.metadataMinimumLengths
        )

        MetadataRequirements.saveMinimumLengths([.description: 30], to: defaults)

        let saved = try #require(
            defaults.data(forKey: UserDefaultsKeys.metadataMinimumLengths)
        )
        #expect(try JSONDecoder().decode([String: Int].self, from: saved) == [
            "description": 30,
            "copyright": -1,
            "futureCaptionField": 99,
        ])
    }

    @Test("legacy required-field arrays migrate without changing persisted values")
    func legacyRequiredFieldArrayMigrates() throws {
        let suiteName = "MetadataFieldIDLegacyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stored = Data(#"["title","copyright"]"#.utf8)
        defaults.set(stored, forKey: UserDefaultsKeys.requiredMetadataFields)

        #expect(MetadataRequirements.load(from: defaults) == [
            .title: .require,
            .copyright: .require,
        ])
    }

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

    @Test("editor fields are partitioned into mandatory and optional fields")
    func editorFieldVisibilityGroupsAreComplete() {
        let mandatory = IPTCMetadata.FieldKey.alwaysVisibleEditorFields
        let optional = Set(IPTCMetadata.FieldKey.optionalEditorFields)

        #expect(mandatory == [.title, .description, .keywords, .copyright])
        #expect(mandatory.isDisjoint(with: optional))
        #expect(mandatory.union(optional) == Set(IPTCMetadata.FieldKey.editorFields))
        #expect(optional.isSuperset(of: [.sublocation, .provinceState, .instructions, .source]))
        #expect(IPTCMetadata.FieldKey.editorFields.contains(.dateCreated))
    }

    @Test("hidden-field decoding accepts only optional editable fields")
    func hiddenFieldDecodingSanitizesStoredValues() {
        let hidden = IPTCMetadata.FieldKey.decodeHidden([
            "extendedDescription",
            "creator",
            "title",
            "keywords",
            "dateCreated",
            "unknownFutureField",
        ])

        #expect(hidden == [.extendedDescription, .creator, .dateCreated])
    }

    @Test("fresh installs start with the concise editorial field set")
    func freshInstallFieldVisibilityDefaults() {
        let visible = Set(IPTCMetadata.FieldKey.editorFields)
            .subtracting(IPTCMetadata.FieldKey.resolvedHiddenEditorFields(storedRawValues: nil))

        #expect(visible == [
            .headline,
            .description,
            .keywords,
            .creator,
            .copyright,
            .personShown,
            .rightsUsageTerms,
        ])
    }

    @Test("an explicit stored visibility choice survives upgrade")
    func storedFieldVisibilitySurvivesUpgrade() {
        #expect(IPTCMetadata.FieldKey.resolvedHiddenEditorFields(storedRawValues: []) == [])
        #expect(IPTCMetadata.FieldKey.resolvedHiddenEditorFields(
            storedRawValues: ["creator", "futureEditorialField"]
        ) == [.creator])
    }

    @Test("field order defaults, persists, and repairs duplicate or missing values")
    func editorFieldOrderRecovery() {
        #expect(MetadataFieldID.resolvedEditorFieldOrder(storedRawValues: nil)
            == MetadataFieldID.editorFields)

        let recovered = MetadataFieldID.resolvedEditorFieldOrder(storedRawValues: [
            "country", "title", "country", "futureEditorialField",
        ])
        #expect(recovered.prefix(2) == [.country, .headline])
        #expect(recovered.count == MetadataFieldID.editorFields.count)
        #expect(Set(recovered) == Set(MetadataFieldID.editorFields))
    }

    @Test("field order round trips through preferences")
    func editorFieldOrderPersistence() throws {
        let suiteName = "MetadataFieldOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["futureEditorialField", "title", "description"],
            forKey: UserDefaultsKeys.iptcMetadataFieldOrder
        )
        let custom = [.description, .headline] + MetadataFieldID.editorFields.filter {
            $0 != .description && $0 != .headline
        }

        MetadataFieldID.saveEditorFieldOrder(custom, to: defaults)

        #expect(MetadataFieldID.loadEditorFieldOrder(from: defaults) == custom)
        #expect(defaults.stringArray(forKey: UserDefaultsKeys.iptcMetadataFieldOrder)?.first
            == "futureEditorialField")
    }

    @Test("dragging downward places the field immediately before its target")
    @MainActor
    func downwardFieldReordering() {
        let order: [MetadataFieldID] = [.headline, .description, .keywords, .creator]
        #expect(SettingsViewModel.iptcMetadataFieldOrder(
            order,
            moving: .headline,
            before: .creator
        ) == [.description, .keywords, .headline, .creator])
    }

    @Test("dragging upward places the field immediately before its target")
    @MainActor
    func upwardFieldReordering() {
        let order: [MetadataFieldID] = [.headline, .description, .keywords, .creator]
        #expect(SettingsViewModel.iptcMetadataFieldOrder(
            order,
            moving: .creator,
            before: .description
        ) == [.headline, .creator, .description, .keywords])
    }

    @Test("saving field customization preserves unknown future field state")
    func futureFieldCustomizationRemainsRecoverable() {
        let order = MetadataFieldID.persistedEditorFieldOrder(
            [.description, .headline] + MetadataFieldID.editorFields.filter {
                $0 != .description && $0 != .headline
            },
            preserving: ["futureBefore", "title", "description", "futureAfter"]
        )
        #expect(order.prefix(4) == ["futureBefore", "description", "title", "futureAfter"])
        #expect(order.filter { $0 == "futureBefore" }.count == 1)
        #expect(order.filter { $0 == "futureAfter" }.count == 1)

        let hidden = MetadataFieldID.persistedHiddenEditorFields(
            [.creator, .headline],
            preserving: ["futureHidden", "creator"]
        )
        #expect(hidden.contains("futureHidden"))
        #expect(hidden.contains(MetadataFieldID.creator.rawValue))
        #expect(!hidden.contains(MetadataFieldID.headline.rawValue))
    }
}

@Suite("Explicit editorial field mutations")
struct MetadataFieldMutationTests {
    private func sampleValue(for field: MetadataFieldID) -> MetadataFieldMutationValue {
        if field.isRepeatable {
            let values: [String] = switch field {
            case .sceneCode: ["scn:011200", "099999"]
            case .keywords: ["wire", "café, presse"]
            case .personShown: ["Kari Nordmann", "李雷"]
            case .organisationShownName: ["Agence Ω", "Harbor Authority"]
            case .organisationShownCode: ["ORG-Ω", "NO-HARBOR"]
            case .subjectCode: ["01000000", "15000000"]
            case .mediaTopic: ["20000587"]
            case .genre: ["Feature"]
            case .creator: ["First Reporter", "Second Reporter"]
            default: []
            }
            return .repeatable(values)
        }

        let value: String = switch field {
        case .digitalSourceType: DigitalSourceType.digitalCapture.newsCodeURI
        case .urgency: "5"
        case .countryCode: "nor"
        case .dateCreated: "2026-08-21T10:15:30Z"
        case .webStatementOfRights: "https://example.test/rights"
        case .digitalImageGUID: "urn:uuid:01234567-89ab-cdef-0123-456789abcdef"
        case .imageSupplier: "[{\"identifier\":\"agency-42\",\"name\":\"Agency 42\"}]"
        default: "Editorial Ω \(field.rawValue)"
        }
        return .scalar(value)
    }

    @Test("Every stable field has one writer key and writable verification field")
    func completeTypedSupportRegistry() {
        let fields = MetadataFieldID.allCases
        #expect(Set(fields.map(\.metadataWriteKey)).count == fields.count)
        #expect(Set(fields.map(\.verificationField)).count == fields.count)
        #expect(fields.allSatisfy {
            IPTCMetadataVerificationField.writableFields.contains($0.verificationField)
        })
    }

    @Test("Every selected field distinguishes overwrite, clear, and untouched")
    func perFieldOverwriteClearUntouched() throws {
        for field in MetadataFieldID.allCases {
            let original = IPTCMetadata(title: "unrelated sentinel")
            let overwritten = try MetadataFieldMutationSet([
                field: .overwrite(sampleValue(for: field)),
            ]).applying(to: original)

            #expect(!field.isEmpty(in: overwritten), "overwrite failed for \(field)")
            #expect(
                overwritten.toWriteFields()[field.metadataWriteKey] != nil,
                "writer mapping missing for \(field)"
            )
            #expect(
                IPTCMetadataVerifier.canonicalValue(
                    for: field.verificationField,
                    in: overwritten
                ) != .absent,
                "verification mapping missing for \(field)"
            )

            let untouched = try MetadataFieldMutationSet([
                field: .untouched,
            ]).applying(to: overwritten)
            #expect(untouched == overwritten, "untouched changed \(field)")

            let cleared = try MetadataFieldMutationSet([
                field: .clear,
            ]).applying(to: overwritten)
            #expect(field.isEmpty(in: cleared), "clear failed for \(field)")
            #expect(
                cleared.toOverwriteFields()[field.metadataWriteKey] == "",
                "authoritative clear missing for \(field)"
            )

            if field != .headline {
                #expect(cleared.title == "unrelated sentinel")
            }
        }
    }

    @Test("Every repeatable field appends Unicode values without duplicates")
    func repeatableAppend() throws {
        for field in MetadataFieldID.allCases where field.isRepeatable {
            var metadata = IPTCMetadata()
            let seed: String
            let addition: String
            let expected: [String]
            switch field {
            case .subjectCode:
                seed = "01000000"
                addition = "15000000"
                expected = ["01000000", "15000000"]
            case .mediaTopic:
                seed = "20000587"
                addition = "20000586"
                expected = [
                    IPTCControlledVocabularyTerm.mediaTopicSchemeURI + "20000587",
                    IPTCControlledVocabularyTerm.mediaTopicSchemeURI + "20000586",
                ]
            case .genre:
                seed = "Feature"
                addition = "Analysis"
                expected = [
                    IPTCControlledVocabularyTerm.genreSchemeURI + "Feature",
                    IPTCControlledVocabularyTerm.genreSchemeURI + "Analysis",
                ]
            default:
                seed = "existing"
                addition = "əlavə Ω"
                expected = [seed, addition]
            }
            try metadata.apply(.overwrite(.repeatable([seed])), to: field)
            try metadata.apply(.append([seed, "  \(addition)  "]), to: field)

            let value = try #require(field.historyValue(in: metadata))
            let decoded: [String]
            if field == .mediaTopic || field == .genre {
                decoded = try JSONDecoder().decode(
                    [IPTCControlledVocabularyTerm].self,
                    from: Data(value.utf8)
                ).map(\.termIdentifier)
            } else {
                decoded = try JSONDecoder().decode([String].self, from: Data(value.utf8))
            }
            #expect(decoded == expected, "append failed for \(field)")
        }
    }

    @Test("Empty and shape-mismatched operations fail without changing the record")
    func ambiguousOperationsFailClosed() throws {
        let original = IPTCMetadata(title: "Keep", keywords: ["existing"])
        var metadata = original

        #expect(throws: MetadataFieldMutationError.emptyOverwriteRequiresClear(.headline)) {
            try metadata.apply(.overwrite(.scalar("  \n ")), to: .headline)
        }
        #expect(metadata == original)

        #expect(throws: MetadataFieldMutationError.repeatableValueRequired(.keywords)) {
            try metadata.apply(.overwrite(.scalar("one, two")), to: .keywords)
        }
        #expect(metadata == original)

        #expect(throws: MetadataFieldMutationError.scalarValueRequired(.headline)) {
            try metadata.apply(.overwrite(.repeatable(["value"])), to: .headline)
        }
        #expect(metadata == original)

        #expect(throws: MetadataFieldMutationError.appendRequiresRepeatableField(.headline)) {
            try metadata.apply(.append(["value"]), to: .headline)
        }
        #expect(metadata == original)

        #expect(throws: MetadataFieldMutationError.emptyAppendRequiresUntouched(.keywords)) {
            try metadata.apply(.append(["", " \n "]), to: .keywords)
        }
        #expect(metadata == original)
    }

    @Test("Controlled values store canonical identifiers rather than display labels")
    func controlledValuesAreCanonical() throws {
        var metadata = IPTCMetadata()
        try metadata.apply(
            .overwrite(.scalar(DigitalSourceType.humanEdits.newsCodeURI)),
            to: .digitalSourceType
        )
        try metadata.apply(
            .overwrite(.repeatable(["011200 — Aerial view", "scn:012400", "099999"])),
            to: .sceneCode
        )
        try metadata.apply(.overwrite(.scalar("nor")), to: .countryCode)

        #expect(metadata.digitalSourceType == .humanEdits)
        #expect(MetadataFieldID.digitalSourceType.textValue(in: metadata) == DigitalSourceType.humanEdits.newsCodeURI)
        #expect(MetadataFieldID.digitalSourceType.textValue(in: metadata) != DigitalSourceType.humanEdits.displayName)
        #expect(metadata.sceneCodes == ["011200", "012400", "099999"])
        #expect(metadata.countryCode == "NOR")

        let beforeInvalid = metadata
        #expect(throws: MetadataFieldMutationError.invalidCanonicalValue(
            .digitalSourceType,
            "Not a controlled vocabulary value"
        )) {
            try metadata.apply(
                .overwrite(.scalar("Not a controlled vocabulary value")),
                to: .digitalSourceType
            )
        }
        #expect(metadata == beforeInvalid)
    }

    @Test("History replay canonicalizes Scene aliases and remains lossless for comma-bearing values")
    func historyReplayCanonicalizesControlledValues() throws {
        var metadata = IPTCMetadata()
        let sceneHistory = try #require(String(
            data: JSONEncoder().encode(["scn:011200", "011200 — Aerial view", "099999"]),
            encoding: .utf8
        ))
        MetadataFieldID.sceneCode.setHistoryValue(sceneHistory, in: &metadata)
        #expect(metadata.sceneCodes == ["011200", "099999"])

        let keywordHistory = try #require(String(
            data: JSONEncoder().encode(["café, presse", "東京", "café, presse"]),
            encoding: .utf8
        ))
        MetadataFieldID.keywords.setHistoryValue(keywordHistory, in: &metadata)
        #expect(metadata.keywords == ["café, presse", "東京"])

        let typedTerms = [
            IPTCControlledVocabularyTerm(
                vocabularyIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI,
                termIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI + "20000587",
                name: "Photography",
                refinedAbout: "https://example.test/topics/photojournalism"
            ),
            IPTCControlledVocabularyTerm(
                vocabularyIdentifier: "https://example.test/vocab/",
                termIdentifier: "https://example.test/vocab/concept-42",
                name: "Newsroom concept"
            ),
        ]
        metadata.mediaTopics = typedTerms
        let typedHistory = try #require(MetadataFieldID.mediaTopic.historyValue(in: metadata))
        metadata.mediaTopics = []
        MetadataFieldID.mediaTopic.setHistoryValue(typedHistory, in: &metadata)
        #expect(metadata.mediaTopics == typedTerms)
    }

    @Test("Controlled repeatable mutation rejects partial invalid input transactionally")
    func controlledRepeatableMutationFailsClosed() throws {
        var metadata = IPTCMetadata(
            subjectCodes: ["legacy-newsroom-subject"],
            mediaTopics: [IPTCControlledVocabularyTerm(
                vocabularyIdentifier: "https://example.test/vocab/",
                termIdentifier: "https://example.test/vocab/concept-42",
                name: "Newsroom concept"
            )]
        )
        let original = metadata

        #expect(throws: MetadataFieldMutationError.invalidCanonicalValue(
            .mediaTopic,
            "not a URI"
        )) {
            try metadata.apply(
                .overwrite(.repeatable(["20000587", "not a URI"])),
                to: .mediaTopic
            )
        }
        #expect(metadata == original)

        try metadata.apply(.append(["20000587"]), to: .mediaTopic)
        #expect(metadata.mediaTopics.first == original.mediaTopics.first)
        #expect(metadata.mediaTopics.last?.mediaTopicCode == "20000587")
    }

    @Test("Mutation transport types are Sendable and can prepare off-main")
    func sendableDetachedPreparation() async throws {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(MetadataFieldMutationValue.self)
        requireSendable(MetadataFieldMutation.self)
        requireSendable(MetadataFieldMutationSet.self)
        requireSendable(MetadataFieldMutationError.self)

        let mutations = MetadataFieldMutationSet([
            .headline: .overwrite(.scalar("Detached headline")),
            .keywords: .append(["wire", "Unicode Ω"]),
        ])
        let result = try await Task.detached {
            try Task.checkCancellation()
            return try mutations.applying(to: IPTCMetadata(keywords: ["existing"]))
        }.value

        #expect(result.title == "Detached headline")
        #expect(result.keywords == ["existing", "wire", "Unicode Ω"])
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

    @Test("two-point endpoint tone curves parse as edits")
    func twoPointEndpointToneCurveParsesAsEdit() throws {
        let identity = parseToneCurveArray(["0, 0", "255, 255"])
        #expect(identity == nil)

        let shadowLift = try #require(parseToneCurveArray(["0, 51", "255, 255"]))
        #expect(shadowLift.count == 2)
        #expect(shadowLift.isIdentityToneCurve == false)
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

    @Test("Custom RAW resolution coerces an unsafe embedded preference to XMP")
    func customRaw() {
        withPreset(.custom) {
            let key = UserDefaultsKeys.metadataWriteModeRaw
            let saved = AppDefaults.store.string(forKey: key)
            AppDefaults.store.set(MetadataWriteMode.writeToFile.rawValue, forKey: key)
            defer {
                if let saved { AppDefaults.store.set(saved, forKey: key) }
                else { AppDefaults.store.removeObject(forKey: key) }
            }
            #expect(MetadataWriteMode.current(forC2PA: false, isRaw: true) == .writeToXMPSidecar)
            #expect(MetadataWriteMode.rawOptions == [.historyOnly, .writeToXMPSidecar])
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

    @Test("iptcMetadataFromDict decodes app-private global density")
    func dictParseDecodesGlobalDensity() throws {
        let dict: [String: Any] = [
            MetadataDictKey.globalDensity: "+35",
        ]
        #expect(iptcMetadataFromDict(dict).cameraRaw?.globalDensity == 35)
    }

    @Test("iptcMetadataFromDict decodes ACR detail adjustments")
    func dictParseDecodesDetailAdjustments() throws {
        let dict: [String: Any] = [
            MetadataDictKey.crsSharpness: "50",
            MetadataDictKey.crsClarity2012: "+24",
            MetadataDictKey.crsDehaze: "+19",
        ]
        let settings = try #require(iptcMetadataFromDict(dict).cameraRaw)
        #expect(settings.sharpness == 50)
        #expect(settings.clarity2012 == 24)
        #expect(settings.dehaze == 19)
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

@Suite("Rounded rectangle mask extension")
struct RoundedRectangleMaskTests {
    @Test("an imported ACR circular gradient remains a standard ellipse")
    func importedACRMaskDefaultsToEllipse() throws {
        let corrections: [[String: Any]] = [[
            "CorrectionActive": "true",
            "CorrectionName": "Radial",
            "CorrectionMasks": [[
                "What": "Mask/CircularGradient",
                "Top": "0.2", "Left": "0.1", "Bottom": "0.8", "Right": "0.9",
                "Angle": "0", "Feather": "50", "Flipped": "true",
            ]],
        ]]

        let mask = try #require(parseMaskGroupBasedCorrections(corrections)?.masks.first)
        #expect(mask.geometry.cornerRadius == nil)
        #expect(mask.geometry.normalizedCornerRadius == 1)
        #expect(mask.layerKind == .ellipseMask)
    }

    @Test("custom corner radius keeps the ACR circular-gradient fallback")
    func customShapeEncodesACRFallback() throws {
        var geometry = EllipseMaskGeometry()
        geometry.cornerRadius = 0.25
        let mask = MaskAdjustment(name: "Rounded", geometry: geometry)

        let correction = try #require(encodeMaskGroupBasedCorrections([mask]).first)
        #expect(correction.maskFields.contains { $0.name == "What" && $0.value == "Mask/CircularGradient" })
        #expect(correction.maskFields.contains { $0.name == "Roundness" && $0.value == "0" })
        #expect(correction.appPrivateFields.contains { $0.name == "CornerRadius" && $0.value == "0.25" })
        #expect(mask.layerKind == .rectangleMask)
    }

    @Test("corner radius round-trips through an XMP sidecar")
    func cornerRadiusRoundTripsThroughSidecar() throws {
        let service = XMPSidecarService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var geometry = EllipseMaskGeometry()
        geometry.cornerRadius = 0.4
        var settings = CameraRawSettings()
        settings.localAdjustments = [MaskAdjustment(name: "Rounded", geometry: geometry)]
        let imageURL = directory.appendingPathComponent("rounded.jpg")

        try service.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let reloaded = try #require(service.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first)
        #expect(reloaded.geometry.cornerRadius.map { abs($0 - 0.4) < 1e-9 } == true)
        #expect(reloaded.layerKind == .rectangleMask)
    }
}

@Suite("Secondary Global layer")
struct SecondaryGlobalLayerTests {
    @Test("full-frame marker keeps an ACR circular-gradient fallback")
    func encodesFullFrameMarkerAndFallback() throws {
        var geometry = EllipseMaskGeometry()
        geometry.centerX = 0.5
        geometry.centerY = 0.5
        geometry.radiusX = 2
        geometry.radiusY = 2
        geometry.feather = 0
        let layer = MaskAdjustment(
            name: "Global 2",
            geometry: geometry,
            fullFrame: true,
            exposure: 0.5
        )

        let correction = try #require(encodeMaskGroupBasedCorrections([layer]).first)
        #expect(correction.maskFields.contains {
            $0.name == "What" && $0.value == "Mask/CircularGradient"
        })
        #expect(correction.appPrivateFields.contains {
            $0.name == "FullFrame" && $0.value == "True"
        })
        #expect(layer.layerKind == .secondaryGlobal)
    }

    @Test("full-frame marker round-trips through an XMP sidecar")
    func roundTripsThroughSidecar() throws {
        let service = XMPSidecarService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var layer = MaskAdjustment(name: "Global 2", fullFrame: true, exposure: 0.75)
        layer.geometry.radiusX = 2
        layer.geometry.radiusY = 2
        layer.geometry.feather = 0
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]
        settings.layerOrder = [.global, .mask(layer.id)]
        let imageURL = directory.appendingPathComponent("secondary-global.jpg")

        try service.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let reloaded = try #require(
            service.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first
        )
        #expect(reloaded.isFullFrame)
        #expect(reloaded.layerKind == .secondaryGlobal)
        #expect(reloaded.name == "Global 2")
        #expect(reloaded.exposure.map { abs($0 - 0.75) < 0.001 } == true)
    }
}

@Suite("Color Transform layer")
struct ColorTransformLayerTests {
    private var space: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

    private var constantRedCube: Data {
        Data("""
        TITLE "News Red"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        0.8 0.1 0.2
        """.utf8)
    }

    private func solid(_ rgb: SIMD3<Float>, size: CGFloat = 32) -> CIImage {
        CIImage(color: CIColor(
            red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z),
            alpha: 1, colorSpace: space
        )!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func sampleRGB(_ image: CIImage, x: Int = 16, y: Int = 16) -> SIMD3<Float> {
        let context = CIContext(options: [.workingColorSpace: space])
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image,
            toBitmap: &buffer,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: CGRect(
                x: image.extent.origin.x + CGFloat(x),
                y: image.extent.origin.y + CGFloat(y),
                width: 1,
                height: 1
            ),
            format: .RGBAf,
            colorSpace: space
        )
        return SIMD3<Float>(buffer[0], buffer[1], buffer[2])
    }

    @Test(".cube parser reads title, domain, and red-fastest row order")
    func parsesCube() throws {
        let data = Data("""
        TITLE "Identity"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """.utf8)
        let cube = try CubeLUTParser.parse(data)
        #expect(cube.title == "Identity")
        #expect(cube.size == 2)
        #expect(cube.value(red: 1, green: 0, blue: 0) == SIMD3<Float>(1, 0, 0))
        #expect(cube.value(red: 0, green: 1, blue: 1) == SIMD3<Float>(0, 1, 1))
    }

    @Test(".cube parser rejects incomplete color tables")
    func rejectsIncompleteCube() {
        let data = Data("LUT_3D_SIZE 2\n0 0 0\n".utf8)
        #expect(throws: CubeLUTParser.ParseError.self) {
            try CubeLUTParser.parse(data)
        }
    }

    @Test("LUT settings round-trip losslessly through XMP")
    func lutRoundTripsThroughSidecar() throws {
        let service = XMPSidecarService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var layer = MaskAdjustment(name: "Transform", amount: 0.65, fullFrame: true)
        layer.colorTransform = ColorTransformSettings(
            mode: .lut,
            lutName: "News Red",
            lutData: constantRedCube
        )
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]
        settings.layerOrder = [.mask(layer.id), .global]
        let imageURL = directory.appendingPathComponent("transform.jpg")

        try service.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let reloaded = try #require(
            service.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first
        )
        #expect(reloaded.layerKind == .colorTransform)
        #expect(reloaded.amount == 0.65)
        #expect(reloaded.colorTransform?.mode == .lut)
        #expect(reloaded.colorTransform?.lutName == "News Red")
        #expect(reloaded.colorTransform?.lutData == constantRedCube)
    }

    @Test("CST settings round-trip through XMP")
    func cstRoundTripsThroughSidecar() throws {
        let service = XMPSidecarService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var layer = MaskAdjustment(name: "CST", fullFrame: true)
        layer.colorTransform = ColorTransformSettings(
            mode: .cst,
            inputSpace: .linearRec2020,
            outputSpace: .linearDisplayP3
        )
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]
        let imageURL = directory.appendingPathComponent("cst.jpg")

        try service.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let transform = try #require(
            service.loadSidecar(for: imageURL)?
                .cameraRaw?.localAdjustments?.first?.colorTransform
        )
        #expect(transform.mode == .cst)
        #expect(transform.inputSpace == .linearRec2020)
        #expect(transform.outputSpace == .linearDisplayP3)
    }

    @Test("LUT mode transforms the complete frame")
    func lutRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var layer = MaskAdjustment(name: "Transform", fullFrame: true)
        layer.colorTransform = ColorTransformSettings(
            mode: .lut,
            lutName: "News Red",
            lutData: constantRedCube
        )
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]

        let result = try #require(MetalEditPipeline.renderOffscreen(
            source: solid(SIMD3<Float>(repeating: 0.4)),
            settings: settings
        ))
        let center = sampleRGB(result)
        let corner = sampleRGB(result, x: 1, y: 1)
        #expect(abs(center.x - 0.8) < 0.04)
        #expect(abs(center.y - 0.1) < 0.04)
        #expect(abs(center.z - 0.2) < 0.04)
        #expect(abs(center.x - corner.x) < 0.02)
        #expect(abs(center.y - corner.y) < 0.02)
        #expect(abs(center.z - corner.z) < 0.02)
    }

    @Test("CST mode converts linear sRGB primaries to linear Display P3")
    func cstRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var layer = MaskAdjustment(name: "CST", fullFrame: true)
        layer.colorTransform = ColorTransformSettings(
            mode: .cst,
            inputSpace: .linearSRGB,
            outputSpace: .linearDisplayP3
        )
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]

        let result = try #require(MetalEditPipeline.renderOffscreen(
            source: solid(SIMD3<Float>(1, 0, 0)),
            settings: settings
        ))
        let rgb = sampleRGB(result)
        #expect(abs(rgb.x - 0.8226) < 0.04)
        #expect(abs(rgb.y - 0.0332) < 0.03)
        #expect(abs(rgb.z - 0.0171) < 0.03)
    }
}

@Suite("Photo Agent AI mask extension")
struct AIMaskExtensionTests {
    @Test("Face is a distinct persisted AI-mask target")
    func faceTargetRoundTrips() throws {
        let encoded = try JSONEncoder().encode(AIMaskTarget.face)
        #expect(try JSONDecoder().decode(AIMaskTarget.self, from: encoded) == .face)
        #expect(AIMaskTarget.face.title == "Face")

        let png = try #require(grayscalePNG([255], width: 1, height: 1))
        let mask = MaskAdjustment(
            name: "Face",
            aiMask: AIMaskGeometry(width: 1, height: 1, pngData: png, target: .face)
        )
        let correction = try #require(encodeMaskGroupBasedCorrections([mask]).first)
        #expect(correction.appPrivateFields.contains {
            $0.name == "AIMaskTarget" && $0.value == "face"
        })
    }

    @Test("Face matte uses top-left raster rows and a soft oval")
    func faceMatteShapeAndCoordinates() {
        // Vision box occupies the image's upper-left quadrant (lower-left Vision y = 0.5).
        let width = 100
        let height = 100
        let bytes = AIMaskGenerator.renderFaceMaskBytes(
            boundingBox: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            width: width,
            height: height
        )
        func at(_ x: Int, _ y: Int) -> UInt8 { bytes[y * width + x] }

        #expect(bytes.count == width * height)
        #expect(at(25, 23) > 245) // face center in the top-left
        #expect(at(25, 77) == 0)  // vertically opposite point remains background
        #expect(at(0, 23) > 0 && at(0, 23) < 255) // feathered oval boundary
        #expect(at(75, 23) == 0)
    }

    @Test("AI masks encode a custom node without an ACR ellipse fallback")
    func encodesWithoutACRFallback() throws {
        let png = try #require(grayscalePNG([255, 0, 255, 0], width: 2, height: 2))
        let ai = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 6,
            displayOrientation: 6,
            target: .person
        )
        let mask = MaskAdjustment(name: "Subject", inverted: true, aiMask: ai, exposure: 0.5)

        let correction = try #require(encodeMaskGroupBasedCorrections([mask]).first)
        let custom = try #require(correction.customMaskFields)
        #expect(correction.maskFields.isEmpty)
        #expect(correction.correctionMasks == nil)
        #expect(custom.contains { $0.name == "What" && $0.value == "Mask/AISelection" })
        #expect(custom.contains { $0.name == "Inverted" && $0.value == "True" })
        #expect(!correction.maskFields.contains { $0.value == "Mask/CircularGradient" })
        #expect(correction.appPrivateFields.contains { $0.name == "AIMaskPNG" })
        #expect(correction.appPrivateFields.contains { $0.name == "AIMaskTarget" && $0.value == "person" })
        #expect(correction.appPrivateFields.contains { $0.name == "AIMaskVersion" && $0.value == "1" })
        #expect(!correction.appPrivateFields.contains { $0.name == "AIMaskBlackPoint" })
        #expect(!correction.appPrivateFields.contains { $0.name == "AIMaskWhitePoint" })
        #expect(!correction.appPrivateFields.contains { $0.name == "AIMaskBlurRadius" })
    }

    @Test("AI mask pixels and orientation round-trip through an XMP sidecar")
    func roundTripsThroughSidecar() throws {
        let service = XMPSidecarService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("ai-mask.jpg")
        let png = try #require(grayscalePNG([255, 0, 255, 0], width: 2, height: 2))
        let ai = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 8,
            displayOrientation: 8,
            target: .object,
            blackPoint: 0.2,
            whitePoint: 0.8,
            blurRadius: 0.005
        )
        var settings = CameraRawSettings()
        settings.localAdjustments = [MaskAdjustment(name: "Object", aiMask: ai, exposure: 0.75)]

        try service.saveCameraRawOnly(settings, orientation: nil, for: imageURL)
        let sidecar = imageURL.deletingPathExtension().appendingPathExtension("xmp")
        let xml = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xml.contains("Mask/AISelection"))
        #expect(!xml.contains("Mask/CircularGradient"))

        let reloaded = try #require(service.loadSidecar(for: imageURL)?.cameraRaw?.localAdjustments?.first)
        let reloadedAI = try #require(reloaded.aiMask)
        #expect(reloaded.layerKind == .aiMask)
        #expect(reloadedAI.width == 2)
        #expect(reloadedAI.height == 2)
        #expect(reloadedAI.sourceOrientation == 8)
        #expect(reloadedAI.resolvedTarget == .object)
        #expect(abs(reloadedAI.resolvedBlackPoint - 0.2) < 1e-9)
        #expect(abs(reloadedAI.resolvedWhitePoint - 0.8) < 1e-9)
        #expect(abs(reloadedAI.resolvedBlurRadius - 0.005) < 1e-9)
        #expect(reloadedAI.pngData == png)
        #expect(reloaded.inverted == false)
        #expect(reloaded.exposure.map { abs($0 - 0.75) < 1e-6 } == true)
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

    @Test("film emulation round-trips through an XMP sidecar save/load cycle")
    func filmEmulationRoundTripsThroughSidecar() throws {
        let svc = XMPSidecarService()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let imageURL = tmp.appendingPathComponent("film.jpg")

        var settings = CameraRawSettings()
        settings.filmEmulation = FilmEmulationSettings(
            grain: 18,
            halation: 27,
            bloom: 36,
            vignette: 45,
            edgeBlur: 54
        )
        try svc.saveCameraRawOnly(settings, orientation: nil, for: imageURL)

        let film = try #require(svc.loadSidecar(for: imageURL)?.cameraRaw?.filmEmulation)
        #expect(film.grain == 18)
        #expect(film.halation == 27)
        #expect(film.bloom == 36)
        #expect(film.vignette == 45)
        #expect(film.edgeBlur == 54)
        #expect(film.hasSpatialEffects)

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

    @Test("brush dabs survive a display↔sensor orientation round-trip for every EXIF value")
    func brushOrientationRoundTrips() {
        let geo = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.1, y: 0.2, flow: 0.6, hardness: 0.3),
                               BrushDab(x: 0.8, y: 0.55, flow: 0.6, hardness: 0.3)],
                        radius: 0.12, density: 1.0, erase: false)
        ])
        for orientation in 1...8 {
            let display = geo.transformedForDisplay(orientation: orientation)
            let back = display.transformedForSensor(orientation: orientation)
            for (a, b) in zip(back.strokes[0].dabs, geo.strokes[0].dabs) {
                #expect(abs(a.x - b.x) < 1e-9)
                #expect(abs(a.y - b.y) < 1e-9)
            }
            // A 90° family swap must actually move the point (not a no-op) except O=1.
            if orientation > 1 {
                #expect(display.strokes[0].dabs[0].x != geo.strokes[0].dabs[0].x
                        || display.strokes[0].dabs[0].y != geo.strokes[0].dabs[0].y)
            }
        }
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
@MainActor
struct BrushRasterizationTests {

    @Test("Metal render-state entry points retain explicit executor preconditions")
    func renderStateExecutorSourceContract() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: workspace.appendingPathComponent(
                "Aagedal Photo Agent/Services/MetalEditPipeline.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("private enum StateExecutor"))
        #expect(source.contains("case mainThread"))
        #expect(source.contains("case offscreenRenderQueue(DispatchQueue)"))
        #expect(source.contains("precondition(Thread.isMainThread, \"Live MetalEditPipeline instances"))
        #expect(source.contains("private final class OffscreenRendererExecutor"))
        #expect(source.contains("dispatchPrecondition(condition: .notOnQueue(queue))"))
        #expect(source.contains("dispatchPrecondition(condition: .onQueue(self.queue))"))
        #expect(source.contains("dispatchPrecondition(condition: .onQueue(queue))"))
        #expect(source.contains("await offscreenRenderer.renderAsync("))

        // Worker-safe state is concentrated in lock-backed publication objects instead of one
        // unsafe isolation escape per field. These names intentionally guard against regressing
        // to independently published texture/orientation or white-balance values.
        #expect(source.contains("private final class SourceState"))
        #expect(source.contains("private final class MirrorState"))
        #expect(source.contains("private final class WhiteBalanceReference"))
        #expect(source.contains("private final class ExecutorOwnedRenderPassState"))
        #expect(source.contains("private struct ViewportStateSnapshot: Sendable"))
        #expect(source.contains("private final class ExecutorOwnedViewportState"))
        #expect(source.contains("private final class ExecutorOwnedCacheState"))
        #expect(source.contains("private func withExecutorOwnedCacheState"))
        #expect(source.contains("this holder can escape that closure"))
        #expect(!source.contains("private var _sourceTexture"))
        #expect(!source.contains("private var _sourceOrientation"))
        #expect(!source.contains("private var _asShotTemperature"))
        #expect(!source.contains("private var _asShotTint"))
        #expect(source.contains("other.preconditionOnStateExecutor()"))
        #expect(!source.contains("nonisolated(unsafe) private var renderPassPlan"))
        #expect(!source.contains("cachedViewportOrigin"))
        #expect(!source.contains("cachedViewportSize"))
        #expect(!source.contains("cachedViewportCenter"))
        #expect(!source.contains("cachedViewportRotation"))
        #expect(!source.contains("cachedCropHalfExtent"))
        for signature in [
            "nonisolated private func replaceRenderPassPlan",
            "nonisolated private func renderPassPlanSnapshot",
            "nonisolated private func replaceViewportState",
            "nonisolated private func viewportStateSnapshot",
            "nonisolated private func withExecutorOwnedCacheState",
        ] {
            let start = try #require(source.range(of: signature))
            let suffix = source[start.lowerBound...]
            let bodyStart = try #require(suffix.firstIndex(of: "{"))
            let bodyPrefix = suffix[bodyStart...].prefix(180)
            #expect(
                bodyPrefix.contains("preconditionOnStateExecutor()"),
                Comment(rawValue: signature)
            )
        }

        // CPU-only conversion scratch and parsed/matrix caches are one executor-owned lifetime,
        // rather than six independently unsafe fields. Their only pipeline-level storage is the
        // immutable holder above, and its checked synchronous access boundary is exercised by
        // LUT upload, cube refresh, and white-balance resolution.
        for removedDeclaration in [
            "nonisolated(unsafe) private var float16Buffer",
            "nonisolated(unsafe) private var lutInterleaveBuffer",
            "nonisolated(unsafe) private var lastBuiltColorLUTData",
            "nonisolated(unsafe) private var parsedColorLUTs",
            "nonisolated(unsafe) private var cachedWBKey",
            "nonisolated(unsafe) private var cachedWBMatrix",
        ] {
            #expect(!source.contains(removedDeclaration), Comment(rawValue: removedDeclaration))
        }
        #expect(source.contains("withExecutorOwnedCacheState { cacheState in"))
        #expect(source.contains("withExecutorOwnedCacheState({ $0.parsedColorLUTs[i] })"))

        // Metal resource references allocated during initialization are immutable Sendable
        // wrappers. Their buffer/texture contents are still mutated only through the
        // executor-checked methods below; only MTLTextureWrapper's cache payload retains an
        // unsafe annotation because the Metal protocol itself is not Sendable.
        #expect(source.contains("private struct StableMetalHandle<Resource>: @unchecked Sendable"))
        for declaration in [
            "nonisolated private let paramsBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let lutTextureHandle: StableMetalHandle<MTLTexture>",
            "nonisolated private let identityLutTextureHandle: StableMetalHandle<MTLTexture>",
            "nonisolated private let maskBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let hslBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let orderBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let overlayParamsBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let emptyBrushAlphaHandle: StableMetalHandle<MTLTexture>",
            "nonisolated private let watermarkParamsBufferHandle: StableMetalHandle<MTLBuffer?>",
            "nonisolated private let emptyWatermarkTextureHandle: StableMetalHandle<MTLTexture>",
            "nonisolated private let colorLUTTextureHandle: StableMetalHandle<MTLTexture>",
        ] {
            #expect(source.contains(declaration), Comment(rawValue: declaration))
        }
        let unsafeEscapeCount = source.components(separatedBy: "nonisolated(unsafe)").count - 1
        #expect(unsafeEscapeCount <= 18)

        for signature in [
            "nonisolated func updateParams",
            "nonisolated func updateOverlayParams",
            "nonisolated func rebuildMaskAlpha",
            "nonisolated func stampBrushStroke",
            "nonisolated func render(",
            "nonisolated func updateViewport",
            "nonisolated func updateCropViewport",
        ] {
            let start = try #require(source.range(of: signature))
            let suffix = source[start.lowerBound...]
            let bodyStart = try #require(suffix.firstIndex(of: "{"))
            let bodyPrefix = suffix[bodyStart...].prefix(180)
            #expect(
                bodyPrefix.contains("preconditionOnStateExecutor()"),
                Comment(rawValue: signature)
            )
        }
    }

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

    @Test("a soft dab fades across its nominal circle and extends beyond it")
    func centeredDabCoverage() throws {
        guard let pipeline = makePipeline() else { return }
        #expect(pipeline.hasBrushPipeline)
        let size = MTLSize(width: 128, height: 128, depth: 1)
        // radius 0.125 of long edge (128) = 16px, centered soft dab at full flow.
        let brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 0.0)],
                        radius: 0.125, density: 1.0, erase: false)
        ])
        let tex = try #require(pipeline.rebuildBrushAlpha([brush], size: size))
        #expect(tex.arrayLength == 1)
        let px = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { px[y * 128 + x] }
        #expect(at(64, 64) > 0.99)         // center pixel is effectively fully covered
        let nominalBoundary = at(80, 64)   // approximately 16px from center
        #expect(nominalBoundary > 0.4 && nominalBoundary < 0.6)
        let outsidePreviewCircle = at(88, 64)
        #expect(outsidePreviewCircle > 0.15 && outsidePreviewCircle < nominalBoundary)
        let outerTail = at(104, 64)        // >2.5× radius: beyond the previous finite cutoff
        #expect(outerTail > 0.005 && outerTail < outsidePreviewCircle)
        #expect(at(120, 64) == 0)          // beyond the 1/1024 raster cutoff
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

    @Test("an AI matte scales into the shared raster alpha slice")
    func aiMaskRasterizes() throws {
        guard let pipeline = makePipeline() else { return }
        // Left column selected, right column clear. Horizontal sampling avoids any ambiguity in
        // bitmap row origin while still proving PNG decode + GPU scaling + slice upload.
        let png = try #require(grayscalePNG([255, 0, 255, 0], width: 2, height: 2))
        let ai = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 1,
            displayOrientation: 1
        )
        let tex = try #require(pipeline.rebuildMaskAlpha([.ai(ai)], size: MTLSize(width: 64, height: 64, depth: 1)))
        let pixels = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { pixels[y * 64 + x] }
        #expect(at(8, 32) > 0.9)
        #expect(at(56, 32) < 0.1)
    }

    @Test("AI matte black and white points remap confidence values")
    func aiMaskLevelsRefineConfidence() throws {
        guard let pipeline = makePipeline() else { return }
        let png = try #require(grayscalePNG([0, 64, 128, 192, 255], width: 5, height: 1))
        let ai = AIMaskGeometry(
            width: 5,
            height: 1,
            pngData: png,
            blackPoint: 0.25,
            whitePoint: 0.75
        )
        let tex = try #require(pipeline.rebuildMaskAlpha(
            [.ai(ai)],
            size: MTLSize(width: 5, height: 1, depth: 1)
        ))
        let pixels = readSlice(tex, slice: 0)
        #expect(pixels[0] < 0.01)
        #expect(pixels[1] < 0.02)
        #expect(pixels[2] > 0.48 && pixels[2] < 0.53)
        #expect(pixels[3] > 0.98)
        #expect(pixels[4] > 0.99)
    }

    @Test("AI matte blur softens both sides of a hard contour")
    func aiMaskBlurSoftensContour() throws {
        guard let pipeline = makePipeline() else { return }
        let width = 101
        let height = 101
        let bytes = (0..<(width * height)).map { index -> UInt8 in
            (index % width) >= 50 ? 255 : 0
        }
        let png = try #require(grayscalePNG(bytes, width: width, height: height))
        let ai = AIMaskGeometry(
            width: width,
            height: height,
            pngData: png,
            blurRadius: 0.02
        )
        let tex = try #require(pipeline.rebuildMaskAlpha(
            [.ai(ai)],
            size: MTLSize(width: width, height: height, depth: 1)
        ))
        let pixels = readSlice(tex, slice: 0)
        func at(_ x: Int) -> Float { pixels[50 * width + x] }
        #expect(at(47) > 0.005 && at(47) < 0.5)
        #expect(at(52) > 0.5 && at(52) < 0.995)
        #expect(at(40) < 0.005)
        #expect(at(60) > 0.995)
    }

    @Test("Core Image AI mattes retain their vertical orientation through PNG and Metal")
    func aiMaskVerticalOrientation() throws {
        guard let pipeline = makePipeline() else { return }
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 1, width: 2, height: 1))
        let image = white.composited(over: black)
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let png = try #require(AIMaskGenerator.renderGrayscalePNG(
            from: image,
            width: 2,
            height: 2,
            bounds: image.extent
        ))
        let ai = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 1,
            displayOrientation: 1
        )
        let tex = try #require(pipeline.rebuildMaskAlpha(
            [.ai(ai)],
            size: MTLSize(width: 64, height: 64, depth: 1)
        ))
        let pixels = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { pixels[y * 64 + x] }
        #expect(at(32, 8) > 0.9)
        #expect(at(32, 56) < 0.1)
    }

    @Test("Vision one-component float mattes retain background values through PNG and Metal")
    func aiMaskOneComponentFloatValues() throws {
        guard let pipeline = makePipeline() else { return }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_OneComponent32Float,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self))
        for y in 0..<2 {
            base[y * rowStride] = 1
            base[y * rowStride + 1] = 0
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let image = CIImage(cvPixelBuffer: buffer)
        let png = try #require(AIMaskGenerator.renderGrayscalePNG(
            from: image,
            width: 2,
            height: 2,
            bounds: image.extent
        ))
        let ai = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 1,
            displayOrientation: 1
        )
        let tex = try #require(pipeline.rebuildMaskAlpha(
            [.ai(ai)],
            size: MTLSize(width: 64, height: 64, depth: 1)
        ))
        let pixels = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { pixels[y * 64 + x] }
        #expect(at(8, 32) > 0.9)
        #expect(at(56, 32) < 0.1)
    }

    @Test("AI selection rejects Vision's uniform full-frame matte")
    func aiMaskRejectsUniformFullFrame() {
        #expect(AIMaskGenerator.isEffectivelyFullFrameMask([255, 252, 248, 240]))
        #expect(!AIMaskGenerator.isEffectivelyFullFrameMask([255, 252, 239, 240]))
        #expect(!AIMaskGenerator.isEffectivelyFullFrameMask([255, 0, 255, 0]))
        #expect(!AIMaskGenerator.isEffectivelyFullFrameMask([]))
    }

    @Test("AI instance hit testing uses top-left preview coordinates")
    func aiMaskInstanceHitTesting() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_OneComponent32Float,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self))
        for y in 0..<4 {
            for x in 0..<4 {
                base[y * stride + x] = x < 2 && y < 2 ? 0.75 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        #expect(AIMaskGenerator.maskCoverage(
            atDisplayPoint: CGPoint(x: 0.25, y: 0.25),
            in: buffer
        ) == 0.75)
        #expect(AIMaskGenerator.maskCoverage(
            atDisplayPoint: CGPoint(x: 0.75, y: 0.25),
            in: buffer
        ) == 0)
        #expect(AIMaskGenerator.maskCoverage(
            atDisplayPoint: CGPoint(x: 0.25, y: 0.75),
            in: buffer
        ) == 0)
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

    @Test("separate add strokes at the same spot accumulate (build up past one stroke's flow)")
    func separateStrokesAccumulate() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 64, height: 64, depth: 1)
        func stroke() -> BrushStroke {
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 0.5, hardness: 1.0)],
                        radius: 0.25, density: 1.0, erase: false)
        }
        // One stroke at flow 0.5 → ~0.5. A SECOND identical stroke must build up (source-over),
        // not clamp at 0.5. Three strokes → higher still.
        let one = BrushMaskGeometry(strokes: [stroke()])
        let two = BrushMaskGeometry(strokes: [stroke(), stroke()])
        let three = BrushMaskGeometry(strokes: [stroke(), stroke(), stroke()])
        func centerAfter(_ b: BrushMaskGeometry) throws -> Float {
            let tex = try #require(pipeline.rebuildBrushAlpha([b], size: size))
            return readSlice(tex, slice: 0)[32 * 64 + 32]
        }
        let a1 = try centerAfter(one), a2 = try centerAfter(two), a3 = try centerAfter(three)
        #expect(abs(a1 - 0.5) < 0.05)     // single stroke ≈ its flow
        #expect(a2 > a1 + 0.15)           // second stroke builds up (≈0.75)
        #expect(a3 > a2)                  // third builds up further
        #expect(a3 < 1.001)              // never exceeds full opacity
    }

    @Test("overlapping soft erase dabs preserve a soft falloff (envelope, not accumulation)")
    func softEraseStaysSoft() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 64, height: 64, depth: 1)
        // Fill an area solid, then erase it with a stroke of TWO overlapping soft dabs at the
        // same spot (hardness 0). A subtractive erase would remove ~2× the soft profile and cut a
        // hard hole; the envelope (min) erase must leave a soft gradient.
        let brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.3, density: 1.0, erase: false),
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 0.0),
                               BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 0.0)],
                        radius: 0.25, density: 1.0, erase: true),
        ])
        let tex = try #require(pipeline.rebuildBrushAlpha([brush], size: size))
        let px = readSlice(tex, slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { px[y * 64 + x] }
        #expect(at(32, 32) < 0.05)              // center fully erased (falloff 1)
        // The nominal 16px circle is the midpoint of the new feather, so the mask should be
        // partially (not fully) erased there. Subtractive over-accumulation would zero it.
        let half = at(48, 32)
        #expect(half > 0.25 && half < 0.75)
    }

    @Test("live-stamping adds dabs into an existing slice without a full rebuild")
    func liveStampAccumulates() throws {
        guard let pipeline = makePipeline() else { return }
        let size = MTLSize(width: 64, height: 64, depth: 1)
        // Seed a texture with one stroke, then live-stamp a second dab elsewhere in the slice.
        let seed = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.25, y: 0.25, flow: 1.0, hardness: 1.0)],
                        radius: 0.15, density: 1.0, erase: false)
        ])
        _ = try #require(pipeline.rebuildBrushAlpha([seed], size: size))
        let stamped = pipeline.stampBrushStroke(
            BrushStroke(dabs: [BrushDab(x: 0.75, y: 0.75, flow: 1.0, hardness: 1.0)],
                        radius: 0.15, density: 1.0, erase: false),
            layer: 0
        )
        #expect(stamped)
        let px = readSlice(try #require(pipeline.brushAlphaTexture), slice: 0)
        func at(_ x: Int, _ y: Int) -> Float { px[y * 64 + x] }
        #expect(at(16, 16) > 0.5)   // original dab survived
        #expect(at(48, 48) > 0.5)   // live-stamped dab is present
    }

    @Test("live-stamping into an out-of-range or missing slice is a safe no-op")
    func liveStampGuards() {
        guard let pipeline = makePipeline() else { return }
        // No texture allocated yet → no-op, returns false.
        let stroke = BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                                 radius: 0.2, density: 1.0, erase: false)
        #expect(pipeline.stampBrushStroke(stroke, layer: 0) == false)
        _ = pipeline.rebuildBrushAlpha([BrushMaskGeometry(strokes: [stroke])],
                                       size: MTLSize(width: 32, height: 32, depth: 1))
        #expect(pipeline.stampBrushStroke(stroke, layer: 5) == false)   // slice 5 doesn't exist
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

/// Phase 3 — the compositing kernel's `maskType` branch. Renders a flat image through the full
/// `editAdjustments` pipeline (via `renderOffscreen`) and confirms a brush mask's adjustment
/// lands only on the painted region, and that the ellipse (SDF) path is unaffected by the branch.
/// Skipped when no Metal device is available.
@Suite("Brush mask compositing")
struct BrushCompositingTests {
    private var space: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

    private func solidGray(_ v: CGFloat, size: CGFloat = 64) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    /// Reads the linear RGB at one pixel of a rendered result.
    private func sample(_ image: CIImage, x: Int, y: Int) -> Float {
        let ctx = CIContext(options: [.workingColorSpace: space])
        var buf = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &buf, rowBytes: 16,
                   bounds: CGRect(x: image.extent.origin.x + CGFloat(x),
                                  y: image.extent.origin.y + CGFloat(y), width: 1, height: 1),
                   format: .RGBAf, colorSpace: space)
        return buf[0]
    }

    @Test("a brush mask's exposure brightens only the painted region")
    func brushMaskBrightensPaintedRegion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var mask = MaskAdjustment()
        mask.brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.3, density: 1.0, erase: false)
        ])
        mask.exposure = 1.0   // +1 EV = 2×
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]
        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.4), settings: settings))
        let center = sample(result, x: 32, y: 32)
        let corner = sample(result, x: 3, y: 3)
        #expect(center > corner + 0.2)          // painted center brightened (~0.8)
        #expect(abs(corner - 0.4) < 0.05)       // unpainted corner ~unchanged (~0.4)
    }

    @Test("an AI mask's exposure applies only inside its raster matte")
    func aiMaskBrightensSelectedRegion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let png = try #require(grayscalePNG([255, 0, 255, 0], width: 2, height: 2))
        var mask = MaskAdjustment()
        mask.aiMask = AIMaskGeometry(
            width: 2,
            height: 2,
            pngData: png,
            sourceOrientation: 1,
            displayOrientation: 1
        )
        mask.exposure = 1.0
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]

        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.4), settings: settings))
        let selected = sample(result, x: 8, y: 32)
        let clear = sample(result, x: 56, y: 32)
        #expect(selected > clear + 0.2)
        #expect(abs(clear - 0.4) < 0.05)
    }

    @Test("a brush anonymizer mask still receives the global exposure adjustment")
    func anonymizerReceivesGlobalAdjustment() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var mask = MaskAdjustment()
        mask.brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.3, density: 1.0, erase: false)
        ])
        var anon = AnonymizerSettings()
        anon.amount = 50
        mask.anonymizer = anon
        var settings = CameraRawSettings()
        settings.exposure2012 = 1.0        // global brighten (~+1 EV)
        settings.localAdjustments = [mask]
        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.3), settings: settings))
        let center = sample(result, x: 32, y: 32)   // anonymized region
        let corner = sample(result, x: 3, y: 3)     // only the global adjustment
        // The anonymized patch must be brightened by the global exposure like its surroundings,
        // not stuck at the raw source value (0.3). On a flat field the two should match closely.
        #expect(center > 0.4)
        #expect(abs(center - corner) < 0.1)
    }

    @Test("a mask's own exposure adjustment applies to its anonymized region")
    func anonymizerReceivesMaskAdjustment() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var mask = MaskAdjustment()
        mask.brush = BrushMaskGeometry(strokes: [
            BrushStroke(dabs: [BrushDab(x: 0.5, y: 0.5, flow: 1.0, hardness: 1.0)],
                        radius: 0.3, density: 1.0, erase: false)
        ])
        var anon = AnonymizerSettings()
        anon.amount = 50
        mask.anonymizer = anon
        mask.exposure = 1.0                 // the mask's OWN exposure (+1 EV), no global edit
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]
        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.3), settings: settings))
        let center = sample(result, x: 32, y: 32)   // anonymized + mask exposure
        let corner = sample(result, x: 3, y: 3)     // untouched (outside the mask)
        #expect(abs(corner - 0.3) < 0.03)   // outside the mask stays raw
        #expect(center > 0.45)              // pixelated region brightened by the mask's exposure
    }

    @Test("the ellipse (SDF) mask path still renders after the maskType branch")
    func ellipseMaskStillRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var mask = MaskAdjustment()
        mask.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5,
                                            radiusX: 0.3, radiusY: 0.3, rotation: 0, feather: 0)
        mask.exposure = 1.0
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]
        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.4), settings: settings))
        let center = sample(result, x: 32, y: 32)
        let corner = sample(result, x: 3, y: 3)
        #expect(center > corner + 0.2)          // ellipse center brightened
        #expect(abs(corner - 0.4) < 0.05)       // outside the ellipse ~unchanged
    }

    @Test("a Secondary Global layer applies uniformly to the complete frame")
    func secondaryGlobalCoversCompleteFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var layer = MaskAdjustment(fullFrame: true)
        // Deliberately leave the ordinary mask geometry at its small default. Exact full-frame
        // coverage must come from maskType=2, not from the persisted ACR fallback ellipse.
        layer.exposure = 1.0
        var settings = CameraRawSettings()
        settings.localAdjustments = [layer]

        let result = try #require(
            MetalEditPipeline.renderOffscreen(source: solidGray(0.4), settings: settings)
        )
        let center = sample(result, x: 32, y: 32)
        let corner = sample(result, x: 1, y: 1)
        #expect(center > 0.7)
        #expect(abs(center - corner) < 0.03)
    }

    @Test("zero corner radius includes the rectangular corners while ACR ellipse does not")
    func rectangleMaskIncludesCorners() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var ellipse = MaskAdjustment()
        ellipse.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5,
                                               radiusX: 0.3, radiusY: 0.3,
                                               rotation: 0, feather: 0)
        ellipse.exposure = 1.0
        var rectangle = ellipse
        rectangle.geometry.cornerRadius = 0

        var ellipseSettings = CameraRawSettings()
        ellipseSettings.localAdjustments = [ellipse]
        var rectangleSettings = CameraRawSettings()
        rectangleSettings.localAdjustments = [rectangle]

        let ellipseResult = try #require(MetalEditPipeline.renderOffscreen(
            source: solidGray(0.4), settings: ellipseSettings
        ))
        let rectangleResult = try #require(MetalEditPipeline.renderOffscreen(
            source: solidGray(0.4), settings: rectangleSettings
        ))
        let ellipseCorner = sample(ellipseResult, x: 47, y: 47)
        let rectangleCorner = sample(rectangleResult, x: 47, y: 47)

        #expect(abs(ellipseCorner - 0.4) < 0.05)
        #expect(rectangleCorner > ellipseCorner + 0.2)
    }

    @Test("rounded-rectangle feather preserves the selected corner proportion")
    func roundedRectangleFeatherDoesNotFormXPattern() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var rectangle = MaskAdjustment()
        rectangle.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5,
                                                 radiusX: 0.35, radiusY: 0.35,
                                                 rotation: 0, feather: 50,
                                                 cornerRadius: 0.4)
        rectangle.exposure = 1.0
        var settings = CameraRawSettings()
        settings.localAdjustments = [rectangle]

        let result = try #require(
            MetalEditPipeline.renderOffscreen(source: solidGray(0.4, size: 256), settings: settings)
        )
        // These are both approximately 70% of the way from the center to the nominal outline:
        // one through a straight edge and one through the middle of a rounded corner. Feather
        // contours must be scaled copies of that outline, so their coverage should match. A
        // Euclidean SDF makes the diagonal point much stronger and exposes its medial axes as X.
        let edge = sample(result, x: 191, y: 128)
        let diagonalCorner = sample(result, x: 183, y: 183)

        #expect(abs(edge - diagonalCorner) < 0.015)
    }

    @Test("a fully feathered ellipse extends a Gaussian tail beyond its nominal outline")
    func ellipseFeatherExtendsBeyondOutline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        var mask = MaskAdjustment()
        mask.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5,
                                            radiusX: 0.25, radiusY: 0.25,
                                            rotation: 0, feather: 100)
        mask.exposure = 1.0
        var settings = CameraRawSettings()
        settings.localAdjustments = [mask]
        let result = try #require(MetalEditPipeline.renderOffscreen(source: solidGray(0.4), settings: settings))
        let midpoint = sample(result, x: 40, y: 32)
        let nominalOutline = sample(result, x: 48, y: 32)
        let outsideTail = sample(result, x: 51, y: 32)
        let farOutside = sample(result, x: 60, y: 32)
        #expect(midpoint > 0.60 && midpoint < 0.66)
        #expect(nominalOutline > 0.43 && nominalOutline < midpoint)
        #expect(outsideTail > 0.408 && outsideTail < nominalOutline)
        #expect(abs(farOutside - 0.4) < 0.01)
    }

    @Test("a later local layer can recover highlights raised above SDR white globally")
    func localLayerRecoversGlobalSuperWhites() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        // Two distinct scene-referred highlights. Global Whites pushes both well beyond the
        // old SDR shoulder's hard ceiling; the following full-image mask pulls them down again.
        let width = 64, height = 16
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: Float = x < width / 2 ? 2.0 : 3.0
                let i = (y * width + x) * 4
                pixels[i] = value
                pixels[i + 1] = value
                pixels[i + 2] = value
            }
        }
        let data = Data(bytes: pixels, count: pixels.count * MemoryLayout<Float>.size)
        let source = CIImage(bitmapData: data,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                             size: CGSize(width: width, height: height),
                             format: .RGBAf,
                             colorSpace: space)

        var recovery = MaskAdjustment()
        recovery.geometry = EllipseMaskGeometry(centerX: 0.5, centerY: 0.5,
                                                 radiusX: 1.0, radiusY: 1.0,
                                                 rotation: 0, feather: 0)
        recovery.exposure = -2.0

        var settings = CameraRawSettings()
        settings.sourceHasHDRHeadroom = true
        settings.whites2012 = 100
        settings.localAdjustments = [recovery]

        let result = try #require(MetalEditPipeline.renderOffscreen(source: source, settings: settings))
        let lowerHighlight = sample(result, x: 16, y: 8)
        let higherHighlight = sample(result, x: 48, y: 8)

        #expect(lowerHighlight < 0.95)
        #expect(higherHighlight > lowerHighlight + 0.08,
                "the global layer must not flatten distinct super-whites before local recovery")
    }
}
