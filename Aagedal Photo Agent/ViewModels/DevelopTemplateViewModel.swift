import Foundation

@Observable
final class DevelopTemplateViewModel {
    var templates: [DevelopTemplate] = []
    var editingTemplate = DevelopTemplate()
    var isEditing = false
    var isEditingExistingTemplate = false
    var errorMessage: String?
    private(set) var saveError: TemplateSaveError?

    private let storage: DevelopTemplateStorageService

    init(storage: DevelopTemplateStorageService = DevelopTemplateStorageService()) {
        self.storage = storage
    }

    func loadTemplates() {
        do {
            templates = try storage.loadAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTemplate(
        from settings: CameraRawSettings?,
        name: String,
        includesCrop: Bool = true
    ) -> Result<DevelopTemplate, TemplateSaveError> {
        saveTemplate(
            DevelopTemplate(
                name: name,
                settings: settings ?? CameraRawSettings(),
                includesCrop: includesCrop
            )
        )
    }

    @discardableResult
    func saveTemplate(_ template: DevelopTemplate) -> Result<DevelopTemplate, TemplateSaveError> {
        saveError = nil
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
            return .success(template)
        } catch {
            let failure = TemplateSaveError(
                templateKind: .develop,
                reason: error.localizedDescription
            )
            saveError = failure
            errorMessage = failure.localizedDescription
            return .failure(failure)
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
        isEditingExistingTemplate = true
        saveError = nil
        isEditing = true
    }

    @discardableResult
    func saveEditingTemplate() -> Result<DevelopTemplate, TemplateSaveError> {
        finishEditingIfSaved(saveTemplate(editingTemplate))
    }

    @discardableResult
    func saveEditingTemplateAsNew() -> Result<DevelopTemplate, TemplateSaveError> {
        var copy = editingTemplate
        copy.id = UUID()
        let result = saveTemplate(copy)
        if case .success = result {
            editingTemplate = copy
        }
        return finishEditingIfSaved(result)
    }

    func cancelEditing() {
        isEditingExistingTemplate = false
        saveError = nil
        isEditing = false
    }

    @discardableResult
    private func finishEditingIfSaved(
        _ result: Result<DevelopTemplate, TemplateSaveError>
    ) -> Result<DevelopTemplate, TemplateSaveError> {
        if case .success = result {
            isEditingExistingTemplate = false
            isEditing = false
        }
        return result
    }

    func template(forSlot slot: Int) -> DevelopTemplate? {
        templates.first { $0.shortcutSlot == slot }
    }
}
