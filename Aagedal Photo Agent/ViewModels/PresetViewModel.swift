import Foundation

@Observable
final class PresetViewModel {
    var presets: [MetadataPreset] = []
    var selectedPreset: MetadataPreset?
    var isEditing = false
    var editingPreset = MetadataPreset()
    var errorMessage: String?

    private let storage = PresetStorageService()
    private let interpolator = PresetVariableInterpolator()

    func loadPresets() {
        do {
            presets = try storage.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func savePreset(_ preset: MetadataPreset) {
        do {
            try storage.save(preset)
            loadPresets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePreset(_ preset: MetadataPreset) {
        do {
            try storage.delete(preset)
            loadPresets()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startEditing(_ preset: MetadataPreset? = nil) {
        editingPreset = preset ?? MetadataPreset()
        isEditing = true
    }

    func saveEditingPreset() {
        savePreset(editingPreset)
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }

    /// Creates a preset from the current metadata state.
    func createPresetFromMetadata(_ metadata: IPTCMetadata, name: String) {
        var preset = MetadataPreset(name: name, presetType: .full)
        var fields: [PresetField] = []

        if let v = metadata.title, !v.isEmpty { fields.append(PresetField(fieldKey: "title", templateValue: v)) }
        if let v = metadata.description, !v.isEmpty { fields.append(PresetField(fieldKey: "description", templateValue: v)) }
        if !metadata.keywords.isEmpty { fields.append(PresetField(fieldKey: "keywords", templateValue: metadata.keywords.joined(separator: ", "))) }
        if !metadata.personShown.isEmpty { fields.append(PresetField(fieldKey: "personShown", templateValue: metadata.personShown.joined(separator: ", "))) }
        if let v = metadata.digitalSourceType { fields.append(PresetField(fieldKey: "digitalSourceType", templateValue: v.rawValue)) }
        if let v = metadata.creator, !v.isEmpty { fields.append(PresetField(fieldKey: "creator", templateValue: v)) }
        if let v = metadata.credit, !v.isEmpty { fields.append(PresetField(fieldKey: "credit", templateValue: v)) }
        if let v = metadata.copyright, !v.isEmpty { fields.append(PresetField(fieldKey: "copyright", templateValue: v)) }
        if let v = metadata.dateCreated, !v.isEmpty { fields.append(PresetField(fieldKey: "dateCreated", templateValue: v)) }
        if let v = metadata.city, !v.isEmpty { fields.append(PresetField(fieldKey: "city", templateValue: v)) }
        if let v = metadata.country, !v.isEmpty { fields.append(PresetField(fieldKey: "country", templateValue: v)) }
        if let v = metadata.event, !v.isEmpty { fields.append(PresetField(fieldKey: "event", templateValue: v)) }

        preset.fields = fields
        savePreset(preset)
    }

    /// Resolves a preset's template variables and returns field key-value pairs ready for application.
    func resolvePreset(_ preset: MetadataPreset, filename: String = "", existingMetadata: IPTCMetadata? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for field in preset.fields {
            let resolved = interpolator.resolve(field.templateValue, filename: filename, existingMetadata: existingMetadata)
            result[field.fieldKey] = resolved
        }
        return result
    }
}
