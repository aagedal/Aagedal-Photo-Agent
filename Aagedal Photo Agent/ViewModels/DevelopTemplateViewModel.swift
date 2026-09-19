import Foundation

@Observable
final class DevelopTemplateViewModel {
    var templates: [DevelopTemplate] = []
    var editingTemplate = DevelopTemplate()
    var isEditing = false
    var isEditingExistingTemplate = false
    var errorMessage: String?
    private(set) var saveError: TemplateSaveError?

    @ObservationIgnored private var editingBaseline: DevelopTemplate?
    @ObservationIgnored private var inventoryAuthorities: [UUID: TemplateFileAuthority] = [:]
    @ObservationIgnored private var editingAuthority: TemplateFileAuthority?
    @ObservationIgnored private var inventoryDirectoryURL: URL?
    @ObservationIgnored private var hasInventoryProvenance = false
    @ObservationIgnored private var editingDirectoryURL: URL?
    @ObservationIgnored private var editingHasInventoryProvenance = false

    private let crudService: TemplateCRUDService<DevelopTemplate>
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadRequestID: UUID?
    @ObservationIgnored private var mutationTask: Task<TemplateMutationOperationResult<DevelopTemplate>, Error>?
    @ObservationIgnored private var mutationRequestID: UUID?

    init(
        storage: DevelopTemplateStorageService = DevelopTemplateStorageService(),
        crudService: TemplateCRUDService<DevelopTemplate>? = nil
    ) {
        self.crudService = crudService
            ?? TemplateCRUDService(access: .storage(storage))
    }

    func loadTemplates(onLoaded: (([DevelopTemplate]) -> Void)? = nil) {
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
                self.inventoryAuthorities = snapshot.authorities
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
    func createTemplate(
        from settings: CameraRawSettings?,
        name: String,
        includesCrop: Bool = true
    ) async -> Result<DevelopTemplate, TemplateSaveError> {
        await saveTemplate(
            DevelopTemplate(
                name: name,
                settings: settings ?? CameraRawSettings(),
                includesCrop: includesCrop
            )
        )
    }

    @discardableResult
    func saveTemplate(_ template: DevelopTemplate, expectedExisting: DevelopTemplate? = nil, expectedDirectoryURL: URL? = nil, expectedAuthority: TemplateFileAuthority? = nil) async -> Result<DevelopTemplate, TemplateSaveError> {
        saveError = nil
        invalidatePendingLoad()
        mutationTask?.cancel()
        let requestID = UUID()
        mutationRequestID = requestID
        let task = Task { [crudService] in
            try await crudService.save(template, expectedExisting: expectedExisting, expectedDirectoryURL: expectedDirectoryURL, expectedAuthority: expectedAuthority, requestID: requestID)
        }
        mutationTask = task
        do {
            let result = try await task.value
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError())
            }
            mutationTask = nil
            mutationRequestID = nil
            guard case .committed(let commit) = result,
                  commit.requestedTemplateCommitted else {
                return recordSaveFailure(reason: "Save was cancelled.")
            }
            templates = commit.refreshedTemplates
            inventoryDirectoryURL = commit.directoryURL
            inventoryAuthorities = commit.authorities
            hasInventoryProvenance = commit.inventoryWasRead
            if let reason = commit.inventoryRefreshFailureReason {
                errorMessage = "Template was saved, but the list could not be refreshed: \(reason)"
            } else {
                errorMessage = nil
            }
            return .success(template)
        } catch let error as TemplateMutationError<DevelopTemplate> {
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError())
            }
            mutationTask = nil
            mutationRequestID = nil
            if !error.durableTemplateIDs.isEmpty {
                templates = error.refreshedTemplates
                hasInventoryProvenance = false
            }
            return recordSaveFailure(reason: error.reason, isSnapshotConflict: error.isSnapshotConflict)
        } catch {
            guard mutationRequestID == requestID else {
                return .failure(supersededSaveError())
            }
            mutationTask = nil
            mutationRequestID = nil
            return recordSaveFailure(reason: error.localizedDescription)
        }
    }

    func deleteTemplate(_ template: DevelopTemplate) {
        guard hasInventoryProvenance, inventoryDirectoryURL == nil || inventoryAuthorities[template.id] != nil else {
            errorMessage = "Reload the template list before deleting."
            return
        }
        let expectedDirectoryURL = inventoryDirectoryURL
        let expectedAuthority = inventoryAuthorities[template.id]
        invalidatePendingLoad()
        mutationTask?.cancel()
        let requestID = UUID()
        mutationRequestID = requestID
        let task = Task { [crudService] in
            try await crudService.delete(template, expectedDirectoryURL: expectedDirectoryURL, expectedAuthority: expectedAuthority, requestID: requestID)
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
                self.inventoryAuthorities = commit.authorities
                self.hasInventoryProvenance = commit.inventoryWasRead
                self.errorMessage = commit.inventoryRefreshFailureReason
            } catch let error as TemplateMutationError<DevelopTemplate> {
                guard let self, self.mutationRequestID == requestID else { return }
                self.mutationTask = nil
                self.mutationRequestID = nil
                if !error.durableTemplateIDs.isEmpty || error.isSnapshotConflict {
                    self.templates = error.refreshedTemplates
                    self.inventoryDirectoryURL = error.directoryURL
                    self.inventoryAuthorities = error.authorities
                    self.hasInventoryProvenance = error.directoryURL != nil && !error.authorities.isEmpty
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

    func startEditing(_ template: DevelopTemplate) {
        editingBaseline = template
        editingAuthority = inventoryAuthorities[template.id]
        editingDirectoryURL = inventoryDirectoryURL
        editingHasInventoryProvenance = hasInventoryProvenance && templates.contains(template)
        editingTemplate = template
        isEditingExistingTemplate = true
        saveError = nil
        isEditing = true
    }

    @discardableResult
    func saveEditingTemplate() async -> Result<DevelopTemplate, TemplateSaveError> {
        guard editingBaseline == nil || (editingHasInventoryProvenance && (editingDirectoryURL == nil || editingAuthority != nil)) else {
            return recordSaveFailure(
                reason: "Reopen this template from the loaded template list before saving, or save a new copy.",
                isSnapshotConflict: true
            )
        }
        return finishEditingIfSaved(await saveTemplate(
            editingTemplate, expectedExisting: editingBaseline, expectedDirectoryURL: editingDirectoryURL, expectedAuthority: editingAuthority
        ))
    }

    @discardableResult
    func saveEditingTemplateAsNew() async -> Result<DevelopTemplate, TemplateSaveError> {
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
        editingAuthority = nil
        editingDirectoryURL = nil
        editingHasInventoryProvenance = false
        isEditingExistingTemplate = false
        saveError = nil
        isEditing = false
    }

    @discardableResult
    private func finishEditingIfSaved(
        _ result: Result<DevelopTemplate, TemplateSaveError>
    ) -> Result<DevelopTemplate, TemplateSaveError> {
        if case .success = result {
            editingBaseline = nil
            editingAuthority = nil
            editingDirectoryURL = nil
            editingHasInventoryProvenance = false
            isEditingExistingTemplate = false
            isEditing = false
        }
        return result
    }

    func template(forSlot slot: Int) -> DevelopTemplate? {
        templates.first { $0.shortcutSlot == slot }
    }

    private func recordSaveFailure(reason: String, isSnapshotConflict: Bool = false) -> Result<DevelopTemplate, TemplateSaveError> {
        let failure = TemplateSaveError(templateKind: .develop, reason: reason, isSnapshotConflict: isSnapshotConflict)
        saveError = failure
        errorMessage = failure.localizedDescription
        return .failure(failure)
    }

    private func supersededSaveError() -> TemplateSaveError {
        TemplateSaveError(
            templateKind: .develop,
            reason: "A newer template operation replaced this save."
        )
    }

    private func invalidatePendingLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID = nil
    }
}
