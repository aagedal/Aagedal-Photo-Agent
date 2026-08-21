import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BatchRenameExecutionQuiescenceError: LocalizedError, Equatable {
    case faceScan(String)
    case analysis(String)

    var errorDescription: String? {
        switch self {
        case .faceScan(let detail):
            "Face-data writer could not be stopped safely: \(detail)"
        case .analysis(let detail):
            "Analysis writer could not be stopped safely: \(detail)"
        }
    }
}

struct BatchRenameExecutionQuiescence {
    enum Completion {
        case succeeded([BatchRenameExecutionPresentation.Mapping])
        case abortedBeforeExecution
        case executionFailed
    }

    let prepare: @MainActor () async throws -> Void
    let complete: @MainActor (Completion) async throws -> Void

    static let noOp = BatchRenameExecutionQuiescence(
        prepare: {},
        complete: { _ in }
    )
}

/// A value-only planning request captured on the main actor before background work starts.
/// The planner never reaches back into observable sheet state while evaluating a preview.
nonisolated struct BatchRenamePlanningSnapshot: Sendable {
    let items: [RenamePlanningItem]
    let recipe: BatchRenameRecipe
    let collisionPolicy: RenameCollisionPolicy
    let artifactRegistry: RenameArtifactRegistry
    let environment: RenamePlanningEnvironment
}

/// Serializes the synchronous, CPU-heavy planner away from the main actor. Cancellation is
/// checked on both sides of the non-suspending planner call: an in-flight calculation finishes,
/// while cancelled calculations waiting behind it are discarded before doing more work.
private actor BatchRenamePlanningWorker {
    typealias PlanBuilder = @Sendable (BatchRenamePlanningSnapshot) -> RenamePlan

    private let planBuilder: PlanBuilder

    init(planBuilder: @escaping PlanBuilder) {
        self.planBuilder = planBuilder
    }

    func makePlan(from snapshot: BatchRenamePlanningSnapshot) throws -> RenamePlan {
        try Task.checkCancellation()
        let plan = planBuilder(snapshot)
        try Task.checkCancellation()
        return plan
    }
}

@MainActor
@Observable
final class BatchRenameSheetSession {
    typealias PlanBuilder = @Sendable (BatchRenamePlanningSnapshot) -> RenamePlan

    let request: BatchRenameSheetRequest
    let artifactRegistry: RenameArtifactRegistry

    var editor: BatchRenameEditorState {
        didSet {
            if !isSwitchingRecipe {
                storeCurrentDraft()
            }
            rebuildPlan()
        }
    }
    private(set) var selectedRecipePresetID: UUID?
    private(set) var environment: RenamePlanningEnvironment?
    private(set) var plan: RenamePlan?
    private(set) var isPlanning = false
    private(set) var snapshotError: String?
    private(set) var executionGuardError: String?
    private(set) var isPreparing = false
    private(set) var isExecuting = false
    private(set) var executionPresentation: BatchRenameExecutionPresentation?
    private(set) var reassociationResult: RenameReassociationResult?
    private(set) var requiresFreshSnapshotAfterFailure = false
    private(set) var hasCompletedExecution = false
    private var adHocDraft: BatchRenameEditorState
    private var presetDrafts: [UUID: BatchRenameEditorState] = [:]
    private var presetBaselines: [UUID: BatchRenameRecipePreset] = [:]
    private var isSwitchingRecipe = false
    private let executionQuiescence: BatchRenameExecutionQuiescence
    @ObservationIgnored private let planningWorker: BatchRenamePlanningWorker
    @ObservationIgnored private let planningDebounce: Duration
    @ObservationIgnored private var planningGeneration: UInt64 = 0
    @ObservationIgnored private var planningTask: Task<Void, Never>?

    init(
        request: BatchRenameSheetRequest,
        artifactRegistry: RenameArtifactRegistry = .standard,
        environment: RenamePlanningEnvironment? = nil,
        executionQuiescence: BatchRenameExecutionQuiescence = .noOp,
        planningDebounce: Duration = .milliseconds(120),
        planBuilder: @escaping PlanBuilder = { snapshot in
            RenamePlanningService().makePlan(
                items: snapshot.items,
                recipe: snapshot.recipe,
                collisionPolicy: snapshot.collisionPolicy,
                artifactRegistry: snapshot.artifactRegistry,
                environment: snapshot.environment
            )
        }
    ) {
        self.request = request
        self.artifactRegistry = artifactRegistry
        self.executionQuiescence = executionQuiescence
        self.planningDebounce = planningDebounce
        planningWorker = BatchRenamePlanningWorker(planBuilder: planBuilder)
        let initialEditor = BatchRenameEditorState(
            sourceFilenames: request.items.map { $0.sourceImageURL.lastPathComponent }
        )
        editor = initialEditor
        adHocDraft = initialEditor
        self.environment = environment
        if environment != nil {
            rebuildPlan()
        }
    }

    var previewRows: [BatchRenamePreviewRow] {
        plan?.entries.map(BatchRenamePreviewRow.init(entry:)) ?? []
    }

    var sampleName: String {
        previewRows.first?.requestedName ?? "—"
    }

    var canExecute: Bool {
        plan?.canExecute == true
            && plan?.entries.contains(where: { $0.disposition == .rename }) == true
            && !requiresFreshSnapshotAfterFailure
            && !hasCompletedExecution
            && executionGuardError == nil
            && !isPreparing
            && !isPlanning
            && !isExecuting
            && !editor.components.isEmpty
    }

    var issueSummary: BatchRenameIssueSummary? {
        plan.map(BatchRenameIssueSummary.init(plan:))
    }

    var hasUnsavedPresetChanges: Bool {
        guard let selectedRecipePresetID,
              let baseline = presetBaselines[selectedRecipePresetID] else { return false }
        return editor.recipe != baseline.recipe
            || editor.collisionChoice != baseline.collisionChoice
    }

    func selectRecipePreset(_ preset: BatchRenameRecipePreset) {
        storeCurrentDraft()
        let baseline = BatchRenameEditorState(
            recipe: preset.recipe,
            collisionChoice: preset.collisionChoice
        )
        presetBaselines[preset.id] = preset
        selectedRecipePresetID = preset.id
        setEditor(presetDrafts[preset.id] ?? baseline)
    }

    func useAdHocRecipe() {
        storeCurrentDraft()
        selectedRecipePresetID = nil
        setEditor(adHocDraft)
    }

    func markRecipePresetSaved(_ preset: BatchRenameRecipePreset) {
        var savedEditor = editor
        savedEditor.setRecipeName(preset.name)
        presetBaselines[preset.id] = preset
        presetDrafts[preset.id] = savedEditor
        selectedRecipePresetID = preset.id
        setEditor(savedEditor)
    }

    func synchronizeRenamedPreset(_ preset: BatchRenameRecipePreset) {
        presetBaselines[preset.id] = preset
        guard selectedRecipePresetID == preset.id else { return }
        var renamedEditor = editor
        renamedEditor.setRecipeName(preset.name)
        presetDrafts[preset.id] = renamedEditor
        setEditor(renamedEditor)
    }

    func preserveDeletedPresetAsAdHoc(id: UUID) {
        presetBaselines.removeValue(forKey: id)
        let deletedDraft = presetDrafts.removeValue(forKey: id)
        guard selectedRecipePresetID == id else { return }
        adHocDraft = deletedDraft ?? editor
        selectedRecipePresetID = nil
        setEditor(adHocDraft)
    }

    func prepareSnapshot() async {
        guard environment == nil, !isPreparing else { return }
        isPreparing = true
        snapshotError = nil
        let folderURL = request.folderURL
        let registry = artifactRegistry
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try BatchRenamePlanningSnapshotService().snapshot(
                    folderURL: folderURL,
                    artifactRegistry: registry
                )
            }.value
            environment = snapshot
            requiresFreshSnapshotAfterFailure = false
            rebuildPlan()
        } catch is CancellationError {
            snapshotError = "Planning was cancelled."
        } catch {
            snapshotError = error.localizedDescription
        }
        isPreparing = false
    }

    func appendComponent(_ kind: BatchRenameEditorComponentKind) {
        editor.components.append(BatchRenameEditorComponent(kind: kind))
    }

    func removeComponent(id: UUID) {
        editor.components.removeAll { $0.id == id }
    }

    func execute() async -> RenameExecutionResult? {
        guard let plan, canExecute else { return nil }
        isExecuting = true
        executionPresentation = nil
        executionGuardError = nil

        do {
            try await executionQuiescence.prepare()
        } catch {
            executionGuardError = Self.executionBarrierMessage(for: error)
            isExecuting = false
            return nil
        }

        let flushOutcome = await DevelopVersionFlushCoordinator.shared.flush(.imageNavigation)
        if case .failed(let message) = flushOutcome {
            executionGuardError = "Named Develop changes could not be saved before rename: \(message)"
            do {
                try await executionQuiescence.complete(.abortedBeforeExecution)
            } catch {
                executionGuardError = [
                    executionGuardError,
                    Self.executionBarrierMessage(for: error),
                ].compactMap { $0 }.joined(separator: " ")
            }
            isExecuting = false
            return nil
        }
        let result = await RenameExecutionService().execute(plan)
        recordExecutionResult(result)
        if result.succeeded {
            let presentation = BatchRenameExecutionPresentation(result: result)
            var reassociation = await RenameReassociationService().reassociate(
                folderURL: request.folderURL,
                mappings: presentation.mappings
            )
            do {
                try await executionQuiescence.complete(.succeeded(presentation.mappings))
            } catch {
                reassociation = RenameReassociationResult(
                    faceReferenceCount: reassociation.faceReferenceCount,
                    analysisCaseCount: reassociation.analysisCaseCount,
                    issues: reassociation.issues + [RenameReassociationIssue(
                        subsystem: .imageAnalysis,
                        detail: Self.executionBarrierMessage(for: error)
                    )]
                )
            }
            reassociationResult = reassociation
        } else {
            do {
                try await executionQuiescence.complete(.executionFailed)
            } catch {
                executionGuardError = Self.executionBarrierMessage(for: error)
            }
        }
        isExecuting = false
        return result
    }

    func refreshSnapshotAfterFailure() async {
        invalidatePlanning(clearPlan: true)
        environment = nil
        snapshotError = nil
        await prepareSnapshot()
    }

    /// Kept separate from filesystem execution so stale-plan invalidation is directly testable.
    func recordExecutionResult(_ result: RenameExecutionResult) {
        executionPresentation = BatchRenameExecutionPresentation(result: result)
        if result.succeeded {
            hasCompletedExecution = true
            return
        }
        requiresFreshSnapshotAfterFailure = true
        invalidatePlanning(clearPlan: true)
        environment = nil
    }

    private func rebuildPlan() {
        guard let environment else {
            invalidatePlanning(clearPlan: true)
            return
        }
        executionPresentation = nil
        executionGuardError = nil
        planningGeneration &+= 1
        let generation = planningGeneration
        planningTask?.cancel()
        isPlanning = true

        let snapshot = BatchRenamePlanningSnapshot(
            items: request.items,
            recipe: editor.recipe,
            collisionPolicy: editor.collisionChoice.policy,
            artifactRegistry: artifactRegistry,
            environment: environment
        )
        let worker = planningWorker
        let debounce = planningDebounce
        planningTask = Task { [weak self] in
            do {
                if debounce > .zero {
                    try await Task.sleep(for: debounce)
                }
                let candidate = try await worker.makePlan(from: snapshot)
                try Task.checkCancellation()
                guard let self, planningGeneration == generation else { return }
                plan = candidate
                isPlanning = false
                planningTask = nil
            } catch {
                guard let self, planningGeneration == generation else { return }
                isPlanning = false
                planningTask = nil
            }
        }
    }

    /// Deterministic synchronization point for tests and non-UI callers. Production UI observes
    /// `isPlanning` and never waits for preview planning on the main actor.
    func waitForPlanning() async {
        while isPlanning {
            let generation = planningGeneration
            let task = planningTask
            await task?.value
            if generation == planningGeneration { return }
        }
    }

    private func invalidatePlanning(clearPlan: Bool) {
        planningGeneration &+= 1
        planningTask?.cancel()
        planningTask = nil
        isPlanning = false
        if clearPlan {
            plan = nil
        }
    }

    private func storeCurrentDraft() {
        if let selectedRecipePresetID {
            presetDrafts[selectedRecipePresetID] = editor
        } else {
            adHocDraft = editor
        }
    }

    private func setEditor(_ editor: BatchRenameEditorState) {
        isSwitchingRecipe = true
        self.editor = editor
        isSwitchingRecipe = false
    }

    private static func executionBarrierMessage(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription.isEmpty
            ? "The rename safety barrier could not complete."
            : error.localizedDescription
    }
}

struct BatchRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: BatchRenameSheetSession
    @State private var recipeLibrary = BatchRenameRecipeLibraryModel()
    @State private var executionTask: Task<Void, Never>?
    @State private var recipeNamePrompt: RecipeNamePrompt?
    @State private var proposedRecipeName = ""
    @State private var confirmsRecipeDelete = false

    private enum RecipeNamePrompt: Equatable {
        case save
        case duplicate
        case rename

        var title: String {
            switch self {
            case .save: "Save Rename Recipe"
            case .duplicate: "Duplicate Rename Recipe"
            case .rename: "Rename Recipe"
            }
        }
    }

    let onSuccess: (BatchRenameExecutionPresentation, RenameReassociationResult) -> Void
    let onFailureOrCancellation: (RenameExecutionResult) -> Void

    init(
        request: BatchRenameSheetRequest,
        executionQuiescence: BatchRenameExecutionQuiescence = .noOp,
        onSuccess: @escaping (BatchRenameExecutionPresentation, RenameReassociationResult) -> Void,
        onFailureOrCancellation: @escaping (RenameExecutionResult) -> Void
    ) {
        _session = State(initialValue: BatchRenameSheetSession(
            request: request,
            executionQuiescence: executionQuiescence
        ))
        self.onSuccess = onSuccess
        self.onFailureOrCancellation = onFailureOrCancellation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                recipeEditor
                    .frame(minWidth: 330, idealWidth: 380, maxWidth: 460)
                preview
                    .frame(minWidth: 560)
            }
            Divider()
            footer
        }
        .frame(minWidth: 940, idealWidth: 1080, minHeight: 640, idealHeight: 760)
        .accessibilityIdentifier("batchRename.workspace")
        .task { await session.prepareSnapshot() }
        .task {
            await recipeLibrary.loadIfNeeded()
            if session.selectedRecipePresetID == nil,
               let persistedSelection = recipeLibrary.selectedPreset {
                // `selectRecipePreset` first records the current ad-hoc draft, so even edits made
                // while the catalog was loading remain available under Ad Hoc.
                session.selectRecipePreset(persistedSelection)
            }
        }
        .onDisappear { executionTask?.cancel() }
        .alert(
            recipeNamePrompt?.title ?? "Rename Recipe",
            isPresented: Binding(
                get: { recipeNamePrompt != nil },
                set: { if !$0 { recipeNamePrompt = nil } }
            )
        ) {
            TextField("Recipe name", text: $proposedRecipeName)
            Button("Cancel", role: .cancel) { recipeNamePrompt = nil }
            Button(recipeNamePrompt == .rename ? "Rename" : "Save") {
                performRecipeNameAction()
            }
            .disabled(proposedRecipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Recipe names are unique. Presets contain filename rules only.")
        }
        .confirmationDialog(
            "Delete \(selectedPreset?.name ?? "this rename recipe")?",
            isPresented: $confirmsRecipeDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) { deleteSelectedRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved preset is removed. Your current editor values remain available as an ad-hoc recipe.")
        }
        .alert("Rename Recipe Error", isPresented: Binding(
            get: { recipeLibrary.errorMessage != nil },
            set: { if !$0 { recipeLibrary.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { recipeLibrary.errorMessage = nil }
        } message: {
            Text(recipeLibrary.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.request.items.count == 1 ? "Rename File" : "Batch Rename")
                    .font(.title2.weight(.semibold))
                Text("\(session.request.items.count) selected \(session.request.items.count == 1 ? "file" : "files") · recipe order follows the visible browser sort")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.isPreparing {
                ProgressView()
                    .controlSize(.small)
                Text("Inspecting paths…")
                    .foregroundStyle(.secondary)
            } else if session.isPlanning {
                ProgressView()
                    .controlSize(.small)
                Text(session.plan == nil ? "Building preview…" : "Updating preview…")
                    .foregroundStyle(.secondary)
            } else if let environment = session.environment {
                Label(
                    environment.caseSensitivity == .caseSensitive ? "Case-sensitive volume" : "Case-insensitive volume",
                    systemImage: "externaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var recipeEditor: some View {
        @Bindable var editableSession = session

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Filename Recipe")
                    .font(.headline)
                Spacer()
                if recipeLibrary.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Picker("Preset", selection: presetSelection) {
                    Text("Ad Hoc").tag(UUID?.none)
                    ForEach(recipeLibrary.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }

                Menu {
                    Button("Save as New…") {
                        proposedRecipeName = ""
                        recipeNamePrompt = .save
                    }
                    Button("Update Saved Recipe") { updateSelectedRecipe() }
                        .disabled(selectedPreset == nil)
                    Button("Duplicate…") {
                        proposedRecipeName = selectedPreset.map { "\($0.name) Copy" } ?? ""
                        recipeNamePrompt = .duplicate
                    }
                    .disabled(selectedPreset == nil)
                    Button("Rename…") {
                        proposedRecipeName = selectedPreset?.name ?? ""
                        recipeNamePrompt = .rename
                    }
                    .disabled(selectedPreset == nil)
                    Divider()
                    Button("Import…", action: importRecipe)
                    Button("Export…", action: exportSelectedRecipe)
                        .disabled(selectedPreset == nil)
                    Divider()
                    Button("Delete…", role: .destructive) {
                        confirmsRecipeDelete = true
                    }
                    .disabled(selectedPreset == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Manage rename recipes")
            }

            if session.hasUnsavedPresetChanges {
                Label("This preset has unsaved edits", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($editableSession.editor.components) { $component in
                        componentRow(component: $component)
                    }
                }
            }

            Menu {
                ForEach(BatchRenameEditorComponentKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { session.appendComponent(kind) }
                }
            } label: {
                Label("Add Component", systemImage: "plus")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Live sample")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.sampleName)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Picker("Name conflicts", selection: $editableSession.editor.collisionChoice) {
                ForEach(BatchRenameCollisionChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }

            Text("The extension is part of the recipe. Add the Extension token when you want to preserve it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
    }

    private func componentRow(component: Binding<BatchRenameEditorComponent>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Picker("Component", selection: component.kind) {
                    ForEach(BatchRenameEditorComponentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                Spacer()
                Button {
                    session.removeComponent(id: component.wrappedValue.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove component")
                .accessibilityLabel(
                    "Remove \(component.wrappedValue.kind.displayName) component"
                )
            }

            switch component.wrappedValue.kind {
            case .literal:
                TextField("Text", text: component.literal)
                    .textFieldStyle(.roundedBorder)
            case .sequence:
                HStack {
                    TextField("Start", value: component.sequenceStart, format: .number)
                    TextField("Step", value: component.sequenceStep, format: .number)
                    TextField("Padding", value: component.sequencePadding, format: .number)
                }
                .textFieldStyle(.roundedBorder)
            case .captureDate:
                TextField("Date format", text: component.dateFormat)
                    .textFieldStyle(.roundedBorder)
                Picker("Fallback", selection: component.captureDateFallback) {
                    Text("None").tag(BatchRenameCaptureDateFallback.none)
                    Text("File creation").tag(BatchRenameCaptureDateFallback.fileCreation)
                    Text("File modification").tag(BatchRenameCaptureDateFallback.fileModification)
                }
            case .fileCreationDate, .fileModificationDate:
                TextField("Date format", text: component.dateFormat)
                    .textFieldStyle(.roundedBorder)
            case .metadata:
                Picker("Field", selection: component.metadataField) {
                    ForEach(BatchRenameMetadataField.allCases, id: \.self) { field in
                        Text(metadataFieldName(field)).tag(field)
                    }
                }
            case .originalFilename, .originalStem, .originalExtension, .jobTitle, .importTitle:
                EmptyView()
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if let plan = session.plan {
                    Text("\(plan.entries.count) rows")
                        .foregroundStyle(.secondary)
                }
                if session.isPlanning, session.plan != nil {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = session.snapshotError {
                ContentUnavailableView(
                    "Could Not Build Preview",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if session.isPreparing || session.plan == nil {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView(
                        session.isPreparing
                            ? "Inspecting current filenames and associated files…"
                            : "Building rename preview…"
                    )
                    Spacer()
                }
                Spacer()
            } else {
                Table(session.previewRows) {
                    TableColumn("Old name", value: \.oldName)
                    TableColumn("Requested", value: \.requestedName)
                    TableColumn("Planned", value: \.plannedName)
                    TableColumn("Status") { row in
                        Text(statusText(row))
                            .foregroundStyle(row.blockingIssueCount > 0 ? .red : (row.warningIssueCount > 0 ? .orange : .secondary))
                    }
                    .width(min: 90, ideal: 120)
                    TableColumn("Issues", value: \.issueText)
                        .width(min: 160, ideal: 260)
                }

                planSummary
            }

            if let error = session.executionGuardError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }

            if let presentation = session.executionPresentation {
                if presentation.status != .succeeded {
                    executionFailure(presentation)
                } else if let result = session.reassociationResult, !result.succeeded {
                    reassociationFailure(result)
                }
            }
        }
        .padding(18)
    }

    private var planSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = session.issueSummary {
                HStack(spacing: 14) {
                    summaryBadge("\(summary.blockingCount) blockers", color: summary.blockingCount > 0 ? .red : .secondary)
                    summaryBadge("\(summary.warningCount) warnings", color: summary.warningCount > 0 ? .orange : .secondary)
                    summaryBadge("\(summary.conflictCount) conflicts", color: .secondary)
                    summaryBadge("\(summary.missingValueCount) missing", color: .secondary)
                    summaryBadge("\(summary.invalidFilenameCount) invalid", color: .secondary)
                    summaryBadge("\(summary.caseWarningCount) case-only", color: .secondary)
                }
            }
            if let artifacts = session.plan?.associatedArtifactSummary, !artifacts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(artifacts, id: \.identifier) { artifact in
                            Text("\(artifact.displayName): \(artifact.presentCount) present, \(artifact.renamedCount) move")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func executionFailure(_ presentation: BatchRenameExecutionPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Label(presentation.headline, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(presentation.recoveryMessage)
                ForEach(presentation.issueDetails, id: \.self) { Text($0).font(.caption.monospaced()) }
                ForEach(presentation.residualDetails, id: \.self) { Text($0).font(.caption.monospaced()) }
                if presentation.canRefreshOriginalRequest {
                    Button("Refresh Preview from Disk") {
                        Task { await session.refreshSnapshotAfterFailure() }
                    }
                    .disabled(session.isPreparing)
                } else {
                    Text("Close this sheet, review the reloaded folder, then select the authoritative files and open Rename again.")
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .padding(10)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reassociationFailure(_ result: RenameReassociationResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Files renamed; some app references need review", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("The folder was reloaded from disk. Close Rename, verify the listed app data, and do not retry this completed plan.")
            ForEach(result.issues, id: \.subsystem) { issue in
                Text("\(issue.subsystem.rawValue): \(issue.detail)")
                    .font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if session.isExecuting {
                ProgressView()
                    .controlSize(.small)
                Text("Moving image bundles safely…")
                    .foregroundStyle(.secondary)
            } else if session.isPlanning {
                ProgressView()
                    .controlSize(.small)
                Text("Updating the rename preview…")
                    .foregroundStyle(.secondary)
            } else if session.hasCompletedExecution {
                Text("Rename completed; this plan cannot be run again")
                    .foregroundStyle(.secondary)
            } else if session.plan?.canExecute == false {
                Label("Resolve blocking preview issues before renaming", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if session.plan?.canExecute == true && !session.canExecute {
                Text("Change the recipe to produce at least one new filename")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(session.isExecuting ? "Cancel Rename" : "Close") {
                if session.isExecuting {
                    executionTask?.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Button("Rename") { startExecution() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canExecute)
        }
        .padding(18)
    }

    private func startExecution() {
        executionTask?.cancel()
        executionTask = Task {
            guard let result = await session.execute() else { return }
            let presentation = BatchRenameExecutionPresentation(result: result)
            if result.succeeded {
                let reassociation = session.reassociationResult ?? .noChanges
                onSuccess(presentation, reassociation)
                if reassociation.succeeded { dismiss() }
            } else {
                onFailureOrCancellation(result)
            }
        }
    }

    private func statusText(_ row: BatchRenamePreviewRow) -> String {
        if row.blockingIssueCount > 0 { return "Blocked (\(row.blockingIssueCount))" }
        if row.warningIssueCount > 0 { return "Warning (\(row.warningIssueCount))" }
        switch row.disposition {
        case .rename: return "Rename"
        case .unchanged: return "Unchanged"
        case .skipped: return "Skipped"
        case .blocked: return "Blocked"
        }
    }

    private func summaryBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
    }

    private var selectedPreset: BatchRenameRecipePreset? {
        guard let id = session.selectedRecipePresetID else { return nil }
        return recipeLibrary.presets.first { $0.id == id }
    }

    private var presetSelection: Binding<UUID?> {
        Binding(
            get: { session.selectedRecipePresetID },
            set: { id in
                guard let id else {
                    session.useAdHocRecipe()
                    return
                }
                Task {
                    if let preset = await recipeLibrary.select(id) {
                        session.selectRecipePreset(preset)
                    }
                }
            }
        )
    }

    private func performRecipeNameAction() {
        let action = recipeNamePrompt
        let name = proposedRecipeName
        recipeNamePrompt = nil
        Task {
            switch action {
            case .save:
                if let preset = await recipeLibrary.create(name: name, from: session.editor) {
                    session.markRecipePresetSaved(preset)
                }
            case .duplicate:
                guard let id = session.selectedRecipePresetID else { return }
                if let preset = await recipeLibrary.duplicate(id: id, name: name) {
                    session.selectRecipePreset(preset)
                }
            case .rename:
                guard let id = session.selectedRecipePresetID else { return }
                if let preset = await recipeLibrary.rename(id: id, to: name) {
                    session.synchronizeRenamedPreset(preset)
                }
            case nil:
                break
            }
        }
    }

    private func updateSelectedRecipe() {
        guard let id = session.selectedRecipePresetID else { return }
        Task {
            if let preset = await recipeLibrary.update(id: id, from: session.editor) {
                session.markRecipePresetSaved(preset)
            }
        }
    }

    private func deleteSelectedRecipe() {
        guard let id = session.selectedRecipePresetID else { return }
        Task {
            if await recipeLibrary.delete(id: id) {
                session.preserveDeletedPresetAsAdHoc(id: id)
            }
        }
    }

    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a versioned rename-recipe JSON file."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            if let preset = await recipeLibrary.importPreset(from: source) {
                session.selectRecipePreset(preset)
            }
        }
    }

    private func exportSelectedRecipe() {
        guard let preset = selectedPreset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(preset.name)).rename-recipe.json"
        panel.message = "Export a portable rename recipe. Existing files are not overwritten."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await recipeLibrary.export(id: preset.id, to: destination) }
    }

    private func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let result = value.components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Rename Recipe" : result
    }

    private func metadataFieldName(_ field: BatchRenameMetadataField) -> String {
        switch field {
        case .title: "Title"
        case .creator: "Creator"
        case .creatorJobTitle: "Creator job title"
        case .jobID: "Job ID"
        case .event: "Event"
        case .city: "City"
        case .country: "Country"
        case .countryCode: "Country code"
        case .cameraMake: "Camera make"
        case .cameraModel: "Camera model"
        case .cameraSerial: "Camera serial"
        case .rating: "Rating"
        case .colorLabel: "Color label"
        }
    }
}
