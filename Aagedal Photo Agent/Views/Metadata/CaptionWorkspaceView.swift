import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    /// Photo-only browser list, refreshed when the browser's visible items change.
    @State private var photoList: CaptionPhotoList
    /// Transient, non-blocking feedback (for example "nothing to copy").
    @State private var inlineNotice: String?
    @State private var voiceMemoBadgeRefreshToken: UInt64 = 0
    @State private var preview: NSImage?
    @State private var previewFailed = false
    @State private var validationReport = MetadataValidationReport(issues: [])
    @State private var errorMessage: String?
    @State private var isWorkspaceActive = false
    @State private var workspaceLifetimeID: UUID?
    @State private var conflictOperationID: UUID?
    @State private var conflictReviewRequestID: UUID?
    @State private var flushCoordinator = CaptionWorkspaceFlushCoordinator.shared
    @State private var conflictReview: CaptionConflictSnapshot?
    @State private var reviewedFailure: CaptionQueueFailure?
    @State private var conflictExportReceipt: CaptionConflictExportReceipt?
    @State private var conflictCheckpoint: CaptionConflictEditorCheckpoint?
    @State private var conflictImage: ImageFile?
    @State private var pendingReviewPhoto: URL?
    @State private var isConflictRecoveryBusy = false
    @State private var conflictRecoveryError: String?
    @State private var conflictRecoveryNotice: String?
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
    @State private var captionKeyboardWindow = WorkspaceEventWindowReference()
    @State private var activeEditorField: MetadataFieldID?
    @State private var lastEditorField: MetadataFieldID?
    @State private var isEditorTransientPresented = false
    @State private var isAwaitingTemplatePalette = false
    @State private var isAwaitingEditorLoad = false
    @State private var restoresEditorFocusAfterTransition = false
    @State private var resynchronizesListAfterTransition = false
    @FocusState private var focusedAction: CaptionActionFocus?
    @Environment(\.openSettings) private var openSettings
    @Environment(AppCommandRouter.self) private var commandRouter

    private var visibleImages: [ImageFile] { photoList.images }

    private var visibleURLs: [URL] { photoList.urls }

    private var currentImage: ImageFile? {
        guard let currentURL = session.currentURL else { return nil }
        return photoList.image(forStandardizedURL: currentURL)
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

        let photoList = CaptionPhotoList(browserImages: browserViewModel.visibleImages)
        let urls = photoList.urls
        _photoList = State(initialValue: photoList)
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
            if let failure = flushCoordinator.failure { queuedFailureBanner(failure) }
            if let inlineNotice {
                Text(inlineNotice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("caption.inlineNotice")
                    .task(id: inlineNotice) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        self.inlineNotice = nil
                    }
            }
            if let conflictRecoveryNotice {
                Text(conflictRecoveryNotice)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("caption.conflictRecovery.notice")
            }
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
                            if let deadlineProfile {
                                Text("Fields come from the “\(deadlineProfile.name)” Deadline profile.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            } else {
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
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                    }
                    .frame(minWidth: 340, idealWidth: 430, maxWidth: 560)
                    .disabled(isCurrentPhotoUnderReview || isEditorTransitioning)
                }
            }

            Divider()
            actionBar
                .disabled(isEditorTransitioning)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WorkspaceEventWindowReader(reference: captionKeyboardWindow))
        .accessibilityIdentifier("caption.workspace")
        .onAppear {
            isWorkspaceActive = true
            workspaceLifetimeID = UUID()
            photoList = CaptionPhotoList(browserImages: browserViewModel.visibleImages)
            synchronizeSessionWithBrowser()
            updateReadiness()
            installCaptionShortcutMonitor()
        }
        .onDisappear {
            isWorkspaceActive = false
            workspaceLifetimeID = nil
            conflictOperationID = nil
            conflictReviewRequestID = nil
            removeCaptionShortcutMonitor()
            if let conflictReview {
                Task { await flushCoordinator.endConflictReview(conflictReview) }
            }
            conflictReview = nil
            pendingReviewPhoto = nil
            reviewedFailure = nil
            conflictExportReceipt = nil
            conflictCheckpoint = nil
            conflictImage = nil
            isConflictRecoveryBusy = false
        }
        .onChange(of: browserViewModel.visibleImages) { _, images in
            // Rating/label edits replace items without changing the list; only reorder,
            // filtering, or deletion needs the session to follow.
            let previousURLs = photoList.urls
            photoList = CaptionPhotoList(browserImages: images)
            if photoList.urls != previousURLs {
                synchronizeSessionWithBrowser(capturingDraft: true)
            }
        }
        .onChange(of: browserViewModel.isFullScreen) { wasFullScreen, isFullScreen in
            guard wasFullScreen, !isFullScreen, isWorkspaceActive else { return }
            adoptBrowserSelectionAfterFullScreen()
        }
        .onChange(of: focusedAction) { _, action in
            if action != nil { activeEditorField = nil }
        }
        .onChange(of: isEditorTransitioning) { _, isTransitioning in
            guard !isTransitioning else { return }
            if resynchronizesListAfterTransition {
                resynchronizesListAfterTransition = false
                synchronizeSessionWithBrowser(capturingDraft: true)
            }
            if restoresEditorFocusAfterTransition {
                restoresEditorFocusAfterTransition = false
                restoreLastEditorFocus()
            }
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
            if let saveError, conflictReview == nil, pendingReviewPhoto == nil { errorMessage = saveError }
        }
        .onChange(of: flushCoordinator.failure) { _, failure in
            guard let review = conflictReview, let failure else { return }
            if failure.id != review.failure.id || failure.affectedRequestCount != review.requestCount {
                conflictExportReceipt = nil
                conflictRecoveryError = "The queued edits changed. Cancel this review and open Review Queued Conflict again to export the current set."
            }
        }
        .onChange(of: commandRouter.latestDelivery) { _, delivery in
            if case .restoreCaptionEditorFocus? = delivery?.command, isEditorTransitioning {
                // The template palette closes before its template crosses the flush barrier, so
                // this arrives mid-transition. Stop routing Tab to the palette now and restore
                // the field focus once the transition finishes.
                isAwaitingTemplatePalette = false
                restoresEditorFocusAfterTransition = true
                return
            }
            guard let delivery, !isEditorTransitioning, conflictReview == nil, pendingReviewPhoto == nil else { return }
            switch delivery.command {
            case .selectPreviousImage:
                navigate(previous: true)
            case .selectNextImage:
                navigate(previous: false)
            case .restoreCaptionEditorFocus:
                isAwaitingTemplatePalette = false
                restoreLastEditorFocus()
            case .openFolder, .openRecentFolder, .setRating, .setLabel,
                 .renderSelected, .advancedExportSelected, .renderAll,
                 .saveAsJPEG, .saveAsPNG, .archiveRAW,
                 .rotateClockwise, .rotateCounterclockwise,
                 .renameSelected, .duplicateSelected,
                 .resetAllEdits, .removeAllIPTC,
                 .showImport, .showWebImport, .backupEditedFiles, .backupEditedFilesForFolder,
                 .openInInternalEditor, .openInExternalEditor,
                 .deleteSelected, .moveRejectedToFolder,
                 .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
                 .setScopeMode, .toggleGamutClipping,
                 .uploadSelected, .uploadAll,
                 .processVariablesSelected, .processVariablesAll, .transcribeVoiceMemosSelected,
                 .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
                 .writeAllPendingMetadata, .openCaptionWorkspace,
                 .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
                 .showVariableReference, .showRawMetadata, .showStructuredKeywords,
                 .showKnownPeopleDatabase, .registerOpenFolderForSidebar:
                break
            }
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
        .sheet(isPresented: Binding(
            get: { conflictReview != nil },
            set: { if !$0 { cancelConflictReview() } }
        )) {
            if let review = conflictReview, let failure = reviewedFailure {
                CaptionConflictRecoveryView(photoURL: review.photoURL, reason: failure.message,
                    requestCount: review.requestCount, exportURL: conflictExportReceipt?.exportURL,
                    isBusy: isConflictRecoveryBusy, errorMessage: conflictRecoveryError,
                    onExport: exportReviewedConflict, onDiscard: discardReviewedConflict,
                    onCancel: cancelConflictReview)
            }
        }
        .alert("Caption Workspace", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
            if let failure = flushCoordinator.failure, failure.kind == .replayConflict {
                Button("Review Queued Conflict…") {
                    errorMessage = nil
                    Task { @MainActor in beginConflictReview(failure) }
                }
            }
        } message: {
            Text(errorMessage ?? "The transition was cancelled.")
        }
    }

    private var isCurrentPhotoUnderReview: Bool {
        guard let current = session.currentURL else { return false }
        if let pendingReviewPhoto,
           pendingReviewPhoto.resolvingSymlinksInPath().path == current.resolvingSymlinksInPath().path { return true }
        return flushCoordinator.isReviewing(current)
    }

    private func queuedFailureBanner(_ failure: CaptionQueueFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(failure.kind == .replayConflict ? "Queued Caption Conflict" : "Caption Save Needs Attention")
                    .font(.headline)
                if let photo = failure.photoURL { Text(photo.lastPathComponent).font(.caption) }
                Text(failure.message).font(.callout).lineLimit(2)
            }
            Spacer()
            if failure.kind == .replayConflict {
                Button("Review Queued Conflict…") { beginConflictReview(failure) }
                    .accessibilityIdentifier("caption.conflictRecovery.review")
            } else {
                Button("Retry Saving") { retryQueuedCaptionPersistence() }
                    .accessibilityIdentifier("caption.conflictRecovery.retry")
            }
        }
        .disabled(isConflictRecoveryBusy || metadataViewModel.isSaving)
        .padding(12)
        .background(.orange.opacity(0.08))
    }

    private func beginConflictReview(_ failure: CaptionQueueFailure) {
        guard isWorkspaceActive, !isConflictRecoveryBusy,
              conflictReview == nil, pendingReviewPhoto == nil, let photo = failure.photoURL,
              !metadataViewModel.isSaving else { return }
        errorMessage = nil
        conflictRecoveryError = nil
        conflictRecoveryNotice = nil
        conflictExportReceipt = nil
        do {
            // Capture only this photo's live text and dependent request. Do not drain the failed
            // FIFO, and do not touch another selected photo's editor merely to review its head.
            if metadataViewModel.selectedURLs.count == 1,
               metadataViewModel.selectedURLs[0].resolvingSymlinksInPath().path == photo.resolvingSymlinksInPath().path {
                guard try flushCoordinator.editorCompositionState() == .committed else {
                    throw CaptionWorkspaceFlushError.persistenceFailed("Finish the active text composition before reviewing queued edits.")
                }
                try flushCoordinator.enqueueFlush()
            }
            conflictCheckpoint = metadataViewModel.captionConflictEditorCheckpoint(for: photo)
            conflictImage = visibleImages.first { $0.url.resolvingSymlinksInPath().path == photo.resolvingSymlinksInPath().path }
            pendingReviewPhoto = photo
            isConflictRecoveryBusy = true
            let requestID = UUID()
            conflictReviewRequestID = requestID
            Task { @MainActor in
                do {
                    let snapshot = try await flushCoordinator.beginConflictReview(failure)
                    guard isWorkspaceActive, conflictReviewRequestID == requestID else {
                        await flushCoordinator.endConflictReview(snapshot)
                        return
                    }
                    reviewedFailure = snapshot.failure
                    conflictReview = snapshot
                } catch {
                    if isWorkspaceActive, conflictReviewRequestID == requestID { errorMessage = error.localizedDescription }
                }
                if conflictReviewRequestID == requestID {
                    pendingReviewPhoto = nil
                    isConflictRecoveryBusy = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportReviewedConflict() {
        guard let review = conflictReview, let lifetimeID = workspaceLifetimeID,
              isWorkspaceActive, !isConflictRecoveryBusy else { return }
        let operationID = UUID()
        conflictOperationID = operationID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(review.photoURL.lastPathComponent) Caption Recovery.json"
        panel.title = "Export Queued Caption Recovery"
        panel.message = "Save a local copy of the queued metadata and history before discarding these edits."
        isConflictRecoveryBusy = true
        conflictRecoveryError = nil
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
                defer { finishConflictOperation(operationID, lifetimeID: lifetimeID) }
                guard response == .OK, let url = panel.url else { return }
                do {
                    let receipt = try await flushCoordinator.exportConflict(review, to: url)
                    guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
                    conflictExportReceipt = receipt
                } catch {
                    guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
                    conflictExportReceipt = nil
                    conflictRecoveryError = conflictReviewErrorDescription(error)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func discardReviewedConflict() {
        guard let review = conflictReview, let receipt = conflictExportReceipt,
              let lifetimeID = workspaceLifetimeID, isWorkspaceActive, !isConflictRecoveryBusy else { return }
        let operationID = UUID()
        conflictOperationID = operationID
        isConflictRecoveryBusy = true
        conflictRecoveryError = nil
        Task { @MainActor in
            defer { finishConflictOperation(operationID, lifetimeID: lifetimeID) }
            do {
                let result = try await flushCoordinator.discardExportedConflict(review, receipt: receipt)
                guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
                metadataViewModel.clearCaptionPersistenceFailure(requestID: review.failure.id)
                let reloaded = if let checkpoint = conflictCheckpoint, let image = conflictImage {
                    metadataViewModel.reloadAfterCaptionConflictRecovery(checkpoint, image: image)
                } else { false }
                conflictRecoveryNotice = "Removed \(result.discardedCount) exported queued \(result.discardedCount == 1 ? "edit" : "edits"). Saved files were kept."
                if conflictCheckpoint != nil, !reloaded {
                    conflictRecoveryNotice = (conflictRecoveryNotice ?? "")
                        + " The current editor was kept because it has unsaved changes or changed during review. Reopen the photo when you are ready to load its saved metadata."
                }
                browserViewModel.refreshPendingStatus()
                conflictReview = nil
                reviewedFailure = nil
                conflictExportReceipt = nil
                conflictCheckpoint = nil
                conflictImage = nil
                if let remaining = result.remainingFailure { errorMessage = remaining.message }
            } catch {
                guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
                conflictExportReceipt = nil
                conflictRecoveryError = conflictReviewErrorDescription(error)
            }
        }
    }

    private func ownsConflictOperation(_ operationID: UUID, lifetimeID: UUID) -> Bool {
        isWorkspaceActive && workspaceLifetimeID == lifetimeID && conflictOperationID == operationID
    }

    private func finishConflictOperation(_ operationID: UUID, lifetimeID: UUID) {
        guard ownsConflictOperation(operationID, lifetimeID: lifetimeID) else { return }
        conflictOperationID = nil
        isConflictRecoveryBusy = false
    }

    private func conflictReviewErrorDescription(_ error: any Error) -> String {
        if let recoveryError = error as? CaptionConflictRecoveryError, case .obsoleteReview = recoveryError {
            return "The queued edits changed. Cancel this review and open Review Queued Conflict again to export the current set."
        }
        return error.localizedDescription
    }

    private func cancelConflictReview() {
        guard let review = conflictReview, let lifetimeID = workspaceLifetimeID,
              isWorkspaceActive, !isConflictRecoveryBusy else { return }
        let operationID = UUID()
        conflictOperationID = operationID
        isConflictRecoveryBusy = true
        Task { @MainActor in
            defer { finishConflictOperation(operationID, lifetimeID: lifetimeID) }
            await flushCoordinator.endConflictReview(review)
            guard ownsConflictOperation(operationID, lifetimeID: lifetimeID), conflictReview?.id == review.id else { return }
            conflictReview = nil
            reviewedFailure = nil
            conflictExportReceipt = nil
            conflictCheckpoint = nil
            conflictImage = nil
            conflictRecoveryError = nil
        }
    }

    private func retryQueuedCaptionPersistence() {
        guard let lifetimeID = workspaceLifetimeID, isWorkspaceActive, !isConflictRecoveryBusy else { return }
        let operationID = UUID()
        conflictOperationID = operationID
        isConflictRecoveryBusy = true
        let failureID = flushCoordinator.currentQueueFailure?.id
        errorMessage = nil
        Task { @MainActor in
            defer { finishConflictOperation(operationID, lifetimeID: lifetimeID) }
            do {
                try await flushCoordinator.retryQueuedPersistence()
                guard ownsConflictOperation(operationID, lifetimeID: lifetimeID) else { return }
                if let failureID { metadataViewModel.clearCaptionPersistenceFailure(requestID: failureID) }
            } catch {
                guard ownsConflictOperation(operationID, lifetimeID: lifetimeID) else { return }
                errorMessage = error.localizedDescription
            }
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
            : "\(validationReport.blockerCount) \(validationReport.blockerCount == 1 ? "blocker" : "blockers"), \(validationReport.warningCount) \(validationReport.warningCount == 1 ? "warning" : "warnings")"
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
                        openFullScreen()
                    }
                    .disabled(currentImage == nil || isEditorTransitioning)

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
                    isUnavailable: previewFailed,
                    mode: previewMode,
                    confirmedPeople: showsConfirmedFaces ? confirmedPeople : []
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: session.currentURL) {
                await loadCurrentPreview()
            }

            Divider()
            CaptionVoiceMemoPlayerView(
                imageURL: session.currentURL,
                isMetadataReviewOrSaveBusy: metadataViewModel.isSaving
                    || isEditorTransitioning || isCurrentPhotoUnderReview
                    || conflictReview != nil || pendingReviewPhoto != nil
                    || isConflictRecoveryBusy,
                onVoiceMemoChange: { voiceMemoBadgeRefreshToken &+= 1 }
            ) {
                settingsViewModel.requestedDestination = .transcription
                openSettings()
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(visibleImages) { image in
                            CaptionFilmstripItem(
                                image: image,
                                thumbnailService: browserViewModel.thumbnailService,
                                isSelected: session.currentURL == image.url.standardizedFileURL,
                                voiceMemoRefreshToken: voiceMemoBadgeRefreshToken
                            ) {
                                select(image.url)
                            }
                            .id(image.url.standardizedFileURL)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.visible)
                .frame(height: 92)
                .onAppear {
                    if let currentURL = session.currentURL { proxy.scrollTo(currentURL, anchor: .center) }
                }
                .onChange(of: session.currentURL) { _, currentURL in
                    guard let currentURL else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(currentURL, anchor: .center)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                Button("Previous", systemImage: "chevron.left") {
                    navigate(previous: true)
                }
                .disabled(!session.canGoPrevious || isEditorTransitioning)
                .focused($focusedAction, equals: .previous)

                Button("Save & Next", systemImage: "chevron.right") {
                    navigate(previous: false, announcesAdvance: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.currentURL == nil || isEditorTransitioning)
                .help(shortcutHelp(for: .saveAndNext))
                .focused($focusedAction, equals: .saveAndNext)

                Button(
                    session.canGoNext ? "Write & Next" : "Write",
                    systemImage: "square.and.arrow.down"
                ) {
                    if session.canGoNext { writeAndNext() } else { writeCurrent() }
                }
                .disabled(
                    session.currentURL == nil
                        || metadataViewModel.isSaving
                        || isEditorTransitioning
                )
                .help(session.canGoNext
                    ? "Durably flush, write the current photo, then advance only after the write succeeds. \(shortcutHelp(for: .writeAndNext))"
                    : "Write the last photo. \(shortcutHelp(for: .writeAndNext))")
                .focused($focusedAction, equals: .writeAndNext)

                Divider().frame(height: 20)

                Menu("Apply Template", systemImage: "wand.and.stars") {
                    Button("Replace…") { applyTemplateAfterFlush(append: false) }
                    Button("Append…") { applyTemplateAfterFlush(append: true) }
                }
                .accessibilityIdentifier("caption.applyTemplate")
                .disabled(session.currentURL == nil || isEditorTransitioning)
                .focused($focusedAction, equals: .applyTemplate)

                Menu("Copy Previous", systemImage: "doc.on.doc") {
                    Button("Replace Caption Fields") { copyPrevious(mode: .replace) }
                    Button("Append Caption Fields") { copyPrevious(mode: .append) }
                }
                .disabled(
                    session.previousURL == nil
                        || isEditorTransitioning
                        || isCopyingPrevious
                        || metadataViewModel.isLoading
                )
                .help("Copy caption, headline, people, and keywords from the previous photo. Capture-specific metadata is always protected.")
                .focused($focusedAction, equals: .copyPrevious)

                Button("Fix Next", systemImage: "wrench.and.screwdriver") {
                    focusNextValidationIssue()
                }
                .disabled(nextVisibleValidationIssue == nil || isEditorTransitioning)
                .help(nextVisibleValidationIssue == nil && !validationReport.issues.isEmpty
                    ? (deadlineProfile == nil
                        ? "The remaining issues are in fields hidden in Settings → Metadata."
                        : "The remaining issues are in fields the Deadline profile does not show.")
                    : "Move to the next field that needs attention")
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
                // Escape is routed by the caption key monitor: it leaves a focused field first and
                // only closes the workspace when no editor or input method owns the key.
                .help("Close the Caption workspace (Esc when no field is being edited)")
                .disabled(isEditorTransitioning)
                .focused($focusedAction, equals: .close)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 50)
        .scrollIndicators(.hidden)
    }

    private var isEditorTransitioning: Bool { session.isTransitioning || flushCoordinator.isTransitioning }

    /// The editor's selection load trails navigation, so right after moving its draft can still
    /// belong to the previous photo (or be a load placeholder). Actions that read or write the
    /// editor must only act once it describes the photo the header shows.
    private var editorDescribesCurrentPhoto: Bool {
        guard let currentURL = session.currentURL else { return false }
        return !metadataViewModel.isLoading
            && metadataViewModel.selectedURLs.count == 1
            && metadataViewModel.selectedURLs.first?.standardizedFileURL == currentURL
    }

    /// Waits (once, without stacking repeated presses) for the current photo's editor load, then
    /// confirms focus is still on `target`. Returns false with a brief notice otherwise, so an
    /// action never lands on the previous photo's editor.
    private func waitForEditor(describing target: URL) async -> Bool {
        if editorDescribesCurrentPhoto, session.currentURL == target { return true }
        guard !isAwaitingEditorLoad else {
            inlineNotice = "The photo's metadata is still loading. Try again in a moment."
            return false
        }
        isAwaitingEditorLoad = true
        defer { isAwaitingEditorLoad = false }
        if metadataViewModel.selectedURLs.map(\.standardizedFileURL) != [target],
           let image = photoList.image(forStandardizedURL: target) {
            metadataViewModel.loadSelectionMetadataNow(for: [image], folderURL: browserViewModel.currentFolderURL)
        }
        await metadataViewModel.waitForMetadataLoad()
        guard session.currentURL == target, editorDescribesCurrentPhoto else {
            inlineNotice = "The photo's metadata is still loading. Try again in a moment."
            return false
        }
        return true
    }

    /// Full screen is a separate window whose arrow keys change the browser selection directly,
    /// bypassing the session's flush barrier. Capture the buffered caption before it opens.
    private func openFullScreen() {
        guard !isEditorTransitioning else { return }
        do {
            try enqueueCurrentDraftPersistence()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        preservingEditorFocus {
            browserViewModel.isFullScreen = true
        }
    }

    /// Follows the photo the user navigated to in full screen so the header, preview and editor
    /// describe the same photo again.
    private func adoptBrowserSelectionAfterFullScreen() {
        guard browserViewModel.selectedImageIDs.count == 1,
              let browserURL = browserViewModel.selectedImageIDs.first,
              photoList.contains(browserURL) else {
            // Full screen ended on a video or a multi-selection that Caption cannot edit. Put the
            // browser (and so the metadata editor) back on the photo the header shows.
            publishSessionSelection()
            return
        }
        if browserURL.standardizedFileURL != session.currentURL {
            select(browserURL)
        }
    }

    private func synchronizeSessionWithBrowser(capturingDraft: Bool = false) {
        if capturingDraft, isWorkspaceActive,
           let currentURL = session.currentURL,
           !visibleURLs.contains(where: { $0.standardizedFileURL == currentURL }) {
            // The focused photo can leave the filtered list (for example after a rating change).
            // Capture its buffered text before the session moves focus to a neighbour. Never move
            // on without it: mid-transition, retry once the transition ends; if the capture fails,
            // keep the editor on this photo and say so.
            guard !isEditorTransitioning else {
                resynchronizesListAfterTransition = true
                return
            }
            do {
                try enqueueCurrentDraftPersistence()
            } catch {
                resynchronizesListAfterTransition = true
                errorMessage = "\(currentURL.lastPathComponent) left the current filter, but its caption edits could not be saved: \(error.localizedDescription) The photo stays open in Caption until they are saved."
                return
            }
        }
        resynchronizesListAfterTransition = false
        session.replaceImages(visibleURLs)
        // Full screen owns the browser selection while it is open (rating, label, or delete there
        // can change the list); pushing Caption's photo back would snap it to another image.
        // `adoptBrowserSelectionAfterFullScreen` reconciles on exit.
        guard !browserViewModel.isFullScreen, let currentURL = session.currentURL else { return }
        let browserURL = originalBrowserURL(for: currentURL)
        if browserViewModel.selectedImageIDs != [browserURL] {
            browserViewModel.selectedImageIDs = [browserURL]
            browserViewModel.lastClickedImageURL = browserURL
        }
    }

    private func prepareAndPerform(
        _ action: CaptionSessionAction,
        operation: @MainActor () -> Void
    ) async throws {
        let token = try flushCoordinator.reserveTransition()
        try await flushCoordinator.performReservedTransition(token, flush: {
            try await session.prepare(for: action) { try await flushCoordinator.flushAsync() }
        }, operation: {
            session.markCommitted()
            operation()
        })
    }

    private func enqueueCurrentDraftPersistence() throws {
        guard !flushCoordinator.isTransitioning else { throw CaptionSessionError.transitionInProgress }
        try CaptionWorkspaceFlushCoordinator.shared.enqueueFlush()
        session.markCommitted()
    }

    private func navigate(previous: Bool, announcesAdvance: Bool = false) {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning else { return }
            do {
                if announcesAdvance, !previous, !session.canGoNext {
                    // Save & Next on the last photo still saves; say why focus stays put.
                    guard session.currentURL != nil, !session.isTransitioning else { return }
                    try enqueueCurrentDraftPersistence()
                    inlineNotice = "Saved — last photo"
                    return
                }
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
            guard !flushCoordinator.isTransitioning else { return }
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
        // Load the editor now rather than after the browser's selection debounce, so Write,
        // Copy Previous and code replacement are not left waiting on (or racing) the old draft.
        if metadataViewModel.selectedURLs != [browserURL], let image = photoList.image(forStandardizedURL: url) {
            metadataViewModel.loadSelectionMetadataNow(for: [image], folderURL: browserViewModel.currentFolderURL)
        }
    }

    private func originalBrowserURL(for sessionURL: URL) -> URL {
        photoList.image(forStandardizedURL: sessionURL)?.url ?? sessionURL
    }

    private func applyTemplateAfterFlush(append: Bool?) {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning else { return }
            do {
                try await prepareAndPerform(.applyTemplate) {
                    isAwaitingTemplatePalette = true
                    onApplyTemplate(append)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func copyPrevious(mode: CaptionCopyPreviousMergeMode) {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning else { return }
            guard !isCopyingPrevious else { return }
            isCopyingPrevious = true
            defer { isCopyingPrevious = false }
            guard let target = session.currentURL, await waitForEditor(describing: target),
                  !flushCoordinator.isTransitioning else { return }

            do {
                let token = try flushCoordinator.reserveTransition()
                var previousMetadata: IPTCMetadata?
                var loadToken: CaptionLoadToken?
                try await flushCoordinator.performReservedTransition(token, flush: {
                    try await session.prepare(for: .copyPrevious) { try await flushCoordinator.flushAsync() }
                    session.markCommitted()
                    guard let previousURL = session.previousURL else {
                        errorMessage = "There is no previous photo in the current order."
                        return
                    }
                    guard let currentLoad = session.beginLoad() else { return }
                    loadToken = currentLoad
                    previousMetadata = try await metadataViewModel.loadCaptionCopyPreviousMetadata(
                        for: originalBrowserURL(for: previousURL))
                }, operation: {
                    guard let previous = previousMetadata, let loadToken, session.accepts(load: loadToken),
                          editorDescribesCurrentPhoto else { return }
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
                    guard result.changed else {
                        inlineNotice = "The previous photo has no different caption fields to copy."
                        return
                    }
                    metadataViewModel.editingMetadata = updated
                    metadataViewModel.hasChanges = true
                    session.markCurrentDirty()
                    updateReadiness()
                })
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareCodeReplacementPreview() {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning, let target = session.currentURL,
                  await waitForEditor(describing: target), !flushCoordinator.isTransitioning else { return }
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

                try await prepareAndPerform(.codeReplacement) {
                    guard let previewURL = session.currentURL, previewURL == target,
                          editorDescribesCurrentPhoto else {
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
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyPendingCodeReplacement() {
        guard !isEditorTransitioning else { return }
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
            guard !flushCoordinator.isTransitioning, let target = session.currentURL,
                  await waitForEditor(describing: target), !flushCoordinator.isTransitioning else { return }
            do {
                try await prepareAndPerform(.write) {
                    guard session.currentURL == target, editorDescribesCurrentPhoto else { return }
                    metadataViewModel.writeMetadataAndClearSidecar()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func writeAndNext() {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning, let target = session.currentURL,
                  await waitForEditor(describing: target), !flushCoordinator.isTransitioning else { return }
            do {
                try await prepareAndPerform(.write) {
                    guard let currentURL = session.currentURL, currentURL == target,
                          editorDescribesCurrentPhoto else { return }
                    pendingWriteAndNextURL = currentURL
                    metadataViewModel.writeMetadataAndClearSidecar()
                    // A write refused before it starts (for example an unpersisted Develop edit)
                    // sets `saveError` without toggling `isSaving`, so the completion handler
                    // never consumes this; a later unrelated save must not advance.
                    if !metadataViewModel.isSaving { pendingWriteAndNextURL = nil }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func completeWriteAndNextIfPossible() {
        guard let pendingURL = pendingWriteAndNextURL else { return }
        pendingWriteAndNextURL = nil
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning else { return }
            guard metadataViewModel.saveError == nil,
                  pendingURL.standardizedFileURL == session.currentURL?.standardizedFileURL else { return }
            do {
                guard try CaptionWorkspaceFlushCoordinator.shared.editorCompositionState() == .committed else { return }
                // Text entered during the write may still live in AppKit's field editor. Capture
                // it in this navigation turn; a newer pending draft must keep this photo selected.
                try CaptionWorkspaceFlushCoordinator.shared.enqueueFlush()
                guard CaptionWriteAndNextGate.shouldAdvance(
                    pendingURL: pendingURL,
                    currentURL: session.currentURL,
                    writeSucceeded: metadataViewModel.saveError == nil,
                    hasPendingChanges: metadataViewModel.hasChanges,
                    hasUnpersistedEditorChanges: metadataViewModel.hasUnpersistedEditorChanges
                ) else { return }
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

    /// The next issue in a field the editor actually shows; issues in hidden fields cannot take focus.
    private var nextVisibleValidationIssue: MetadataValidationIssue? {
        CaptionWorkspaceChecklistSummary.make(
            report: validationReport,
            actionableFields: Set(fieldLayout.priority + fieldLayout.secondary)
        ).nextIssue
    }

    private func focusNextValidationIssue() {
        guard let issue = nextVisibleValidationIssue else { return }
        requestFocus(issue.field)
    }

    private func requestFocus(_ field: MetadataFieldID) {
        guard !isEditorTransitioning else { return }
        focusedAction = nil
        requestedFocusedField = nil
        DispatchQueue.main.async {
            guard !isEditorTransitioning else { return }
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
            // Local event monitors see every app window. Settings/shortcut recording,
            // other workspaces and sheets must retain their own Tab and advance keys.
            guard isWorkspaceActive, captionKeyboardWindow.ownsEvent(in: event.window),
                  !isEditorTransitioning, conflictReview == nil, pendingReviewPhoto == nil else { return event }
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
            if event.keyCode == 53, modifiers.isEmpty {
                guard !inputState.textEditorOwnsInput,
                      !inputState.imeHasMarkedText,
                      !isEditorTransientPresented,
                      !showingCodeReplacementSettings,
                      !showingCodeReplacementPreview,
                      errorMessage == nil else { return event }
                closeAfterFlush()
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
                guard session.currentURL != nil, !isEditorTransitioning else { return nil }
                navigate(previous: false, announcesAdvance: true)
            case .writeAndNext:
                guard session.currentURL != nil,
                      !isEditorTransitioning,
                      !metadataViewModel.isSaving else { return nil }
                if session.canGoNext { writeAndNext() } else { writeCurrent() }
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
        case .previous: session.canGoPrevious && !isEditorTransitioning
        case .saveAndNext: session.currentURL != nil && !isEditorTransitioning
        case .writeAndNext:
            session.currentURL != nil && !isEditorTransitioning && !metadataViewModel.isSaving
        case .applyTemplate: session.currentURL != nil && !isEditorTransitioning
        case .copyPrevious:
            session.previousURL != nil && !isEditorTransitioning && !isCopyingPrevious
        case .fixNext: nextVisibleValidationIssue != nil && !isEditorTransitioning
        case .more, .close: !isEditorTransitioning
        }
    }

    private func removeCaptionShortcutMonitor() {
        guard let captionShortcutMonitor else { return }
        NSEvent.removeMonitor(captionShortcutMonitor)
        self.captionShortcutMonitor = nil
    }

    private func closeAfterFlush() {
        Task { @MainActor in
            guard !flushCoordinator.isTransitioning else { return }
            do {
                try await prepareAndPerform(.workspaceExit) { onClose() }
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
        previewFailed = false
        confirmedPeople = []
        guard let token = session.beginPreviewLoad() else { return }
        let image = currentImage
        // The editor's selection load is debounced, so right after navigating its draft still
        // belongs to the previous photo. Only trust it once it describes this photo.
        let settings = editorDescribesCurrentPhoto
            ? metadataViewModel.editingMetadata.cameraRaw
            : image?.cameraRawSettings
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
        guard !Task.isCancelled, session.acceptsPreview(load: token) else { return }
        // Show the photo before the folder's face data, which can be slow on large folders.
        preview = loaded
        previewFailed = loaded == nil
        let folderURL = token.imageURL.deletingLastPathComponent()
        let faceDataResult = await FaceDataFolderLoadService.shared.loadDocument(
            folderURL: folderURL
        )
        let faceData: FolderFaceData? = if case .complete(let evidence) = faceDataResult {
            evidence.faceData
        } else {
            nil
        }
        // Face rects describe the uncropped photo; the edited preview shows the Develop crop.
        // The fallback thumbnail's framing is unknown, so a cropped photo shows no boxes there.
        let crop = settings?.crop
        let people: [CaptionConfirmedPerson] = if crop?.isEffectiveCrop == true, cgImage == nil {
            []
        } else {
            CaptionConfirmedPersonOrdering.people(for: token.imageURL, in: faceData).compactMap { person in
                guard let rect = CaptionPreviewGeometry.croppedVisionRect(
                    person.normalizedFaceRect, crop: crop, displayOrientation: orientation,
                    renderedSize: loaded?.size ?? .zero) else { return nil }
                return CaptionConfirmedPerson(id: person.id, name: person.name, normalizedFaceRect: rect)
            }
        }
        guard !Task.isCancelled, session.acceptsPreview(load: token) else { return }
        confirmedPeople = people
    }
}

private struct CaptionEditedPreview: View {
    let image: NSImage?
    let isUnavailable: Bool
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
            } else if isUnavailable {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The photo could not be decoded. You can still edit its caption.")
                )
                .foregroundStyle(.white)
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
    let voiceMemoRefreshToken: UInt64
    let onSelect: () -> Void
    @State private var thumbnail: NSImage?
    @State private var voiceMemoStatus: CaptionVoiceMemoTranscriptionStatus = .none
    @State private var transcriptChangeToken: UInt64 = 0

    private struct StatusRequest: Equatable {
        let imageURL: URL
        let refreshToken: UInt64
        let transcriptChangeToken: UInt64
    }

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
            .overlay(alignment: .bottomTrailing) {
                if voiceMemoStatus == .needsTranscription || voiceMemoStatus == .transcribed {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(voiceMemoStatus == .needsTranscription ? Color.orange : Color.green)
                        .padding(4)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                        .help(voiceMemoStatus.accessibilityDescription)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .help("\(image.filename)\n\(voiceMemoStatus.accessibilityDescription)")
        .accessibilityLabel(image.filename)
        .accessibilityValue("\(isSelected ? "Selected" : "Not selected"), \(voiceMemoStatus.accessibilityDescription)")
        .accessibilityHint("Select this photo for caption editing")
        .onReceive(NotificationCenter.default.publisher(for: MetadataSidecarService.voiceMemoTranscriptDidChange)
            .receive(on: DispatchQueue.main)) { notification in
            guard let url = notification.object as? URL,
                  url.standardizedFileURL.path == image.url.standardizedFileURL.path else { return }
            transcriptChangeToken &+= 1
        }
        .task(id: StatusRequest(imageURL: image.url, refreshToken: voiceMemoRefreshToken,
            transcriptChangeToken: transcriptChangeToken)) {
            let status = await CaptionVoiceMemoStatusService.shared.status(for: image.url)
            guard !Task.isCancelled else { return }
            voiceMemoStatus = status
        }
        .task(id: image.url) {
            if let cached = thumbnailService.thumbnail(for: image.url) {
                thumbnail = cached
            } else {
                thumbnail = await thumbnailService.loadThumbnail(for: image.url)
            }
        }
    }
}
