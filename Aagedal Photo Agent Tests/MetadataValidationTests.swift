import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Editorial metadata validation")
struct MetadataValidationTests {
    private let imageURL = URL(fileURLWithPath: "/fixtures/editorial.jpg")

    private var portableProfileFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EditorialMetadata/newsroom-validation-profile.json")
    }

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
            "editorial.country-code.iso-3166-alpha-3",
            "editorial.urgency.one-through-eight",
            "editorial.web-statement-of-rights.http-url",
        ])
        #expect(profile.rules.map(\.severity) == [.blocker, .blocker, .warning, .warning, .blocker, .blocker, .blocker])
    }

    @Test("Web Statement of Rights accepts HTTP URLs and blocks malformed values")
    func webStatementURLValidation() {
        let profile = MetadataValidationProfile.currentRequirements(levels: [:], minimumLengths: [:])
        let empty = MetadataValidationEngine().validate(
            IPTCMetadata(), imageURL: imageURL, profile: profile
        )
        let valid = MetadataValidationEngine().validate(
            IPTCMetadata(webStatementOfRights: "HTTPS://example.test/rights/42"),
            imageURL: imageURL,
            profile: profile
        )
        let invalid = MetadataValidationEngine().validate(
            IPTCMetadata(webStatementOfRights: "example.test/rights"),
            imageURL: imageURL,
            profile: profile
        )

        #expect(empty.issues.isEmpty)
        #expect(valid.issues.isEmpty)
        #expect(invalid.blockerCount == 1)
        #expect(invalid.issues.first?.field == .webStatementOfRights)
    }

    @Test("Country Code stores canonical alpha-3 values and rejects unknown codes")
    func countryCodeValidation() {
        #expect(ISO3166Country.all.count == 249)
        #expect(ISO3166Country.normalizedAlpha3(" nor ") == "NOR")
        #expect(ISO3166Country.isValidAlpha3("NOR"))
        #expect(!ISO3166Country.isValidAlpha3("XKX"))
        #expect(!ISO3166Country.isValidAlpha3("ZZZ"))

        let profile = MetadataValidationProfile.currentRequirements(levels: [:], minimumLengths: [:])
        let valid = MetadataValidationEngine().validate(
            IPTCMetadata(countryCode: "nor"),
            imageURL: imageURL,
            profile: profile
        )
        let invalid = MetadataValidationEngine().validate(
            IPTCMetadata(countryCode: "zzz"),
            imageURL: imageURL,
            profile: profile
        )

        #expect(valid.issues.isEmpty)
        #expect(invalid.blockerCount == 1)
        #expect(invalid.issues.first?.field == .countryCode)
    }

    @Test("Urgency accepts 1 through 8 and blocks out-of-range values")
    func urgencyValidation() {
        let profile = MetadataValidationProfile.currentRequirements(levels: [:], minimumLengths: [:])
        for value in 1...8 {
            let report = MetadataValidationEngine().validate(
                IPTCMetadata(urgency: value), imageURL: imageURL, profile: profile
            )
            #expect(report.issues.isEmpty)
        }

        for value in [0, 9] {
            let report = MetadataValidationEngine().validate(
                IPTCMetadata(urgency: value), imageURL: imageURL, profile: profile
            )
            #expect(report.blockerCount == 1)
            #expect(report.issues.first?.field == .urgency)
        }
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

    @Test("Organisation codes validate as independent repeated values")
    func organisationCodeValidation() {
        let profile = MetadataValidationProfile(
            name: "Agency codes",
            rules: [
                .init(
                    id: "organisation.codes.allowed",
                    severity: .blocker,
                    requirement: .allowedValues(
                        field: .organisationShownCode,
                        values: ["OCC", "NO-HARBOR"]
                    )
                ),
            ]
        )
        let report = MetadataValidationEngine().validate(
            IPTCMetadata(organisationsShownCodes: ["OCC", "UNKNOWN"]),
            imageURL: imageURL,
            profile: profile
        )

        #expect(report.blockerCount == 1)
        #expect(report.issues.first?.field == .organisationShownCode)
        // Validation diagnostics deliberately report counts rather than potentially sensitive
        // field values; the field identity still points the user to the rejected code list.
        #expect(report.issues.first?.technicalDetail == "Rejected canonical value count: 1.")
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
          "schemaVersion": 3,
          "id": "4F9AC8E2-418E-48B1-96E6-50637D72A960",
          "name": "Future",
          "rules": []
        }
        """.utf8)
        #expect(throws: EditorialJSONSchemaError.self) {
            try JSONDecoder().decode(MetadataValidationProfile.self, from: newer)
        }
    }

    @Test("Synthesized version-one rule JSON migrates to the portable contract")
    func synthesizedRuleMigration() throws {
        let legacy = Data(#"{"schemaVersion":1,"id":"4F9AC8E2-418E-48B1-96E6-50637D72A960","name":"Legacy Desk","rules":[{"id":"headline.minimum","severity":"blocker","requirement":{"minimumLength":{"field":"title","count":12}}}]}"#.utf8)
        let io = MetadataValidationProfileIO()

        let profile = try io.decode(legacy)

        #expect(profile.rules.map(\.requirement) == [
            .minimumLength(field: .headline, count: 12),
        ])
        let canonical = try #require(String(data: io.encode(profile), encoding: .utf8))
        #expect(canonical.contains(#""type" : "minimumLength""#))
        #expect(!canonical.contains(#""minimumLength" : {"#))
        #expect(canonical.contains(#""schemaVersion" : 2"#))
    }

    @Test("Portable profile fixture uses the stable public rule schema")
    func portableProfileFixture() throws {
        let io = MetadataValidationProfileIO()
        let source = try Data(contentsOf: portableProfileFixtureURL)
        let profile = try io.decode(source)

        #expect(profile.id == UUID(uuidString: "7A70A73D-5A60-480A-91CB-965CE2D10BA9"))
        #expect(profile.name == "Example News Desk")
        #expect(profile.rules.count == 8)
        #expect(profile.rules.map(\.requirement) == [
            .required(field: .headline),
            .minimumLength(field: .description, count: 30),
            .maximumLength(field: .description, count: 1800),
            .maximumUTF8Bytes(field: .description, count: 2000),
            .pattern(field: .country, expression: "[A-Z]{3}"),
            .allowedValues(field: .digitalSourceType, values: [
                DigitalSourceType.digitalCapture.newsCodeURI,
                DigitalSourceType.humanEdits.newsCodeURI,
            ]),
            .requires(field: .creator, whenPresent: .credit),
            .forbidsPlaceholder(field: .description),
        ])

        let canonical = try io.encode(profile)
        #expect(canonical == source)
        let object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        let rules = try #require(object["rules"] as? [[String: Any]])
        let firstRequirement = try #require(rules.first?["requirement"] as? [String: Any])
        #expect(firstRequirement["type"] as? String == "required")
        #expect(firstRequirement["field"] as? String == "title")
    }

    @Test("IPTC-IIM byte limits count UTF-8 bytes and repeated values independently")
    func iimCompatibilityByteLimits() {
        let engine = MetadataValidationEngine()
        let exact = IPTCMetadata(
            keywords: [String(repeating: "ø", count: 32), "short"],
            creator: String(repeating: "ø", count: 16)
        )
        let over = IPTCMetadata(
            keywords: [String(repeating: "ø", count: 32), String(repeating: "K", count: 65)],
            creator: String(repeating: "ø", count: 16) + "X"
        )

        let exactReport = engine.validate(
            exact,
            imageURL: imageURL,
            profile: .iptcIIMCompatibility
        )
        let overReport = engine.validate(
            over,
            imageURL: imageURL,
            profile: .iptcIIMCompatibility
        )

        #expect(exactReport.issues.isEmpty)
        #expect(overReport.issues.map(\.field) == [.keywords, .creator])
        #expect(overReport.warningCount == 2)
        #expect(overReport.issues[0].technicalDetail?.contains("65 bytes") == true)
        #expect(overReport.issues[1].message.contains("IPTC-IIM 2:80"))
    }

    @Test("Portable profile export atomically replaces and imports a file")
    func portableProfileFileRoundTrip() throws {
        let io = MetadataValidationProfileIO()
        let profile = try io.importProfile(from: portableProfileFixtureURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataValidationProfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Desk.json")
        try Data("stale".utf8).write(to: destination)

        try io.export(profile, to: destination)

        #expect(try io.importProfile(from: destination) == profile)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: portableProfileFixtureURL))
    }

    @Test("Portable profile import rejects unsafe rule definitions")
    func portableProfileSemanticValidation() throws {
        let io = MetadataValidationProfileIO()
        let valid = try io.importProfile(from: portableProfileFixtureURL)

        var emptyName = valid
        emptyName.name = "  \n"
        #expect(throws: MetadataValidationProfileIOError.emptyProfileName) {
            try io.encode(emptyName)
        }

        var duplicate = valid
        duplicate.rules = [valid.rules[0], valid.rules[0]]
        #expect(throws: MetadataValidationProfileIOError.duplicateRuleID("headline.required")) {
            try io.encode(duplicate)
        }

        var invalidMinimum = valid
        invalidMinimum.rules = [.init(
            id: "headline.minimum",
            severity: .blocker,
            requirement: .minimumLength(field: .headline, count: 0)
        )]
        #expect(throws: MetadataValidationProfileIOError.invalidMinimumLength(
            ruleID: "headline.minimum",
            count: 0
        )) {
            try io.encode(invalidMinimum)
        }

        var emptyVocabulary = valid
        emptyVocabulary.rules = [.init(
            id: "source.allowed",
            severity: .blocker,
            requirement: .allowedValues(field: .digitalSourceType, values: [])
        )]
        #expect(throws: MetadataValidationProfileIOError.emptyAllowedValues(ruleID: "source.allowed")) {
            try io.encode(emptyVocabulary)
        }

        var selfDependency = valid
        selfDependency.rules = [.init(
            id: "creator.requires-itself",
            severity: .warning,
            requirement: .requires(field: .creator, whenPresent: .creator)
        )]
        #expect(throws: MetadataValidationProfileIOError.selfDependency(
            ruleID: "creator.requires-itself",
            field: .creator
        )) {
            try io.encode(selfDependency)
        }

        var invalidPattern = valid
        invalidPattern.rules = [.init(
            id: "country.pattern",
            severity: .blocker,
            requirement: .pattern(field: .country, expression: "[")
        )]
        #expect(throws: MetadataValidationProfileIOError.self) {
            try io.encode(invalidPattern)
        }
    }

    @Test("Portable profile import enforces schema and size boundaries before decoding")
    func portableProfileBoundaryValidation() {
        let io = MetadataValidationProfileIO()
        let unversioned = Data(#"{"id":"7A70A73D-5A60-480A-91CB-965CE2D10BA9","name":"Desk","rules":[]}"#.utf8)
        #expect(throws: EditorialJSONSchemaError.missingOrInvalidSchemaVersion) {
            try io.decode(unversioned)
        }

        let newer = Data(#"{"schemaVersion":3,"id":"7A70A73D-5A60-480A-91CB-965CE2D10BA9","name":"Desk","rules":[]}"#.utf8)
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "metadata validation profile",
            found: 3,
            supported: 2
        )) {
            try io.decode(newer)
        }

        let oversized = Data(repeating: 0x20, count: MetadataValidationProfileIO.maximumFileSize + 1)
        #expect(throws: MetadataValidationProfileIOError.fileTooLarge(
            found: oversized.count,
            limit: MetadataValidationProfileIO.maximumFileSize
        )) {
            try io.decode(oversized)
        }
    }
}
