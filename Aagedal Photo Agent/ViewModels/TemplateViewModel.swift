import Foundation

nonisolated struct TemplateSaveError: Error, Equatable, LocalizedError, Sendable {
    nonisolated enum TemplateKind: String, Equatable, Sendable {
        case metadata = "Metadata"
        case develop = "Develop"
    }

    let templateKind: TemplateKind
    let reason: String
    var isSnapshotConflict: Bool = false

    var errorDescription: String? {
        "\(templateKind.rawValue) template wasn’t saved: \(reason)"
    }

    var recoverySuggestion: String? {
        isSnapshotConflict
            ? "This template changed or is no longer available. Save a new copy, or reopen the latest template and reapply your changes. Your edits are still here."
            : "Your edits are still here. Retry the save or save a new copy."
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

    @ObservationIgnored private var editingBaseline: MetadataTemplate?
    @ObservationIgnored private var inventoryDirectoryURL: URL?
    @ObservationIgnored private var hasInventoryProvenance = false
    @ObservationIgnored private var editingDirectoryURL: URL?
    @ObservationIgnored private var editingHasInventoryProvenance = false

    private let crudService: TemplateCRUDService<MetadataTemplate>
    private let importPreviewService: TemplateImportPreviewService
    private let importCommitService: TemplateImportCommitService
    private let interpolator = PresetVariableInterpolator()
    @ObservationIgnored private var importPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var importPreviewRequestID: UUID?
    @ObservationIgnored private var importCommitTask: Task<Void, Never>?
    @ObservationIgnored private var importCommitRequestID: UUID?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadRequestID: UUID?
    @ObservationIgnored private var mutationTask: Task<TemplateMutationOperationResult<MetadataTemplate>, Error>?
    @ObservationIgnored private var mutationRequestID: UUID?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportRequestID: UUID?

    init(
        storage: TemplateStorageService = TemplateStorageService(),
        crudService: TemplateCRUDService<MetadataTemplate>? = nil,
        importPreviewService: TemplateImportPreviewService? = nil,
        importCommitService: TemplateImportCommitService? = nil
    ) {
        self.crudService = crudService
            ?? TemplateCRUDService(access: .storage(storage))
        self.importPreviewService = importPreviewService
            ?? TemplateImportPreviewService(storage: storage)
        self.importCommitService = importCommitService
            ?? TemplateImportCommitService(storage: storage)
    }

    func loadTemplates(onLoaded: (([MetadataTemplate]) -> Void)? = nil) {
        loadTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        loadTask = Task { [weak self, crudService] in
            do {
                let result = try await crudService.load(requestID: requestID)
                guard let self,
                      self.loadRequestID == requestID,
                      !Task.isCancelled else { return }
                self.loadTask = nil
                self.loadRequestID = nil
                guard case .loaded(let snapshot) = result else { return }
                self.templates = snapshot.templates
                self.inventoryDirectoryURL = snapshot.directoryURL
                self.hasInventoryProvenance = true
                self.errorMessage = nil
                onLoaded?(snapshot.templates)
            } catch {
                guard let self,
                      self.loadRequestID == requestID,
                      !Task.isCancelled else { return }
                self.loadTask = nil
                self.loadRequestID = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func saveTemplate(_ template: MetadataTemplate, expectedExisting: MetadataTemplate? = nil, expectedDirectoryURL: URL? = nil) async -> Result<MetadataTemplate, TemplateSaveError> {
        saveError = nil
        invalidatePendingLoad()
        mutationTask?.cancel()
        let requestID = UUID()
        mutationRequestID = requestID
        let task = Task { [crudService] in
            try await crudService.save(template, expectedExisting: expectedExisting, expectedDirectoryURL: expectedDirectoryURL, requestID: requestID)
        }
        mutationTask = task
        do {
            let result = try await task.value
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError(kind: .metadata))
            }
            mutationTask = nil
            mutationRequestID = nil
            guard case .committed(let commit) = result,
                  commit.requestedTemplateCommitted else {
                return recordSaveFailure(reason: "Save was cancelled.", kind: .metadata)
            }
            templates = commit.refreshedTemplates
            inventoryDirectoryURL = commit.directoryURL
            hasInventoryProvenance = true
            if let reason = commit.inventoryRefreshFailureReason {
                errorMessage = "Template was saved, but the list could not be refreshed: \(reason)"
            } else {
                errorMessage = nil
            }
            return .success(template)
        } catch let error as TemplateMutationError<MetadataTemplate> {
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError(kind: .metadata))
            }
            mutationTask = nil
            mutationRequestID = nil
            if !error.durableTemplateIDs.isEmpty {
                templates = error.refreshedTemplates
                hasInventoryProvenance = false
            }
            return recordSaveFailure(reason: error.reason, kind: .metadata, isSnapshotConflict: error.isSnapshotConflict)
        } catch {
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError(kind: .metadata))
            }
            mutationTask = nil
            mutationRequestID = nil
            return recordSaveFailure(reason: error.localizedDescription, kind: .metadata)
        }
    }

    func deleteTemplate(_ template: MetadataTemplate) {
        guard hasInventoryProvenance else {
            errorMessage = "Reload the template list before deleting."
            return
        }
        let expectedDirectoryURL = inventoryDirectoryURL
        invalidatePendingLoad()
        mutationTask?.cancel()
        let requestID = UUID()
        mutationRequestID = requestID
        let task = Task { [crudService] in
            try await crudService.delete(template, expectedDirectoryURL: expectedDirectoryURL, requestID: requestID)
        }
        mutationTask = task
        Task { [weak self] in
            do {
                let result = try await task.value
                guard let self, self.mutationRequestID == requestID else { return }
                self.mutationTask = nil
                self.mutationRequestID = nil
                guard case .committed(let commit) = result else { return }
                self.templates = commit.refreshedTemplates
                self.inventoryDirectoryURL = commit.directoryURL
                self.hasInventoryProvenance = true
                self.errorMessage = commit.inventoryRefreshFailureReason
            } catch let error as TemplateMutationError<MetadataTemplate> {
                guard let self, self.mutationRequestID == requestID else { return }
                self.mutationTask = nil
                self.mutationRequestID = nil
                if !error.durableTemplateIDs.isEmpty || error.isSnapshotConflict {
                    self.templates = error.refreshedTemplates
                    self.inventoryDirectoryURL = error.directoryURL
                    self.hasInventoryProvenance = error.directoryURL != nil
                }
                self.errorMessage = error.reason
            } catch {
                guard let self, self.mutationRequestID == requestID else { return }
                self.mutationTask = nil
                self.mutationRequestID = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func startEditing(_ template: MetadataTemplate? = nil) {
        editingBaseline = template
        editingDirectoryURL = template == nil ? nil : inventoryDirectoryURL
        editingHasInventoryProvenance = hasInventoryProvenance && template.map { templates.contains($0) } == true
        editingTemplate = template ?? MetadataTemplate()
        isEditingExistingTemplate = template != nil
        saveError = nil
        isEditing = true
    }

    @discardableResult
    func saveEditingTemplate() async -> Result<MetadataTemplate, TemplateSaveError> {
        guard editingBaseline == nil || editingHasInventoryProvenance else {
            return recordSaveFailure(
                reason: "Reopen this template from the loaded template list before saving, or save a new copy.", kind: .metadata,
                isSnapshotConflict: true
            )
        }
        return finishEditingIfSaved(await saveTemplate(
            editingTemplate, expectedExisting: editingBaseline, expectedDirectoryURL: editingDirectoryURL
        ))
    }

    @discardableResult
    func saveEditingTemplateAsNew() async -> Result<MetadataTemplate, TemplateSaveError> {
        var copy = editingTemplate
        copy.id = UUID()
        let result = await saveTemplate(copy)
        if case .success = result {
            editingTemplate = copy
        }
        return finishEditingIfSaved(result)
    }

    func cancelEditing() {
        editingBaseline = nil
        editingDirectoryURL = nil
        editingHasInventoryProvenance = false
        isEditingExistingTemplate = false
        saveError = nil
        isEditing = false
    }

    @discardableResult
    private func finishEditingIfSaved(
        _ result: Result<MetadataTemplate, TemplateSaveError>
    ) -> Result<MetadataTemplate, TemplateSaveError> {
        if case .success = result {
            editingBaseline = nil
            editingDirectoryURL = nil
            editingHasInventoryProvenance = false
            isEditingExistingTemplate = false
            isEditing = false
        }
        return result
    }

    /// Creates a template from the current metadata state.
    func createTemplateFromMetadata(_ metadata: IPTCMetadata, name: String) async {
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
        _ = await saveTemplate(template)
    }

    /// Returns the template assigned to the given shortcut slot (1-9), if any.
    func template(forSlot slot: Int) -> MetadataTemplate? {
        templates.first { $0.shortcutSlot == slot }
    }

    /// Resolves a template's variables and returns field key-value pairs ready for application.
    func resolveTemplate(
        _ template: MetadataTemplate,
        filename: String = "",
        existingMetadata: IPTCMetadata? = nil,
        voiceMemoTranscriptContext: VoiceMemoTranscriptVariableContext? = nil
    ) -> [String: String] {
        var result: [String: String] = [:]
        for field in template.fields {
            // Structured supplier JSON is an atomic typed payload. Its object braces are not
            // variable delimiters and supplier member text is never interpolated implicitly.
            let resolved = field.fieldKey == "imageSupplier"
                ? field.templateValue
                : interpolator.resolve(
                    field.templateValue,
                    filename: filename,
                    existingMetadata: existingMetadata,
                    voiceMemoTranscriptContext: voiceMemoTranscriptContext
                )
            result[field.fieldKey] = resolved
        }
        return result
    }

    // MARK: - Export / Import

    var pendingImportPreview: TemplateImportPreview?

    func exportAll(to destination: URL) {
        exportTask?.cancel()
        let requestID = UUID()
        exportRequestID = requestID
        exportTask = Task { [weak self, crudService] in
            do {
                let result = try await crudService.exportAll(to: destination, requestID: requestID)
                guard let self,
                      self.exportRequestID == requestID,
                      !Task.isCancelled else { return }
                self.exportTask = nil
                self.exportRequestID = nil
                guard case .exported = result else { return }
                self.errorMessage = nil
            } catch {
                guard let self,
                      self.exportRequestID == requestID,
                      !Task.isCancelled else { return }
                self.exportTask = nil
                self.exportRequestID = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func recordSaveFailure(
        reason: String,
        kind: TemplateSaveError.TemplateKind,
        isSnapshotConflict: Bool = false
    ) -> Result<MetadataTemplate, TemplateSaveError> {
        let failure = TemplateSaveError(templateKind: kind, reason: reason, isSnapshotConflict: isSnapshotConflict)
        saveError = failure
        errorMessage = failure.localizedDescription
        return .failure(failure)
    }

    private func supersededSaveError(kind: TemplateSaveError.TemplateKind) -> TemplateSaveError {
        TemplateSaveError(templateKind: kind, reason: "A newer template operation replaced this save.")
    }

    private func invalidatePendingLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID = nil
    }

    func preparePreview(from source: URL) {
        importPreviewTask?.cancel()
        let requestID = UUID()
        importPreviewRequestID = requestID
        pendingImportPreview = nil
        errorMessage = nil

        importPreviewTask = Task { [weak self, importPreviewService] in
            do {
                let result = try await importPreviewService.preparePreview(
                    from: source,
                    requestID: requestID
                )
                guard let self,
                      self.importPreviewRequestID == requestID,
                      !Task.isCancelled else { return }
                self.importPreviewTask = nil
                self.importPreviewRequestID = nil
                switch result {
                case .prepared(let completion):
                    self.pendingImportPreview = completion.preview
                case .cancelledBeforeRead, .cancelledAfterRead:
                    break
                }
            } catch {
                guard let self,
                      self.importPreviewRequestID == requestID,
                      !Task.isCancelled else { return }
                self.importPreviewTask = nil
                self.importPreviewRequestID = nil
                self.errorMessage = "Could not read bundle: \(error.localizedDescription)"
            }
        }
    }

    func commitPendingImport() {
        guard let preview = pendingImportPreview else { return }
        importCommitTask?.cancel()
        let requestID = UUID()
        importCommitRequestID = requestID
        pendingImportPreview = nil
        errorMessage = nil

        importCommitTask = Task { [weak self, importCommitService] in
            do {
                let result = try await importCommitService.commit(
                    preview.bundle,
                    sourceURL: preview.source,
                    requestID: requestID
                )
                guard let self, self.importCommitRequestID == requestID else { return }
                self.importCommitTask = nil
                self.importCommitRequestID = nil
                switch result {
                case .committed(let commit):
                    self.templates = commit.refreshedTemplates
                    self.inventoryDirectoryURL = commit.directoryURL
                    self.hasInventoryProvenance = true
                    self.errorMessage = commit.inventoryRefreshFailureReason
                case .cancelledBeforeCommit:
                    break
                }
            } catch {
                guard let self, self.importCommitRequestID == requestID else { return }
                self.importCommitTask = nil
                self.importCommitRequestID = nil
                if let commitError = error as? TemplateImportCommitError {
                    self.templates = commitError.refreshedTemplates
                    self.inventoryDirectoryURL = commitError.directoryURL
                    self.hasInventoryProvenance = true
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPendingImport() {
        importPreviewTask?.cancel()
        importPreviewTask = nil
        importPreviewRequestID = nil
        importCommitTask?.cancel()
        importCommitTask = nil
        importCommitRequestID = nil
        pendingImportPreview = nil
    }
}
