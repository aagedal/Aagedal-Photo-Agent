import AppKit
import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("IPTC metadata canonical verification")
struct IPTCMetadataVerificationTests {
    private func completeSelectedMetadata() -> IPTCMetadata {
        IPTCMetadata(
            title: "Unicode headline Ω",
            description: "First line\nSecond line — 東京",
            extendedDescription: "Accessible description é",
            keywords: ["wire", "sports", "東京"],
            personShown: ["Kari Nordmann", "李雷"],
            organisationsShownNames: ["Agence Ω", "Harbor Authority"],
            organisationsShownCodes: ["ORG-OMEGA", "NO-HARBOR"],
            digitalSourceType: .digitalCapture,
            urgency: 3,
            sceneCodes: ["011200", "012400"],
            subjectCodes: ["01000000", "15000000"],
            mediaTopics: [IPTCControlledVocabularyTerm(
                vocabularyIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI,
                termIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI + "20000587",
                name: "Photography"
            )],
            genres: [IPTCControlledVocabularyTerm(
                vocabularyIdentifier: IPTCControlledVocabularyTerm.genreSchemeURI,
                termIdentifier: IPTCControlledVocabularyTerm.genreSchemeURI + "Feature",
                name: "Feature"
            )],
            creator: "Alex Example",
            creatorJobTitle: "Staff Photographer",
            descriptionWriter: "Night Desk",
            credit: "Aagedal News",
            copyright: "© 2026 Aagedal News",
            rightsUsageTerms: "Editorial use only",
            webStatementOfRights: "https://example.test/rights",
            digitalImageGUID: "urn:uuid:01234567-89ab-cdef-0123-456789abcdef",
            imageSupplierImageID: "AGENCY-2026-0042",
            jobId: "ASSIGNMENT-42",
            dateCreated: "2026-08-21",
            city: "Oslo",
            sublocation: "City Hall",
            provinceState: "Oslo",
            country: "Norway",
            countryCode: "NOR",
            event: "Election night",
            instructions: "Hold until 18:00",
            source: "Newsroom desk"
        )
    }

    private func makeJPEG(at url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try #require(bitmap.representation(using: .jpeg, properties: [:])).write(to: url)
    }

    @Test("SwiftExif read-back entry verifies a completed embedded write")
    func swiftExifReadBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPTCMetadataVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("read-back.jpg")
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: url)

        let expected = IPTCMetadata(
            title: "Read-back headline",
            description: "Verification caption",
            keywords: ["verification", "news"],
            digitalSourceType: .digitalCapture,
            sceneCodes: ["010100"],
            latitude: 59.913_868_41,
            longitude: 10.752_245_39,
            creator: "Reporter"
        )
        try await SwiftExifWriteEngine().writeFields(expected.toWriteFields(), to: [url])

        let report = try await SwiftExifReadService().verifyReadBack(at: url, expected: expected)
        #expect(report.isMatch)
        #expect(report.differences.isEmpty)
    }

    @Test("Every selected field round-trips through sidecar XMP and embedded JPEG read-back")
    func everySelectedFieldRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPTCSelectedFieldRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let expected = completeSelectedMetadata()
        let selectedVerificationFields = MetadataFieldID.allCases.map(\.verificationField)

        let rawURL = directory.appendingPathComponent("sidecar.nef")
        let sidecarService = XMPSidecarService()
        try sidecarService.saveSidecar(metadata: expected, for: rawURL)
        let sidecarActual = try #require(sidecarService.loadSidecar(for: rawURL))
        let sidecarReport = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: sidecarActual,
            fields: selectedVerificationFields
        )
        #expect(sidecarReport.isMatch, "Sidecar differences: \(sidecarReport.differences)")

        let jpegURL = directory.appendingPathComponent("embedded.jpg")
        try makeJPEG(at: jpegURL)
        try await SwiftExifWriteEngine().writeFields(
            expected.toWriteFields(),
            to: [jpegURL],
            structuredData: StructuredWriteData(
                editorial: EditorialStructuredWriteData(metadata: expected)
            )
        )
        let embeddedActual = try await SwiftExifReadService().readFullMetadata(url: jpegURL)
        let embeddedReport = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: embeddedActual,
            fields: selectedVerificationFields
        )
        #expect(embeddedReport.isMatch, "Embedded differences: \(embeddedReport.differences)")
    }

    @Test("An empty embedded write is an exact byte no-op")
    func emptyEmbeddedWritePreservesExactBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPTCEmptyWrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpegURL = directory.appendingPathComponent("no-op.jpg")
        try makeJPEG(at: jpegURL)
        let before = try Data(contentsOf: jpegURL)

        try await SwiftExifWriteEngine().writeFields([:], to: [jpegURL])

        #expect(try Data(contentsOf: jpegURL) == before)
    }

    @Test("Scalar boundary whitespace and line endings normalize without hiding internal edits")
    func scalarWhitespace() {
        let expected = IPTCMetadata(
            title: "  Headline  ",
            description: "Line one\r\nLine two"
        )
        let equivalent = IPTCMetadata(
            title: "Headline",
            description: "Line one\nLine two\n"
        )
        let changed = IPTCMetadata(
            title: "Head line",
            description: "Line one Line two"
        )

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: equivalent).isMatch)
        let report = IPTCMetadataVerifier.compare(expected: expected, actual: changed)
        #expect(report.differences.map(\.field) == [.headline, .description])
        #expect(report.differences.allSatisfy { $0.rule == .scalarWhitespace })
    }

    @Test("Bag fields ignore order, duplicates, empty values, and boundary whitespace")
    func unorderedRepeatableFields() {
        let expected = IPTCMetadata(
            keywords: ["news", " sport ", "news"],
            personShown: ["Ada", "Grace"],
            organisationsShownNames: ["Agency B", "Agency A"],
            organisationsShownCodes: ["B", "A"]
        )
        let actual = IPTCMetadata(
            keywords: ["sport", "", "news"],
            personShown: ["Grace", "Ada", "Grace"],
            organisationsShownNames: ["Agency A", "Agency B"],
            organisationsShownCodes: ["A", "B", "A"]
        )

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: actual).isMatch)
    }

    @Test("localized Titles verify language, value, and order while nil remains no-op")
    func localizedTitleSemantics() {
        let norwegian = LocalizedMetadataText(languageTag: "nb-NO", value: "Norsk")
        let nynorsk = LocalizedMetadataText(languageTag: "nn", value: "Nynorsk")
        let expected = IPTCMetadata(localizedTitles: [norwegian, nynorsk])

        #expect(IPTCMetadataVerifier.compare(
            expected: expected,
            actual: expected,
            fields: [.localizedTitles]
        ).isMatch)
        let reordered = IPTCMetadata(localizedTitles: [nynorsk, norwegian])
        let report = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: reordered,
            fields: [.localizedTitles]
        )
        #expect(report.differences.first?.field == .localizedTitles)
        #expect(report.differences.first?.rule == .orderedLocalizedText)

        let unmodeled = IPTCMetadataVerifier.compare(
            expected: IPTCMetadata(),
            actual: expected,
            fields: [.localizedTitles]
        )
        #expect(unmodeled.isMatch)
        #expect(unmodeled.checkedFields.isEmpty)
        let cleared = IPTCMetadataVerifier.compare(
            expected: IPTCMetadata(localizedTitles: []),
            actual: IPTCMetadata(),
            fields: [.localizedTitles]
        )
        #expect(cleared.isMatch)
        #expect(cleared.checkedFields == [.localizedTitles])
    }

    @Test("Scene NewsCodes URI and QCode aliases compare as canonical unordered values")
    func controlledURIAliases() {
        var expected = IPTCMetadata(sceneCodes: ["010100", "012400"])
        var actual = IPTCMetadata()
        expected.sceneCodes.append("010100")
        actual.sceneCodes = [
            "https://cv.iptc.org/newscodes/scene/012400",
            "scn:010100",
        ]

        let report = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: actual,
            fields: [.sceneCodes]
        )
        #expect(report.isMatch)
        #expect(IPTCMetadataVerifier.rule(for: .digitalSourceType) == .controlledVocabularyURI)
    }

    @Test("CV-Term verification ignores Bag order but retains optional semantics")
    func controlledVocabularyTermSemantics() {
        let photography = IPTCControlledVocabularyTerm(
            vocabularyIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI,
            termIdentifier: IPTCControlledVocabularyTerm.mediaTopicSchemeURI + "20000587",
            name: "Photography"
        )
        let newsroom = IPTCControlledVocabularyTerm(
            vocabularyIdentifier: "https://example.test/vocab/",
            termIdentifier: "https://example.test/vocab/concept-42",
            name: "Newsroom concept"
        )
        let expected = IPTCMetadata(mediaTopics: [photography, newsroom])
        let reordered = IPTCMetadata(mediaTopics: [newsroom, photography])
        #expect(IPTCMetadataVerifier.compare(
            expected: expected,
            actual: reordered,
            fields: [.mediaTopics]
        ).isMatch)

        var changedLabel = photography
        changedLabel.name = "Changed label"
        let report = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: IPTCMetadata(mediaTopics: [changedLabel, newsroom]),
            fields: [.mediaTopics]
        )
        #expect(report.differences.first?.rule == .unorderedControlledVocabularyTerms)
    }

    @Test("Dates normalize equivalent timezone projections but retain precision and timezone state")
    func datePrecision() {
        let expected = IPTCMetadata(dateCreated: "2026-08-21T10:15:30Z")
        let sameInstant = IPTCMetadata(dateCreated: "2026-08-21T12:15:30+02:00")
        let lessPrecise = IPTCMetadata(dateCreated: "2026-08-21T10:15Z")
        let unknownTimezone = IPTCMetadata(dateCreated: "2026-08-21T10:15:30")

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: sameInstant).isMatch)
        #expect(!IPTCMetadataVerifier.compare(expected: expected, actual: lessPrecise).isMatch)
        #expect(!IPTCMetadataVerifier.compare(expected: expected, actual: unknownTimezone).isMatch)

        let dateOnly = IPTCMetadata(dateCreated: "2026-08-21")
        let midnight = IPTCMetadata(dateCreated: "2026-08-21T00:00:00")
        #expect(!IPTCMetadataVerifier.compare(expected: dateOnly, actual: midnight).isMatch)
    }

    @Test("GPS compares at writer precision and reports a structured field difference")
    func coordinatePrecision() {
        let expected = IPTCMetadata(latitude: 59.913_868_41, longitude: 10.752_245_39)
        let roundedSame = IPTCMetadata(latitude: 59.913_868_40, longitude: 10.752_245_41)
        let changed = IPTCMetadata(latitude: 59.913_870, longitude: 10.752_245_41)

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: roundedSame).isMatch)
        let report = IPTCMetadataVerifier.compare(expected: expected, actual: changed)
        #expect(report.differences.count == 1)
        #expect(report.differences.first?.field == .latitude)
        #expect(report.differences.first?.rule == .coordinateSixDecimalPlaces)
        #expect(report.differences.first?.expected == .decimal("59.913868"))
        #expect(report.differences.first?.actual == .decimal("59.913870"))
    }

    @Test("Structured contact and Location Bag semantics are explicit")
    func structuredFields() {
        let oslo = EditorialLocation(
            identifiers: ["https://example.test/oslo", "urn:place:oslo"],
            name: " Oslo ",
            countryCode: "nor",
            latitude: 59.913_868_41,
            longitude: 10.752_245_39
        )
        let bergen = EditorialLocation(name: "Bergen", countryCode: "NOR")
        let expected = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["Newsroom", "Main Street 1", "Newsroom"],
                emails: ["desk@example.test", "editor@example.test"],
                phoneNumbers: ["+47 123"],
                webURLs: ["https://example.test"]
            ),
            locationsShown: [oslo, bergen, oslo]
        )
        let actual = IPTCMetadata(
            creatorContactInfo: CreatorContactInfo(
                addressLines: ["Newsroom", "Main Street 1"],
                emails: [" editor@example.test ", "desk@example.test", "desk@example.test"],
                phoneNumbers: ["+47 123"],
                webURLs: ["https://example.test"]
            ),
            locationsShown: [
                bergen,
                EditorialLocation(
                    identifiers: ["urn:place:oslo", "https://example.test/oslo"],
                    name: "Oslo",
                    countryCode: "NOR",
                    latitude: 59.913_868_40,
                    longitude: 10.752_245_41
                ),
            ]
        )

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: actual).isMatch)

        var reorderedAddress = actual
        reorderedAddress.creatorContactInfo?.addressLines.reverse()
        let report = IPTCMetadataVerifier.compare(expected: expected, actual: reorderedAddress)
        #expect(report.differences.map(\.field) == [.creatorContactInfo])
        #expect(report.differences.first?.rule == .structuredContact)
    }

    @Test("Default comparison excludes read-only Capture Date and supports explicit selection")
    func writableDefaultFieldSet() {
        let expected = IPTCMetadata(title: "Headline", captureDate: "2026-08-21T10:15:30Z")
        let actual = IPTCMetadata(title: "Headline", captureDate: "2025-01-01")

        #expect(IPTCMetadataVerifier.compare(expected: expected, actual: actual).isMatch)
        let report = IPTCMetadataVerifier.compare(
            expected: expected,
            actual: actual,
            fields: [.captureDate, .captureDate]
        )
        #expect(report.checkedFields == [.captureDate])
        #expect(report.differences.map(\.field) == [.captureDate])
    }
}
