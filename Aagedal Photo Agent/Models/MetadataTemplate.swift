import Foundation

struct MetadataTemplate: Codable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var templateType: TemplateType
    var fields: [TemplateField]
    var shortcutSlot: Int?
    /// When true, applying this template immediately resolves metadata variables
    /// (e.g. {date}, {seq}, {filename}) for the images it was applied to, instead
    /// of leaving them for a later "Process Variables" pass.
    var processInstantly: Bool

    init(id: UUID = UUID(), name: String = "", templateType: TemplateType = .full, fields: [TemplateField] = [], shortcutSlot: Int? = nil, processInstantly: Bool = false) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.templateType = templateType
        self.fields = fields
        self.shortcutSlot = shortcutSlot
        self.processInstantly = processInstantly
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, templateType, presetType, fields, shortcutSlot, processInstantly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedVersion > 0 else {
            throw EditorialJSONSchemaError.missingOrInvalidSchemaVersion
        }
        guard decodedVersion <= Self.currentSchemaVersion else {
            throw EditorialJSONSchemaError.newerSchemaRequiresReadOnly(
                document: "metadata template",
                found: decodedVersion,
                supported: Self.currentSchemaVersion
            )
        }
        schemaVersion = Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let currentType = try container.decodeIfPresent(TemplateType.self, forKey: .templateType) {
            templateType = currentType
        } else {
            templateType = try container.decode(TemplateType.self, forKey: .presetType)
        }
        fields = try container.decodeIfPresent([TemplateField].self, forKey: .fields) ?? []
        shortcutSlot = try container.decodeIfPresent(Int.self, forKey: .shortcutSlot)
        // Default to false for templates saved before this flag existed.
        processInstantly = try container.decodeIfPresent(Bool.self, forKey: .processInstantly) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(templateType, forKey: .templateType)
        try container.encode(fields, forKey: .fields)
        try container.encodeIfPresent(shortcutSlot, forKey: .shortcutSlot)
        try container.encode(processInstantly, forKey: .processInstantly)
    }

    enum TemplateType: String, Codable, CaseIterable, Sendable {
        case full = "Full"
        case perField = "Per Field"
    }
}

struct TemplateField: Codable, Identifiable, Sendable, Hashable {
    var id: UUID
    var fieldKey: String
    var templateValue: String

    init(id: UUID = UUID(), fieldKey: String, templateValue: String) {
        self.id = id
        self.fieldKey = fieldKey
        self.templateValue = templateValue
    }

    static let availableFields: [(key: String, label: String)] = [
        ("title", "Headline"),
        ("description", "Description"),
        ("extendedDescription", "Extended Description"),
        ("keywords", "Keywords"),
        ("personShown", "Person Shown"),
        ("organisationShownName", "Organisation Shown Name"),
        ("organisationShownCode", "Organisation Shown Code"),
        ("digitalSourceType", "Digital Source Type"),
        ("urgency", "Urgency"),
        ("sceneCode", "Scene Code"),
        ("subjectCode", "Subject Code"),
        ("mediaTopic", "Media Topic"),
        ("genre", "Genre"),
        ("creator", "Creator"),
        ("creatorJobTitle", "Creator Job Title"),
        ("descriptionWriter", "Description Writer"),
        ("credit", "Credit"),
        ("copyright", "Copyright"),
        ("rightsUsageTerms", "Rights Usage Terms"),
        ("webStatementOfRights", "Web Statement of Rights"),
        ("digitalImageGUID", "Digital Image GUID"),
        ("imageSupplierImageID", "Image Supplier Image ID"),
        ("imageSupplier", "Image Supplier"),
        ("jobId", "Job ID"),
        ("dateCreated", "Date Created"),
        ("city", "City"),
        ("sublocation", "Sublocation"),
        ("provinceState", "State / Province"),
        ("country", "Country"),
        ("countryCode", "Country Code"),
        ("event", "Event"),
        ("instructions", "Instructions"),
        ("source", "Source"),
    ]

    static func label(for key: String) -> String {
        availableFields.first { $0.key == key }?.label ?? key
    }
}
