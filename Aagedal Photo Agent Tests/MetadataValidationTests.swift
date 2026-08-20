import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Editorial metadata validation")
struct MetadataValidationTests {
    private let imageURL = URL(fileURLWithPath: "/fixtures/editorial.jpg")

    @Test("Current requirements migrate to shared blocker and warning rules")
    func currentRequirementsMigration() {
        let profile = MetadataValidationProfile.currentRequirements(
            levels: [.headline: .require, .description: .warnOnEmpty],
            minimumLengths: [.headline: 10, .description: 30]
        )

        #expect(profile.rules.map(\.id) == [
            "legacy.required.title",
            "legacy.minimumLength.title",
            "legacy.required.description",
            "legacy.minimumLength.description",
        ])
        #expect(profile.rules.map(\.severity) == [.blocker, .blocker, .warning, .warning])
    }

    @Test("Required and length rules produce stable aggregate results")
    func requiredAndLengthRules() {
        let profile = MetadataValidationProfile(
            name: "Wire",
            rules: [
                .init(
                    id: "description.required",
                    severity: .warning,
                    requirement: .required(field: .description)
                ),
                .init(
                    id: "headline.minimum",
                    severity: .blocker,
                    requirement: .minimumLength(field: .headline, count: 10)
                ),
                .init(
                    id: "headline.maximum",
                    severity: .information,
                    requirement: .maximumLength(field: .headline, count: 4)
                ),
            ]
        )
        let metadata = IPTCMetadata(title: "Short")

        let report = MetadataValidationEngine().validate(
            metadata,
            imageURL: imageURL,
            profile: profile
        )

        #expect(report.blockerCount == 1)
        #expect(report.warningCount == 1)
        #expect(report.informationCount == 1)
        #expect(report.isBlocked)
        #expect(report.nextBlockingIssue?.field == .headline)
        #expect(report.issues.map(\.severity) == [.blocker, .warning, .information])
        #expect(report.issues.allSatisfy { $0.imageURL == imageURL })
        #expect(report.issues.allSatisfy { $0.id.contains(imageURL.path) })
    }

    @Test("Pattern, dependency, and repeated allowed-value rules")
    func structuredRules() {
        let profile = MetadataValidationProfile(
            name: "Agency",
            rules: [
                .init(
                    id: "country.pattern",
                    severity: .blocker,
                    requirement: .pattern(field: .country, expression: "[A-Z]{2}")
                ),
                .init(
                    id: "credit.requires.creator",
                    severity: .warning,
                    requirement: .requires(field: .creator, whenPresent: .credit)
                ),
                .init(
                    id: "keywords.allowed",
                    severity: .blocker,
                    requirement: .allowedValues(field: .keywords, values: ["news", "sports"])
                ),
            ]
        )
        let metadata = IPTCMetadata(
            keywords: ["news", "unapproved"],
            creator: nil,
            credit: "Agency",
            country: "Norway"
        )

        let report = MetadataValidationEngine().validate(
            metadata,
            imageURL: imageURL,
            profile: profile
        )

        #expect(report.issues.map(\.field) == [.country, .keywords, .creator])
        #expect(report.blockerCount == 2)
        #expect(report.warningCount == 1)
    }

    @Test("Digital Source Type compares canonical NewsCodes values, not display labels")
    func canonicalVocabularyValidation() {
        let profile = MetadataValidationProfile(
            name: "Canonical vocabulary",
            rules: [
                .init(
                    id: "source.allowed",
                    severity: .blocker,
                    requirement: .allowedValues(
                        field: .digitalSourceType,
                        values: ["digsrctype:digitalCapture"]
                    )
                ),
            ]
        )
        let metadata = IPTCMetadata(digitalSourceType: .digitalCapture)

        let report = MetadataValidationEngine().validate(
            metadata,
            imageURL: imageURL,
            profile: profile
        )

        #expect(report.issues.isEmpty)
        #expect(MetadataFieldID.digitalSourceType.textValue(in: metadata) == DigitalSourceType.digitalCapture.newsCodeURI)
        #expect(MetadataFieldID.digitalSourceType.textValue(in: metadata) != DigitalSourceType.digitalCapture.displayName)
    }

    @Test("Placeholder detection ignores ordinary brace punctuation")
    func placeholderDetection() {
        #expect(MetadataTemplatePlaceholderDetector.containsPlaceholder("Filed by {initials}"))
        #expect(MetadataTemplatePlaceholderDetector.containsPlaceholder("{field:Creator}"))
        #expect(MetadataTemplatePlaceholderDetector.containsPlaceholder("{date:yyyy-MM-dd}"))
        #expect(!MetadataTemplatePlaceholderDetector.containsPlaceholder("The {best} frame"))
        #expect(!MetadataTemplatePlaceholderDetector.containsPlaceholder("Use braces { like this }"))

        let profile = MetadataValidationProfile(
            name: "Delivery",
            rules: [
                .init(
                    id: "description.variables",
                    severity: .blocker,
                    requirement: .forbidsPlaceholder(field: .description)
                ),
            ]
        )
        let unresolved = MetadataValidationEngine().validate(
            IPTCMetadata(description: "Filed by {initials}"),
            imageURL: imageURL,
            profile: profile
        )
        let prose = MetadataValidationEngine().validate(
            IPTCMetadata(description: "The {best} frame"),
            imageURL: imageURL,
            profile: profile
        )

        #expect(unresolved.blockerCount == 1)
        #expect(prose.issues.isEmpty)
    }

    @Test("Legacy fieldFails delegates to the shared engine")
    func legacyFieldFailsBridge() {
        let levels: MetadataRequirements.Levels = [.headline: .require]
        let lengths: MetadataRequirements.MinimumLengths = [.headline: 10]

        #expect(MetadataRequirements.fieldFails(
            .headline,
            in: IPTCMetadata(),
            levels: levels,
            minimumLengths: lengths
        ))
        #expect(MetadataRequirements.fieldFails(
            .headline,
            in: IPTCMetadata(title: "Short"),
            levels: levels,
            minimumLengths: lengths
        ))
        #expect(!MetadataRequirements.fieldFails(
            .headline,
            in: IPTCMetadata(title: "Long enough headline"),
            levels: levels,
            minimumLengths: lengths
        ))
    }

    @Test("Validation profiles round trip and reject a newer schema")
    func profileSchemaSafety() throws {
        let profile = MetadataValidationProfile(
            id: UUID(uuidString: "4F9AC8E2-418E-48B1-96E6-50637D72A960")!,
            name: "Desk",
            rules: [
                .init(
                    id: "headline.required",
                    severity: .blocker,
                    requirement: .required(field: .headline)
                ),
            ]
        )
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(MetadataValidationProfile.self, from: data) == profile)

        let newer = Data("""
        {
          "schemaVersion": 2,
          "id": "4F9AC8E2-418E-48B1-96E6-50637D72A960",
          "name": "Future",
          "rules": []
        }
        """.utf8)
        #expect(throws: EditorialJSONSchemaError.self) {
            try JSONDecoder().decode(MetadataValidationProfile.self, from: newer)
        }
    }
}
