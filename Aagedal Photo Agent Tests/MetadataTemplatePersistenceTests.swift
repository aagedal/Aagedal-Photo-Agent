import Foundation
import Testing
@testable import Aagedal_Photo_Agent

@Suite("Metadata template persistence")
struct MetadataTemplatePersistenceTests {
    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataTemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("earliest preset-shaped templates migrate with shipped defaults")
    func legacyPresetShapeMigrates() throws {
        let id = UUID()
        let fieldID = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy",
              "presetType": "Full",
              "fields": [
                {
                  "id": "\(fieldID.uuidString)",
                  "fieldKey": "title",
                  "templateValue": "News"
                }
              ]
            }
            """.utf8
        )

        let template = try JSONDecoder().decode(MetadataTemplate.self, from: data)
        #expect(template.schemaVersion == MetadataTemplate.currentSchemaVersion)
        #expect(template.templateType == .full)
        #expect(template.shortcutSlot == nil)
        #expect(template.processInstantly == false)
        #expect(template.fields.map(\.templateValue) == ["News"])

        let encoded = try JSONEncoder().encode(template)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == MetadataTemplate.currentSchemaVersion)
        #expect(object["presetType"] == nil)
    }

    @Test("template storage writes schema markers")
    func storageWritesSchemaMarker() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = MetadataTemplate(name: "Desk")
        let service = TemplateStorageService(directoryURL: folder)

        try service.save(template)

        let url = folder.appendingPathComponent("\(template.id.uuidString).json")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == MetadataTemplate.currentSchemaVersion)
        #expect(try service.loadAll().map(\.name) == ["Desk"])
    }

    @Test("editorial role fields survive template persistence")
    func editorialRoleFieldsRoundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expectedFields = [
            TemplateField(fieldKey: "creatorJobTitle", templateValue: "Staff Photographer"),
            TemplateField(fieldKey: "descriptionWriter", templateValue: "Night Desk"),
            TemplateField(fieldKey: "countryCode", templateValue: "NOR"),
            TemplateField(fieldKey: "organisationShownName", templateValue: "Example News"),
            TemplateField(fieldKey: "organisationShownCode", templateValue: "EXNEWS"),
            TemplateField(fieldKey: "rightsUsageTerms", templateValue: "Editorial use only"),
            TemplateField(fieldKey: "webStatementOfRights", templateValue: "https://example.test/rights"),
        ]
        let template = MetadataTemplate(name: "Editorial roles", fields: expectedFields)
        let service = TemplateStorageService(directoryURL: folder)

        try service.save(template)
        let loaded = try #require(service.loadAll().first)

        #expect(loaded.fields == expectedFields)
        #expect(TemplateField.label(for: "creatorJobTitle") == "Creator Job Title")
        #expect(TemplateField.label(for: "descriptionWriter") == "Description Writer")
        #expect(TemplateField.label(for: "countryCode") == "Country Code")
        #expect(TemplateField.label(for: "organisationShownName") == "Organisation Shown Name")
        #expect(TemplateField.label(for: "organisationShownCode") == "Organisation Shown Code")
        #expect(TemplateField.label(for: "rightsUsageTerms") == "Rights Usage Terms")
        #expect(TemplateField.label(for: "webStatementOfRights") == "Web Statement of Rights")
    }

    @Test("newer templates are skipped and protected from overwrite")
    func newerTemplateIsReadOnly() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let template = MetadataTemplate(name: "Current build")
        let url = folder.appendingPathComponent("\(template.id.uuidString).json")
        let futureData = Data(
            """
            {
              "schemaVersion": 2,
              "id": "\(template.id.uuidString)",
              "name": "Future build",
              "future": {"keep": true}
            }
            """.utf8
        )
        try futureData.write(to: url)
        let service = TemplateStorageService(directoryURL: folder)

        #expect(try service.loadAll().isEmpty)
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "metadata template",
            found: 2,
            supported: MetadataTemplate.currentSchemaVersion
        )) {
            try service.save(template)
        }
        #expect(try Data(contentsOf: url) == futureData)
    }

    @Test("legacy bundles migrate and newer bundles are rejected")
    func bundleVersionHandling() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = TemplateStorageService(directoryURL: folder)
        let source = folder.appendingPathComponent("bundle.json")
        let exportedAt = "2026-08-19T12:00:00Z"
        try Data(
            #"{"version":1,"exportedAt":"\#(exportedAt)","templates":[]}"#.utf8
        ).write(to: source)

        let legacy = try service.loadBundle(from: source)
        #expect(legacy.schemaVersion == TemplateBundle.currentSchemaVersion)
        #expect(legacy.templates.isEmpty)

        let futureData = Data(
            #"{"schemaVersion":2,"exportedAt":"\#(exportedAt)","templates":[]}"#.utf8
        )
        try futureData.write(to: source, options: .atomic)
        #expect(throws: EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
            document: "template bundle",
            found: 2,
            supported: TemplateBundle.currentSchemaVersion
        )) {
            _ = try service.loadBundle(from: source)
        }
        #expect(try Data(contentsOf: source) == futureData)
    }
}
