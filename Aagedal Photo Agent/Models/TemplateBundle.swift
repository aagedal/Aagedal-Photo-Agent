import Foundation

struct TemplateBundle: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var version: Int { schemaVersion }
    var exportedAt: Date
    var templates: [MetadataTemplate]

    init(version: Int = currentSchemaVersion, exportedAt: Date = Date(), templates: [MetadataTemplate]) {
        self.schemaVersion = version
        self.exportedAt = exportedAt
        self.templates = templates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, exportedAt, templates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .version)
            ?? 1
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "template bundle",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }
        schemaVersion = Self.currentSchemaVersion
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        templates = try container.decodeIfPresent([MetadataTemplate].self, forKey: .templates) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(templates, forKey: .templates)
    }
}

struct TemplateImportPreview: Sendable, Identifiable {
    let id = UUID()
    let source: URL
    let bundle: TemplateBundle
    let newCount: Int
    let overwriteCount: Int
}

struct TemplateImportResult: Sendable {
    var added: Int
    var overwritten: Int
}
