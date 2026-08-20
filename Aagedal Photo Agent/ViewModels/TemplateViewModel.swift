import Foundation

@Observable
final class TemplateViewModel {
    var templates: [MetadataTemplate] = []
    var selectedTemplate: MetadataTemplate?
    var isEditing = false
    var isEditingExistingTemplate = false
    var editingTemplate = MetadataTemplate()
    var errorMessage: String?

    private let storage = TemplateStorageService()
    private let interpolator = PresetVariableInterpolator()

    func loadTemplates() {
        do {
            templates = try storage.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveTemplate(_ template: MetadataTemplate) {
        do {
            // If this template claims a shortcut slot, clear it from any other template
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

    func deleteTemplate(_ template: MetadataTemplate) {
        do {
            try storage.delete(template)
            loadTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startEditing(_ template: MetadataTemplate? = nil) {
        editingTemplate = template ?? MetadataTemplate()
        isEditingExistingTemplate = template != nil
        isEditing = true
    }

    func saveEditingTemplate() {
        saveTemplate(editingTemplate)
        isEditingExistingTemplate = false
        isEditing = false
    }

    func cancelEditing() {
        isEditingExistingTemplate = false
        isEditing = false
    }

    /// Creates a template from the current metadata state.
    func createTemplateFromMetadata(_ metadata: IPTCMetadata, name: String) {
        var template = MetadataTemplate(name: name, templateType: .full)
        var fields: [TemplateField] = []

        if let v = metadata.title, !v.isEmpty { fields.append(TemplateField(fieldKey: "title", templateValue: v)) }
        if let v = metadata.description, !v.isEmpty { fields.append(TemplateField(fieldKey: "description", templateValue: v)) }
        if let v = metadata.extendedDescription, !v.isEmpty { fields.append(TemplateField(fieldKey: "extendedDescription", templateValue: v)) }
        if !metadata.keywords.isEmpty { fields.append(TemplateField(fieldKey: "keywords", templateValue: metadata.keywords.joined(separator: ", "))) }
        if !metadata.personShown.isEmpty { fields.append(TemplateField(fieldKey: "personShown", templateValue: metadata.personShown.joined(separator: ", "))) }
        if !metadata.organisationsShownNames.isEmpty { fields.append(TemplateField(fieldKey: "organisationShownName", templateValue: metadata.organisationsShownNames.joined(separator: ", "))) }
        if !metadata.organisationsShownCodes.isEmpty { fields.append(TemplateField(fieldKey: "organisationShownCode", templateValue: metadata.organisationsShownCodes.joined(separator: ", "))) }
        if let v = metadata.digitalSourceType { fields.append(TemplateField(fieldKey: "digitalSourceType", templateValue: v.rawValue)) }
        if let v = metadata.urgency { fields.append(TemplateField(fieldKey: "urgency", templateValue: String(v))) }
        if let v = metadata.creator, !v.isEmpty { fields.append(TemplateField(fieldKey: "creator", templateValue: v)) }
        if let v = metadata.creatorJobTitle, !v.isEmpty { fields.append(TemplateField(fieldKey: "creatorJobTitle", templateValue: v)) }
        if let v = metadata.descriptionWriter, !v.isEmpty { fields.append(TemplateField(fieldKey: "descriptionWriter", templateValue: v)) }
        if let v = metadata.credit, !v.isEmpty { fields.append(TemplateField(fieldKey: "credit", templateValue: v)) }
        if let v = metadata.copyright, !v.isEmpty { fields.append(TemplateField(fieldKey: "copyright", templateValue: v)) }
        if let v = metadata.jobId, !v.isEmpty { fields.append(TemplateField(fieldKey: "jobId", templateValue: v)) }
        if let v = metadata.dateCreated, !v.isEmpty { fields.append(TemplateField(fieldKey: "dateCreated", templateValue: v)) }
        if let v = metadata.city, !v.isEmpty { fields.append(TemplateField(fieldKey: "city", templateValue: v)) }
        if let v = metadata.sublocation, !v.isEmpty { fields.append(TemplateField(fieldKey: "sublocation", templateValue: v)) }
        if let v = metadata.provinceState, !v.isEmpty { fields.append(TemplateField(fieldKey: "provinceState", templateValue: v)) }
        if let v = metadata.country, !v.isEmpty { fields.append(TemplateField(fieldKey: "country", templateValue: v)) }
        if let v = metadata.countryCode, !v.isEmpty { fields.append(TemplateField(fieldKey: "countryCode", templateValue: v)) }
        if let v = metadata.event, !v.isEmpty { fields.append(TemplateField(fieldKey: "event", templateValue: v)) }
        if let v = metadata.instructions, !v.isEmpty { fields.append(TemplateField(fieldKey: "instructions", templateValue: v)) }
        if let v = metadata.source, !v.isEmpty { fields.append(TemplateField(fieldKey: "source", templateValue: v)) }

        template.fields = fields
        saveTemplate(template)
    }

    /// Returns the template assigned to the given shortcut slot (1-9), if any.
    func template(forSlot slot: Int) -> MetadataTemplate? {
        templates.first { $0.shortcutSlot == slot }
    }

    /// Resolves a template's variables and returns field key-value pairs ready for application.
    func resolveTemplate(_ template: MetadataTemplate, filename: String = "", existingMetadata: IPTCMetadata? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for field in template.fields {
            let resolved = interpolator.resolve(field.templateValue, filename: filename, existingMetadata: existingMetadata)
            result[field.fieldKey] = resolved
        }
        return result
    }

    // MARK: - Export / Import

    var pendingImportPreview: TemplateImportPreview?

    func exportAll(to destination: URL) {
        do {
            try storage.exportAll(to: destination)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func preparePreview(from source: URL) {
        do {
            pendingImportPreview = try storage.previewImport(from: source)
        } catch {
            errorMessage = "Could not read bundle: \(error.localizedDescription)"
        }
    }

    func commitPendingImport() {
        guard let preview = pendingImportPreview else { return }
        do {
            _ = try storage.importBundle(preview.bundle, overwriteByID: true)
            loadTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
        pendingImportPreview = nil
    }

    func cancelPendingImport() {
        pendingImportPreview = nil
    }
}
