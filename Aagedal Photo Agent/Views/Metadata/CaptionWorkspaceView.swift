import AppKit
import SwiftUI

private enum CaptionPreviewMode: Hashable {
    case fit
    case actualSize
}

/// A focused, sidecar-first metadata workspace. `MetadataPanel` remains the editor and
/// `MetadataViewModel` remains the only persistence owner; this view only coordinates safe
/// transitions, validation status, and preview state.
struct CaptionWorkspaceView: View {
    @Bindable var metadataViewModel: MetadataViewModel
    @Bindable var browserViewModel: BrowserViewModel
    let settingsViewModel: SettingsViewModel
    let deadlineProfile: DeadlineProfile?
    let initialFocusedField: MetadataFieldID?
    let onApplyTemplate: (Bool?) -> Void
    let onClose: () -> Void

    @State private var session: CaptionSession
    @State private var preview: NSImage?
    @State private var validationReport = MetadataValidationReport(issues: [])
    @State private var errorMessage: String?
    @State private var isCopyingPrevious = false
    @State private var codeReplacementStore: CodeReplacementSettingsStore
    @State private var showingCodeReplacementSettings = false
    @State private var showingCodeReplacementPreview = false
    @State private var pendingCodeReplacement: CaptionCodeReplacementPendingPreview?
    @State private var previewMode: CaptionPreviewMode = .fit
    @State private var showsConfirmedFaces = false
    @State private var confirmedPeople: [CaptionConfirmedPerson] = []
    @State private var requestedFocusedField: MetadataFieldID?
    @State private var pendingWriteAndNextURL: URL?
    @State private var captionAdvanceShortcuts = CaptionAdvanceShortcutRegistry.shared
    @State private var captionShortcutMonitor: Any?
    @State private var activeEditorField: MetadataFieldID?
    @State private var lastEditorField: MetadataFieldID?
    @State private var isEditorTransientPresented = false
    @State private var isAwaitingTemplatePalette = false
    @FocusState private var focusedAction: CaptionActionFocus?
    @Environment(\.openSettings) private var openSettings
    @Environment(AppCommandRouter.self) private var commandRouter

    private var visibleImages: [ImageFile] {
        browserViewModel.visibleImages.filter(\.isImageFile)
    }

    private var visibleURLs: [URL] { visibleImages.map(\.url) }

    private var currentImage: ImageFile? {
        guard let currentURL = session.currentURL else { return nil }
        return visibleImages.first { $0.url.standardizedFileURL == currentURL }
    }

    private var validationProfile: MetadataValidationProfile {
        if case let .snapshot(profile) = deadlineProfile?.validationProfile {
            return profile
        }
        return MetadataValidationProfile.currentRequirements(
            levels: MetadataRequirements.load(),
            minimumLengths: MetadataRequirements.loadMinimumLengths()
        )
    }

    private var fieldLayout: CaptionWorkspaceFieldLayout {
        if let configuration = deadlineProfile?.captionFields {
            return CaptionWorkspaceFieldLayout.make(configuration: configuration)
        }
        return CaptionWorkspaceFieldLayout.make(
            configuration: DeadlineCaptionFieldConfiguration(
                orderedFieldIDs: settingsViewModel.orderedIPTCMetadataFields,
                visibleFieldIDs: settingsViewModel.visibleIPTCMetadataFieldsInOrder
            ),
            groupsSecondaryFields: false
        )
    }

    init(
        metadataViewModel: MetadataViewModel,
        browserViewModel: BrowserViewModel,
        settingsViewModel: SettingsViewModel,
        deadlineProfile: DeadlineProfile? = nil,
        initialFocusedField: MetadataFieldID? = nil,
        onApplyTemplate: @escaping (Bool?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.metadataViewModel = metadataViewModel
        self.browserViewModel = browserViewModel
        self.settingsViewModel = settingsViewModel
        self.deadlineProfile = deadlineProfile
        self.initialFocusedField = initialFocusedField
        self.onApplyTemplate = onApplyTemplate
        self.onClose = onClose

        let images = browserViewModel.visibleImages.filter(\.isImageFile)
        let urls = images.map(\.url)
        let selected = browserViewModel.selectedImageIDs
        let focused = browserViewModel.lastClickedImageURL
            .flatMap { selected.contains($0) ? $0 : nil }
            ?? selected.first
            ?? urls.first
        _session = State(initialValue: CaptionSession(
            imageURLs: urls,
            currentURL: focused,
            selectedURLs: Set(focused.map { [$0] } ?? [])
        ))
        _codeReplacementStore = State(initialValue: CodeReplacementSettingsStore())
        _requestedFocusedField = State(initialValue: initialFocusedField)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()

            if session.currentURL == nil {
                ContentUnavailableView(
                    "No Photos to Caption",
                    systemImage: "text.below.photo",
                    description: Text("Open a folder or adjust the current filters.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    previewColumn
                        .frame(minWidth: 360, idealWidth: 720, maxWidth: .infinity)

                    VStack(spacing: 0) {
                        CaptionPriorityFieldNavigator(
                            layout: fieldLayout,
                            metadata: metadataViewModel.editingMetadata,
                            validationProfile: validationProfile,
                            report: validationReport,
                            onFocus: requestFocus
                        )
                        Divider()
                        MetadataPanel(
                            viewModel: metadataViewModel,
                            browserViewModel: browserViewModel,
                            settingsViewModel: settingsViewModel,
                            initialFocusedField: requestedFocusedField,
                            onApplyTemplate: { applyTemplateAfterFlush(append: nil) },
                            onSaveTemplate: nil,
                            onPendingStatusChanged: browserViewModel.refreshPendingStatus,
                            commitsToHistorySidecarOnly: true,
                            captionFlushCoordinator: .shared,
                            onFocusedFieldChanged: { field in
                                activeEditorField = field
                                if let field {
                                    lastEditorField = field
                                    focusedAction = nil
                                }
                            },
                            onAutocompletePresentationChanged: { isPresented in
                                isEditorTransientPresented = isPresented
                            },
                            onTabTraversalRequested: { field, reverse in
                                moveCaptionFocus(from: field, reverse: reverse)
                            }
                        )
                        Divider()
                        HStack(spacing: 8) {
                            Text("Additional IPTC fields can be enabled in Settings → Metadata.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Metadata Settings…") {
                                settingsViewModel.requestedDestination = .metadata
                                openSettings()
                            }
                            .controlSize(.small)
                            .accessibilityHint("Open Settings at the Metadata field controls")
                            .accessibilityIdentifier("caption.metadataSettings")
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                    }
                    .frame(minWidth: 340, idealWidth: 430, maxWidth: 560)
                }
            }

            Divider()
            actionBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("caption.workspace")
        .onAppear {
            synchronizeSessionWithBrowser()
            updateReadiness()
            installCaptionShortcutMonitor()
        }
        .onDisappear { removeCaptionShortcutMonitor() }
        .onChange(of: visibleURLs) { _, _ in
            synchronizeSessionWithBrowser()
        }
        .onChange(of: focusedAction) { _, action in
            if action != nil { activeEditorField = nil }
        }
        .onChange(of: metadataViewModel.editingMetadata) { _, _ in
            // Async selection loads assign the draft while `isLoading` is still true. Ignore that
            // persisted state, but do record edits even when an already-pending sidecar means the
            // view model's `hasChanges` Boolean was true before the user typed.
            if !metadataViewModel.isLoading,
               metadataViewModel.selectedURLs.first?.standardizedFileURL == session.currentURL {
                session.markCurrentDirty()
            }
            updateReadiness()
        }
        .onChange(of: metadataViewModel.metadataLoadGeneration) { _, _ in
            updateReadiness()
        }
        .onChange(of: metadataViewModel.isSaving) { wasSaving, isSaving in
            guard wasSaving, !isSaving else { return }
            browserViewModel.refreshPendingStatus()
            if let saveError = metadataViewModel.saveError {
                errorMessage = saveError
            }
            completeWriteAndNextIfPossible()
        }
        .onChange(of: metadataViewModel.saveError) { _, saveError in
            if let saveError { errorMessage = saveError }
        }
        .onChange(of: commandRouter.latestDelivery) { _, delivery in
            guard let delivery else { return }
            switch delivery.command {
            case .selectPreviousImage:
                navigate(previous: true)
            case .selectNextImage:
                navigate(previous: false)
            case .openFolder, .openRecentFolder, .setRating, .setLabel,
                 .renderSelected, .advancedExportSelected, .renderAll,
                 .saveAsJPEG, .saveAsPNG, .archiveRAW,
                 .rotateClockwise, .rotateCounterclockwise,
                 .renameSelected, .duplicateSelected,
                 .resetAllEdits, .removeAllIPTC,
                 .showImport, .backupEditedFiles, .backupEditedFilesForFolder,
                 .openInInternalEditor, .openInExternalEditor,
                 .deleteSelected, .moveRejectedToFolder,
                 .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
                 .setScopeMode, .toggleGamutClipping,
                 .uploadSelected, .uploadAll:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreCaptionEditorFocus)) { _ in
            isAwaitingTemplatePalette = false
            restoreLastEditorFocus()
        }
        .sheet(
            isPresented: $showingCodeReplacementSettings,
            onDismiss: restoreLastEditorFocus
        ) {
            CodeReplacementSettingsView(store: codeReplacementStore)
        }
        .sheet(
            isPresented: $showingCodeReplacementPreview,
            onDismiss: restoreLastEditorFocus
        ) {
            if let pendingCodeReplacement {
                CodeReplacementApplyPreviewView(result: pendingCodeReplacement.result) {
                    applyPendingCodeReplacement()
                }
            }
        }
        .alert("Caption Workspace", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The transition was cancelled.")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.below.photo")
                .foregroundStyle(.secondary)

            Text(session.currentURL?.lastPathComponent ?? "Caption Workspace")
                .font(.headline)
                .lineLimit(1)
                .help(session.currentURL?.lastPathComponent ?? "")

            if let position = session.position {
                Text("\(position) of \(session.count)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let image = currentImage {
                Label("\(image.starRating.rawValue)", systemImage: "star.fill")
                    .foregroundStyle(image.starRating == .none ? Color.secondary : Color.yellow)
                    .help("Rating: \(image.starRating.rawValue) of 5")

                if let color = image.colorLabel.color {
                    Circle()
                        .fill(color)
                        .frame(width: 11, height: 11)
                        .help("Label: \(image.colorLabel.displayName)")
                        .accessibilityLabel("Color label: \(image.colorLabel.displayName)")
                }
            }

            if metadataViewModel.hasChanges || currentImage?.hasPendingMetadataChanges == true {
                Label("Pending", systemImage: "circle.dotted")
                    .foregroundStyle(.orange)
                    .help("Changes are saved non-destructively and are pending an explicit write.")
            }

            readinessBadge
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }

    private var readinessBadge: some View {
        let readiness = session.currentReadiness ?? .warnings
        let title: String
        let icon: String
        let color: Color
        switch readiness {
        case .ready:
            title = "Ready"
            icon = "checkmark.circle.fill"
            color = .green
        case .warnings:
            title = "Warnings"
            icon = "exclamationmark.triangle.fill"
            color = .orange
        case .blocked:
            title = "Blocked"
            icon = "xmark.octagon.fill"
            color = .red
        }
        let summary = validationReport.issues.isEmpty
            ? "No validation issues"
            : "\(validationReport.blockerCount) blockers, \(validationReport.warningCount) warnings"
        return Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .help(summary)
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Picker("Preview size", selection: Binding(
                        get: { previewMode },
                        set: { value in preservingEditorFocus { previewMode = value } }
                    )) {
                        Text("Fit").tag(CaptionPreviewMode.fit)
                        Text("100%").tag(CaptionPreviewMode.actualSize)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)

                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        preservingEditorFocus {
                            browserViewModel.isFullScreen = true
                        }
                    }
                    .disabled(currentImage == nil)

                    Toggle("Faces", systemImage: "face.smiling", isOn: Binding(
                        get: { showsConfirmedFaces },
                        set: { value in preservingEditorFocus { showsConfirmedFaces = value } }
                    ))
                    .toggleStyle(.button)
                    .disabled(confirmedPeople.isEmpty)
                    .help("Show only confirmed, named faces with valid geometry")

                    Spacer()

                    if !confirmedPeople.isEmpty {
                        Text(confirmedPeople.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Confirmed people, ordered left to right")
                            .accessibilityLabel("Confirmed people left to right")
                            .accessibilityValue(confirmedPeople.map(\.name).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 38)

                CaptionEditedPreview(
                    image: preview,
                    mode: previewMode,
                    confirmedPeople: showsConfirmedFaces ? confirmedPeople : []
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: session.currentURL) {
                await loadCurrentPreview()
            }

            Divider()
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(visibleImages) { image in
                        CaptionFilmstripItem(
                            image: image,
                            thumbnailService: browserViewModel.thumbnailService,
                            isSelected: session.currentURL == image.url.standardizedFileURL
                        ) {
                            select(image.url)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.visible)
            .frame(height: 92)
        }
    }

    private var actionBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Button("Previous", systemImage: "chevron.left") {
                    navigate(previous: true)
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!session.canGoPrevious || session.isTransitioning)
                .focused($focusedAction, equals: .previous)

                Button("Save & Next", systemImage: "chevron.right") {
                    navigate(previous: false, announcesAdvance: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canGoNext || session.isTransitioning)
                .help(shortcutHelp(for: .saveAndNext))
                .focused($focusedAction, equals: .saveAndNext)

                Button("Write & Next", systemImage: "square.and.arrow.down") {
                    writeAndNext()
                }
                .disabled(
                    !session.canGoNext
                        || metadataViewModel.isSaving
                        || session.isTransitioning
                )
                .help("Durably flush, write the current photo, then advance only after the write succeeds. \(shortcutHelp(for: .writeAndNext))")
                .focused($focusedAction, equals: .writeAndNext)

                Divider().frame(height: 20)

                Menu("Apply Template", systemImage: "wand.and.stars") {
                    Button("Replace…") { applyTemplateAfterFlush(append: false) }
                    Button("Append…") { applyTemplateAfterFlush(append: true) }
                }
                .disabled(session.currentURL == nil || session.isTransitioning)
                .focused($focusedAction, equals: .applyTemplate)

                Menu("Copy Previous", systemImage: "doc.on.doc") {
                    Button("Replace Caption Fields") { copyPrevious(mode: .replace) }
                    Button("Append Caption Fields") { copyPrevious(mode: .append) }
                }
                .disabled(
                    session.previousURL == nil
                        || session.isTransitioning
                        || isCopyingPrevious
                        || metadataViewModel.isLoading
                )
                .help("Copy caption, headline, people, and keywords from the previous photo. Capture-specific metadata is always protected.")
                .focused($focusedAction, equals: .copyPrevious)

                Button("Fix Next", systemImage: "wrench.and.screwdriver") {
                    focusNextValidationIssue()
                }
                .disabled(validationReport.issues.isEmpty || session.isTransitioning)
                .focused($focusedAction, equals: .fixNext)

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Write Current") { writeCurrent() }
                        .disabled(metadataViewModel.isSaving || session.currentURL == nil)
                    Button("Preview Code Replacement…") { prepareCodeReplacementPreview() }
                        .disabled(
                            !codeReplacementStore.configuration.isEnabled
                                || codeReplacementStore.configuration.source == nil
                                || session.currentURL == nil
                                || metadataViewModel.isLoading
                        )
                    Button("Code Replacement Settings…") {
                        showingCodeReplacementSettings = true
                    }
                }
                .focused($focusedAction, equals: .more)

                Spacer(minLength: 12)

                Button("Close") {
                    closeAfterFlush()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(session.isTransitioning)
                .focused($focusedAction, equals: .close)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .scrollIndicators(.hidden)
    }

    private func synchronizeSessionWithBrowser() {
        session.replaceImages(visibleURLs)
        guard let currentURL = session.currentURL else { return }
        let browserURL = originalBrowserURL(for: currentURL)
        if browserViewModel.selectedImageIDs != [browserURL] {
            browserViewModel.selectedImageIDs = [browserURL]
            browserViewModel.lastClickedImageURL = browserURL
        }
    }

    private func flushCurrentDraftDurably() throws {
        try CaptionWorkspaceFlushCoordinator.shared.flush()
        session.markCommitted()
    }

    private func enqueueCurrentDraftPersistence() throws {
        try CaptionWorkspaceFlushCoordinator.shared.enqueueFlush()
        session.markCommitted()
    }

    private func navigate(previous: Bool, announcesAdvance: Bool = false) {
        Task { @MainActor in
            do {
                let moved = if previous {
                    try await session.goPrevious { try enqueueCurrentDraftPersistence() }
                } else {
                    try await session.goNext { try enqueueCurrentDraftPersistence() }
                }
                if moved {
                    publishSessionSelection()
                    if announcesAdvance {
                        AccessibilityAnnouncementCenter.post(.success(.captionSavedAndAdvanced))
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func select(_ url: URL) {
        Task { @MainActor in
            do {
                let changed = try await session.select([url], focusedURL: url) {
                    try enqueueCurrentDraftPersistence()
                }
                if changed { publishSessionSelection() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func publishSessionSelection() {
        guard let url = session.currentURL else { return }
        let browserURL = originalBrowserURL(for: url)
        browserViewModel.selectedImageIDs = [browserURL]
        browserViewModel.lastClickedImageURL = browserURL
    }

    private func originalBrowserURL(for sessionURL: URL) -> URL {
        visibleImages.first { $0.url.standardizedFileURL == sessionURL }?.url ?? sessionURL
    }

    private func applyTemplateAfterFlush(append: Bool?) {
        Task { @MainActor in
            do {
                try await session.prepare(for: .applyTemplate) { try flushCurrentDraftDurably() }
                isAwaitingTemplatePalette = true
                onApplyTemplate(append)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyPrevious(mode: CaptionCopyPreviousMergeMode) {
        Task { @MainActor in
            guard !isCopyingPrevious else { return }
            isCopyingPrevious = true
            defer { isCopyingPrevious = false }

            do {
                try await session.prepare(for: .copyPrevious) { try flushCurrentDraftDurably() }
                guard let previousURL = session.previousURL else {
                    errorMessage = "There is no previous photo in the current order."
                    return
                }
                guard let loadToken = session.beginLoad() else { return }
                let sourceURL = originalBrowserURL(for: previousURL)
                let previous = try await metadataViewModel.loadCaptionCopyPreviousMetadata(for: sourceURL)
                guard !Task.isCancelled, session.accepts(load: loadToken) else { return }

                let configuration = CaptionCopyPreviousConfiguration(defaultMode: mode)
                let result = CaptionCopyPreviousService().copy(
                    previous: previous,
                    current: metadataViewModel.editingMetadata,
                    configuration: configuration
                )
                guard result.status == .completed, let updated = result.metadata else {
                    errorMessage = "The previous photo's metadata could not be copied."
                    return
                }
                guard result.changed else { return }

                // Keep the same session focus. The next save/navigation crosses the usual
                // sidecar-first flush path, which records this draft and its history normally.
                metadataViewModel.editingMetadata = updated
                metadataViewModel.hasChanges = true
                session.markCurrentDirty()
                updateReadiness()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareCodeReplacementPreview() {
        Task { @MainActor in
            do {
                guard codeReplacementStore.sourceLoadError == nil else {
                    errorMessage = codeReplacementStore.sourceLoadError
                    return
                }

                // A marked range must not be read into the model or persisted. Query the actual
                // AppKit field editor before crossing the normal flush barrier; once committed,
                // the explicit command is safely post-flush and no longer depends on UI buffers.
                let composition = try CaptionWorkspaceFlushCoordinator.shared.editorCompositionState()
                guard composition == .committed else {
                    errorMessage = "Finish the active text composition before applying code replacement."
                    return
                }

                try await session.prepare(for: .codeReplacement) { try flushCurrentDraftDurably() }
                guard let previewURL = session.currentURL else {
                    errorMessage = "The current photo is no longer available."
                    return
                }
                let inputMetadata = metadataViewModel.editingMetadata
                let result = CaptionCodeReplacementCoordinator().plan(
                    metadata: inputMetadata,
                    list: codeReplacementStore.list,
                    configuration: codeReplacementStore.configuration,
                    compositionState: composition
                )
                switch result.status {
                case .completed:
                    pendingCodeReplacement = CaptionCodeReplacementPendingPreview(
                        imageURL: previewURL,
                        inputMetadata: inputMetadata,
                        result: result
                    )
                    showingCodeReplacementPreview = true
                case .unchanged:
                    errorMessage = "No matching code-replacement tokens were found in the caption fields."
                case .disabled:
                    errorMessage = "Code replacement is disabled."
                case .activeComposition:
                    errorMessage = "Finish the active text composition before applying code replacement."
                case .invalidConfiguration:
                    errorMessage = "Both code-replacement delimiters must be nonempty."
                case .invalidSource:
                    errorMessage = "Resolve the code-replacement source errors before applying."
                case .ambiguousOccurrence:
                    errorMessage = "An ambiguous code occurs in the caption fields. Resolve the conflicting source definitions first."
                case .unrepresentableCode:
                    errorMessage = "A code containing a configured delimiter occurs in the caption fields and cannot be expanded safely."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyPendingCodeReplacement() {
        guard let pendingCodeReplacement else { return }
        guard let updated = pendingCodeReplacement.validatedMetadata(
            currentURL: session.currentURL,
            currentMetadata: metadataViewModel.editingMetadata
        ) else {
            self.pendingCodeReplacement = nil
            showingCodeReplacementPreview = false
            errorMessage = "The current photo or caption changed after this preview was created. Preview code replacement again."
            return
        }
        metadataViewModel.editingMetadata = updated
        metadataViewModel.markChanged()
        session.markCurrentDirty()
        self.pendingCodeReplacement = nil
        showingCodeReplacementPreview = false
        updateReadiness()
    }

    private func writeCurrent() {
        Task { @MainActor in
            do {
                try await session.prepare(for: .write) { try flushCurrentDraftDurably() }
                metadataViewModel.writeMetadataAndClearSidecar()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func writeAndNext() {
        Task { @MainActor in
            do {
                try await session.prepare(for: .write) { try flushCurrentDraftDurably() }
                guard let currentURL = session.currentURL else { return }
                pendingWriteAndNextURL = currentURL
                metadataViewModel.writeMetadataAndClearSidecar()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func completeWriteAndNextIfPossible() {
        guard let pendingURL = pendingWriteAndNextURL else { return }
        pendingWriteAndNextURL = nil
        guard CaptionWriteAndNextGate.shouldAdvance(
            pendingURL: pendingURL,
            currentURL: session.currentURL,
            writeSucceeded: metadataViewModel.saveError == nil
        ) else { return }
        Task { @MainActor in
            do {
                let moved = try await session.goNext(flush: {})
                if moved {
                    publishSessionSelection()
                    AccessibilityAnnouncementCenter.post(.success(.captionWroteAndAdvanced))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func focusNextValidationIssue() {
        guard let issue = validationReport.nextBlockingIssue ?? validationReport.issues.first else { return }
        requestFocus(issue.field)
    }

    private func requestFocus(_ field: MetadataFieldID) {
        focusedAction = nil
        requestedFocusedField = nil
        DispatchQueue.main.async {
            requestedFocusedField = field
        }
    }

    private func restoreLastEditorFocus() {
        guard let lastEditorField else { return }
        requestFocus(lastEditorField)
    }

    private func preservingEditorFocus(_ action: () -> Void) {
        let window = NSApp.keyWindow
        let responder = window?.firstResponder
        action()
        DispatchQueue.main.async {
            guard let window, let responder else { return }
            window.makeFirstResponder(responder)
        }
    }

    private func shortcutHelp(for command: CaptionAdvanceShortcutCommand) -> String {
        captionAdvanceShortcuts.chord(for: command).map { "Shortcut: \($0.displayName)" }
            ?? "No shortcut assigned"
    }

    private func installCaptionShortcutMonitor() {
        guard captionShortcutMonitor == nil else { return }
        captionShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let inputState = keyboardTextInputState(in: event.window)
            let modifiers = KeyboardShortcutModifiers(event.modifierFlags)
            if event.keyCode == 48,
               modifiers.subtracting(.shift).isEmpty,
               !inputState.imeHasMarkedText,
               !isEditorTransientPresented,
               !showingCodeReplacementSettings,
               !showingCodeReplacementPreview,
               !isAwaitingTemplatePalette {
                moveCaptionFocus(reverse: modifiers.contains(.shift))
                return nil
            }
            guard let key = event.charactersIgnoringModifiers,
                  let command = CaptionAdvanceShortcutRouter.resolve(
                    KeyboardShortcutRouteInput(
                        key: key,
                        modifiers: KeyboardShortcutModifiers(event.modifierFlags),
                        textEditorOwnsInput: inputState.textEditorOwnsInput,
                        imeHasMarkedText: inputState.imeHasMarkedText,
                        isRepeat: event.isARepeat
                    ),
                    bindings: captionAdvanceShortcuts.bindings
                  ) else { return event }
            switch command {
            case .saveAndNext:
                guard session.canGoNext, !session.isTransitioning else { return nil }
                navigate(previous: false, announcesAdvance: true)
            case .writeAndNext:
                guard session.canGoNext,
                      !session.isTransitioning,
                      !metadataViewModel.isSaving else { return nil }
                writeAndNext()
            }
            return nil
        }
    }

    private func moveCaptionFocus(from field: MetadataFieldID? = nil, reverse: Bool) {
        let order = CaptionKeyboardOrder(priorityFields: fieldLayout.priority)
        let current = field.map(CaptionKeyboardSurface.priorityField)
            ?? activeEditorField.map(CaptionKeyboardSurface.priorityField)
            ?? focusedAction.map(CaptionKeyboardSurface.action)
        var candidate = order.adjacent(to: current, reverse: reverse)
        var inspected = 0
        while let surface = candidate, inspected < order.surfaces.count {
            if case let .action(action) = surface, !isActionAvailable(action) {
                candidate = order.adjacent(to: surface, reverse: reverse)
                inspected += 1
                continue
            }
            switch surface {
            case let .priorityField(field): requestFocus(field)
            case let .action(action):
                activeEditorField = nil
                focusedAction = action
            }
            return
        }
    }

    private func isActionAvailable(_ action: CaptionActionFocus) -> Bool {
        switch action {
        case .previous: session.canGoPrevious && !session.isTransitioning
        case .saveAndNext: session.canGoNext && !session.isTransitioning
        case .writeAndNext:
            session.canGoNext && !session.isTransitioning && !metadataViewModel.isSaving
        case .applyTemplate: session.currentURL != nil && !session.isTransitioning
        case .copyPrevious:
            session.previousURL != nil && !session.isTransitioning && !isCopyingPrevious
        case .fixNext: !validationReport.issues.isEmpty && !session.isTransitioning
        case .more, .close: !session.isTransitioning
        }
    }

    private func removeCaptionShortcutMonitor() {
        guard let captionShortcutMonitor else { return }
        NSEvent.removeMonitor(captionShortcutMonitor)
        self.captionShortcutMonitor = nil
    }

    private func closeAfterFlush() {
        Task { @MainActor in
            do {
                try await session.prepare(for: .workspaceExit) { try flushCurrentDraftDurably() }
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateReadiness() {
        guard let url = session.currentURL else {
            validationReport = MetadataValidationReport(issues: [])
            return
        }
        let report = MetadataValidationEngine().validate(
            metadataViewModel.editingMetadata,
            imageURL: url,
            profile: validationProfile
        )
        validationReport = report
        session.setReadiness(CaptionReadinessResolver.readiness(for: report), for: url)
    }

    private func loadCurrentPreview() async {
        preview = nil
        confirmedPeople = []
        guard let token = session.beginLoad() else { return }
        let image = currentImage
        let settings = metadataViewModel.editingMetadata.cameraRaw
        let orientation = image?.exifOrientation ?? 1
        let cgImage = await FullScreenImageCache.decodedEditedPreview(
            for: token.imageURL,
            settings: settings,
            orientation: orientation,
            screenMaxPx: 3_840
        )
        let loaded: NSImage?
        if let cgImage {
            loaded = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } else {
            loaded = await browserViewModel.thumbnailService.loadThumbnail(for: token.imageURL)
        }
        let folderURL = token.imageURL.deletingLastPathComponent()
        let people = await Task.detached(priority: .utility) {
            CaptionConfirmedPersonOrdering.people(
                for: token.imageURL,
                in: FaceDataStorageService().loadFaceData(for: folderURL)
            )
        }.value
        guard !Task.isCancelled, session.accepts(load: token) else { return }
        preview = loaded
        confirmedPeople = people
    }
}

private struct CaptionEditedPreview: View {
    let image: NSImage?
    let mode: CaptionPreviewMode
    let confirmedPeople: [CaptionConfirmedPerson]

    var body: some View {
        ZStack {
            Color.black
            if let image {
                switch mode {
                case .fit:
                    GeometryReader { geometry in
                        let container = CGSize(
                            width: max(0, geometry.size.width - 24),
                            height: max(0, geometry.size.height - 24)
                        )
                        let fitted = CaptionPreviewGeometry.fittedImageRect(
                            imageSize: image.size,
                            containerSize: container
                        ).offsetBy(dx: 12, dy: 12)
                        ZStack(alignment: .topLeading) {
                            Color.black
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: fitted.midX, y: fitted.midY)
                            faceOverlays(in: fitted)
                        }
                    }
                case .actualSize:
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: image.size.width, height: image.size.height)
                            faceOverlays(in: CGRect(origin: .zero, size: image.size))
                        }
                        .frame(width: image.size.width, height: image.size.height)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edited color-managed caption preview")
        .accessibilityIdentifier("caption.editedPreview")
    }

    @ViewBuilder
    private func faceOverlays(in imageRect: CGRect) -> some View {
        ForEach(confirmedPeople) { person in
            let rect = CaptionPreviewGeometry.displayRect(
                forVisionRect: person.normalizedFaceRect,
                in: imageRect
            )
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                Text(person.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.yellow)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityLabel("Confirmed person: \(person.name)")
        }
    }
}

private struct CaptionPriorityFieldNavigator: View {
    let layout: CaptionWorkspaceFieldLayout
    let metadata: IPTCMetadata
    let validationProfile: MetadataValidationProfile
    let report: MetadataValidationReport
    let onFocus: (MetadataFieldID) -> Void
    @State private var showsAllFields = false

    private var summary: CaptionWorkspaceChecklistSummary {
        CaptionWorkspaceChecklistSummary.make(
            report: report,
            actionableFields: Set(layout.priority + layout.secondary)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Metadata checks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label(readinessTitle, systemImage: readinessIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(readinessColor)
                Text(countSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            nextIssueRow

            DisclosureGroup("All metadata fields", isExpanded: $showsAllFields) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(layout.priority, id: \.self) { field in
                                fieldRow(field)
                            }
                        }
                    }
                    .frame(maxHeight: 160)

                    if !layout.secondary.isEmpty {
                        DisclosureGroup("Secondary & Technical") {
                            ScrollView(.horizontal) {
                                HStack(spacing: 6) {
                                    ForEach(layout.secondary, id: \.self) { field in
                                        Button(field.displayName) { onFocus(field) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                        .font(.caption)
                    }
                }
            }
            .font(.caption)
            .accessibilityIdentifier("caption.metadataChecklist.disclosure")
        }
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .accessibilityIdentifier("caption.metadataChecklist")
    }

    @ViewBuilder
    private var nextIssueRow: some View {
        if let issue = summary.nextIssue {
            Button {
                onFocus(issue.field)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(color(for: issue.severity))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Next: \(issue.field.displayName)")
                            .font(.caption.weight(.semibold))
                        Text(issue.message)
                            .font(.caption2)
                            .foregroundStyle(color(for: issue.severity))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Fix")
                        .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next metadata issue, \(issue.field.displayName): \(issue.message)")
            .accessibilityHint("Move editor focus to this field")
            .accessibilityIdentifier("caption.metadataChecklist.nextIssue")
        } else if summary.blockerCount + summary.warningCount + summary.informationCount > 0 {
            Label("No visible issue to fix", systemImage: "eye.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Validation issues remain in fields hidden from this layout.")
                .accessibilityIdentifier("caption.metadataChecklist.noActionableIssue")
        } else {
            Label("No validation issues", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Ready. No validation issues.")
                .accessibilityIdentifier("caption.metadataChecklist.ready")
        }
    }

    private var readinessTitle: String {
        switch summary.readiness {
        case .ready: "Ready"
        case .warnings: "Warnings"
        case .blocked: "Blocked"
        }
    }

    private var readinessIcon: String {
        switch summary.readiness {
        case .ready: "checkmark.circle.fill"
        case .warnings: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private var readinessColor: Color {
        switch summary.readiness {
        case .ready: .green
        case .warnings: .orange
        case .blocked: .red
        }
    }

    private var countSummary: String {
        var parts: [String] = []
        if summary.blockerCount > 0 {
            parts.append("\(summary.blockerCount) blocker\(summary.blockerCount == 1 ? "" : "s")")
        }
        if summary.warningCount > 0 {
            parts.append("\(summary.warningCount) warning\(summary.warningCount == 1 ? "" : "s")")
        }
        if summary.informationCount > 0 {
            parts.append("\(summary.informationCount) info")
        }
        return parts.isEmpty ? "No issues" : parts.joined(separator: " · ")
    }

    private func color(for severity: MetadataValidationSeverity) -> Color {
        switch severity {
        case .information: .secondary
        case .warning: .orange
        case .blocker: .red
        }
    }

    private func fieldRow(_ field: MetadataFieldID) -> some View {
        let issues = CaptionWorkspaceValidationSummary.issues(for: field, in: report)
        let count = CaptionWorkspaceValidationSummary.characterCount(
            for: field,
            metadata: metadata
        )
        let limit = CaptionWorkspaceValidationSummary.maximumCharacterCount(
            for: field,
            profile: validationProfile
        )
        return Button {
            onFocus(field)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: issues.isEmpty ? "circle" : "exclamationmark.circle.fill")
                    .foregroundStyle(issues.isEmpty ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.displayName)
                    if let issue = issues.first {
                        Text(issue.message)
                            .font(.caption2)
                            .foregroundStyle(issue.severity == .blocker ? Color.red : Color.orange)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if field == .headline || field == .description {
                    Text(limit.map { "\(count)/\($0)" } ?? "\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(limit.map { count > $0 } == true ? Color.red : Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Move editor focus to this field")
    }
}

private struct CaptionFilmstripItem: View {
    let image: ImageFile
    let thumbnailService: ThumbnailService
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Color.black
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 86, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .help(image.filename)
        .accessibilityLabel(image.filename)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Select this photo for caption editing")
        .task(id: image.url) {
            if let cached = thumbnailService.thumbnail(for: image.url) {
                thumbnail = cached
            } else {
                thumbnail = await thumbnailService.loadThumbnail(for: image.url)
            }
        }
    }
}
