import Foundation

struct MetadataPreset: Codable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var presetType: PresetType
    var fields: [PresetField]

    init(id: UUID = UUID(), name: String = "", presetType: PresetType = .full, fields: [PresetField] = []) {
        self.id = id
        self.name = name
        self.presetType = presetType
        self.fields = fields
    }

    enum PresetType: String, Codable, CaseIterable, Sendable {
        case full = "Full"
        case perField = "Per Field"
    }
}

struct PresetField: Codable, Identifiable, Sendable, Hashable {
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
