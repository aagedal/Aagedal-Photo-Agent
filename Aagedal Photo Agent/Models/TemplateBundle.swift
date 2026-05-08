import Foundation

struct TemplateBundle: Codable, Sendable {
    var version: Int
    var exportedAt: Date
    var templates: [MetadataTemplate]

    init(version: Int = 1, exportedAt: Date = Date(), templates: [MetadataTemplate]) {
        self.version = version
        self.exportedAt = exportedAt
        self.templates = templates
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
