import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Deadline profile")
struct DeadlineProfileTests {
    @Test("New profiles default to isolated staged-copy delivery")
    func newProfileDefaultsToStagedCopies() throws {
        #expect(DeadlineProfile(name: "Wire").metadataWriteStrategy == .stagedCopies)

        // A missing key belongs to a legacy schema-v1 profile and keeps the old fallback.
        let legacy = Data(#"{"schemaVersion":1,"name":"Legacy"}"#.utf8)
        #expect(try JSONDecoder().decode(DeadlineProfile.self, from: legacy)
            .metadataWriteStrategy == .xmpSidecars)
    }

    private let io = DeadlineProfileIO()

    @Test("A complete snapshot profile round-trips through portable JSON")
    func completeRoundTrip() throws {
        let validation = MetadataValidationProfile(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Wire",
            rules: [
                MetadataValidationRule(
                    id: "headline.required",
                    severity: .blocker,
                    requirement: .required(field: .headline)
                ),
            ]
        )
        let template = DeadlineMetadataTemplateSnapshot(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            name: "Desk",
            templateType: .full,
            fields: [
                DeadlineMetadataTemplateField(fieldID: .credit, templateValue: "{creator}/News"),
            ]
        )
        let recipe = BatchRenameRecipe(
            name: "Wire names",
            components: [
                .token(.date(BatchRenameDateToken(source: .capture()))),
                .literal("_"),
                .token(.sequence(BatchRenameSequence(padding: 4))),
                .literal("."),
                .token(.originalExtension),
            ]
        )
        let export = DeadlineExportSnapshot(
            sdrFormat: .jpeg,
            sdrQuality: 0.9,
            sdrGamut: .sRGB,
            hdrFormat: .jpegGainMap,
            hdrQuality: 0.85,
            hdrGamut: .displayP3,
            tiffCompression: .lzw,
            resolutionLimit: .pixels4000,
            maximumOutputByteCount: 2_500_000
        )
        let profile = DeadlineProfile(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            name: "Evening wire",
            validationProfile: .snapshot(validation),
            captionFields: DeadlineCaptionFieldConfiguration(
                orderedFieldIDs: [.headline, .description, .credit, .copyright],
                visibleFieldIDs: [.headline, .description, .credit]
            ),
            metadataTemplate: DeadlineMetadataTemplateConfiguration(
                source: .snapshot(template),
                variablePolicy: .processAtDeadline
            ),
            requiredLists: [.init(identifier: "iptc-scene-codes")],
            rename: DeadlineRenameConfiguration(
                recipe: .snapshot(recipe),
                collisionPolicy: .appendDeterministicSuffix(separator: "-", startAt: 2)
            ),
            export: .snapshot(export),
            destination: DeadlineDestinationConfiguration(
                connectionIdentifier: "40000000-0000-0000-0000-000000000004",
                remotePathTemplate: "/incoming/{date}/{job}"
            ),
            gpsPolicy: .remove,
            metadataWriteStrategy: .stagedCopies
        )

        let encoded = try io.encode(profile)
        let decoded = try io.decode(encoded)

        #expect(decoded == profile)
        #expect(decoded.export == .snapshot(export))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == DeadlineProfile.currentSchemaVersion)
        #expect(String(decoding: encoded, as: UTF8.self).contains("40000000-0000-0000-0000-000000000004"))
        #expect(!String(decoding: encoded, as: UTF8.self).localizedCaseInsensitiveContains("password"))

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeadlineProfile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try io.export(profile, to: destination)
        #expect(try io.importProfile(from: destination) == profile)
    }

    @Test("References report every unavailable library resource")
    func missingReferenceDiagnostics() {
        let profile = DeadlineProfile(
            name: "References",
            validationProfile: .reference(.init(identifier: "validation-wire")),
            metadataTemplate: .init(
                source: .reference(.init(identifier: "template-desk")),
                variablePolicy: .preservePlaceholders
            ),
            requiredLists: [.init(identifier: "list-country"), .init(identifier: "list-scene")],
            rename: .init(
                recipe: .reference(.init(identifier: "rename-wire")),
                collisionPolicy: .block
            ),
            export: .reference(.init(identifier: "export-jpeg")),
            destination: .init(
                connectionIdentifier: "50000000-0000-0000-0000-000000000005",
                remotePathTemplate: "/incoming"
            )
        )

        #expect(io.diagnostics(for: profile, catalog: .init()) == [
            .missingValidationProfile(identifier: "validation-wire"),
            .missingMetadataTemplate(identifier: "template-desk"),
            .missingList(identifier: "list-country"),
            .missingList(identifier: "list-scene"),
            .missingRenameRecipe(identifier: "rename-wire"),
            .missingExportConfiguration(identifier: "export-jpeg"),
            .missingDestinationConnection(identifier: "50000000-0000-0000-0000-000000000005"),
        ])

        let completeCatalog = DeadlineProfileReferenceCatalog(
            validationProfileIdentifiers: ["validation-wire"],
            metadataTemplateIdentifiers: ["template-desk"],
            listIdentifiers: ["list-country", "list-scene"],
            renameRecipeIdentifiers: ["rename-wire"],
            exportConfigurationIdentifiers: ["export-jpeg"],
            connectionIdentifiers: ["50000000-0000-0000-0000-000000000005"]
        )
        #expect(io.diagnostics(for: profile, catalog: completeCatalog).isEmpty)
    }

    @Test("Initial unversioned shape migrates using safe defaults")
    func unversionedDefaults() throws {
        let data = Data(#"{"name":"Legacy deadline"}"#.utf8)
        let profile = try io.decode(data)

        #expect(profile.schemaVersion == DeadlineProfile.currentSchemaVersion)
        #expect(profile.name == "Legacy deadline")
        #expect(profile.captionFields == .default)
        #expect(profile.validationProfile == nil)
        #expect(profile.metadataTemplate == nil)
        #expect(profile.requiredLists.isEmpty)
        #expect(profile.rename == nil)
        #expect(profile.export == nil)
        #expect(profile.destination == nil)
        #expect(profile.gpsPolicy == .retain)
        #expect(profile.metadataWriteStrategy == .xmpSidecars)

        let migrated = try io.encode(profile)
        let object = try #require(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
    }

    @Test("Legacy export snapshots without a byte ceiling decode with no limit")
    func legacyExportMaximumDefaultsToNil() throws {
        let data = Data(#"""
        {
          "sdrFormat": "jpeg",
          "sdrQuality": 0.9,
          "sdrGamut": "sRGB",
          "hdrFormat": "jpegGainMap",
          "hdrQuality": 0.8,
          "hdrGamut": "displayP3",
          "tiffCompression": "lzw",
          "resolutionLimit": "original"
        }
        """#.utf8)

        let export = try JSONDecoder().decode(DeadlineExportSnapshot.self, from: data)
        #expect(export.maximumOutputByteCount == nil)
    }

    @Test("Template snapshot conversion fails instead of dropping an unknown field")
    func unsupportedTemplateFieldIsRejected() {
        let template = MetadataTemplate(
            name: "Future field",
            fields: [TemplateField(fieldKey: "futureDeskField", templateValue: "value")]
        )

        #expect(throws: DeadlineProfileSnapshotError.unsupportedMetadataTemplateFieldKey("futureDeskField")) {
            try DeadlineMetadataTemplateSnapshot(validating: template)
        }
    }

    @Test("A newer profile is rejected before decoding")
    func futureSchemaRejected() {
        let data = Data(#"{"schemaVersion":99,"id":"30000000-0000-0000-0000-000000000003","name":"Future"}"#.utf8)

        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "deadline profile",
            found: 99,
            supported: 1
        )) {
            try io.decode(data)
        }
    }

    @Test("Export never overwrites a newer profile")
    func futureDestinationIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeadlineProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("deadline.json")
        let future = Data(#"{"schemaVersion":42,"name":"Created by a newer app"}"#.utf8)
        try future.write(to: destination)

        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "deadline profile",
            found: 42,
            supported: 1
        )) {
            try io.export(DeadlineProfile(name: "Current"), to: destination)
        }
        #expect(try Data(contentsOf: destination) == future)
    }

    @Test("Structural validation rejects ambiguous fields, credentials, and invalid quality")
    func structuralValidation() {
        let duplicate = DeadlineProfile(
            name: "Duplicate",
            captionFields: .init(
                orderedFieldIDs: [.headline, .headline],
                visibleFieldIDs: [.headline]
            )
        )
        #expect(throws: DeadlineProfileIOError.duplicateCaptionField) {
            try io.validate(duplicate)
        }

        for rejectedIdentifier in [
            "ftp://reporter:secret@example.test",
            "https://example.test/incoming?token=secret",
            "reporter:secret@example.test",
            "50000000-0000-0000-0000-000000000005?token=secret",
            "50000000-0000-0000-0000-00000000000A",
        ] {
            let credentials = DeadlineProfile(
                name: "Credentials",
                destination: .init(
                    connectionIdentifier: rejectedIdentifier,
                    remotePathTemplate: "/incoming"
                )
            )
            #expect(
                throws: DeadlineProfileIOError.invalidDestinationConnectionIdentifier(
                    rejectedIdentifier
                )
            ) {
                try io.validate(credentials)
            }
        }

        let badExport = DeadlineProfile(
            name: "Bad quality",
            export: .snapshot(.init(
                sdrFormat: .jpeg,
                sdrQuality: 2,
                sdrGamut: .sRGB,
                hdrFormat: .jpegGainMap,
                hdrQuality: 0.8,
                hdrGamut: .displayP3,
                tiffCompression: .lzw,
                resolutionLimit: .original
            ))
        )
        #expect(throws: DeadlineProfileIOError.invalidExportQuality) {
            try io.validate(badExport)
        }

        let invalidMaximum = DeadlineProfile(
            name: "Bad maximum",
            export: .snapshot(.init(
                sdrFormat: .jpeg,
                sdrQuality: 0.9,
                sdrGamut: .sRGB,
                hdrFormat: .jpegGainMap,
                hdrQuality: 0.8,
                hdrGamut: .displayP3,
                tiffCompression: .lzw,
                resolutionLimit: .original,
                maximumOutputByteCount: 0
            ))
        )
        #expect(throws: DeadlineProfileIOError.invalidMaximumOutputByteCount) {
            try io.validate(invalidMaximum)
        }

        let duplicateList = DeadlineProfile(
            name: "Duplicate list",
            requiredLists: [
                .init(identifier: "desk-list"),
                .init(identifier: "desk-list"),
            ]
        )
        #expect(throws: DeadlineProfileIOError.duplicateRequiredListIdentifier("desk-list")) {
            try io.validate(duplicateList)
        }
    }
}
