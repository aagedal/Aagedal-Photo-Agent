import Foundation

nonisolated struct TemplateSaveError: Error, Equatable, LocalizedError, Sendable {
    nonisolated enum TemplateKind: String, Equatable, Sendable {
        case metadata = "Metadata"
        case develop = "Develop"
    }

    let templateKind: TemplateKind
    let reason: String

    var errorDescription: String? {
        "\(templateKind.rawValue) template wasn’t saved: \(reason)"
    }

    var recoverySuggestion: String? {
        "Your edits are still here. Retry the save or save a new copy."
    }
}

@Observable
final class TemplateViewModel {
    var templates: [MetadataTemplate] = []
    var selectedTemplate: MetadataTemplate?
    var isEditing = false
    var isEditingExistingTemplate = false
    var editingTemplate = MetadataTemplate()
    var errorMessage: String?
    private(set) var saveError: TemplateSaveError?

    private let storage: TemplateStorageService
    private let interpolator = PresetVariableInterpolator()

    init(storage: TemplateStorageService = TemplateStorageService()) {
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
    func saveTemplate(_ template: MetadataTemplate) -> Result<MetadataTemplate, TemplateSaveError> {
        saveError = nil
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
            return .success(template)
        } catch {
            let failure = TemplateSaveError(
                templateKind: .metadata,
                reason: error.localizedDescription
            )
            saveError = failure
            errorMessage = failure.localizedDescription
            return .failure(failure)
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
        saveError = nil
        isEditing = true
    }

    @discardableResult
    func saveEditingTemplate() -> Result<MetadataTemplate, TemplateSaveError> {
        finishEditingIfSaved(saveTemplate(editingTemplate))
    }

    @discardableResult
    func saveEditingTemplateAsNew() -> Result<MetadataTemplate, TemplateSaveError> {
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
        _ result: Result<MetadataTemplate, TemplateSaveError>
    ) -> Result<MetadataTemplate, TemplateSaveError> {
        if case .success = result {
            isEditingExistingTemplate = false
            isEditing = false
        }
        return result
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
        if !metadata.sceneCodes.isEmpty { fields.append(TemplateField(fieldKey: "sceneCode", templateValue: metadata.sceneCodes.joined(separator: ", "))) }
        if !metadata.subjectCodes.isEmpty { fields.append(TemplateField(fieldKey: "subjectCode", templateValue: metadata.subjectCodes.joined(separator: ", "))) }
        if let value = IPTCControlledVocabularyTerm.templateValue(for: metadata.mediaTopics) {
            fields.append(TemplateField(fieldKey: "mediaTopic", templateValue: value))
        }
        if let value = IPTCControlledVocabularyTerm.templateValue(for: metadata.genres) {
            fields.append(TemplateField(fieldKey: "genre", templateValue: value))
        }
        if let v = metadata.digitalImageGUID, !v.isEmpty { fields.append(TemplateField(fieldKey: "digitalImageGUID", templateValue: v)) }
        if let v = metadata.imageSupplierImageID, !v.isEmpty { fields.append(TemplateField(fieldKey: "imageSupplierImageID", templateValue: v)) }
        if let value = EditorialImageSupplier.canonicalJSONString(for: metadata.imageSuppliers) {
            fields.append(TemplateField(fieldKey: "imageSupplier", templateValue: value))
        }
        if let v = metadata.creatorTransportValue {
            fields.append(TemplateField(fieldKey: "creator", templateValue: v))
        }
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
            // Structured supplier JSON is an atomic typed payload. Its object braces are not
            // variable delimiters and supplier member text is never interpolated implicitly.
            let resolved = field.fieldKey == "imageSupplier"
                ? field.templateValue
                : interpolator.resolve(
                    field.templateValue,
                    filename: filename,
                    existingMetadata: existingMetadata
                )
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
