import Foundation

struct MetadataTemplate: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var templateType: TemplateType
    var fields: [TemplateField]

    init(id: UUID = UUID(), name: String = "", templateType: TemplateType = .full, fields: [TemplateField] = []) {
        self.id = id
        self.name = name
        self.templateType = templateType
        self.fields = fields
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
        ("title", "Title"),
        ("description", "Description"),
        ("keywords", "Keywords"),
        ("personShown", "Person Shown"),
        ("digitalSourceType", "Digital Source Type"),
        ("creator", "Creator"),
        ("credit", "Credit"),
        ("copyright", "Copyright"),
        ("dateCreated", "Date Created"),
        ("city", "City"),
        ("country", "Country"),
        ("event", "Event"),
    ]

    static func label(for key: String) -> String {
        availableFields.first { $0.key == key }?.label ?? key
    }
}
