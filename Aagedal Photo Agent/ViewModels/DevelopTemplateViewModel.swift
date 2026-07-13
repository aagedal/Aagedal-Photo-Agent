import Foundation

@Observable
final class DevelopTemplateViewModel {
    var templates: [DevelopTemplate] = []
    var editingTemplate = DevelopTemplate()
    var isEditing = false
    var errorMessage: String?

    private let storage = DevelopTemplateStorageService()

    func loadTemplates() {
        do {
            templates = try storage.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createTemplate(from settings: CameraRawSettings?, name: String, includesCrop: Bool = true) {
        saveTemplate(
            DevelopTemplate(
                name: name,
                settings: settings ?? CameraRawSettings(),
                includesCrop: includesCrop
            )
        )
    }

    func saveTemplate(_ template: DevelopTemplate) {
        do {
            if let slot = template.shortcutSlot {
                for existing in templates where existing.shortcutSlot == slot && existing.id != template.id {
                    var cleared = existing
                    cleared.shortcutSlot = nil
                    try storage.save(cleared)
                }
            }
            try storage.save(template)
            loadTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteTemplate(_ template: DevelopTemplate) {
        do {
            try storage.delete(template)
            loadTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startEditing(_ template: DevelopTemplate) {
        editingTemplate = template
        isEditing = true
    }

    func saveEditingTemplate() {
        saveTemplate(editingTemplate)
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }

    func template(forSlot slot: Int) -> DevelopTemplate? {
        templates.first { $0.shortcutSlot == slot }
    }
}
