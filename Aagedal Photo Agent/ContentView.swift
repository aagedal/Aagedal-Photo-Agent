import Combine
import AppKit
import CoreImage
import os.log
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main View Mode

enum MainViewMode {
    /// Deadline UI is deferred to 3.1; keep its implementation and saved data intact.
    static let isDeadlineAvailable = false

    case browser           // Normal photo browsing
    case caption           // Keyboard-first, sidecar-safe captioning workspace
    case deadline          // Delivery preflight and fix-next workspace
    case metadataReview    // Folder-wide metadata comparison list
    case imageAnalysis     // Source-bound evidence and OSINT workspace
    case comparison        // Revision-bound two-image comparison workspace
    case editing           // Dedicated image editing workspace
    case faceManagement    // Expanded face management (existing)
    case peopleDatabase    // Known People database view
}

/// A pending on-disk draft is not permission to embed it during navigation or backgrounding.
/// Caption and Metadata Review use their registered buffered-editor/FIFO boundary; explicit Write commands
/// remain separate. Keeping this admission here makes both lifecycle observers share the rule.
@MainActor
enum MetadataAutomaticSaveBoundary {
    enum Trigger { case selectionChange, deactivation }

    static func perform(
        _ trigger: Trigger,
        in workspace: MainViewMode,
        viewModel: MetadataViewModel,
        captionFlush: () throws -> Void,
        commitConfigured: () -> Void
    ) rethrows {
        if workspace == .caption || workspace == .metadataReview {
            // Capture buffered AppKit text even when it has not yet changed the published
            // editing model. Caption selection uses its navigation barrier; Review retains every row.
            if trigger == .deactivation { try captionFlush() }
            return
        }
        // Keyboard navigation (Cmd+N/Cmd+P) and backgrounding leave the field editor focused,
        // so its typed text has not reached the model yet.
        viewModel.captureFocusedEditorText()
        guard viewModel.hasUnpersistedEditorChanges else { return }
        if viewModel.shouldDeferAutomaticCommitForVariables {
            // Never embed literal {variable} tokens automatically: keep the edit as a pending
            // draft that Process Variables (or an explicit Write) resolves later.
            viewModel.keepUnresolvedVariablesAsPendingDraft()
            return
        }
        commitConfigured()
    }
}

/// Lets termination persist the Browser metadata panel, which (unlike Caption) has no FIFO
/// flush coordinator: typed field text and unsaved edits would otherwise be lost on Quit.
@MainActor
final class MetadataEditorTerminationFlush {
    static let shared = MetadataEditorTerminationFlush()
    private var handler: (@MainActor () async throws -> Void)?

    func register(_ handler: @escaping @MainActor () async throws -> Void) { self.handler = handler }

    func flush() async throws { try await handler?() }
}

enum TemplateCommandTarget: Equatable {
    case metadata
    case develop
}

extension MainViewMode {
    /// Develop owns the shared template shortcuts only while its workspace is
    /// active. Every other view intentionally falls back to metadata templates.
    var templateCommandTarget: TemplateCommandTarget {
        self == .editing ? .develop : .metadata
    }

    /// Image Analysis hides the Browser selection behind a source-bound evidence case. Commands
    /// that would trash, move, rename, rotate, or rewrite the files of that hidden selection (and
    /// so remove the evidence or change its source bytes) are ignored while Analysis is shown.
    func suppressesHiddenSelectionCommand(_ command: AppCommand) -> Bool {
        guard self == .imageAnalysis else { return false }
        switch command {
        case .deleteSelected, .moveRejectedToFolder,
             .rotateClockwise, .rotateCounterclockwise,
             .renameSelected, .duplicateSelected,
             .resetAllEdits, .removeAllIPTC,
             .setRating, .setLabel,
             .processVariablesSelected, .processVariablesAll,
             .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
             .pasteIPTCMetadata, .addNewMask, .removeOrResetSelectedEditLayer:
            return true
        default:
            return false
        }
    }
}

struct FTPUploadItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct BackupEditedItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Keeps the credentials sheet's content and source URL in one state value. A
/// `.sheet(item:)` closure that receives a missing URL renders an empty macOS
/// sheet, which presents as a small rounded rectangle on first launch.
private struct C2PADetailPresentation: Identifiable {
    let id = UUID()
    let imageURL: URL
}

/// Pulls the safety and culling command handlers out of the main content chain
/// so the type-checker can finish
/// inside its time budget.
private struct SafetyAndCullingHandlers: ViewModifier {
    let browserViewModel: BrowserViewModel
    let commandRouter: AppCommandRouter
    let mainViewMode: MainViewMode
    let performAfterMetadataFlush: (@escaping @MainActor () -> Void) -> Void
    @Binding var backupEditedFolderItem: BackupEditedItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: commandRouter.latestDelivery) { _, delivery in
                guard let delivery, !CaptionWorkspaceFlushCoordinator.shared.isTransitioning,
                      !mainViewMode.suppressesHiddenSelectionCommand(delivery.command) else { return }
                switch delivery.command {
                case .backupEditedFiles:
                    if let folder = browserViewModel.currentFolderURL {
                        backupEditedFolderItem = BackupEditedItem(url: folder)
                    }
                case .backupEditedFilesForFolder(let url):
                    backupEditedFolderItem = BackupEditedItem(url: url)
                case .moveRejectedToFolder:
                    performAfterMetadataFlush { browserViewModel.moveRejectedToFolder() }
                case .openFolder, .openRecentFolder, .setRating, .setLabel,
                     .renderSelected, .advancedExportSelected, .renderAll,
                     .saveAsJPEG, .saveAsPNG, .archiveRAW,
                     .selectPreviousImage, .selectNextImage,
                     .rotateClockwise, .rotateCounterclockwise,
                     .renameSelected, .duplicateSelected,
                     .resetAllEdits, .removeAllIPTC,
                     .showImport, .showWebImport, .openInInternalEditor, .openInExternalEditor,
                     .deleteSelected,
                     .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
                     .setScopeMode, .toggleGamutClipping,
                     .uploadSelected, .uploadAll,
                     .processVariablesSelected, .processVariablesAll, .transcribeVoiceMemosSelected,
                     .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
                     .writeAllPendingMetadata, .openCaptionWorkspace,
                     .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
                     .showVariableReference, .showRawMetadata, .showStructuredKeywords,
                     .showKnownPeopleDatabase, .registerOpenFolderForSidebar,
                     .restoreCaptionEditorFocus:
                    break
                }
            }
    }
}

private struct AdvancedExportRequest {
    let urls: [URL]
    let configurations: [AdvancedExportConfiguration]
}

/// When the browse-mode inspector decodes its own scope source for a selection.
enum BrowseScopeLoadPolicy {
    /// Edit mode posts its own scope image; collapsed scopes display nothing, so the
    /// extra 720 px decode is deferred until they are expanded.
    static func shouldDecode(scopesExpanded: Bool, mainViewMode: MainViewMode) -> Bool {
        scopesExpanded && mainViewMode != .editing
    }
}

struct ContentView: View {
    @State private var panes: BrowserPanesModel
    /// The pane every single consumer follows — sidebar folder loads, metadata panel,
    /// face bar, and edit view all bind to this (the focused pane in split view).
    private var browserViewModel: BrowserViewModel { panes.active }
    /// Canonical owner of the sidebar's folder-tree state (favorites, open folders,
    /// expansion, subfolders). Always the primary pane, so the sidebar stays stable no
    /// matter which pane is focused — only folder *opening* follows the active pane.
    private var sidebarViewModel: BrowserViewModel { panes.panes[0] }

    /// Open a folder into the active pane. The shared sidebar (primary pane) picks it up
    /// through the scene command router, so it shows even when a non-primary pane opened it.
    private func openFolderInActivePane(_ url: URL, addToOpenFolders: Bool) {
        let targetPane = panes.active
        performAfterBrowserEditorCommit {
            targetPane.loadFolder(url: url, addToOpenFolders: addToOpenFolders)
        }
    }

    /// Close a sidebar root in the sidebar's pane and in any other pane showing it.
    private func closeFolderInAllPanes(_ url: URL) {
        performAfterBrowserEditorCommit {
            sidebarViewModel.closeOpenFolder(url)
            for pane in panes.panes.dropFirst() {
                pane.releaseClosedFolder(url)
            }
        }
    }
    @State private var metadataViewModel: MetadataViewModel
    /// A Browser-editor save admitted ahead of a folder or workspace change is still running.
    @State private var isCommittingBrowserEditor = false
    @State private var faceRecognitionViewModel: FaceRecognitionViewModel
    @State private var templateViewModel: TemplateViewModel
    @State private var developTemplateViewModel = DevelopTemplateViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var advancedExportSession: AdvancedExportSession?
    @State private var advancedExportPreparationTask: Task<Void, Never>?
    @State private var advancedExportPreparationRequestID = UUID()
    @State private var pendingAdvancedExportRequest: AdvancedExportRequest?
    @State private var settingsViewModel: SettingsViewModel
    @State private var importViewModel: ImportViewModel
    /// Shared, persisted log of recent imports and uploads.
    @State private var activityHistory: ActivityHistoryStore
    /// Privacy-preserving, immutable delivery evidence surfaced alongside Activity history.
    @State private var deliveryReceiptLibrary = DeliveryReceiptLibraryModel()
    /// Privacy-safe discovery and explicit recovery/cleanup for retained delivery workflows.
    @State private var deliveryWorkflowActivity: DeliveryWorkflowActivityModel
    /// Retains migration failures that can happen before this view exists.
    @State private var migrationRecoveryNotices = MigrationRecoveryNoticeCenter.shared

    @State private var isShowingTemplateEditor = false
    @State private var isShowingTemplatePalette = false
    @State private var captionTemplateAppendOverride: Bool?
    @State private var isShowingDevelopTemplatePalette = false
    @State private var ftpUploadItem: FTPUploadItem?
    @State private var isShowingSaveTemplateName = false
    @State private var isShowingSaveDevelopTemplateName = false
    @State private var isShowingImport = false
    @State private var isShowingWebImport = false
    /// Height of the main window's content area, used to cap sheet heights.
    @State private var windowContentHeight: CGFloat = 0
    @State private var backupEditedFolderItem: BackupEditedItem?
    @State private var isShowingWriteAllC2PAWarning = false
    @State private var isShowingVariableRecovery = false
    @State private var isShowingPrimaryDevelopRecovery = false
    @State private var c2paDetailPresentation: C2PADetailPresentation?
    @State private var c2paValidation: C2PAValidationResult?
    @State private var pendingWriteAllC2PACount = 0
    @State private var saveTemplateName = ""
    @State private var saveDevelopTemplateName = ""
    @State private var saveDevelopTemplateIncludesCrop = true
    @AppStorage(UserDefaultsKeys.metadataPanelWidth) private var metadataPanelWidth: Double = 320
    @State private var mainViewMode: MainViewMode = .browser
    @State private var deadlineProfileLibrary: DeadlineProfileLibraryModel
    @State private var deadlineRenameRecipeLibrary = BatchRenameRecipeLibraryModel()
    @State private var deadlineLiveSnapshot = DeadlinePreflightLiveSnapshotModel()
    @State private var deadlineDeliverySession: DeadlineDeliveryProductionSession
    @State private var pendingDeadlineResumeWorkflowIdentifier: UUID?
    @State private var pendingDeadlineCaptionField: MetadataFieldID?
    @State private var isShowingDeadlineStagingActivity = false
    @State private var isShowingDeadlineProfileManager = false
    @State private var lastNonPeopleViewMode: MainViewMode = .browser
    @State private var navigationSplitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var navigationSplitViewVisibilityBeforeAnalysis: NavigationSplitViewVisibility?
    /// Defers the Develop transition until the separate full-screen window has
    /// actually been ordered out. Building the editor underneath that key,
    /// always-on-top window can leave AppKit focus handling wedged.
    @State private var opensEditWorkspaceAfterFullScreenDismissal = false
    /// Comparison follows the same focus-safe handoff: freeze the pair, order the dedicated
    /// full-screen window out, and only then construct the comparison workspace.
    @State private var opensComparisonAfterFullScreenDismissal = false
    @State private var faceSelectionState = FaceSelectionState()
    @State private var technicalMetadata: TechnicalMetadata?
    @State private var technicalMetadataCache: [URL: TechnicalMetadata] = [:]
    @State private var technicalMetadataTask: Task<Void, Never>?
    @State private var technicalMetadataRequestID: UUID?
    @AppStorage(UserDefaultsKeys.scopesExpanded) private var scopesExpanded = true
    @State private var isRenderingEditedFolder = false
    @State private var renderExportCurrent = 0
    @State private var renderExportTotal = 0
    @State private var renderEditedFolderSuccessCount = 0
    @State private var renderEditedFolderFailureCount = 0
    @State private var renderExportTask: Task<Void, Never>?
    @State private var lastBatchResult: BatchOperationResult?
    @State private var isBatchResultExpanded = false
    @State private var scopeViewModel = ScopeViewModel()
    @State private var scopeImageTask: Task<Void, Never>?
    @State private var analysisWorkspaceModel = AnalysisWorkspaceModel()
    @State private var comparisonImages: [ImageFile] = []
    @State private var comparisonRenameEvent: ComparisonRenameEvent?
    @State private var comparisonOrigin: ComparisonOriginWorkspace = .browser
    @State private var comparisonInitialLeftRepresentation: ComparisonRepresentation?
    /// The photo in Compare's focused pane. Ratings and labels apply to it explicitly (like
    /// full screen): rating it out of the active filter moves the Browser selection on.
    @State private var comparisonFocusedURL: URL?
    private let uiTestLaunchConfiguration: UITestLaunchConfiguration
    private let commandRouter: AppCommandRouter

    // Keyword-list backup recovery (prompts when a list comes back empty at launch).
    @State private var voiceMemoBatchModel = CaptionVoiceMemoBatchTranscriptionModel()
    @State private var isShowingVoiceMemoBatch = false
    @State private var voiceMemoBatchPreparationTask: Task<Void, Never>?

    @State private var isShowingListRecoveryPrompt = false
    @State private var isShowingListBackups = false
    @State private var listRecoveryHandled = false
    /// Names of the lists that read empty when the prompt fired, frozen at that
    /// moment so the alert and sheet describe exactly what was flagged.
    @State private var listRecoveryAffectedNames: [String] = []

    init(settingsViewModel: SettingsViewModel, commandRouter: AppCommandRouter,
         faceRecognition: FaceRecognitionViewModel, history: ActivityHistoryStore) {
        let uiTestLaunchConfiguration = UITestLaunchConfiguration.current
        let deliverySession = DeadlineDeliveryProductionSession()
        let thumbnailService = ThumbnailService()
        let fullScreenImageCache = FullScreenImageCache()
        let browser = BrowserViewModel(thumbnailService: thumbnailService, fullScreenImageCache: fullScreenImageCache)
        // Wire face deletion onto every pane (primary now, the split pane when created).
        let configurePane: (BrowserViewModel) -> Void = { [weak faceRecognition, weak commandRouter] vm in
            vm.onImagesDeleted = { urls in faceRecognition?.deleteFaces(forImageURLs: urls) }
            vm.onDidOpenRootFolder = { [weak commandRouter] url in
                commandRouter?.send(.registerOpenFolderForSidebar(url))
            }
        }
        let panesModel = BrowserPanesModel(
            primary: browser,
            thumbnailService: thumbnailService,
            fullScreenImageCache: fullScreenImageCache
        )
        // Sidebar folder rename/move/trash runs on the primary pane; every other pane showing
        // that folder (or a descendant) must follow it too instead of keeping a dead path.
        let configureWithPanes: (BrowserViewModel) -> Void = { [weak panesModel] vm in
            configurePane(vm)
            vm.onFolderRelocated = { [weak panesModel, weak vm] oldURL, newURL in
                for pane in panesModel?.panes ?? [] where pane !== vm {
                    pane.followRelocatedFolder(from: oldURL, to: newURL)
                }
            }
        }
        configureWithPanes(browser)
        panesModel.configurePane = configureWithPanes
        _panes = State(initialValue: panesModel)
        _metadataViewModel = State(initialValue: MetadataViewModel(readService: browser.metadataReadService, writeEngine: browser.writeEngine))
        _faceRecognitionViewModel = State(initialValue: faceRecognition)
        _templateViewModel = State(initialValue: TemplateViewModel(
            storage: TemplateStorageService(directoryURL: uiTestLaunchConfiguration.templateRootURL)
        ))
        _settingsViewModel = State(initialValue: settingsViewModel)
        if uiTestLaunchConfiguration.isEnabled,
           let profileStoreURL = uiTestLaunchConfiguration.profileStoreURL {
            _deadlineProfileLibrary = State(initialValue: DeadlineProfileLibraryModel(
                repository: DeadlineProfileRepository(documentURL: profileStoreURL)
            ))
        } else {
            _deadlineProfileLibrary = State(initialValue: DeadlineProfileLibraryModel())
        }
        _activityHistory = State(initialValue: history)
        _voiceMemoBatchModel = State(initialValue: CaptionVoiceMemoBatchTranscriptionModel(activityHistory: history))
        _deadlineDeliverySession = State(initialValue: deliverySession)
        _deliveryWorkflowActivity = State(initialValue: DeliveryWorkflowActivityModel(
            dependencies: .production(session: deliverySession)
        ))
        _pendingDeadlineResumeWorkflowIdentifier = State(initialValue: nil)
        _importViewModel = State(initialValue: ImportViewModel(readService: browser.metadataReadService, writeEngine: browser.writeEngine, activityHistory: history))
        self.uiTestLaunchConfiguration = uiTestLaunchConfiguration
        self.commandRouter = commandRouter
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        contentWithStateHandlers
            .disabled(CaptionWorkspaceFlushCoordinator.shared.isTransitioning)
            .task {
                _ = await settingsViewModel.refreshC2PACertificateStatus(requestID: UUID())
                if MainViewMode.isDeadlineAvailable {
                    await deadlineProfileLibrary.loadIfNeeded()
                }
                await deadlineRenameRecipeLibrary.loadIfNeeded()
                await deliveryReceiptLibrary.reload()
                await deliveryWorkflowActivity.reload()
                await runUITestWorkflowIfRequested()
            }
            .task(id: deadlineLiveCaptureRevision) {
                guard let request = makeDeadlineLiveCaptureRequest() else {
                    await deadlineLiveSnapshot.clear()
                    return
                }
                await deadlineLiveSnapshot.refresh(request)
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
                deadlineLiveSnapshot.refreshValidationPreferences()
            }
            .sheet(isPresented: $isShowingDeadlineProfileManager) {
                DeadlineProfileManagementView(
                    model: deadlineProfileLibrary,
                    onClose: { isShowingDeadlineProfileManager = false }
                )
            }
            .onChange(of: browserViewModel.selectedImageIDs) { _, _ in
                // Closing the inspector cancels its validation task; validation is only
                // meaningful for the image that opened it.
                c2paDetailPresentation = nil
                c2paValidation = nil
            }
            .onChange(of: KeywordListsBackupService.shared.recoverableKeys.map(\.relativePath)) { _, keys in
                // A keyword list read empty at launch while a backup exists.
                // Offer to restore — once per launch, and never auto-write.
                if !keys.isEmpty && !listRecoveryHandled {
                    listRecoveryHandled = true
                    listRecoveryAffectedNames = KeywordListsBackupService.shared.recoverableKeys.map(\.displayName)
                    isShowingListRecoveryPrompt = true
                }
            }
            .alert("Some keyword lists look empty", isPresented: $isShowingListRecoveryPrompt) {
                Button("Not Now", role: .cancel) { }
                Button("Restore…") { isShowingListBackups = true }
            } message: {
                Text("These lists came back empty, but local backups are available:\n\n\(listRecoveryAffectedNames.joined(separator: "\n"))\n\nYou can restore an earlier version.")
            }
            .alert(
                migrationRecoveryNotices.notice?.title ?? "Some data still needs updating",
                isPresented: Binding(
                    get: { migrationRecoveryNotices.notice != nil },
                    set: { if !$0 { migrationRecoveryNotices.dismiss() } }
                )
            ) {
                Button("OK") { migrationRecoveryNotices.dismiss() }
            } message: {
                Text(migrationRecoveryNotices.notice?.message ?? "")
            }
            .sheet(isPresented: $isShowingListBackups) {
                KeywordListBackupsSheet(
                    initialKey: KeywordListsBackupService.shared.recoverableKeys.first,
                    recoverableKeys: KeywordListsBackupService.shared.recoverableKeys
                )
            }
    }

    /// Cap sheets at 90% of the window so they don't reach the window's bottom edge.
    private var sheetMaxHeight: CGFloat? {
        windowContentHeight > 0 ? windowContentHeight * 0.9 : nil
    }

    private var contentBase: some View {
        mainContent
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { windowContentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, newValue in
                            windowContentHeight = newValue
                        }
                }
            )
            .toolbar { toolbarContent }
            .navigationTitle(browserViewModel.currentFolderName ?? "Aagedal Photo Agent")
            .modifier(ContentViewModifiers(
                panes: panes,
                browserViewModel: browserViewModel,
                metadataViewModel: metadataViewModel,
                ftpViewModel: ftpViewModel,
                faceRecognitionViewModel: faceRecognitionViewModel,
                settingsViewModel: settingsViewModel,
                importViewModel: importViewModel,
                mainViewMode: mainViewMode,
                comparisonFocusedURL: { comparisonFocusedURL },
                commandRouter: commandRouter,
                loadTechnicalMetadata: loadTechnicalMetadata,
                performAfterMetadataFlush: performAfterBrowserEditorCommit,
                selectAdjacentAnalysisImage: selectAdjacentAnalysisImage(offset:),
                technicalMetadataCache: $technicalMetadataCache,
                technicalMetadata: $technicalMetadata
            ))
            // Single source of truth for the develop-editor gate (multiple enter/exit sites set
            // `mainViewMode`). While editing, suppress speculative full-screen prefetch — its
            // ImageIO XMP parsing races the editor's concurrent sidecar write — and tighten the
            // edited-image cache to relieve the IOSurface memory pressure that amplifies the fault.
            .onChange(of: mainViewMode) { oldMode, mode in
                // Compare rates its focused photo; keep the Browser selection (and metadata
                // editor) on it even when that rating takes it out of the filter.
                for pane in panes.panes {
                    pane.keepsSelectionThroughFilterChanges = (mode == .comparison)
                }
                let editing = (mode == .editing)
                browserViewModel.fullScreenImageCache.setPrefetchSuppressed(editing)
                browserViewModel.fullScreenImageCache.setEditingMemoryProfile(editing)
                // Develop shows the live Metal scope and no longer publishes a CPU scope image,
                // so the browse scope must load its own source again when the editor closes.
                if oldMode == .editing, !editing {
                    reloadBrowseScopeImage()
                }
            }
            .onChange(of: mainViewMode) { oldMode, newMode in
                let oldUsesFocusedWorkspace = oldMode == .caption || oldMode == .imageAnalysis || oldMode == .comparison
                let newUsesFocusedWorkspace = newMode == .caption || newMode == .imageAnalysis || newMode == .comparison
                if !oldUsesFocusedWorkspace, newUsesFocusedWorkspace {
                    navigationSplitViewVisibilityBeforeAnalysis = navigationSplitViewVisibility
                    navigationSplitViewVisibility = .detailOnly
                } else if oldUsesFocusedWorkspace, !newUsesFocusedWorkspace {
                    navigationSplitViewVisibility = navigationSplitViewVisibilityBeforeAnalysis ?? .all
                    navigationSplitViewVisibilityBeforeAnalysis = nil
                }
            }
            .onChange(of: importViewModel.isImporting) { _, isImporting in
                BackgroundOperationMonitor.shared.isImporting = isImporting
            }
            .onChange(of: ftpViewModel.isUploading) { _, isUploading in
                BackgroundOperationMonitor.shared.isUploading = isUploading
            }
            .onChange(of: ftpViewModel.isRendering) { _, isRendering in
                BackgroundOperationMonitor.shared.isRenderingForUpload = isRendering
            }
    }

    private var contentWithSheets: some View {
        contentBase
            .sheet(item: Binding(
                get: { metadataViewModel.voiceMemoVariablePreview },
                set: { newValue in
                    if newValue == nil, let current = metadataViewModel.voiceMemoVariablePreview {
                        metadataViewModel.cancelVoiceMemoVariablePreview(current.id)
                    }
                }
            )) { preview in
                VoiceMemoVariablePreviewView(
                    preview: preview,
                    onConfirm: { metadataViewModel.confirmVoiceMemoVariablePreview(preview.id) },
                    onCancel: { metadataViewModel.cancelVoiceMemoVariablePreview(preview.id) }
                )
            }
            .sheet(isPresented: $isShowingVoiceMemoBatch) {
                CaptionVoiceMemoBatchTranscriptionView(
                    model: voiceMemoBatchModel,
                    reviewOrSaveBusy: metadataViewModel.isSaving || metadataViewModel.isProcessingFolder,
                    providerBusy: FFmpegWhisperSetupModel.shared.isTranscribing,
                    onClose: { isShowingVoiceMemoBatch = false },
                    onReset: { prepareSelectedVoiceMemoBatch(imageURLs: voiceMemoBatchModel.selectedImageURLs,
                        languageIdentifier: voiceMemoBatchModel.selectedLanguageIdentifier) },
                    onSelectLanguage: { language in
                        prepareSelectedVoiceMemoBatch(imageURLs: voiceMemoBatchModel.selectedImageURLs,
                            languageIdentifier: language)
                    }
                )
            }
            .sheet(isPresented: $isShowingPrimaryDevelopRecovery) {
                PrimaryDevelopRecoveryHost(viewModel: metadataViewModel)
            }
            .sheet(isPresented: $isShowingVariableRecovery) {
                VariableConflictRecoveryHost(viewModel: metadataViewModel)
            }
            .sheet(isPresented: $isShowingSaveTemplateName, onDismiss: {
                // Template palette → Save New… ends here; hand Caption its field focus (and
                // Tab traversal) back the way closing the palette does.
                if mainViewMode == .caption { commandRouter.send(.restoreCaptionEditorFocus) }
            }) { saveTemplateSheet }
            .sheet(isPresented: $isShowingSaveDevelopTemplateName) { saveDevelopTemplateSheet }
            .sheet(item: $ftpUploadItem) { item in
                FTPUploadView(
                    viewModel: ftpViewModel,
                    files: item.urls,
                    hasC2PASigningCertificate: settingsViewModel.c2paHasCertificate
                        && C2PASigningService.isAvailable,
                    readService: browserViewModel.metadataReadService,
                    writeEngine: browserViewModel.writeEngine,
                    inMemoryCameraRaw: browserViewModel.currentCameraRawSettings,
                    thumbnailService: browserViewModel.thumbnailService,
                    onStartUpload: { ftpUploadItem = nil }
                )
            }
            .sheet(isPresented: $ftpViewModel.isShowingServerForm) {
                FTPServerForm(viewModel: ftpViewModel)
            }
            .sheet(isPresented: $isShowingDeadlineStagingActivity) {
                ActivityHistoryView(
                    history: activityHistory,
                    faceViewModel: faceRecognitionViewModel,
                    transcriptionModel: voiceMemoBatchModel,
                    receiptLibrary: deliveryReceiptLibrary,
                    workflowActivity: deliveryWorkflowActivity,
                    onResumeWorkflow: { workflowIdentifier in
                        await resumeDeadlineWorkflow(workflowIdentifier)
                    }
                )
            }
            .sheet(item: $advancedExportSession, onDismiss: {
                guard let request = pendingAdvancedExportRequest else { return }
                pendingAdvancedExportRequest = nil
                renderAndSaveEditedFolder(
                    urls: request.urls,
                    configurations: request.configurations
                )
            }) { session in
                AdvancedExportView(
                    session: session,
                    initialConfiguration: advancedExportConfiguration
                ) { configurations in
                    if let primaryConfiguration = configurations.first {
                        applyAdvancedExportConfiguration(primaryConfiguration)
                    }
                    pendingAdvancedExportRequest = AdvancedExportRequest(
                        urls: session.items.map(\.sourceURL),
                        configurations: configurations
                    )
                    advancedExportSession = nil
                }
            }
            .sheet(isPresented: $isShowingImport) { importSheet }
            .sheet(isPresented: $isShowingWebImport) {
                WebImportView { folder in browserViewModel.loadFolder(url: folder) }
            }
            .sheet(item: Bindable(browserViewModel).batchRenameSheetRequest) { request in
                BatchRenameSheet(
                    request: request,
                    executionQuiescence: BatchRenameExecutionQuiescence(
                        prepare: {
                            let workspace = mainViewMode
                            let selection = browserViewModel.selectedImageIDs
                            let isCurrent: @MainActor @Sendable () -> Bool = {
                                mainViewMode == workspace
                                    && browserViewModel.currentFolderURL == request.folderURL
                                    && browserViewModel.selectedImageIDs == selection
                                    && browserViewModel.batchRenameSheetRequest?.id == request.id
                            }
                            try await CaptionWorkspaceFlushCoordinator.shared.prepareForTransition(
                                hasLiveEditor: workspace == .caption || workspace == .metadataReview,
                                isCurrent: isCurrent
                            )
                            browserViewModel.beginRenameQuiescence()
                            do {
                                try await faceRecognitionViewModel.quiesceScanForRename(
                                    in: request.folderURL
                                )
                                try Task.checkCancellation()
                                guard isCurrent() else { throw CancellationError() }
                            } catch {
                                browserViewModel.endRenameQuiescence()
                                faceRecognitionViewModel.endRenameQuiescence(in: request.folderURL)
                                if error is CancellationError { throw error }
                                throw BatchRenameExecutionQuiescenceError.faceScan(
                                    error.localizedDescription
                                )
                            }
                            do {
                                try await analysisWorkspaceModel.beginRenameQuiescence(
                                    in: request.folderURL
                                )
                            } catch {
                                browserViewModel.endRenameQuiescence()
                                faceRecognitionViewModel.endRenameQuiescence(
                                    in: request.folderURL
                                )
                                throw BatchRenameExecutionQuiescenceError.analysis(
                                    error.localizedDescription
                                )
                            }
                            if Task.isCancelled || !isCurrent() {
                                defer {
                                    browserViewModel.endRenameQuiescence()
                                    faceRecognitionViewModel.endRenameQuiescence(in: request.folderURL)
                                }
                                try await analysisWorkspaceModel.cancelRenameQuiescenceBeforeExecution()
                                throw CancellationError()
                            }
                        },
                        complete: { completion in
                            defer {
                                faceRecognitionViewModel.endRenameQuiescence(
                                    in: request.folderURL
                                )
                            }
                            switch completion {
                            case .succeeded(let mappings):
                                do {
                                    try await analysisWorkspaceModel.finishRenameQuiescence(
                                        using: mappings
                                    )
                                } catch {
                                    throw BatchRenameExecutionQuiescenceError.analysis(
                                        error.localizedDescription
                                    )
                                }
                            case .abortedBeforeExecution:
                                defer { browserViewModel.endRenameQuiescence() }
                                do {
                                    try await analysisWorkspaceModel
                                        .cancelRenameQuiescenceBeforeExecution()
                                } catch {
                                    throw BatchRenameExecutionQuiescenceError.analysis(
                                        error.localizedDescription
                                    )
                                }
                            case .executionFailed:
                                await analysisWorkspaceModel.invalidateAfterRenameExecutionFailure()
                            }
                        }
                    ),
                    onSuccess: { presentation, reassociation in
                        for mapping in presentation.mappings {
                            technicalMetadataCache.removeValue(forKey: mapping.sourceURL)
                            technicalMetadataCache.removeValue(forKey: mapping.destinationURL)
                        }
                        let destinations = Dictionary(uniqueKeysWithValues: presentation.mappings.map {
                            ($0.sourceURL.standardizedFileURL, $0.destinationURL.standardizedFileURL)
                        })
                        comparisonImages = comparisonImages.map { image in
                            guard let destination = destinations[image.url.standardizedFileURL] else {
                                return image
                            }
                            return ImageFile(url: destination, relocating: image)
                        }
                        comparisonRenameEvent = ComparisonRenameEvent(mappings: presentation.mappings)
                        // Keep the sheet open when app references need review so its
                        // reassociation report stays visible.
                        browserViewModel.applySuccessfulRename(
                            presentation,
                            dismissSheet: reassociation.succeeded
                        )
                        faceRecognitionViewModel.loadFaceData(
                            for: request.folderURL,
                            cleanupPolicy: settingsViewModel.faceCleanupPolicy
                        )
                        if !reassociation.succeeded,
                           browserViewModel.currentFolderURL?.standardizedFileURL
                            == request.folderURL.standardizedFileURL {
                            browserViewModel.loadFolder(
                                url: request.folderURL,
                                addToOpenFolders: false
                            )
                        }
                    },
                    onFailureOrCancellation: { result in
                        for item in request.items {
                            technicalMetadataCache.removeValue(forKey: item.sourceImageURL)
                        }
                        for bundle in result.bundles {
                            if let destination = bundle.destinationImageURL {
                                technicalMetadataCache.removeValue(forKey: destination)
                            }
                        }
                        for residual in result.residuals {
                            technicalMetadataCache.removeValue(forKey: residual.expectedSourceURL)
                            technicalMetadataCache.removeValue(forKey: residual.intendedDestinationURL)
                            if let current = residual.currentURL {
                                technicalMetadataCache.removeValue(forKey: current)
                            }
                        }
                        browserViewModel.recoverAfterRenameFailure(result, request: request)
                    }
                )
            }
            .sheet(item: $backupEditedFolderItem) { item in
                BackupEditedFilesSheet(
                    sourceFolder: item.url,
                    onDismiss: { backupEditedFolderItem = nil }
                )
            }
            .sheet(item: $c2paDetailPresentation) { presentation in
                C2PADetailSheet(
                    imageURL: presentation.imageURL,
                    readService: browserViewModel.metadataReadService,
                    initialValidation: c2paValidation,
                    onValidationChanged: { c2paValidation = $0 }
                )
            }
    }

    private var contentWithAlerts: some View {
        contentWithSheets
            .alert("C2PA Protected Images", isPresented: $isShowingWriteAllC2PAWarning) {
                Button("Cancel", role: .cancel) { }
                Button("Skip C2PA") {
                    performAfterCaptionFlush {
                        metadataViewModel.writeAllPendingChanges(
                            in: browserViewModel.currentFolderURL,
                            images: browserViewModel.images,
                            skipC2PA: true
                        )
                    }
                }
                Button("Write Anyway") {
                    performAfterCaptionFlush {
                        metadataViewModel.writeAllPendingChanges(
                            in: browserViewModel.currentFolderURL,
                            images: browserViewModel.images,
                            skipC2PA: false
                        )
                    }
                }
            } message: {
                let count = pendingWriteAllC2PACount
                let suffix = count == 1 ? "image has" : "images have"
                Text("\(count) pending \(suffix) C2PA content credentials in this folder. Writing metadata will invalidate the authenticity chain.")
            }
            .imageDeletionConfirmation(
                viewModel: browserViewModel,
                isActiveHost: !browserViewModel.isFullScreen
            )
            // Sidebar folder dialogs: the folder tree rows act on the sidebar's pane (always the
            // primary one), so these must too — not the active pane, or they never appear in split view.
            .alert("Move Folder to Trash", isPresented: Bindable(sidebarViewModel).showTrashSubfolderConfirmation) {
                Button("Cancel", role: .cancel) {
                    sidebarViewModel.pendingTrashSubfolderURL = nil
                }
                Button("Move to Trash", role: .destructive) {
                    sidebarViewModel.trashPendingSubfolder()
                }
            } message: {
                if let url = sidebarViewModel.pendingTrashSubfolderURL {
                    Text("Are you sure you want to move \"\(url.lastPathComponent)\" and all its contents to the Trash?")
                }
            }
            .sheet(isPresented: Bindable(sidebarViewModel).showRenameSubfolderAlert) {
                RenameFolderSheet(viewModel: sidebarViewModel)
            }
            .alert("New Subfolder", isPresented: Bindable(sidebarViewModel).showNewSubfolderAlert) {
                TextField("Name", text: Bindable(sidebarViewModel).newSubfolderName)
                Button("Cancel", role: .cancel) {
                    sidebarViewModel.pendingNewSubfolderParentURL = nil
                }
                Button("Create") {
                    sidebarViewModel.createPendingSubfolder()
                }
            } message: {
                Text("Enter a name for the new subfolder.")
            }
            .alert("Reset All Edits", isPresented: Bindable(browserViewModel).showResetEditsConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    let affected = browserViewModel.selectedImageIDs
                    browserViewModel.resetAllEditsOnSelected()
                    // If the live edit session is showing image(s) that were just reset,
                    // clear their CRS in memory too — otherwise the develop editor keeps
                    // (or reloads) the stale edits until the async XMP rewrite lands.
                    if !metadataViewModel.selectedURLs.isEmpty,
                       metadataViewModel.selectedURLs.allSatisfy({ affected.contains($0) }) {
                        metadataViewModel.resetCameraRawEdits()
                    }
                }
            } message: {
                let count = browserViewModel.selectedImageIDs.count
                Text("Reset camera raw edits and crop on \(count) \(count == 1 ? "image" : "images")? This cannot be undone.")
            }
            .alert("Remove All IPTC Metadata", isPresented: Bindable(browserViewModel).showRemoveIPTCConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Remove", role: .destructive) {
                    browserViewModel.removeIPTCFromImageFiles { [self] in
                        reloadMetadataForSelection()
                    }
                }
            } message: {
                let count = browserViewModel.removeIPTCSelectedURLs.count
                Text("Remove all IPTC and XMP metadata from \(count) \(count == 1 ? "image" : "images")? This writes directly to the files and cannot be undone.")
            }
            .confirmationDialog(
                "Remove All IPTC Metadata",
                isPresented: Bindable(browserViewModel).showRemoveIPTCSidecarChoice,
                titleVisibility: .visible
            ) {
                Button("Remove from Image Files Only", role: .destructive) {
                    browserViewModel.removeIPTCFromImageFiles { [self] in
                        reloadMetadataForSelection()
                    }
                }
                Button("Delete XMP Sidecars Only", role: .destructive) {
                    browserViewModel.removeIPTCFromXMPSidecars { [self] in
                        reloadMetadataForSelection()
                    }
                }
                Button("Remove from Both", role: .destructive) {
                    browserViewModel.removeIPTCFromBoth { [self] in
                        reloadMetadataForSelection()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let count = browserViewModel.removeIPTCSelectedURLs.count
                Text("Some of the \(count) selected \(count == 1 ? "image has" : "images have") an XMP sidecar file. Where do you want to remove metadata from?")
            }
    }

    private var contentWithOverlay: some View {
        contentWithAlerts
            .overlay {
                if isShowingTemplatePalette {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeTemplatePalette(restoringGridFocus: true)
                        }
                        .onAppear {
                            templateViewModel.loadTemplates()
                        }
                    TemplatePaletteView(
                        templates: templateViewModel.templates,
                        onApply: { template, append in
                            let resolvedAppend = captionTemplateAppendOverride ?? append
                            closeTemplatePalette(restoringGridFocus: true)
                            // Presenting the picker is read-only and stays reachable during
                            // recovery. Applying a choice still crosses the persistence barrier.
                            performAfterCaptionFlush {
                                applyTemplate(template, append: resolvedAppend)
                            }
                        },
                        onSaveNew: {
                            closeTemplatePalette(restoringGridFocus: false)
                            performAfterCaptionFlush {
                                isShowingSaveTemplateName = true
                            }
                        },
                        onDismiss: {
                            closeTemplatePalette(restoringGridFocus: true)
                        }
                    )
                } else if isShowingDevelopTemplatePalette {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeDevelopTemplatePalette()
                        }
                        .onAppear {
                            developTemplateViewModel.loadTemplates()
                        }
                    DevelopTemplatePaletteView(
                        templates: developTemplateViewModel.templates,
                        onApply: { template in
                            commandRouter.send(.applyDevelopTemplate(template))
                            closeDevelopTemplatePalette()
                        },
                        onSaveNew: {
                            closeDevelopTemplatePalette()
                            saveDevelopTemplateIncludesCrop = true
                            isShowingSaveDevelopTemplateName = true
                        },
                        onDismiss: {
                            closeDevelopTemplatePalette()
                        }
                    )
                }
            }
    }

    private var contentWithFileOperationHandlers: some View {
        contentWithOverlay
            .onChange(of: commandRouter.latestDelivery) { _, delivery in
                guard let delivery, !CaptionWorkspaceFlushCoordinator.shared.isTransitioning,
                      !mainViewMode.suppressesHiddenSelectionCommand(delivery.command) else { return }
                if browserViewModel.isCurrentFolderUnavailable, delivery.command.requiresAvailableFolder { return }
                if delivery.command.actsOnBrowserSelection {
                    browserViewModel.collapseSelectionToFullScreenImage()
                }
                switch delivery.command {
                case .renderSelected:
                    let urls = browserViewModel.selectedImages.map(\.url)
                    renderAndSaveEditedFolder(urls: urls)
                case .advancedExportSelected:
                    showAdvancedExportSelected()
                case .renderAll:
                    renderAndSaveEditedFolder()
                case .saveAsJPEG:
                    saveSelectedAs(format: .jpeg)
                case .saveAsPNG:
                    saveSelectedAs(format: .png)
                case .archiveRAW(let format):
                    archiveSelectedRAW(as: format)
                case .renameSelected:
                    // Commit the Browser metadata panel first: a rename moves the files the
                    // panel's unsaved edits are keyed to.
                    performAfterMetadataFileOperation { browserViewModel.renameSelected() }
                case .duplicateSelected:
                    performAfterCaptionFlush { browserViewModel.duplicateSelectedImages() }
                case .resetAllEdits:
                    performAfterCaptionFlush { browserViewModel.confirmResetAllEdits() }
                case .removeAllIPTC:
                    performAfterCaptionFlush { browserViewModel.confirmRemoveAllIPTC() }
                case .showWebImport:
                    isShowingWebImport = true
                case .showImport:
                    importViewModel.prepareForNewSession()
                    isShowingImport = true
                case .openInInternalEditor:
                    openEditWorkspace()
                case .uploadSelected:
                    let urls = browserViewModel.selectedImages.map(\.url)
                    if !urls.isEmpty {
                        ftpUploadItem = FTPUploadItem(urls: urls)
                    }
                case .uploadAll:
                    let urls = browserViewModel.images.map(\.url)
                    if !urls.isEmpty {
                        ftpUploadItem = FTPUploadItem(urls: urls)
                    }
                case .openFolder, .openRecentFolder, .setRating, .setLabel,
                     .selectPreviousImage, .selectNextImage,
                     .rotateClockwise, .rotateCounterclockwise,
                     .backupEditedFiles, .backupEditedFilesForFolder,
                     .openInExternalEditor,
                     .deleteSelected, .moveRejectedToFolder,
                     .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
                     .setScopeMode, .toggleGamutClipping,
                     .processVariablesSelected, .processVariablesAll, .transcribeVoiceMemosSelected,
                     .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
                     .writeAllPendingMetadata, .openCaptionWorkspace,
                     .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
                     .showVariableReference, .showRawMetadata, .showStructuredKeywords,
                     .showKnownPeopleDatabase, .registerOpenFolderForSidebar,
                     .restoreCaptionEditorFocus:
                    break
                }
            }
            .onChange(of: browserViewModel.selectedImageIDs) {
                cancelAdvancedExportPreparation()
            }
    }

    private var contentWithNotificationHandlers: some View {
        contentWithFileOperationHandlers
            .modifier(SafetyAndCullingHandlers(
                browserViewModel: browserViewModel,
                commandRouter: commandRouter,
                mainViewMode: mainViewMode,
                performAfterMetadataFlush: performAfterCaptionFlush,
                backupEditedFolderItem: $backupEditedFolderItem
            ))
            .onReceive(NotificationCenter.default.publisher(for: .importStarted)) { notification in
                handleImportStarted(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .importCompleted)) { notification in
                handleImportCompleted(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .templatesStorageDidChange)) { _ in
                templateViewModel.loadTemplates()
                developTemplateViewModel.loadTemplates()
            }
            .onChange(of: commandRouter.latestDelivery) { _, delivery in
                guard let delivery, !CaptionWorkspaceFlushCoordinator.shared.isTransitioning,
                      !mainViewMode.suppressesHiddenSelectionCommand(delivery.command) else { return }
                switch delivery.command {
                case .processVariablesSelected:
                    if metadataViewModel.hasRetainedVariableWrites {
                        // Command-P is also the natural recovery gesture. It must not pass
                        // through the lifecycle gate held by the request it needs to retry.
                        metadataViewModel.retryVariableWrites()
                    } else {
                        let selected = browserViewModel.selectedImages
                        guard !selected.isEmpty else { break }
                        performAfterCaptionFlush { metadataViewModel.processVariablesForImages(selected) }
                    }
                case .processVariablesAll:
                    if metadataViewModel.hasRetainedVariableWrites {
                        metadataViewModel.retryVariableWrites()
                    } else {
                        performAfterCaptionFlush {
                            metadataViewModel.processVariablesInFolder(images: browserViewModel.images)
                        }
                    }
                case .showTemplatePalette:
                    switch mainViewMode.templateCommandTarget {
                    case .metadata:
                        // Opening the palette does not change metadata. The selected action
                        // performs its own flush before applying or saving a template.
                        isShowingTemplatePalette = true
                    case .develop:
                        isShowingDevelopTemplatePalette = true
                    }
                case .applyTemplateShortcut(let slot):
                    switch mainViewMode.templateCommandTarget {
                    case .metadata:
                        performAfterCaptionFlush {
                            templateViewModel.withLoadedTemplates { templates in
                                guard let templates else {
                                    metadataViewModel.notice = MetadataPanelNotice(
                                        title: "Templates couldn’t be loaded",
                                        detail: [templateViewModel.errorMessage ?? "Template shortcut \(slot) was not applied."],
                                        severity: .warning)
                                    return
                                }
                                guard let template = templates.first(where: { $0.shortcutSlot == slot }) else {
                                    metadataViewModel.notice = MetadataPanelNotice(
                                        title: "No template is assigned to shortcut \(slot)",
                                        detail: ["Assign a shortcut in the template editor."],
                                        severity: .info)
                                    return
                                }
                                applyTemplate(template)
                                restoreGridFocus()
                            }
                        }
                    case .develop:
                        developTemplateViewModel.loadTemplates { templates in
                            if let template = templates.first(where: { $0.shortcutSlot == slot }) {
                                commandRouter.send(.applyDevelopTemplate(template))
                            }
                        }
                    }
                case .writeAllPendingMetadata:
                    requestWriteAllPendingMetadata()
                case .transcribeVoiceMemosSelected:
                    prepareSelectedVoiceMemoBatch()
                case .openCaptionWorkspace:
                    openCaptionWorkspace()
                case .renderAndSignSelected:
                    renderAndSignSelected()
                case .copyIPTCMetadata:
                    copyIPTCMetadata()
                case .pasteIPTCMetadata:
                    pasteIPTCMetadata()
                case .showStructuredKeywords:
                    openWindow(id: "structuredKeywords")
                case .showKnownPeopleDatabase:
                    // Settings → Known People can fire this from Caption, Analysis or Develop; leave them
                    // through their flush barriers like the toolbar toggle does.
                    leaveEditWorkspaceIfNeeded { openPeopleDatabase() }
                case .registerOpenFolderForSidebar(let url):
                    panes.panes[0].registerOpenFolderForSidebar(url)
                default:
                    break
                }
            }
    }

    private var contentWithStateHandlers: some View {
        contentWithNotificationHandlers
            .onChange(of: browserViewModel.isFullScreen) { _, isFullScreen in
                guard isFullScreen else { return }
                // Sync current editing state (including masks) to the ImageFile so the
                // fullscreen view has up-to-date local adjustments.
                if let url = metadataViewModel.selectedURLs.first,
                   metadataViewModel.selectedCount == 1,
                   let index = browserViewModel.urlToImageIndex[url] {
                    let editingCameraRaw = metadataViewModel.editingMetadata.cameraRaw
                    if editingCameraRaw != browserViewModel.images[index].cameraRawSettings {
                        browserViewModel.images[index].cameraRawSettings = editingCameraRaw
                    }
                }
                guard browserViewModel.fullScreenFaceContext == nil else { return }
                browserViewModel.fullScreenFaceContext = BrowserViewModel.FullScreenFaceContext(
                    faceRecognitionViewModel: faceRecognitionViewModel,
                    highlightedFaceID: nil,
                    navigationItems: nil,
                    onNavigateToFace: nil
                )
            }
            .fullScreenImagePresenter(
                viewModel: browserViewModel,
                scopeViewModel: scopeViewModel,
                canOpenComparison: fullScreenComparisonImages != nil,
                onRequestComparison: openComparisonFromFullScreen,
                onDismissed: {
                    if opensComparisonAfterFullScreenDismissal {
                        opensComparisonAfterFullScreenDismissal = false
                        mainViewMode = .comparison
                        return
                    }
                    guard opensEditWorkspaceAfterFullScreenDismissal else { return }
                    opensEditWorkspaceAfterFullScreenDismissal = false
                    openEditWorkspace()
                }
            )
            .cleanFeedPresenter(controller: CleanFeedController.shared, panes: panes)
            .task {
                await sidebarViewModel.loadFavorites()
                guard !Task.isCancelled else { return }
                sidebarViewModel.loadFavoriteTopLevelSubfolders()
            }
            .onAppear {
                templateViewModel.loadTemplates()
                developTemplateViewModel.loadTemplates()
                ftpViewModel.loadConnections()
                ftpViewModel.activityHistory = activityHistory
                BackgroundOperationMonitor.shared.isImporting = importViewModel.isImporting
                BackgroundOperationMonitor.shared.isUploading = ftpViewModel.isUploading
                BackgroundOperationMonitor.shared.isRenderingForUpload = ftpViewModel.isRendering
                MetadataEditorTerminationFlush.shared.register { try await commitBrowserMetadataEditor() }
                AnalysisWorkspaceTerminationFlush.shared.register(analysisWorkspaceModel)
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $navigationSplitViewVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 320, max: 800)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            // Face bar shown full-width for non-browser, non-editing modes
            if browserViewModel.hasImages, mainViewMode == .faceManagement {
                faceBar
                Divider()
            }

            switch mainViewMode {
            case .browser:
                browserAndMetadataPanel
            case .caption:
                CaptionWorkspaceView(
                    metadataViewModel: metadataViewModel,
                    browserViewModel: browserViewModel,
                    settingsViewModel: settingsViewModel,
                    deadlineProfile: MainViewMode.isDeadlineAvailable ? deadlineProfileLibrary.selectedProfile : nil,
                    initialFocusedField: pendingDeadlineCaptionField,
                    onApplyTemplate: { append in
                        captionTemplateAppendOverride = append
                        isShowingTemplatePalette = true
                    },
                    onClose: {
                        pendingDeadlineCaptionField = nil
                        mainViewMode = .browser
                        browserViewModel.shouldRestoreGridFocus = true
                    }
                )
            case .deadline:
                DeadlineWorkspaceView(
                    input: deadlineWorkspaceInput,
                    deliveryDependencies: deadlineDeliveryDependencies,
                    resumeWorkflowIdentifier: pendingDeadlineResumeWorkflowIdentifier,
                    onFixNext: handleDeadlineRemediation,
                    onManageProfiles: {
                        isShowingDeadlineProfileManager = true
                    },
                    onResumeWorkflowConsumed: { workflowIdentifier in
                        if pendingDeadlineResumeWorkflowIdentifier == workflowIdentifier {
                            pendingDeadlineResumeWorkflowIdentifier = nil
                        }
                    },
                    onClose: {
                        mainViewMode = .browser
                        browserViewModel.shouldRestoreGridFocus = true
                    }
                )
            case .metadataReview:
                MetadataReviewView(viewModel: browserViewModel)
            case .imageAnalysis:
                AnalysisWorkspaceView(
                    model: analysisWorkspaceModel,
                    folderImages: browserViewModel.sortedImages.filter(\.isImageFile),
                    thumbnailService: browserViewModel.thumbnailService,
                    onSelectImage: { image in
                        browserViewModel.selectedImageIDs = [image.url]
                        browserViewModel.lastClickedImageURL = image.url
                        analysisWorkspaceModel.requestOpenInCurrentWorkspace(image)
                    },
                    onOpenImportedProject: { folderURL in
                        openFolderInActivePane(folderURL, addToOpenFolders: true)
                        mainViewMode = .browser
                    },
                    onClose: {
                        mainViewMode = .browser
                        browserViewModel.shouldRestoreGridFocus = true
                    }
                )
            case .comparison:
                ComparisonWorkspaceView(
                    images: comparisonImages,
                    navigationImages: browserViewModel.visibleImages,
                    availableImages: browserViewModel.sortedImages.filter(\.isImageFile),
                    fullScreenImageCache: browserViewModel.fullScreenImageCache,
                    origin: comparisonOrigin,
                    initialLeftRepresentation: comparisonInitialLeftRepresentation,
                    liveSource: nil,
                    initialRightSource: nil,
                    allowsSourceReplacement: true,
                    allowsDeletion: true,
                    renameEvent: comparisonRenameEvent,
                    isRenaming: browserViewModel.batchRenameSheetRequest != nil,
                    onFocusedImageChange: { image in
                        comparisonFocusedURL = image.url
                        browserViewModel.selectedImageIDs = [image.url]
                        browserViewModel.lastClickedImageURL = image.url
                    },
                    onRequestDelete: { image in
                        browserViewModel.selectedImageIDs = [image.url]
                        browserViewModel.lastClickedImageURL = image.url
                        performAfterCaptionFlush { browserViewModel.confirmDeleteSelectedImages() }
                    },
                    onClose: { sourceURLs, focusedURL in
                        comparisonFocusedURL = nil
                        browserViewModel.selectedImageIDs = sourceURLs
                        browserViewModel.lastClickedImageURL = focusedURL ?? sourceURLs.first
                        mainViewMode = .browser
                        if comparisonOrigin == .fullScreen, focusedURL != nil {
                            browserViewModel.shouldRestoreGridFocus = false
                            Task { @MainActor in
                                // Let SwiftUI remove Compare and restore Browser before creating
                                // a new dedicated key window for the returning full-screen image.
                                await Task.yield()
                                guard mainViewMode == .browser else { return }
                                browserViewModel.isFullScreen = true
                            }
                        } else {
                            browserViewModel.shouldRestoreGridFocus = true
                        }
                    }
                )
            case .editing:
                editingWorkspaceView
            case .faceManagement:
                ExpandedFaceManagementView(
                    viewModel: faceRecognitionViewModel,
                    settingsViewModel: settingsViewModel,
                    selectionState: faceSelectionState,
                    folderURL: browserViewModel.currentFolderURL,
                    images: browserViewModel.images,
                    onLabelImages: { urls, label in
                        browserViewModel.selectedImageIDs = urls
                        browserViewModel.setLabel(label)
                    },
                    onClose: { mainViewMode = .browser },
                    onPhotosDeleted: { trashedURLs in
                        browserViewModel.images.removeAll { trashedURLs.contains($0.url) }
                        browserViewModel.selectedImageIDs.subtract(trashedURLs)
                    },
                    onOpenFullScreen: { imageURL, highlightedFaceID in
                        browserViewModel.selectedImageIDs = [imageURL]
                        browserViewModel.lastClickedImageURL = imageURL

                        let navigationItems: [BrowserViewModel.FullScreenFaceNavigationItem]? = {
                            guard let highlightedFaceID,
                                  let selectedFace = faceRecognitionViewModel.face(byID: highlightedFaceID),
                                  let groupID = selectedFace.groupID,
                                  let group = faceRecognitionViewModel.group(byID: groupID) else {
                                return nil
                            }

                            var orderedItems: [BrowserViewModel.FullScreenFaceNavigationItem] = []
                            var indexByImageURL: [URL: Int] = [:]

                            for face in faceRecognitionViewModel.faces(in: group) {
                                if let existingIndex = indexByImageURL[face.imageURL] {
                                    if face.id == highlightedFaceID {
                                        orderedItems[existingIndex] = BrowserViewModel.FullScreenFaceNavigationItem(
                                            imageURL: face.imageURL,
                                            faceID: face.id
                                        )
                                    }
                                    continue
                                }
                                indexByImageURL[face.imageURL] = orderedItems.count
                                orderedItems.append(BrowserViewModel.FullScreenFaceNavigationItem(
                                    imageURL: face.imageURL,
                                    faceID: face.id
                                ))
                            }

                            if !orderedItems.contains(where: { $0.imageURL == imageURL }) {
                                orderedItems.insert(BrowserViewModel.FullScreenFaceNavigationItem(
                                    imageURL: imageURL,
                                    faceID: highlightedFaceID
                                ), at: 0)
                            }
                            return orderedItems.isEmpty ? nil : orderedItems
                        }()

                        browserViewModel.fullScreenFaceContext = BrowserViewModel.FullScreenFaceContext(
                            faceRecognitionViewModel: faceRecognitionViewModel,
                            highlightedFaceID: highlightedFaceID,
                            navigationItems: navigationItems,
                            onNavigateToFace: { faceID in
                                guard let faceID else { return }
                                faceSelectionState.selectFace(faceID)
                            }
                        )
                        browserViewModel.isFullScreen = true
                    }
                )
            case .peopleDatabase:
                ExpandedKnownPeopleView(
                    onClose: { closePeopleDatabase() }
                )
            }
        }
    }

    // MARK: - People Database Navigation

    private func openPeopleDatabase() {
        if mainViewMode != .peopleDatabase {
            lastNonPeopleViewMode = mainViewMode
        }
        mainViewMode = .peopleDatabase
    }

    private func closePeopleDatabase() {
        mainViewMode = lastNonPeopleViewMode
    }

    private func togglePeopleDatabase() {
        if mainViewMode == .peopleDatabase {
            closePeopleDatabase()
        } else {
            leaveEditWorkspaceIfNeeded {
                openPeopleDatabase()
            }
        }
    }

    private func toggleEditWorkspace() {
        if mainViewMode == .editing {
            leaveEditWorkspaceIfNeeded {
                mainViewMode = .browser
                browserViewModel.shouldRestoreGridFocus = true
            }
            return
        }
        openEditWorkspace()
    }

    /// Toolbar and workspace-menu transitions live outside `EditWorkspaceView`, so they cannot use
    /// its local exit button. Route them through the same registered flush handler and leave the
    /// editor visible when persistence fails.
    private func leaveEditWorkspaceIfNeeded(_ transition: @escaping @MainActor () -> Void) {
        performAfterBrowserEditorCommit {
            performAfterAnalysisClose {
                performAfterDevelopFlush(reason: .workspaceExit, transition)
            }
        }
    }

    /// Analysis keeps its case editable after a failed save; leaving it from outside the
    /// workspace raises the same Retry Save / Discard / Cancel prompt as its Close button.
    private func performAfterAnalysisClose(_ transition: @escaping @MainActor () -> Void) {
        guard mainViewMode == .imageAnalysis else { transition(); return }
        analysisWorkspaceModel.requestClose(thenPerform: transition)
    }

    private func requestWriteAllPendingMetadata() {
        performAfterCaptionFlush {
            let c2paPending = browserViewModel.images.filter {
                $0.hasPendingMetadataChanges && $0.hasC2PA
            }
            if !c2paPending.isEmpty {
                pendingWriteAllC2PACount = c2paPending.count
                isShowingWriteAllC2PAWarning = true
            } else {
                metadataViewModel.writeAllPendingChanges(
                    in: browserViewModel.currentFolderURL,
                    images: browserViewModel.images
                )
            }
        }
    }

    /// Capture the command's target context before suspending for durable metadata. Folder or
    /// selection replacement abandons the command rather than applying it to a new target set.
    private func performAfterMetadataFileOperation(_ operation: @escaping @MainActor () -> Void) {
        let folder = browserViewModel.currentFolderURL
        let selection = browserViewModel.selectedImageIDs
        performAfterCaptionFlush {
            guard browserViewModel.currentFolderURL == folder,
                  browserViewModel.selectedImageIDs == selection else { return }
            Task { @MainActor in
                // Paste/Copy IPTC and file exports act on disk (or the editor) state: commit the
                // Browser panel's typed and unsaved edits first so they are neither lost nor stale.
                do { try await commitBrowserMetadataEditor() }
                catch { return }
                guard browserViewModel.currentFolderURL == folder,
                      browserViewModel.selectedImageIDs == selection else { return }
                operation()
            }
        }
    }

    /// Browser-mode counterpart of the Caption flush: captures the focused field's typed text
    /// and saves unsaved edits with the configured write mode, waiting for the write to finish.
    /// Literal variable tokens are kept as a pending draft rather than embedded.
    private func commitBrowserMetadataEditor() async throws {
        guard mainViewMode == .browser || mainViewMode == .faceManagement else { return }
        metadataViewModel.captureFocusedEditorText()
        // Quit, rename and Copy/Paste IPTC must also wait for saves already running, even when
        // the editor itself has nothing new to commit.
        await metadataViewModel.waitForPendingWrites()
        guard metadataViewModel.hasUnpersistedEditorChanges else { return }
        let editorURLs = metadataViewModel.selectedURLs
        if metadataViewModel.shouldDeferAutomaticCommitForVariables {
            let failure: String? = await withCheckedContinuation { continuation in
                metadataViewModel.keepUnresolvedVariablesAsPendingDraft { continuation.resume(returning: $0) }
            }
            await metadataViewModel.waitForPendingWrites()
            browserViewModel.refreshPendingStatusBatch(for: editorURLs)
            if let failure { throw CaptionWorkspaceFlushError.persistenceFailed(failure) }
            return
        }
        let mode = metadataViewModel.editorWriteMode(knownC2PAURLs: browserViewModel.c2paURLs(among: editorURLs))
        let result = await withCheckedContinuation { continuation in
            metadataViewModel.commitEditsReportingResult(mode: mode) { continuation.resume(returning: $0) }
        }
        await metadataViewModel.waitForPendingWrites()
        browserViewModel.refreshPendingStatusBatch(for: editorURLs)
        switch result {
        case .succeeded: return
        case .failed(let message), .cancelled(let message):
            throw CaptionWorkspaceFlushError.persistenceFailed(message)
        }
    }

    private func resumeDeadlineWorkflow(_ identifier: UUID) async -> Bool {
        guard MainViewMode.isDeadlineAvailable else { return false }
        let workspace = mainViewMode
        let folder = browserViewModel.currentFolderURL
        let selection = browserViewModel.selectedImageIDs
        do {
            try await CaptionWorkspaceFlushCoordinator.shared.prepareForTransition(
                hasLiveEditor: workspace == .caption || workspace == .metadataReview,
                isCurrent: {
                    mainViewMode == workspace
                        && browserViewModel.currentFolderURL == folder
                        && browserViewModel.selectedImageIDs == selection
                }
            )
            pendingDeadlineResumeWorkflowIdentifier = identifier
            isShowingDeadlineStagingActivity = false
            mainViewMode = .deadline
            return true
        } catch is CancellationError {
            return false
        } catch {
            if workspace == .metadataReview { browserViewModel.errorMessage = error.localizedDescription }
            else { metadataViewModel.saveError = error.localizedDescription }
            return false
        }
    }

    /// Folder switches, folder closes and workspace exits leave the Browser editor's photos.
    /// Save them first — with the editor's own mode and folder, before the browser arrays are
    /// replaced — then run the usual flush. A failed write keeps a pending draft and continues.
    /// When nothing durable can hold the edit (a read-only card), ask whether to discard it and
    /// continue or stay, so Close Folder, Open Folder and workspace exits are never a dead end.
    private func performAfterBrowserEditorCommit(_ operation: @escaping @MainActor () -> Void) {
        let workspace = mainViewMode
        guard workspace == .browser || workspace == .faceManagement,
              !CaptionWorkspaceFlushCoordinator.shared.isTransitioning else {
            performAfterCaptionFlush(operation)
            return
        }
        metadataViewModel.captureFocusedEditorText()
        guard metadataViewModel.hasUnpersistedEditorChanges || metadataViewModel.isSaving else {
            performAfterCaptionFlush(operation)
            return
        }
        guard !isCommittingBrowserEditor else { return }
        isCommittingBrowserEditor = true
        Task { @MainActor in
            defer { isCommittingBrowserEditor = false }
            let editorURLs = metadataViewModel.selectedURLs
            let outcome = await commitDepartingBrowserEditor()
            browserViewModel.refreshPendingStatusBatch(for: editorURLs)
            switch EditorBoundaryDecision.resolve(outcome, canStay: true) {
            case .proceed(let attention):
                guard mainViewMode == workspace else { return }
                performAfterCaptionFlush(operation)
                // After the operation: a folder load clears the browser's error banner.
                if let attention { browserViewModel.errorMessage = attention }
            case .askToDiscard(let message):
                metadataViewModel.saveError = message
                guard confirmDiscardAfterFailedSave(message) else { return }
                metadataViewModel.discardUnsavedEditorChanges()
                guard mainViewMode == workspace else { return }
                performAfterCaptionFlush(operation)
            }
        }
    }

    /// Waits for saves already running (they may carry these edits, and History Only drafts
    /// finish asynchronously), then saves whatever is still unsaved and waits for it too.
    private func commitDepartingBrowserEditor() async -> EditorBoundaryCommitOutcome {
        await metadataViewModel.waitForPendingWrites()
        metadataViewModel.captureFocusedEditorText()
        guard metadataViewModel.hasUnpersistedEditorChanges else { return .nothingToCommit }
        let editorURLs = metadataViewModel.selectedURLs
        if metadataViewModel.shouldDeferAutomaticCommitForVariables {
            let failure: String? = await withCheckedContinuation { continuation in
                metadataViewModel.keepUnresolvedVariablesAsPendingDraft { continuation.resume(returning: $0) }
            }
            guard let failure else { return .saved }
            return .failed(message: EditorBoundaryCommitOutcome.failureMessage(
                files: editorURLs.map(\.lastPathComponent).joined(separator: ", "), reason: failure))
        }
        let outcome = await withCheckedContinuation { continuation in
            metadataViewModel.commitDepartingEditor(
                knownC2PAURLs: browserViewModel.c2paURLs(among: editorURLs)
            ) { continuation.resume(returning: $0) }
        }
        await metadataViewModel.waitForPendingWrites()
        return outcome
    }

    private func confirmDiscardAfterFailedSave(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Metadata Edits Not Saved"
        alert.informativeText = message
        alert.addButton(withTitle: "Stay")
        alert.addButton(withTitle: "Discard Edits and Continue")
        alert.buttons.last?.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func performAfterCaptionFlush(_ operation: @escaping @MainActor () -> Void) {
        let coordinator = CaptionWorkspaceFlushCoordinator.shared
        guard !coordinator.isTransitioning else { return }
        let workspace = mainViewMode
        let hasLiveEditor = workspace == .caption || workspace == .metadataReview
        guard hasLiveEditor || coordinator.hasPendingPersistence else { operation(); return }
        let token: UUID
        do { token = try coordinator.reserveTransition() }
        catch { return }
        Task { @MainActor in
            do {
                try await coordinator.performReservedTransition(token, flush: {
                    if hasLiveEditor { try await coordinator.flushAsync() }
                    else { try await coordinator.flushQueuedPersistenceAsync() }
                }, operation: {
                    guard mainViewMode == workspace else { return }
                    operation()
                })
            } catch is CancellationError {
                // Admitted writes finish; cancellation abandons the requested transition.
            } catch {
                if workspace == .metadataReview {
                    browserViewModel.errorMessage = error.localizedDescription
                } else {
                    metadataViewModel.saveError = error.localizedDescription
                }
            }
        }
    }

    private func performAfterDevelopFlush(
        reason: DevelopVersionFlushReason,
        _ transition: @escaping @MainActor () -> Void
    ) {
        guard mainViewMode == .editing else { transition(); return }
        Task { @MainActor in
            let outcome = await DevelopVersionFlushCoordinator.shared.flush(reason)
            guard outcome == .succeeded, mainViewMode == .editing else { return }
            transition()
        }
    }

    private func openEditWorkspace() {
        if mainViewMode == .caption || mainViewMode == .metadataReview || mainViewMode == .imageAnalysis {
            leaveEditWorkspaceIfNeeded {
                mainViewMode = .browser
                openEditWorkspace()
            }
            return
        }
        if browserViewModel.selectedImageIDs.isEmpty,
           let firstVisible = browserViewModel.visibleImages.first(where: \.isImageFile) {
            browserViewModel.selectedImageIDs = [firstVisible.url]
            browserViewModel.lastClickedImageURL = firstVisible.url
        }
        // Don't open edit mode for non-image files (visible when "Show all files" is on)
        guard let selectedURL = browserViewModel.lastClickedImageURL ?? browserViewModel.selectedImageIDs.first,
              SupportedImageFormats.isSupported(url: selectedURL) else {
            return
        }

        // Full screen is a separate key, always-on-top NSWindow. Tear it down before
        // constructing Develop so the editor cannot activate behind it and contend for
        // focus/event monitors. FullScreenPresenter calls us back after orderOut.
        if browserViewModel.isFullScreen {
            opensEditWorkspaceAfterFullScreenDismissal = true
            browserViewModel.isFullScreen = false
            return
        }

        guard mainViewMode == .browser || mainViewMode == .faceManagement else {
            mainViewMode = .editing
            return
        }
        performAfterBrowserEditorCommit { mainViewMode = .editing }
    }

    private func prepareSelectedVoiceMemoBatch(imageURLs: [URL]? = nil, languageIdentifier: String? = nil) {
        // Right-click preserves an existing multi-selection. Freeze Browser order before any
        // association or provider check can suspend and the user can change selection.
        let urls = imageURLs ?? browserViewModel.visibleImages.filter {
            browserViewModel.selectedImageIDs.contains($0.url) && $0.isImageFile
        }.map(\.url)
        guard !voiceMemoBatchModel.isChecking, voiceMemoBatchPreparationTask == nil else { return }
        if voiceMemoBatchModel.isRunning {
            isShowingDeadlineStagingActivity = true
            return
        }
        let reviewBusy = metadataViewModel.isSaving || metadataViewModel.isProcessingFolder
        let setup = FFmpegWhisperSetupModel.shared
        let providerBusy = setup.isTranscribing
        // Withdraw the old confirmation synchronously before provider restoration suspends.
        // A language change must never leave the previous batch start button available.
        voiceMemoBatchModel.dismissConfirmation()
        voiceMemoBatchPreparationTask = Task {
            defer { voiceMemoBatchPreparationTask = nil }
            await setup.restoreSelections()
            let provider: AutomationVoiceTranscriptionBatchService.Provider?
            let languageTitle: String
            let selectedLanguage: String
            let languages: [WhisperTranscriptionLanguage.Option]
            switch setup.choice {
            case .appleSpeech:
                let requestedLocale = languageIdentifier.map { Locale(identifier: $0) } ?? .current
                let availability = await VoiceMemoTranscriptionService().availability(preferredLocale: requestedLocale)
                let locale = availability.selectedLocale ?? requestedLocale
                selectedLanguage = locale.identifier
                languages = availability.supportedLocales.map { .init(id: $0.identifier,
                    title: Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }.sorted { $0.title < $1.title }
                provider = availability.status == .installed ? .apple(locale) : nil
                languageTitle = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            case .whisper:
                selectedLanguage = languageIdentifier ?? setup.language
                languages = WhisperTranscriptionLanguage.options
                await ManagedWhisperSetupModel.shared.refresh()
                provider = WhisperTranscriptionLanguage.isValid(selectedLanguage) ? ManagedWhisperSetupModel.shared.provider(language: selectedLanguage,
                    useGPU: setup.useGPU, translate: setup.translate).map { .whisper($0) } : nil
                languageTitle = WhisperTranscriptionLanguage.title(for: selectedLanguage) + (setup.translate ? " · Translate into English" : " · Original language")
            case .customWhisper:
                selectedLanguage = languageIdentifier ?? setup.language
                languages = WhisperTranscriptionLanguage.options
                provider = WhisperTranscriptionLanguage.isValid(selectedLanguage) ? setup.provider(language: selectedLanguage).map { .whisper($0) } : nil
                languageTitle = WhisperTranscriptionLanguage.title(for: selectedLanguage) + (setup.translate ? " · Translate into English" : " · Original language")
            }
            if !reviewBusy, !providerBusy, provider != nil,
               (1...AutomationVoiceTranscriptionBatchService.maximumPhotos).contains(urls.count) {
                let associations = CaptionVoiceMemoAssociationService()
                for url in urls {
                    guard !Task.isCancelled else { return }
                    _ = try? await associations.associateAutomatically(imageURL: url)
                }
            }
            guard !Task.isCancelled else { return }
            await voiceMemoBatchModel.prepare(imageURLs: urls, provider: provider,
                providerTitle: setup.choice.title, languageTitle: languageTitle,
                languageIdentifier: selectedLanguage, availableLanguages: languages,
                reviewOrSaveBusy: reviewBusy, providerBusy: providerBusy)
            if !Task.isCancelled { isShowingVoiceMemoBatch = true }
        }
    }

    private func openCaptionWorkspace() {
        guard mainViewMode != .caption else { return }
        leaveEditWorkspaceIfNeeded {
            if !browserViewModel.selectedImages.contains(where: \.isImageFile),
               let firstVisible = browserViewModel.visibleImages.first(where: \.isImageFile) {
                browserViewModel.selectedImageIDs = [firstVisible.url]
                browserViewModel.lastClickedImageURL = firstVisible.url
            }
            guard browserViewModel.selectedImages.contains(where: \.isImageFile) else { return }
            mainViewMode = .caption
        }
    }

    private func openDeadlineWorkspace() {
        guard MainViewMode.isDeadlineAvailable, mainViewMode != .deadline else { return }
        leaveEditWorkspaceIfNeeded {
            if !browserViewModel.selectedImages.contains(where: \.isImageFile),
               let firstVisible = browserViewModel.visibleImages.first(where: \.isImageFile) {
                browserViewModel.selectedImageIDs = [firstVisible.url]
                browserViewModel.lastClickedImageURL = firstVisible.url
            }
            guard browserViewModel.selectedImages.contains(where: \.isImageFile) else { return }
            mainViewMode = .deadline
        }
    }

    /// Drives real workflow entry points with disposable paths supplied by the UI-test process.
    /// The explicit `--ui-testing` gate keeps this entirely inert for interactive launches.
    private func runUITestWorkflowIfRequested() async {
        let configuration = uiTestLaunchConfiguration
        guard configuration.isEnabled, let workflow = configuration.workflow else { return }

        if workflow == .importPreflight {
            guard let sourceURL = configuration.sourceURL,
                  let destinationURL = configuration.destinationURL else { return }
            importViewModel.prepareForNewSession()
            importViewModel.configuration.sourceURL = sourceURL
            importViewModel.configuration.destinationBaseURL = destinationURL
            importViewModel.configuration.importTitle = "UI Smoke Import"
            importViewModel.configuration.fileTypeFilter = .both
            importViewModel.configuration.conflictPolicy = .overwrite
            importViewModel.configuration.createSubFolders = false
            importViewModel.configuration.applyMetadata = false
            importViewModel.configuration.verificationMode = .off
            importViewModel.configuration.skipPreviouslyImported = false
            importViewModel.sortByDate = false
            do {
                importViewModel.sourceFiles = try await browserViewModel.fileSystemService
                    .supportedFilesSnapshot(at: sourceURL)
            } catch is CancellationError {
                return
            } catch {
                importViewModel.sourceFiles = []
            }
            isShowingImport = true
            return
        }

        guard let folderURL = configuration.folderURL else { return }
        if configuration.templateRootURL != nil {
            let fixtureID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
            let template = MetadataTemplate(
                id: fixtureID,
                name: "UI Smoke Voice Memo",
                fields: [
                    .init(fieldKey: "title", templateValue: VoiceMemoTranscriptVariablePolicy.token),
                    .init(fieldKey: "description", templateValue: VoiceMemoTranscriptVariablePolicy.token),
                    .init(fieldKey: "extendedDescription", templateValue: VoiceMemoTranscriptVariablePolicy.token),
                    .init(fieldKey: "instructions", templateValue: VoiceMemoTranscriptVariablePolicy.token),
                ],
                processInstantly: true
            )
            _ = await templateViewModel.saveTemplate(template)
        }
        openFolderInActivePane(folderURL, addToOpenFolders: false)

        for _ in 0..<200 where browserViewModel.isLoading {
            try? await Task.sleep(for: .milliseconds(50))
        }

        if workflow == .openFolder || workflow == .recoveryError { return }
        guard !browserViewModel.visibleImages.isEmpty else { return }

        let selection = workflow == .batchRename || workflow == .voiceMemoVariableBatch || workflow == .voiceMemoTranscriptionBatch
            ? Array(browserViewModel.visibleImages.prefix(2))
            : Array(browserViewModel.visibleImages.prefix(1))
        let selectedURLs = Set(selection.map(\.url))
        browserViewModel.applySelection(ids: selectedURLs, active: selection.first?.url)
        metadataViewModel.loadMetadata(for: selection, folderURL: folderURL)

        switch workflow {
        case .caption, .voiceMemoTranscriptionBatch:
            openCaptionWorkspace()
        case .voiceMemoVariableBatch:
            break
        case .batchRename:
            browserViewModel.renameSelected()
        case .deadline:
            guard MainViewMode.isDeadlineAvailable else { return }
            if deadlineProfileLibrary.selectedProfile == nil {
                await deadlineProfileLibrary.create(name: "UI Smoke Deadline")
            }
            openDeadlineWorkspace()
        case .openFolder, .importPreflight, .recoveryError, .knownPeopleInterchange:
            break
        }
    }

    private var deadlineWorkspaceInput: DeadlineWorkspaceInput? {
        deadlineLiveSnapshot.workspaceInput
    }

    private func handleDeadlineRemediation(_ destination: DeadlineRemediationDestination) {
        switch destination {
        case let .caption(imageURL, field):
            if let field {
                settingsViewModel.setIPTCMetadataField(field, visible: true)
            }
            pendingDeadlineCaptionField = field
            guard selectDeadlineRemediationImages(imageURL) else { return }
            mainViewMode = .caption

        case let .sourceImage(imageURL):
            pendingDeadlineCaptionField = nil
            guard selectDeadlineRemediationImages(imageURL) else { return }
            mainViewMode = .browser
            browserViewModel.shouldRestoreGridFocus = true

        case .profileSettings:
            isShowingDeadlineProfileManager = true

        case let .renameSettings(imageURL):
            guard selectDeadlineRemediationImages(imageURL) else { return }
            performAfterMetadataFileOperation { browserViewModel.renameSelected() }

        case let .exportSettings(imageURL):
            guard selectDeadlineRemediationImages(imageURL) else { return }
            showAdvancedExportSelected()

        case let .connectionSettings(identifier):
            let exactIdentifier = identifier
                ?? deadlineWorkspaceInput?.request.profile.destination?.connectionIdentifier
            if let exactIdentifier,
               let connection = ftpViewModel.connections.first(where: {
                   $0.id.uuidString.caseInsensitiveCompare(exactIdentifier) == .orderedSame
               }) {
                ftpViewModel.startEditingConnection(connection)
            } else {
                ftpViewModel.startEditingConnection()
            }

        case .stagingSettings:
            Task { await deliveryWorkflowActivity.reload() }
            isShowingDeadlineStagingActivity = true
        }
    }

    /// A per-image remediation keeps that exact image. Batch remediation uses the complete,
    /// ordered Deadline request rather than guessing from an unrelated browser selection.
    @discardableResult
    private func selectDeadlineRemediationImages(_ imageURL: URL?) -> Bool {
        let urls: [URL]
        if let imageURL {
            urls = [imageURL]
        } else {
            urls = deadlineWorkspaceInput?.request.items.map(\.sourceURL) ?? []
        }
        guard !urls.isEmpty else { return false }
        browserViewModel.selectedImageIDs = Set(urls)
        browserViewModel.lastClickedImageURL = imageURL ?? urls.first
        return true
    }

    /// Live production composition for one confirmed Deadline batch. The preparation closure
    /// captures value state on the main actor, hashes source bytes in a detached task, and asks the
    /// pure planner to revalidate every frozen input before the confirmation sheet is published.
    private var deadlineDeliveryDependencies: DeadlineDeliveryExecutionDependencies {
        let browser = browserViewModel
        let profileLibrary = deadlineProfileLibrary
        let liveSnapshot = deadlineLiveSnapshot
        let ftp = ftpViewModel
        let receipts = deliveryReceiptLibrary
        let workflowActivity = deliveryWorkflowActivity
        let session = deadlineDeliverySession

        return DeadlineDeliveryExecutionDependencies(
            prepare: { preparation in
                let batch = try await session.prepare(
                    preparation,
                    browser: browser,
                    profileLibrary: profileLibrary,
                    liveSnapshot: liveSnapshot
                )
                let identifier = batch.plan.destination.connectionIdentifier
                guard let connection = ftp.connections.first(where: {
                    $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
                }) else { return batch }
                return batch.recordingTransportSecurity(connection)
            },
            start: { batch, progress in
                try await session.execute(
                    batch,
                    connections: ftp.connections,
                    writeEngine: browser.writeEngine,
                    resume: false,
                    onRenameRefused: { id in
                        Task { @MainActor in ftp.markServerRefusesRename(connectionID: id) }
                    },
                    progress: progress
                )
            },
            resume: { batch, progress in
                try await session.execute(
                    batch,
                    connections: ftp.connections,
                    writeEngine: browser.writeEngine,
                    resume: true,
                    onRenameRefused: { id in
                        Task { @MainActor in ftp.markServerRefusesRename(connectionID: id) }
                    },
                    progress: progress
                )
            },
            cancel: { await session.requestCancellation() },
            recover: { try await session.recoverableBatch() },
            reloadReceipts: {
                await receipts.reload()
                await workflowActivity.reload()
            },
            acknowledgeInsecureTransport: { identifier, expectedSecurity in
                guard let connectionID = UUID(uuidString: identifier),
                      let connection = ftp.connections.first(where: { $0.id == connectionID }),
                      connection.transportSecurity == expectedSecurity,
                      connection.requiresFirstInsecureUploadAcknowledgement else {
                    return false
                }
                return ftp.acknowledgeFirstInsecureUpload(connectionID: connectionID) != nil
            },
            recoverWorkflow: { try await session.recoverReservedBatch(for: $0) },
            releaseRecoveredWorkflow: { session.releaseResumeReservation(for: $0) }
        )
    }

    /// Value-only identity for scheduling a fresh background capture. No filesystem, image decode,
    /// capacity, encoder, security-scope, or network work is performed here.
    private var deadlineLiveCaptureRevision: DeadlineLiveCaptureRevision? {
        guard mainViewMode == .deadline,
              deadlineProfileLibrary.selectedProfile != nil else { return nil }
        let selectedURLs = browserViewModel.selectedImageIDs
        let images = browserViewModel.sortedImages.filter {
            selectedURLs.contains($0.url) && $0.isImageFile
        }
        return DeadlineLiveCaptureRevision(
            selectionSource: deadlineSelectionSourceRevision(images),
            metadata: deadlineMetadataRevision(images),
            profile: deadlineEncodableRevision(deadlineProfileLibrary.selectedProfile),
            renameResources: deadlineEncodableRevision(deadlineRenameRecipeLibrary.presets),
            templateResources: deadlineEncodableRevision(
                templateViewModel.templates.map { $0.id.uuidString.lowercased() }.sorted()
            ),
            exportConfiguration: deadlineEncodableRevision(
                DeadlineExportSnapshot(advancedExportConfiguration)
            ),
            developSettings: deadlineEncodableRevision(images.map {
                browserViewModel.currentCameraRawSettings(for: $0.url)
            }),
            connectionInventory: deadlineRevision(
                ftpViewModel.connections.map { $0.id.uuidString.lowercased() }.sorted()
                    .joined(separator: "\n").utf8
            ),
            requiredLists: KeywordListsStore.shared.version,
            renameDirectory: browserViewModel.currentFolderURL?.standardizedFileURL.path,
            validationPreferences: deadlineLiveSnapshot.validationPreferences
        )
    }

    /// Captures only already-owned value state on the main actor. Every live probe happens inside
    /// `DeadlinePreflightLiveSnapshotCoordinator`'s detached capture task.
    private func makeDeadlineLiveCaptureRequest() -> DeadlinePreflightLiveCaptureRequest? {
        guard mainViewMode == .deadline,
              let deadlineProfile = deadlineProfileLibrary.selectedProfile else { return nil }
        let selectedURLs = browserViewModel.selectedImageIDs
        let images = browserViewModel.sortedImages.filter {
            selectedURLs.contains($0.url) && $0.isImageFile
        }
        let items = images.map { image in
            var resolvedMetadata = image.metadata ?? IPTCMetadata()
            resolvedMetadata.cameraRaw = browserViewModel.currentCameraRawSettings(for: image.url)
            return DeadlineLiveSourceItem(
                sourceURL: image.url,
                metadata: resolvedMetadata,
                sidecarState: image.hasPendingMetadataChanges ? .pending : .clean,
                renameContext: BatchRenameContext(originalFilename: image.url.lastPathComponent),
                byteCount: image.fileSize > 0 ? image.fileSize : nil,
                isICloudDownloadPending: image.isICloudDownloadPending,
                isSupportedFormat: image.isImageFile,
                isHDR: image.isNativeHDR,
                hasC2PA: image.hasC2PA,
                exifOrientation: image.exifOrientation
            )
        }
        let templateIdentifiers = Set(templateViewModel.templates.flatMap { template in
            [template.id.uuidString, template.id.uuidString.lowercased()]
        })
        let validationProfiles = [
            MetadataValidationProfile.currentRequirements(
                levels: MetadataRequirements.load(from: AppDefaults.store),
                minimumLengths: MetadataRequirements.loadMinimumLengths(from: AppDefaults.store)
            ),
            MetadataValidationProfile.iptcIIMCompatibility,
        ]
        let inventory = DeadlineLiveResourceInventory(
            validationProfiles: validationProfiles,
            metadataTemplateIdentifiers: templateIdentifiers,
            renamePresets: deadlineRenameRecipeLibrary.presets,
            exportConfigurations: [
                DeadlineLiveExportConfiguration(
                    identifier: DeadlineLiveResourceIdentifier.currentExportConfiguration,
                    snapshot: DeadlineExportSnapshot(advancedExportConfiguration)
                ),
            ]
        )
        let connectionIdentifiers = Set(ftpViewModel.connections.flatMap {
            [$0.id.uuidString, $0.id.uuidString.lowercased()]
        })
        return DeadlinePreflightLiveCaptureRequest(
            profile: deadlineProfile,
            items: items,
            inventory: inventory,
            requiredListCandidates: [
                DeadlineLiveRequiredListCandidate(
                    identifier: DeadlineLiveResourceIdentifier.approvedKeywords
                ),
            ],
            renameDirectoryURL: browserViewModel.currentFolderURL,
            stagingRootURL: nil,
            useDefaultApplicationStagingRoot: true,
            // Renderer-aware estimation is not yet exposed by the live export pipeline. Source
            // byte counts are not a safe substitute for rendered TIFF/PNG output.
            estimatedRequiredBytes: nil,
            connectionIdentifiers: connectionIdentifiers,
            selectionSourceRevision: deadlineSelectionSourceRevision(images),
            metadataRevision: deadlineMetadataRevision(images),
            profileRevision: deadlineEncodableRevision(deadlineProfile),
            developSnapshots: images.map { image in
                guard let settings = browserViewModel.currentCameraRawSettings(for: image.url) else {
                    return nil
                }
                return DevelopVersionSnapshot(settings: settings)
            }
        )
    }

    private func deadlineSelectionSourceRevision(_ images: [ImageFile]) -> UInt64 {
        let description = images.map {
            [
                $0.url.standardizedFileURL.path,
                String($0.fileSize),
                String($0.dateModified.timeIntervalSinceReferenceDate.bitPattern),
                String($0.isICloudDownloadPending),
                String($0.isNativeHDR),
                String($0.hasC2PA),
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return deadlineRevision(description.utf8)
    }

    private func deadlineMetadataRevision(_ images: [ImageFile]) -> UInt64 {
        let metadata = images.map { $0.metadata ?? IPTCMetadata() }
        var revision = deadlineEncodableRevision(metadata)
        revision ^= UInt64(metadataViewModel.metadataLoadGeneration)
        for image in images where image.hasPendingMetadataChanges {
            revision &*= 1_099_511_628_211
            revision ^= deadlineRevision(image.url.standardizedFileURL.path.utf8)
        }
        return revision
    }

    private func deadlineEncodableRevision<Value: Encodable>(_ value: Value) -> UInt64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map(deadlineRevision) ?? 0
    }

    private func deadlineRevision<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        bytes.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    /// Same predicate as `selectedAnalysisImage != nil` without scanning (and observing)
    /// every row: a selected, supported photo that is in the current folder.
    private var hasAnalyzableSelection: Bool {
        let indexed = browserViewModel.urlToImageIndex
        return browserViewModel.selectedImageIDs.contains {
            indexed[$0] != nil && SupportedImageFormats.isSupported(url: $0)
        }
    }

    private var selectedAnalysisImage: ImageFile? {
        AnalysisSelectionResolver.image(
            images: browserViewModel.images,
            selectedURLs: browserViewModel.selectedImageIDs,
            lastClickedURL: browserViewModel.lastClickedImageURL
        )
    }

    /// Previous/Next Image in Analysis step through the workspace's own photo rail (the same
    /// list and open path as clicking a rail thumbnail) instead of the hidden Browser selection.
    private func selectAdjacentAnalysisImage(offset: Int) {
        let images = browserViewModel.sortedImages.filter {
            $0.isImageFile && SupportedImageFormats.isSupported(url: $0.url)
        }
        guard let current = analysisWorkspaceModel.sourceURL?.standardizedFileURL,
              let index = images.firstIndex(where: { $0.url.standardizedFileURL == current }),
              images.indices.contains(index + offset) else { return }
        let image = images[index + offset]
        browserViewModel.selectedImageIDs = [image.url]
        browserViewModel.lastClickedImageURL = image.url
        analysisWorkspaceModel.requestOpenInCurrentWorkspace(image)
    }

    private func openImageAnalysis() {
        guard let image = selectedAnalysisImage else { return }
        leaveEditWorkspaceIfNeeded {
            // After a failed save the workspace keeps the unsaved case and asks before reloading.
            analysisWorkspaceModel.requestOpen(image)
            mainViewMode = .imageAnalysis
        }
    }

    private var selectedComparisonImages: [ImageFile]? {
        ComparisonSelectionResolver.images(
            in: browserViewModel.visibleImages,
            selectedURLs: browserViewModel.selectedImageIDs
        )
    }

    private func openComparison() {
        guard let selectedComparisonImages else { return }
        leaveEditWorkspaceIfNeeded {
            comparisonImages = selectedComparisonImages
            comparisonFocusedURL = nil
            comparisonOrigin = .browser
            comparisonInitialLeftRepresentation = nil
            mainViewMode = .comparison
        }
    }

    private var fullScreenComparisonImages: [ImageFile]? {
        let currentURL: URL?
        if let activeURL = browserViewModel.lastClickedImageURL,
           browserViewModel.selectedImageIDs.contains(activeURL) {
            currentURL = activeURL
        } else {
            currentURL = browserViewModel.selectedImageIDs.first
        }
        return FullScreenComparisonSelectionResolver.images(
            in: browserViewModel.visibleImages,
            currentURL: currentURL,
            selectedURLs: browserViewModel.selectedImageIDs
        )
    }

    private func openComparisonFromFullScreen(renderEdits: Bool) {
        guard browserViewModel.isFullScreen,
              let fullScreenComparisonImages else { return }
        performAfterCaptionFlush {
            guard browserViewModel.isFullScreen else { return }
            comparisonImages = fullScreenComparisonImages
            comparisonFocusedURL = nil
            comparisonOrigin = .fullScreen
            comparisonInitialLeftRepresentation = renderEdits ? .committedEdit : .original
            opensComparisonAfterFullScreenDismissal = true
            browserViewModel.isFullScreen = false
        }
    }

    @ViewBuilder
    private var browserAndMetadataPanel: some View {
        HStack(spacing: 0) {
            // Left column: face bar + browser
            VStack(spacing: 0) {
                // Keep the bar through a folder change: loadFolder clears `images` before the
                // new scan lands, and gating on emptiness alone makes the bar blink out.
                // `isLoading` spans that window, so it stays put.
                if browserViewModel.hasImages || browserViewModel.isLoading {
                    faceBar
                    Divider()
                }

                BrowserPaneContainer(
                    panes: panes,
                    activeFaceCount: faceRecognitionViewModel.faceData?.faces.count ?? 0,
                    activeFaceGroupCount: faceRecognitionViewModel.faceData?.groups.count ?? 0,
                    selectFileVisibility: { settingsViewModel.fileVisibility = $0 }
                )
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                .onKeyPress("m") {
                    guard NSEvent.modifierFlags.contains(.option),
                          !metadataViewModel.isBatchEdit,
                          metadataViewModel.originalImageMetadata != nil else {
                        return .ignored
                    }
                    guard metadataViewModel.hasXmpMetadata else { return .ignored }
                    let next: MetadataReferenceSource = metadataViewModel.metadataReferenceSource == .embedded ? .xmp : .embedded
                    metadataViewModel.applyReferenceSource(next)
                    return .handled
                }
            }

            MetadataPanelDivider(panelWidth: $metadataPanelWidth)

            // Right column: faces-in-image + metadata (full height)
            VStack(spacing: 0) {
                ImageFacesSection(
                    viewModel: faceRecognitionViewModel,
                    settingsViewModel: settingsViewModel,
                    selectedImageURL: browserViewModel.lastClickedImageURL,
                    selectedCount: browserViewModel.selectedImageIDs.count
                )

                MetadataPanel(
                    viewModel: metadataViewModel,
                    browserViewModel: browserViewModel,
                    settingsViewModel: settingsViewModel,
                    onApplyTemplate: { isShowingTemplatePalette = true },
                    onSaveTemplate: { isShowingSaveTemplateName = true },
                    onPendingStatusChanged: {
                        browserViewModel.refreshPendingStatus()
                    },
                    onPendingStatusChangedForURLs: { urls in
                        browserViewModel.refreshPendingStatusBatch(for: urls)
                    }
                )
            }
            .frame(width: CGFloat(metadataPanelWidth))
        }
    }

    @ViewBuilder
    private var faceBar: some View {
        FaceBarView(
            viewModel: faceRecognitionViewModel,
            folderURL: browserViewModel.currentFolderURL,
            images: { browserViewModel.images },
            settingsViewModel: settingsViewModel,
            isExpanded: mainViewMode == .faceManagement,
            selectionState: mainViewMode == .faceManagement ? faceSelectionState : nil,
            onSelectImages: { urls in
                browserViewModel.selectedImageIDs = urls
            },
            onPhotosDeleted: { trashedURLs in
                browserViewModel.images.removeAll { trashedURLs.contains($0.url) }
                browserViewModel.selectedImageIDs.subtract(trashedURLs)
            },
            onToggleExpanded: {
                mainViewMode = mainViewMode == .faceManagement ? .browser : .faceManagement
            },
            onOpenPeopleDatabase: {
                togglePeopleDatabase()
            }
        )
    }

    @ViewBuilder
    private var editingWorkspaceView: some View {
        EditWorkspaceView(
            metadataViewModel: metadataViewModel,
            browserViewModel: browserViewModel,
            settingsViewModel: settingsViewModel,
            scopeViewModel: scopeViewModel,
            cleanFeedController: CleanFeedController.shared,
            isOverlayPresented: isShowingTemplatePalette || isShowingDevelopTemplatePalette,
            onExit: {
                mainViewMode = .browser
                browserViewModel.shouldRestoreGridFocus = true
            },
            onPendingStatusChanged: {
                browserViewModel.refreshPendingStatus()
            }
        )
    }

    private func returnToBrowserWorkspace() {
        leaveEditWorkspaceIfNeeded {
            mainViewMode = .browser
            browserViewModel.shouldRestoreGridFocus = true
        }
    }

    /// Workspace navigation is independent of the browser's saved pane layout.
    private var workspaceMenu: some View {
        Menu {
            Button(action: returnToBrowserWorkspace) {
                Label("Browser", systemImage: mainViewMode == .browser ? "checkmark" : "photo.on.rectangle")
            }

            Button {
                openEditWorkspace()
            } label: {
                Label("Develop", systemImage: mainViewMode == .editing ? "checkmark" : "slider.horizontal.3")
            }
            .disabled(browserViewModel.visibleImages.first(where: \.isImageFile) == nil)

            Divider()
            Button {
                openCaptionWorkspace()
            } label: {
                Label(
                    "Caption Workspace",
                    systemImage: mainViewMode == .caption ? "checkmark" : "text.below.photo"
                )
            }
            .disabled(browserViewModel.visibleImages.first(where: \.isImageFile) == nil)

            if MainViewMode.isDeadlineAvailable {
                Button {
                    openDeadlineWorkspace()
                } label: {
                    Label(
                        "Deadline Workspace",
                        systemImage: mainViewMode == .deadline ? "checkmark" : "paperplane"
                    )
                }
                .disabled(browserViewModel.visibleImages.first(where: \.isImageFile) == nil)
            }

            Button {
                openImageAnalysis()
            } label: {
                Label(
                    "Image Analysis",
                    systemImage: mainViewMode == .imageAnalysis
                        ? "checkmark"
                        : "waveform.path.ecg.rectangle"
                )
            }
            .disabled(!hasAnalyzableSelection)

            Button {
                openComparison()
            } label: {
                Label(
                    "Compare Two Images",
                    systemImage: mainViewMode == .comparison
                        ? "checkmark"
                        : "rectangle.split.2x1"
                )
            }
            .disabled(selectedComparisonImages == nil)

            Button {
                leaveEditWorkspaceIfNeeded {
                    mainViewMode = .metadataReview
                }
            } label: {
                Label("Metadata Review", systemImage: mainViewMode == .metadataReview ? "checkmark" : "list.bullet.rectangle")
            }
        } label: {
            Label("Workspace", systemImage: {
                switch mainViewMode {
                case .caption: "text.below.photo"
                case .deadline: "paperplane"
                case .imageAnalysis: "waveform.path.ecg.rectangle"
                case .comparison: "rectangle.split.2x1"
                case .metadataReview: "list.bullet.rectangle"
                case .editing: "slider.horizontal.3"
                default: "photo.on.rectangle"
                }
            }())
        }
        .help("Switch workspace")
        .accessibilityLabel("Workspace")
    }

    /// Layout changes only rearrange the browser panes; they never switch workspaces.
    private var paneLayoutMenu: some View {
        Menu {
            paneLayoutButton(.single, "Single", "rectangle")
            paneLayoutButton(.splitHorizontal, "Split Side by Side", "rectangle.split.2x1")
            paneLayoutButton(.splitVertical, "Split Top and Bottom", "rectangle.split.1x2")
            paneLayoutButton(.tabs, "Tabs", "square.on.square")
        } label: {
            Label("Layout", systemImage: paneLayoutIcon)
        }
        .help("Arrange browser panes")
        .accessibilityLabel("Layout")
    }

    private func paneLayoutButton(_ layout: BrowserPaneLayout, _ title: String, _ icon: String) -> some View {
        Button {
            panes.setLayout(layout)
        } label: {
            Label(
                title,
                systemImage: mainViewMode == .browser && panes.layout == layout
                    ? "checkmark"
                    : icon
            )
        }
    }

    private var paneLayoutIcon: String {
        switch panes.layout {
        case .single: return "rectangle"
        case .splitHorizontal: return "rectangle.split.2x1"
        case .splitVertical: return "rectangle.split.1x2"
        case .tabs: return "square.on.square"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if mainViewMode == .metadataReview {
            ToolbarItem(placement: .navigation) {
                Button(action: returnToBrowserWorkspace) {
                    Label("Back to Browser", systemImage: "chevron.left")
                }
                .help("Exit Metadata Review and return to the browser")
                .accessibilityLabel("Exit Metadata Review")
            }

            ToolbarItemGroup(placement: .automatic) {
                ColorLabelFilterBar(selectedLabels: Bindable(browserViewModel).selectedColorLabels)
                    .disabled(!browserViewModel.hasImages)
                    .padding(8)
            }

            ToolbarItemGroup(placement: .automatic) {
                StarRatingFilterBar(minimumRating: Bindable(browserViewModel).minimumStarRating)
                    .disabled(!browserViewModel.hasImages)
                    .padding(8)

                metadataReviewFilterMenu
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    browserViewModel.sortReversed.toggle()
                } label: {
                    Image(systemName: browserViewModel.sortReversed ? "arrow.up" : "arrow.down")
                }
                .help(browserViewModel.sortReversed ? "Sort ascending" : "Sort descending")
                .disabled(browserViewModel.sortOrder == .manual)

                BrowserSortOrderMenu(viewModel: browserViewModel)
            }

            ToolbarItemGroup(placement: .automatic) {
                metadataReviewSearchField
            }
        }

        // Show filter and sort controls in the toolbar when in edit mode
        // (BrowserView provides these in browser mode, but isn't in the hierarchy during editing)
        if mainViewMode == .editing {
            ToolbarItemGroup(placement: .automatic) {
                ColorLabelFilterBar(selectedLabels: Bindable(browserViewModel).selectedColorLabels)
                    .disabled(!browserViewModel.hasImages)
                    .padding(8)
            }

            ToolbarItemGroup(placement: .automatic) {
                StarRatingFilterBar(minimumRating: Bindable(browserViewModel).minimumStarRating)
                    .disabled(!browserViewModel.hasImages)
                    .padding(8)

                editFilterMenu
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    browserViewModel.sortReversed.toggle()
                } label: {
                    Image(systemName: browserViewModel.sortReversed ? "arrow.up" : "arrow.down")
                }
                .help(browserViewModel.sortReversed ? "Sort ascending" : "Sort descending")
                .disabled(browserViewModel.sortOrder == .manual)

                BrowserSortOrderMenu(viewModel: browserViewModel)
            }
        }

        ToolbarItem(placement: .automatic) {
            if mainViewMode == .browser
                || mainViewMode == .caption
                || mainViewMode == .deadline
                || mainViewMode == .metadataReview
                || mainViewMode == .imageAnalysis
                || mainViewMode == .comparison
                || mainViewMode == .editing {
                workspaceMenu
            }
        }

        ToolbarItem(placement: .automatic) {
            if mainViewMode == .browser {
                paneLayoutMenu
            }
        }

        folderActionToolbarContent
    }

    /// Give each action a native toolbar identity and explicit accessible name
    /// instead of sharing one hosted item with an inferred group description.
    @ToolbarContentBuilder
    private var folderActionToolbarContent: some ToolbarContent {
        if metadataViewModel.hasRetainedPrimaryDevelopWrites {
            ToolbarItem(id: "develop-primary-review", placement: .secondaryAction) {
                Button {
                    do {
                        try DevelopPrimaryLifecycleCoordinator.shared.captureEditors()
                        isShowingPrimaryDevelopRecovery = true
                    } catch {
                        OperationIssueDetailsPresenter.present(title: "Develop Recovery", message: error.localizedDescription)
                    }
                } label: {
                    Label("Review Develop Conflicts", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("toolbar.develop.review")
                .help("Export retained Primary Develop edits before discarding the exported requests.")
            }
            ToolbarItem(id: "develop-primary-retry", placement: .secondaryAction) {
                Button {
                    Task { @MainActor in
                        do { try await metadataViewModel.retryPrimaryDevelopWrites() }
                        catch {
                            OperationIssueDetailsPresenter.present(title: "Develop Save Failed", message: error.localizedDescription)
                        }
                    }
                } label: {
                    Label("Retry Develop Writes", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("toolbar.develop.retry")
                .help("Retry captured Primary Develop edits using their original file evidence.")
            }
        }
        if let attention = metadataViewModel.variableBatchOutcome?.attention {
            ToolbarItem(id: "folder-variable-details", placement: .secondaryAction) {
                Button {
                    OperationIssueDetailsPresenter.present(title: attention.title, message: attention.message)
                } label: {
                    Label("Variable Processing Details", systemImage: "exclamationmark.triangle")
                }
                .accessibilityLabel(attention.title)
                .accessibilityIdentifier("toolbar.processVariables.details")
                .help("Review variable processing results and retained edits for the original folder.")
            }
        }
        if metadataViewModel.hasRetainedVariableWrites {
            ToolbarItem(id: "folder-variable-review", placement: .secondaryAction) {
                Button {
                    // Recovery must remain reachable while retained variable work blocks flush.
                    do {
                        try metadataViewModel.prepareVariableRecoveryPresentation()
                        isShowingVariableRecovery = true
                    } catch {
                        metadataViewModel.saveError = error.localizedDescription
                    }
                } label: {
                    Label("Review Variable Conflicts", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("toolbar.processVariables.review")
                .help("Export and review retained variable edits for one photo before discarding them.")
            }
            ToolbarItem(id: "folder-variable-retry", placement: .secondaryAction) {
                Button {
                    // Retry owns an immutable request and must remain reachable when its
                    // unpersisted draft is itself blocking ordinary lifecycle transitions.
                    metadataViewModel.retryVariableWrites()
                } label: {
                    Label("Retry Variable Writes", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("toolbar.processVariables.retry")
                .help("Retry captured variable work with its original inputs and write mode.")
                .disabled(metadataViewModel.isProcessingFolder)
            }
        }
        if let attention = metadataViewModel.pendingWriteBatchOutcome?.attention {
            ToolbarItem(id: "folder-write-pending-details", placement: .secondaryAction) {
                Button {
                    OperationIssueDetailsPresenter.present(title: attention.title, message: attention.message)
                } label: {
                    Label("Write All Details", systemImage: "exclamationmark.triangle")
                }
                .accessibilityLabel(attention.title)
                .accessibilityIdentifier("toolbar.writeAllPending.details")
                .help("Review the complete Write All results, including partial writes and retained pending files.")
            }
        }
        if metadataViewModel.isProcessingFolder {
            ToolbarItem(id: "folder-processing-status", placement: .secondaryAction) {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(metadataViewModel.folderProcessProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ToolbarItem(id: "folder-write-pending", placement: .secondaryAction) {
                Button {
                    requestWriteAllPendingMetadata()
                } label: {
                    Label("Write All Pending", systemImage: "square.and.arrow.down.on.square")
                }
                .accessibilityLabel("Write All Pending")
                .accessibilityIdentifier("toolbar.writeAllPending")
                .help("Write all pending sidecar changes to image files")
                .disabled(!browserViewModel.hasImages)
            }

            ToolbarItem(id: "folder-process-variables", placement: .secondaryAction) {
                Button {
                    performAfterCaptionFlush {
                        metadataViewModel.processVariablesInFolder(images: browserViewModel.images)
                    }
                } label: {
                    Label("Process Variables in Folder", systemImage: "curlybraces")
                }
                .accessibilityLabel("Process Variables in Folder")
                .accessibilityIdentifier("toolbar.processVariables")
                .help("Resolve placeholders across this folder and save the resulting metadata using your configured write mode, including other pending editorial changes.")
                .disabled(!browserViewModel.hasImages)
            }

            ToolbarItem(id: "folder-people-database", placement: .secondaryAction) {
                Button {
                    togglePeopleDatabase()
                } label: {
                    Label("People Database", systemImage: "person.text.rectangle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("People Database")
                .accessibilityIdentifier("toolbar.peopleDatabase")
                .help("Open Known People database")
            }

            ToolbarItem(id: "folder-edit-workspace", placement: .secondaryAction) {
                Button {
                    toggleEditWorkspace()
                } label: {
                    Label(
                        mainViewMode == .editing ? "Return to Browser" : "Edit Workspace",
                        systemImage: mainViewMode == .editing
                            ? "xmark.circle.fill"
                            : "slider.horizontal.3"
                    )
                    .labelStyle(.iconOnly)
                }
                .accessibilityLabel(mainViewMode == .editing ? "Return to Browser" : "Edit Workspace")
                .accessibilityIdentifier("toolbar.editWorkspace")
                .help(mainViewMode == .editing ? "Return to browser workspace" : "Open edit workspace")
                .disabled(browserViewModel.visibleImages.isEmpty)
            }

            ToolbarItem(id: "folder-render-save", placement: .secondaryAction) {
                Button {
                    renderAndSaveEditedFolder()
                } label: {
                    Label("Render and Save Folder", systemImage: "photo.badge.arrow.down")
                }
                .accessibilityLabel("Render and Save Folder")
                .accessibilityIdentifier("toolbar.renderAndSave")
                .help("Render all images in the folder to Edited/ as sRGB JPEG")
                .disabled(!browserViewModel.hasImages || isRenderingEditedFolder)
            }
        }
    }

    private var metadataReviewFilterMenu: some View {
        Menu {
            Picker("Person Shown", selection: Bindable(browserViewModel).personShownFilter) {
                ForEach(BrowserViewModel.PersonShownFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Picker("Edited", selection: Bindable(browserViewModel).editedFilter) {
                ForEach(BrowserViewModel.EditedFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Picker("Required Metadata", selection: Bindable(browserViewModel).requiredMetadataFilter) {
                ForEach(BrowserViewModel.RequiredMetadataFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Menu("Missing Field") {
                ForEach(MetadataFieldID.userSelectable, id: \.self) { field in
                    Toggle(field.displayName, isOn: Binding(
                        get: { browserViewModel.missingFieldFilters.contains(field) },
                        set: { enabled in
                            if enabled { browserViewModel.missingFieldFilters.insert(field) }
                            else { browserViewModel.missingFieldFilters.remove(field) }
                        }
                    ))
                }
            }
            Divider()
            Button("Clear Filters") { browserViewModel.clearFilters() }
                .disabled(!browserViewModel.isFilteringActive)
        } label: {
            Label(
                "Filters",
                systemImage: browserViewModel.isFilteringActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter images")
        .disabled(!browserViewModel.hasImages)
    }

    private var metadataReviewSearchField: some View {
        HStack(spacing: 6) {
            TextField("Search", text: Bindable(browserViewModel).searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("browser.search")
            Button {
                browserViewModel.searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear search")
            .opacity(browserViewModel.searchText.isEmpty ? 0 : 1)
            .disabled(browserViewModel.searchText.isEmpty)
            .accessibilityHidden(browserViewModel.searchText.isEmpty)
        }
        .disabled(!browserViewModel.hasImages)
    }

    private var editFilterMenu: some View {
        Menu {
            Picker("Person Shown", selection: Bindable(browserViewModel).personShownFilter) {
                ForEach(BrowserViewModel.PersonShownFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Picker("Edited", selection: Bindable(browserViewModel).editedFilter) {
                ForEach(BrowserViewModel.EditedFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Divider()

            Button("Clear Filters") {
                browserViewModel.clearFilters()
            }
            .disabled(!browserViewModel.isFilteringActive)
        } label: {
            Label(
                "Filters",
                systemImage: browserViewModel.isFilteringActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter images")
        .disabled(!browserViewModel.hasImages)
    }

    @ViewBuilder
    private var importSheet: some View {
        ImportView(
            viewModel: importViewModel,
            templates: templateViewModel.templates,
            thumbnailService: browserViewModel.thumbnailService,
            maxSheetHeight: sheetMaxHeight,
            onDismiss: { isShowingImport = false }
        )
        // Settings edits templates through its own view model, so refresh this window's copy
        // whenever Import opens instead of offering the list from launch.
        .onAppear { templateViewModel.loadTemplates() }
    }

    private func handleImportStarted(_ notification: NotificationCenter.Publisher.Output) {
        isShowingImport = false
        if let folderURL = notification.object as? URL {
            openFolderInActivePane(folderURL, addToOpenFolders: true)
        }
    }

    private func handleImportCompleted(_ notification: NotificationCenter.Publisher.Output) {
        // Import already opened the folder on start — nothing else needed.
    }

    private var hasActiveSidebarWork: Bool {
        importViewModel.isImporting || ftpViewModel.isUploading || ftpViewModel.isRendering
            || faceRecognitionViewModel.isScanning || voiceMemoBatchModel.isRunning
            || metadataViewModel.isProcessingFolder || isRenderingEditedFolder
    }

    private var sidebarOverallProgress: Double? {
        var fractions: [Double] = []
        if importViewModel.isImporting {
            if importViewModel.importPhase == .applyingMetadata {
                fractions.append(Double(importViewModel.metadataProcessedFiles) / Double(max(importViewModel.metadataTotalFiles, 1)))
            } else {
                fractions.append(Double(importViewModel.processedFiles) / Double(max(importViewModel.totalFiles, 1)))
            }
        }
        if ftpViewModel.isRendering {
            fractions.append(Double(ftpViewModel.renderCompletedCount) / Double(max(ftpViewModel.renderTotalCount, 1)))
        } else if ftpViewModel.isUploading { fractions.append(ftpViewModel.overallProgress) }
        if faceRecognitionViewModel.isScanning {
            fractions.append(Double(faceRecognitionViewModel.scanProcessedCount) / Double(max(faceRecognitionViewModel.scanTotalCount, 1)))
        }
        if voiceMemoBatchModel.isRunning {
            fractions.append(Double(voiceMemoBatchModel.record?.batchProgress?.items.filter { $0.state == .completed }.count ?? 0)
                / Double(max(voiceMemoBatchModel.activeImageURLs.count, 1)))
        }
        if isRenderingEditedFolder { fractions.append(Double(renderExportCurrent) / Double(max(renderExportTotal, 1))) }
        if metadataViewModel.isProcessingFolder { return nil }
        guard !fractions.isEmpty else { return nil }
        return min(max(fractions.reduce(0, +) / Double(fractions.count), 0), 1)
    }

    // MARK: - Sidebar

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 14)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // A plain ScrollView rather than List(.sidebar): the NSTableView
            // behind a sidebar list imposes its own row height and inter-row
            // spacing, so compact rows are impossible there — only the
            // highlight shrinks, not the row pitch.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !sidebarViewModel.favoriteFolders.isEmpty {
                        sidebarSectionHeader("Favorites")
                        ForEach(sidebarViewModel.favoriteFolders) { favorite in
                            FolderTreeRow(
                                url: favorite.url,
                                depth: 0,
                                section: .favoriteRoot,
                                tree: .favorites(rootID: favorite.id),
                                isRootOfSection: true,
                                viewModel: sidebarViewModel,
                                currentFolderURL: browserViewModel.currentFolderURL,
                                openFolder: openFolderInActivePane,
                                closeFolder: closeFolderInAllPanes,
                                revealInFinder: revealInFinder
                            )
                        }
                    }

                    if !sidebarViewModel.favoriteFolders.isEmpty && !sidebarViewModel.openFolders.isEmpty {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                            .padding(.vertical, 6)
                    }

                    if !sidebarViewModel.openFolders.isEmpty {
                        sidebarSectionHeader("Open Folders")
                        ForEach(sidebarViewModel.openFolders, id: \.self) { folderURL in
                            FolderTreeRow(
                                url: folderURL,
                                depth: 0,
                                section: .openRoot,
                                tree: .open,
                                isRootOfSection: true,
                                viewModel: sidebarViewModel,
                                currentFolderURL: browserViewModel.currentFolderURL,
                                openFolder: openFolderInActivePane,
                                closeFolder: closeFolderInAllPanes,
                                revealInFinder: revealInFinder
                            )
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)

            if ftpViewModel.isUploading || ftpViewModel.isRendering || ftpViewModel.uploadCompleted {
                Divider()
                FTPUploadProgressView(viewModel: ftpViewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if importViewModel.isImporting {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if importViewModel.importPhase == .applyingMetadata {
                            Text("Writing metadata \(importViewModel.metadataProcessedFiles) of \(importViewModel.metadataTotalFiles)")
                        } else {
                            Text("Importing \(importViewModel.processedFiles) of \(importViewModel.totalFiles)")
                        }
                        Spacer()
                        Button("Cancel") {
                            importViewModel.cancelImport()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if importViewModel.importPhase == .applyingMetadata {
                        ProgressView(value: Double(importViewModel.metadataProcessedFiles), total: Double(max(importViewModel.metadataTotalFiles, 1)))
                    } else {
                        ProgressView(value: Double(importViewModel.processedFiles), total: Double(max(importViewModel.totalFiles, 1)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if importViewModel.showCompletionBanner, let entry = importViewModel.lastCompletionEntry {
                Divider()
                CompletionBannerView(
                    isClean: entry.isClean,
                    message: entry.summary,
                    onConfirm: { importViewModel.dismissCompletionBanner() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            if hasActiveSidebarWork
                || !activityHistory.entries.isEmpty
                || !deliveryReceiptLibrary.receipts.isEmpty
                || !deliveryWorkflowActivity.workflows.isEmpty
                || deliveryWorkflowActivity.error != nil
                || deliveryReceiptLibrary.error != nil {
                Divider()
                HStack {
                    ActivityHistoryButton(
                        history: activityHistory,
                        faceViewModel: faceRecognitionViewModel,
                        transcriptionModel: voiceMemoBatchModel,
                        receiptLibrary: deliveryReceiptLibrary,
                        workflowActivity: deliveryWorkflowActivity,
                        onResumeWorkflow: { workflowIdentifier in
                            await resumeDeadlineWorkflow(workflowIdentifier)
                        },
                        isWorking: hasActiveSidebarWork,
                        overallProgress: sidebarOverallProgress
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if isRenderingEditedFolder {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Exporting image \(renderExportCurrent) of \(renderExportTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            renderExportTask?.cancel()
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    ProgressView(value: Double(renderExportCurrent), total: Double(max(renderExportTotal, 1)))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            if let result = lastBatchResult {
                Divider()
                batchResultBanner(result)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if browserViewModel.selectedImageIDs.count == 1,
               let selectedImage = browserViewModel.selectedImages.first {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ScopeDisplayView(
                        scopeViewModel: scopeViewModel,
                        isExpanded: $scopesExpanded
                    )
                    .onChange(of: scopesExpanded) { _, expanded in
                        if expanded { reloadBrowseScopeImage() }
                    }
                    Divider()
                    if let meta = technicalMetadata, meta.hasC2PA {
                        C2PAMetadataView(metadata: meta, validation: c2paValidation) {
                            loadC2PADetail()
                        }
                        Divider()
                    }
                    TechnicalMetadataView(
                        metadata: technicalMetadata,
                        fileSize: selectedImage.fileSize,
                        orientation: selectedImage.exifOrientation,
                        croppedResolution: croppedResolutionString(
                            metadata: technicalMetadata,
                            orientation: selectedImage.exifOrientation
                        )
                    )
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        revealInFinder(selectedImage.url)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onReceive(NotificationCenter.default.publisher(for: .scopeSourceImageDidChange)) { notification in
                    let update = ScopeSourceImageUpdate(notification: notification)
                    scopeViewModel.updateImage(update?.image)
                    // Auto-select waveform scale and display gamut from settings
                    if let isHDR = update?.isHDR {
                        scopeViewModel.waveformScale = isHDR ? .nits : .percentage
                        scopeViewModel.displayGamut = isHDR
                            ? settingsViewModel.exportColorGamutHDR
                            : settingsViewModel.exportColorGamutSDR
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .editSliderDragStateChanged)) { notification in
                    if let isDragging = notification.userInfo?["isDragging"] as? Bool {
                        scopeViewModel.isDragMode = isDragging
                    }
                }
                .onChange(of: commandRouter.latestDelivery) { _, delivery in
                    guard let delivery, !CaptionWorkspaceFlushCoordinator.shared.isTransitioning else { return }
                    switch delivery.command {
                    case .setScopeMode(let mode):
                        scopeViewModel.scopeMode = mode
                    case .toggleGamutClipping:
                        scopeViewModel.showClippedGamut.toggle()
                    case .openFolder, .openRecentFolder, .setRating, .setLabel,
                         .renderSelected, .advancedExportSelected, .renderAll,
                         .saveAsJPEG, .saveAsPNG, .archiveRAW,
                         .selectPreviousImage, .selectNextImage,
                         .rotateClockwise, .rotateCounterclockwise,
                         .renameSelected, .duplicateSelected,
                         .resetAllEdits, .removeAllIPTC,
                         .showImport, .showWebImport, .backupEditedFiles, .backupEditedFilesForFolder,
                         .openInInternalEditor, .openInExternalEditor,
                         .deleteSelected, .moveRejectedToFolder,
                         .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
                         .uploadSelected, .uploadAll,
                         .processVariablesSelected, .processVariablesAll, .transcribeVoiceMemosSelected,
                         .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
                         .writeAllPendingMetadata, .openCaptionWorkspace,
                         .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
                         .showVariableReference, .showRawMetadata, .showStructuredKeywords,
                         .showKnownPeopleDatabase, .registerOpenFolderForSidebar,
                         .restoreCaptionEditorFocus:
                        break
                    }
                }
                .onChange(of: settingsViewModel.exportColorGamutSDR) { _, newValue in
                    if scopeViewModel.waveformScale == .percentage {
                        scopeViewModel.targetGamut = newValue
                    }
                }
                .onChange(of: settingsViewModel.exportColorGamutHDR) { _, newValue in
                    if scopeViewModel.waveformScale == .nits {
                        scopeViewModel.targetGamut = newValue
                    }
                }
                .onChange(of: settingsViewModel.showOriginalThumbnails) { _, newValue in
                    // A global preference: every split pane follows it, not just the active one.
                    for pane in panes.panes where pane.showOriginalThumbnails != newValue {
                        pane.showOriginalThumbnails = newValue
                    }
                }
            }
        }
        .frame(minWidth: 180)
        .task {
            // Keep the sidebar's subfolder lists in sync with disk: favorites and
            // their (expandable) subfolders are cached on first expand and would
            // otherwise never reflect folders created/renamed externally. The
            // sweep only re-reads what's already visible and leaves selection and
            // expansion untouched. Cancels automatically when the sidebar goes away.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                browserViewModel.refreshExpandedSubfolders()
            }
        }
    }

    // MARK: - Save Template Sheet

    @ViewBuilder
    private var saveTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template")
                .font(.headline)
            TextField("Template Name", text: $saveTemplateName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingSaveTemplateName = false
                    saveTemplateName = ""
                }
                Button("Save") {
                    let metadata = metadataViewModel.editingMetadata
                    let name = saveTemplateName
                    Task {
                        await templateViewModel.createTemplateFromMetadata(metadata, name: name)
                    }
                    isShowingSaveTemplateName = false
                    saveTemplateName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(saveTemplateName.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    @ViewBuilder
    private var saveDevelopTemplateSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Develop Template")
                .font(.headline)
            TextField("Template Name", text: $saveDevelopTemplateName)
                .textFieldStyle(.roundedBorder)
            Toggle("Include crop", isOn: $saveDevelopTemplateIncludesCrop)
                .toggleStyle(.checkbox)
            Text("When crop is excluded, applying this template preserves the destination image's current crop. Image-specific RAW decoder data is never included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingSaveDevelopTemplateName = false
                    saveDevelopTemplateName = ""
                    saveDevelopTemplateIncludesCrop = true
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let settings = metadataViewModel.editingMetadata.cameraRaw
                    let name = saveDevelopTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let includesCrop = saveDevelopTemplateIncludesCrop
                    Task {
                        _ = await developTemplateViewModel.createTemplate(
                            from: settings,
                            name: name,
                            includesCrop: includesCrop
                        )
                    }
                    isShowingSaveDevelopTemplateName = false
                    saveDevelopTemplateName = ""
                    saveDevelopTemplateIncludesCrop = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(saveDevelopTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }

    // MARK: - Render and Sign

    private var advancedExportConfiguration: AdvancedExportConfiguration {
        AdvancedExportConfiguration(
            sdrFormat: settingsViewModel.exportFormatSDR,
            sdrQuality: settingsViewModel.exportQualitySDR,
            sdrGamut: settingsViewModel.exportColorGamutSDR,
            hdrFormat: settingsViewModel.exportFormatHDR,
            hdrQuality: settingsViewModel.exportQualityHDR,
            hdrGamut: settingsViewModel.exportColorGamutHDR,
            tiffCompression: settingsViewModel.exportTIFFCompression,
            resolutionLimit: settingsViewModel.exportResolutionLimit,
            locationMode: settingsViewModel.exportLocationMode,
            customSubfolderName: settingsViewModel.exportCustomSubfolderName
        )
    }

    private func showAdvancedExportSelected() {
        performAfterMetadataFileOperation { showAdvancedExportSelectedAfterMetadataFlush() }
    }

    private func showAdvancedExportSelectedAfterMetadataFlush() {
        guard !isRenderingEditedFolder else { return }

        // A Set backs selection, so derive the queue from visibleImages to preserve
        // the exact order the user sees in the browser.
        let selectedIDs = browserViewModel.selectedImageIDs
        let orderedImages = AdvancedExportQueueBuilder.orderedSelection(
            from: browserViewModel.visibleImages,
            selectedIDs: selectedIDs
        )
        guard !orderedImages.isEmpty else {
            browserViewModel.errorMessage = "No images selected"
            return
        }

        let inputs = orderedImages.map { image in
            AdvancedExportPreparationInput(
                sourceURL: image.url,
                filename: image.filename,
                liveCameraRaw: browserViewModel.currentCameraRawSettings(for: image.url),
                sourceFileSize: image.fileSize > 0 ? image.fileSize : nil,
                exifOrientation: image.exifOrientation,
                isICloudDownloadPending: image.isICloudDownloadPending
            )
        }
        advancedExportPreparationTask?.cancel()
        let requestID = UUID()
        advancedExportPreparationRequestID = requestID
        let service = AdvancedExportPreparationService.shared
        advancedExportPreparationTask = Task {
            let result = await service.prepare(inputs, requestID: requestID)
            guard advancedExportPreparationRequestID == requestID else { return }
            advancedExportPreparationTask = nil
            guard case .complete(let snapshot) = result else { return }
            let currentOrderedURLs = AdvancedExportQueueBuilder.orderedSelection(
                from: browserViewModel.visibleImages,
                selectedIDs: browserViewModel.selectedImageIDs
            ).map(\.url)
            guard currentOrderedURLs == snapshot.requestedURLs else { return }
            advancedExportSession = AdvancedExportSession(items: snapshot.preparedItems)
        }
    }

    private func cancelAdvancedExportPreparation() {
        guard advancedExportPreparationTask != nil else { return }
        advancedExportPreparationTask?.cancel()
        advancedExportPreparationTask = nil
        advancedExportPreparationRequestID = UUID()
    }

    private func applyAdvancedExportConfiguration(
        _ configuration: AdvancedExportConfiguration
    ) {
        settingsViewModel.exportFormatSDR = configuration.sdrFormat
        settingsViewModel.exportQualitySDR = configuration.sdrQuality
        settingsViewModel.exportColorGamutSDR = configuration.sdrGamut
        settingsViewModel.exportFormatHDR = configuration.hdrFormat
        settingsViewModel.exportQualityHDR = configuration.hdrQuality
        settingsViewModel.exportColorGamutHDR = configuration.hdrGamut
        settingsViewModel.exportTIFFCompression = configuration.tiffCompression
        settingsViewModel.exportResolutionLimit = configuration.resolutionLimit
        settingsViewModel.exportLocationMode = configuration.locationMode
        settingsViewModel.exportCustomSubfolderName = configuration.customSubfolderName
    }

    /// Prompts the user to pick a destination folder for `.askOnSave` exports.
    /// Returns nil if the user cancels.
    @MainActor
    private func promptForExportDestination(
        message: String = "Choose a destination folder for exported files"
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = browserViewModel.currentFolderURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func renderAndSignSelected() {
        performAfterMetadataFileOperation { renderAndSignSelectedAfterMetadataFlush() }
    }

    private func renderAndSignSelectedAfterMetadataFlush() {
        guard C2PASigningService.isAvailable else {
            browserViewModel.errorMessage = "c2patool not found in app bundle"
            return
        }
        guard !isRenderingEditedFolder else { return }

        let certPath = settingsViewModel.c2paCertificatePath
        let usesTestCertificate = settingsViewModel.c2paUseTestCertificate
        guard settingsViewModel.c2paHasCertificate else {
            browserViewModel.errorMessage = "No signing certificate configured. Import one in Settings → Signing."
            return
        }

        let selected = browserViewModel.selectedImages
        guard !selected.isEmpty else {
            browserViewModel.errorMessage = "No images selected"
            return
        }

        let privateKeyPEM = usesTestCertificate ? "" : KeychainService.load(forKey: "c2pa_private_key")
        guard let privateKeyPEM else {
            browserViewModel.errorMessage = "No private key found in Keychain for C2PA signing."
            return
        }

        guard let folderURL = browserViewModel.currentFolderURL else { return }

        let author = settingsViewModel.c2paDefaultAuthor.isEmpty ? nil : settingsViewModel.c2paDefaultAuthor

        let locationMode = EditedImageRenderer.currentLocationMode
        var askedFolder: URL?
        if locationMode == .askOnSave {
            guard let chosen = promptForExportDestination() else { return }
            askedFolder = chosen
        }

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = selected.count
        renderEditedFolderSuccessCount = 0
        renderEditedFolderFailureCount = 0

        // Capture the pane that started the sign so the final refresh targets it.
        let browserViewModel = browserViewModel
        renderExportTask = Task {
            defer { renderExportTask = nil }
            let urls = selected.map(\.url)
            let failureTracker = MetadataFailureTracker()

            // Read metadata and overlay CameraRawSettings
            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.metadataReadService.readBatchFullMetadata(urls: urls)
                try await EditExportPipeline.resolveCameraRaw(
                    into: &metadataByURL,
                    urls: urls,
                    inMemory: browserViewModel.currentCameraRawSettings
                )
            } catch is CancellationError {
                // Release the export gate, or every later Export/Save As/Sign is a no-op.
                isRenderingEditedFolder = false
                return
            } catch {
                isRenderingEditedFolder = false
                browserViewModel.errorMessage = "Failed to read metadata: \(error.localizedDescription)"
                return
            }

            var successCount = 0
            var failureCount = 0
            var signFailures: [BatchOperationResult.Failure] = []
            var signedURLs: [URL] = []
            var createdFolders: Set<String> = []
            var lastOutputFolder: URL?

            for (index, image) in selected.enumerated() {
                guard !Task.isCancelled else { break }
                renderExportCurrent = index + 1
                let cameraRaw = metadataByURL[image.url]?.cameraRaw
                let isHDR = cameraRaw?.hdrEditMode == 1

                // Determine output folder per the configured export location mode
                let outputFolder = EditedImageRenderer.resolveOutputFolder(
                    sourceURL: image.url, rootFolder: folderURL,
                    isHDR: isHDR, formatPrefix: "Signed", askedFolder: askedFolder)

                // Create folder on first encounter
                if !createdFolders.contains(outputFolder.path) {
                    do {
                        _ = try await ExportDirectoryService.shared.ensureDirectory(at: outputFolder)
                        createdFolders.insert(outputFolder.path)
                        lastOutputFolder = outputFolder
                    } catch {
                        failureCount += 1
                        signFailures.append(.init(filename: image.url.lastPathComponent, error: error))
                        continue
                    }
                }

                var unsignedRenderURL: URL?
                do {
                    // Step 1: Render + copy source metadata + overlay pending IPTC edits
                    let renderedURL = try await EditExportPipeline.renderForDelivery(
                        sourceURL: image.url, cameraRaw: cameraRaw, kind: .format,
                        outputFolder: outputFolder, folderURL: folderURL,
                        writeEngine: browserViewModel.writeEngine, failureTracker: failureTracker)
                    unsignedRenderURL = renderedURL

                    // Step 2: Build C2PA actions from edit settings
                    let actions = C2PAAction.fromSettings(cameraRaw)

                    // Step 3: Sign — preserve history if source already had C2PA
                    if image.hasC2PA {
                        try await C2PASigningService.signWithParentIngredient(
                            imageURL: renderedURL,
                            parentURL: image.url,
                            certificatePath: usesTestCertificate ? "" : certPath,
                            privateKeyPEM: privateKeyPEM,
                            author: author,
                            actions: actions
                        )
                    } else {
                        try await C2PASigningService.sign(
                            imageURL: renderedURL,
                            certificatePath: usesTestCertificate ? "" : certPath,
                            privateKeyPEM: privateKeyPEM,
                            author: author,
                            actions: actions
                        )
                    }

                    successCount += 1
                    signedURLs.append(renderedURL)
                } catch {
                    failureCount += 1
                    signFailures.append(.init(filename: image.url.lastPathComponent, error: error))
                    // A Signed_* folder must only hold signed files: discard the unsigned
                    // render so it can't be mistaken for (or delivered as) a signed copy.
                    // A metadata-incomplete render throws after finalizing, before returning.
                    if let unsigned = unsignedRenderURL ?? (error as? ExportMetadataIncompleteError)?.renderedURL {
                        try? FileManager.default.removeItem(at: unsigned)
                    }
                }
            }

            renderEditedFolderSuccessCount = successCount
            renderEditedFolderFailureCount = failureCount
            isRenderingEditedFolder = false

            // Files written next to the originals land in the current folder — refresh to show them.
            if locationMode == .sameAsOriginal {
                browserViewModel.refreshCurrentFolderIfNeeded()
            } else if let outputFolder = lastOutputFolder, outputFolder != folderURL {
                // Files went into a sub-folder — surface it in the sidebar tree.
                browserViewModel.revealExportedSubfolder(outputFolder)
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let watermarkWarnings = await failureTracker.missingWatermarkWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if failureCount > 0 || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty || !watermarkWarnings.isEmpty {
                outcome = .partial
            } else {
                outcome = .success
            }
            isBatchResultExpanded = false
            lastBatchResult = BatchOperationResult(
                title: "Sign",
                outcome: outcome,
                successCount: successCount,
                totalCount: selected.count,
                failures: signFailures,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                missingWatermarkFilenames: watermarkWarnings,
                sourceFolderURL: folderURL,
                outputURLs: signedURLs
            )
        }
    }

    // MARK: - Copy & Paste IPTC

    private func copyIPTCMetadata() {
        performAfterMetadataFileOperation { copyIPTCMetadataAfterMetadataFlush() }
    }

    private func copyIPTCMetadataAfterMetadataFlush() {
        guard browserViewModel.selectedImages.count == 1 else {
            browserViewModel.errorMessage = "Select a single image to copy IPTC metadata from."
            return
        }

        let selectedURL = browserViewModel.selectedImages.first?.url
        let source: IPTCMetadata
        if mainViewMode == .metadataReview, let reviewed = browserViewModel.selectedImages.first?.metadata {
            source = reviewed
        } else {
            // Selection loads are debounced: until the editor describes the selected photo, its
            // buffer still holds the previously selected photo's metadata.
            guard let selectedURL, metadataViewModel.selectedURLs == [selectedURL],
                  !metadataViewModel.isLoading, metadataViewModel.metadata != nil else {
                browserViewModel.errorMessage = "The selected photo's metadata is still loading. Try Copy IPTC again."
                return
            }
            source = metadataViewModel.editingMetadata
        }
        browserViewModel.copiedIPTCMetadata = source.copyableIPTCRecord
    }

    private func pasteIPTCMetadata() {
        performAfterMetadataFileOperation { pasteIPTCMetadataAfterMetadataFlush() }
    }

    private func pasteIPTCMetadataAfterMetadataFlush() {
        guard let copied = browserViewModel.copiedIPTCMetadata else {
            browserViewModel.errorMessage = "No IPTC metadata copied."
            return
        }

        let selected = browserViewModel.selectedImages
        guard !selected.isEmpty else {
            browserViewModel.errorMessage = "No images selected."
            return
        }

        guard browserViewModel.currentFolderURL != nil else { return }

        // Preserve the historical no-op for a completely blank copied record while allowing a
        // structured-only record (including localized Title intent) to reach the writer.
        guard copied.hasDescriptiveContent else { return }
        // Each photo follows the configured write preset: RAW and (by default) C2PA get an
        // XMP sidecar that keeps Develop settings; other files are embedded.
        let targets = selected.map { image in
            (url: image.url, mode: MetadataWriteMode.current(
                forC2PA: image.hasC2PA, isRaw: SupportedImageFormats.isRaw(url: image.url)))
        }
        let boundary = DescriptiveMetadataWriteBoundary(writeEngine: browserViewModel.writeEngine)

        let folderURL = browserViewModel.currentFolderURL
        Task {
            let summary = await boundary.pasteMerging(copied, into: targets)
            if let folderURL {
                await metadataViewModel.applyPastedIPTCToPendingDrafts(copied, urls: summary.written, in: folderURL)
            }
            if let message = summary.problemMessage {
                browserViewModel.errorMessage = message
            }
            browserViewModel.refreshPendingStatusBatch(for: summary.written)

            // Reload metadata panel to reflect changes
            reloadMetadataForSelection()
        }
    }

    // MARK: - Helpers

    private func closeTemplatePalette(restoringGridFocus: Bool) {
        isShowingTemplatePalette = false
        captionTemplateAppendOverride = nil
        switch CaptionWorkspaceFocusRestorePolicy.target(
            afterTransientPresentationInCaptionWorkspace: mainViewMode == .caption,
            restoreRequested: restoringGridFocus
        ) {
        case .captionEditor:
            commandRouter.send(.restoreCaptionEditorFocus)
        case .browserGrid:
            restoreGridFocus()
        case .unchanged:
            break
        }
    }

    private func closeDevelopTemplatePalette() {
        isShowingDevelopTemplatePalette = false
    }

    private func restoreGridFocus() {
        let targetViewModel = browserViewModel
        DispatchQueue.main.async {
            targetViewModel.shouldRestoreGridFocus = true
        }
    }

    private func reloadMetadataForSelection() {
        let selected = browserViewModel.selectedImages
        metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
    }

    private func applyTemplate(_ template: MetadataTemplate, append: Bool = false) {
        // The template belongs to the photos selected when it was invoked. The editor loads a
        // new selection only after a debounce, and that load replaces the editor; applying
        // before it completes would hit the previous photo or be discarded.
        let targets = browserViewModel.selectedImages
        let targetURLs = Set(targets.map(\.url))
        let metadataViewModel = metadataViewModel
        let editorMatches = Set(metadataViewModel.selectedURLs) == targetURLs
        if editorMatches, !metadataViewModel.isLoading, !metadataViewModel.isLoadingBatchMetadata {
            applyTemplateToEditor(template, to: targets, append: append)
            return
        }
        if !editorMatches {
            metadataViewModel.loadSelectionMetadataNow(for: targets, folderURL: browserViewModel.currentFolderURL)
        }
        let browserViewModel = browserViewModel
        Task {
            await metadataViewModel.waitForMetadataLoad()
            // The selection may have moved on while the photos loaded; its save already ran and
            // the next load would discard the template, so say so instead of dropping it.
            guard Set(metadataViewModel.selectedURLs) == targetURLs,
                  Set(browserViewModel.selectedImages.map(\.url)) == targetURLs,
                  !metadataViewModel.isLoading, !metadataViewModel.isLoadingBatchMetadata else {
                metadataViewModel.notice = MetadataPanelNotice(
                    title: "Template “\(template.name)” was not applied",
                    detail: ["The selection changed before its metadata finished loading. Apply the template again."],
                    severity: .warning)
                return
            }
            applyTemplateToEditor(template, to: targets, append: append)
        }
    }

    private func applyTemplateToEditor(_ template: MetadataTemplate, to appliedImages: [ImageFile], append: Bool) {
        // Apply raw template values — variables like {date} and {persons}
        // stay as-is until the user clicks "Process Variables"
        var raw: [String: String] = [:]
        for field in template.fields {
            raw[field.fieldKey] = field.templateValue
        }
        if template.processInstantly {
            // Snapshot the images the template is being applied to right now.
            // The user may change the selection while the async variable
            // resolution runs, so the resolved values must be written back to
            // exactly these images, not whatever is selected later.
            metadataViewModel.applyTemplateFieldsAndProcessVariables(raw, to: appliedImages, append: append)
        } else {
            metadataViewModel.applyTemplateFields(raw, append: append)
        }
    }

    private func loadTechnicalMetadata() {
        technicalMetadataTask?.cancel()
        technicalMetadataTask = nil
        let requestID = UUID()
        technicalMetadataRequestID = requestID

        guard browserViewModel.selectedImageIDs.count == 1,
              let image = browserViewModel.selectedImages.first else {
            technicalMetadata = nil
            loadScopeImage(for: nil)
            return
        }

        // Load scope for browse mode (edit mode posts its own notification)
        loadBrowseScopeImage(for: image)

        if let cached = technicalMetadataCache[image.url] {
            technicalMetadata = cached
            return
        }

        let url = image.url
        let hasC2PA = image.hasC2PA
        let readService = browserViewModel.metadataReadService
        // Do not leave the previous image's inspector values visible while this selection loads.
        technicalMetadata = nil
        technicalMetadataTask = Task {
            let fastResult = await TechnicalMetadataFastLoadService.shared.load(
                imageURL: url,
                hasC2PA: hasC2PA,
                requestID: requestID
            )
            guard !Task.isCancelled,
                  technicalMetadataRequestID == requestID,
                  browserViewModel.selectedImages.first?.url == url,
                  case .loaded(let snapshot) = fastResult,
                  snapshot.requestID == requestID,
                  snapshot.imageURL == url else { return }
            let fast = snapshot.metadata
            technicalMetadata = fast

            // Always enrich from SwiftExif for formats ImageIO cannot fully parse and for
            // MakerNote-only fields. The fast path already read native dimensions/profile,
            // so tell this pass not to repeat the same ImageIO header read.
            guard let exifMeta = try? await readService.readTechnicalMetadata(
                url: url,
                includeNativeImageInfo: false
            ), !Task.isCancelled,
                  technicalMetadataRequestID == requestID,
                  browserViewModel.selectedImages.first?.url == url else {
                if technicalMetadataRequestID == requestID,
                   browserViewModel.selectedImages.first?.url == url {
                    technicalMetadataCache[url] = fast
                }
                return
            }
            // When ImageIO already supplied camera fields, keep them and overlay only the
            // MakerNote extras; otherwise take exifMeta's camera/exposure fields wholesale.
            let merged = fast.hasCameraInfo
                ? fast.mergingTechnicalExtras(from: exifMeta)
                : fast.mergingCameraFields(from: exifMeta)
            technicalMetadataCache[url] = merged
            technicalMetadata = merged
        }
    }

    /// Browse-mode scope source for the single selected photo. While the scopes are collapsed
    /// nothing displays them, so the second 720 px decode (a full RAW read on a NAS) is skipped
    /// and any stale scope image cleared; expanding them calls `reloadBrowseScopeImage()`.
    private func loadBrowseScopeImage(for image: ImageFile) {
        guard BrowseScopeLoadPolicy.shouldDecode(scopesExpanded: scopesExpanded, mainViewMode: mainViewMode) else {
            // Still set the waveform scale and gamut from the photo: full screen's gamut-clip
            // overlay reads them with the scopes collapsed.
            if mainViewMode != .editing { loadScopeImage(for: nil, isNativeHDR: image.isNativeHDR) }
            return
        }
        loadScopeImage(
            for: image.url,
            isNativeHDR: image.isNativeHDR,
            settings: image.cameraRawSettings,
            exifOrientation: image.exifOrientation
        )
    }

    /// Expanding the scopes loads them for the current selection (the selection load skipped it).
    private func reloadBrowseScopeImage() {
        guard browserViewModel.selectedImageIDs.count == 1,
              let image = browserViewModel.selectedImages.first else { return }
        loadBrowseScopeImage(for: image)
    }

    private func loadScopeImage(
        for url: URL?,
        isNativeHDR: Bool = false,
        settings: CameraRawSettings? = nil,
        exifOrientation: Int = 1
    ) {
        scopeImageTask?.cancel()
        scopeImageTask = nil
        scopeViewModel.waveformScale = isNativeHDR ? .nits : .percentage
        scopeViewModel.targetGamut = isNativeHDR ? settingsViewModel.exportColorGamutHDR : settingsViewModel.exportColorGamutSDR

        guard let url else {
            scopeViewModel.updateImage(nil)
            return
        }

        // Mirror the edit-view scope: when the browse-mode image carries develop edits,
        // bake them (and the crop) into the scope source so the waveform matches what the
        // user sees in the develop view and in the edited thumbnail. Without this the scope
        // reads the unedited pixels and looks very different across the two views.
        let editSettings = (settings?.isEmpty == false) ? settings : nil

        scopeImageTask = Task {
            // Detached to keep the decode at utility priority off MainActor, but forward the
            // selection change's cancellation to it so a superseded decode stops at the next
            // stage boundary instead of reading the rest of the file.
            // The source lands in the display orientation (sidecar-first), like full screen.
            let decode = Task.detached(priority: .utility) { () -> CGImage? in
                FullScreenImageCache.browseScopeSource(
                    for: url,
                    isNativeHDR: isNativeHDR,
                    settings: editSettings,
                    displayOrientation: exifOrientation
                )
            }
            let cgImage = await withTaskCancellationHandler {
                await decode.value
            } onCancel: {
                decode.cancel()
            }
            guard !Task.isCancelled else { return }
            scopeViewModel.updateImage(cgImage)
        }
    }

    private func croppedResolutionString(metadata: TechnicalMetadata?, orientation: Int) -> String? {
        guard let meta = metadata,
              let w = meta.imageWidth, let h = meta.imageHeight,
              let crop = metadataViewModel.editingMetadata.cameraRaw?.crop,
              crop.hasCrop == true else { return nil }

        let displayCrop = crop.transformedForDisplay(orientation: orientation)
        let cropW = (displayCrop.right ?? 1) - (displayCrop.left ?? 0)
        let cropH = (displayCrop.bottom ?? 1) - (displayCrop.top ?? 0)

        // Swap dimensions for rotated orientations (5–8)
        let (displayW, displayH): (Int, Int)
        switch orientation {
        case 5, 6, 7, 8: (displayW, displayH) = (h, w)
        default: (displayW, displayH) = (w, h)
        }

        // safeInt: a crafted/corrupt XMP crop value of inf/nan would otherwise trap Int(_:).
        guard let croppedW = safeInt((Double(displayW) * cropW).rounded()),
              let croppedH = safeInt((Double(displayH) * cropH).rounded()) else { return nil }

        // Don't show if essentially full resolution
        if croppedW >= displayW && croppedH >= displayH { return nil }

        return "\(croppedW) x \(croppedH)"
    }

    private func loadC2PADetail() {
        guard let image = browserViewModel.selectedImages.first else { return }
        c2paValidation = nil
        // Present first; the sheet owns its loading and retry lifecycle so a
        // slow or failed C2PA read can never make the user's action go silent.
        c2paDetailPresentation = C2PADetailPresentation(imageURL: image.url)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @ViewBuilder
    private func batchResultBanner(_ result: BatchOperationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: bannerIcon(for: result.outcome, hasFailures: result.hasFailures))
                    .foregroundStyle(bannerColor(for: result.outcome, hasFailures: result.hasFailures))
                Text(result.summaryLine)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !result.outputURLs.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(result.outputURLs)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .help("Reveal the exported files in Finder")
                }
                Button {
                    lastBatchResult = nil
                    isBatchResultExpanded = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            if result.hasFailures || result.hasWarnings {
                DisclosureGroup(isExpanded: $isBatchResultExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        bannerItemFailureSection(label: "Failed", failures: result.failures, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "Metadata copy failed", names: result.copyFailureFilenames, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "IPTC overlay failed", names: result.overlayFailureFilenames, folder: result.sourceFolderURL)
                        bannerPathFailureSection(label: "Private cleanup needed", paths: result.cleanupFailurePaths)
                        bannerFailureSection(label: "Used embedded metadata (.xmp sidecar stale)", names: result.staleSidecarFilenames, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "Exported without watermark (image missing)", names: result.missingWatermarkFilenames, folder: result.sourceFolderURL)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Show details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: result.id) {
            // Auto-dismiss success-without-failures. Keep it up longer when it offers
            // "Show in Finder" so there is time to reach the exported files.
            guard !result.hasFailures, result.outcome == .success else { return }
            try? await Task.sleep(for: .seconds(result.outputURLs.isEmpty ? 4 : 15))
            if lastBatchResult?.id == result.id {
                lastBatchResult = nil
            }
        }
    }

    @ViewBuilder
    private func bannerItemFailureSection(
        label: String,
        failures: [BatchOperationResult.Failure],
        folder: URL?
    ) -> some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label) (\(failures.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    HStack(alignment: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(failure.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let reason = failure.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                        if let folder {
                            Button {
                                revealInFinder(folder.appendingPathComponent(failure.filename))
                            } label: {
                                Image(systemName: "folder")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerPathFailureSection(label: String, paths: [String]) -> some View {
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label) (\(paths.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 4) {
                        Text(path)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button {
                            revealInFinder(URL(fileURLWithPath: path))
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bannerFailureSection(label: String, names: [String], folder: URL?) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(label) (\(names.count))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 4) {
                        Text(name)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if let folder {
                            Button {
                                revealInFinder(folder.appendingPathComponent(name))
                            } label: {
                                Image(systemName: "folder")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                    }
                }
            }
        }
    }

    private func bannerIcon(for outcome: BatchOperationResult.Outcome, hasFailures: Bool) -> String {
        switch outcome {
        case .cancelled: return "xmark.circle"
        case .partial: return "exclamationmark.triangle.fill"
        case .success: return hasFailures ? "exclamationmark.triangle" : "checkmark.circle.fill"
        }
    }

    private func bannerColor(for outcome: BatchOperationResult.Outcome, hasFailures: Bool) -> Color {
        switch outcome {
        case .cancelled: return .secondary
        case .partial: return .orange
        case .success: return hasFailures ? .orange : .green
        }
    }

    private func saveSelectedAs(format: EditedImageRenderer.SaveAsFormat) {
        performAfterMetadataFileOperation { saveSelectedAsAfterMetadataFlush(format: format) }
    }

    private func saveSelectedAsAfterMetadataFlush(format: EditedImageRenderer.SaveAsFormat) {
        guard !isRenderingEditedFolder else { return }
        let urls = browserViewModel.selectedImages.map(\.url)
        guard !urls.isEmpty else { return }

        let locationMode = EditedImageRenderer.currentLocationMode
        var askedFolder: URL?
        if locationMode == .askOnSave {
            guard let chosen = promptForExportDestination() else { return }
            askedFolder = chosen
        }

        // Capture the pane and its folder now: `browserViewModel` follows the active
        // pane, so switching pane/folder mid-batch must not redirect the remaining
        // outputs, sidecar overlays or Reveal links to another folder.
        let browser = browserViewModel
        let sourceFolderURL = browser.currentFolderURL

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = urls.count

        renderExportTask = Task {
            defer { renderExportTask = nil }
            let failureTracker = MetadataFailureTracker()
            var createdFolders: Set<String> = []

            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browser.metadataReadService.readBatchFullMetadata(urls: urls)
                try await EditExportPipeline.resolveCameraRaw(
                    into: &metadataByURL,
                    urls: urls,
                    inMemory: browser.currentCameraRawSettings
                )
            } catch is CancellationError {
                // Release the export gate, or every later Export/Save As/Sign is a no-op.
                isRenderingEditedFolder = false
                return
            } catch {
                isRenderingEditedFolder = false
                browser.errorMessage = "Failed to read metadata: \(error.localizedDescription)"
                return
            }

            var savedURLs: [URL] = []
            var saveFailures: [BatchOperationResult.Failure] = []
            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                renderExportCurrent = index + 1
                let cameraRaw = metadataByURL[url]?.cameraRaw
                do {
                    // Resolve destination folder per the configured export location mode.
                    // Save As always renders SDR (JPEG/PNG), so use isHDR: false for naming,
                    // and name the format sub-folder after the Save As format rather than
                    // the configured Export format.
                    let rootFolder = sourceFolderURL ?? url.deletingLastPathComponent()
                    let destinationFolder = EditedImageRenderer.resolveOutputFolder(
                        sourceURL: url, rootFolder: rootFolder,
                        isHDR: false, formatPrefix: "Edited", askedFolder: askedFolder,
                        sdrFormat: format.exportFormat)
                    if !createdFolders.contains(destinationFolder.path) {
                        _ = try await ExportDirectoryService.shared.ensureDirectory(at: destinationFolder)
                        createdFolders.insert(destinationFolder.path)
                    }

                    let outputURL = try await EditExportPipeline.renderItem(
                        sourceURL: url, cameraRaw: cameraRaw, kind: .saveAs(format),
                        outputFolder: destinationFolder, folderURL: sourceFolderURL,
                        writeEngine: browser.writeEngine, failureTracker: failureTracker)
                    savedURLs.append(outputURL)
                } catch {
                    saveFailures.append(.init(filename: url.lastPathComponent, error: error))
                }
            }

            isRenderingEditedFolder = false

            // Add saved files to browser if they're in the same folder; otherwise
            // surface the sub-folder(s) they landed in within the sidebar tree.
            let destinationFolders = Set(savedURLs.map { $0.deletingLastPathComponent() })
            if let folderURL = sourceFolderURL {
                if destinationFolders.contains(folderURL), browser.currentFolderURL == folderURL {
                    browser.refreshCurrentFolderIfNeeded()
                }
                for subfolder in destinationFolders where subfolder != folderURL {
                    browser.revealExportedSubfolder(subfolder)
                }
            } else {
                for subfolder in destinationFolders {
                    browser.revealExportedSubfolder(subfolder)
                }
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let watermarkWarnings = await failureTracker.missingWatermarkWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if !saveFailures.isEmpty || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty || !watermarkWarnings.isEmpty {
                outcome = .partial
            } else {
                outcome = .success
            }
            isBatchResultExpanded = false
            lastBatchResult = BatchOperationResult(
                title: "Save As",
                outcome: outcome,
                successCount: savedURLs.count,
                totalCount: urls.count,
                failures: saveFailures,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                missingWatermarkFilenames: watermarkWarnings,
                sourceFolderURL: sourceFolderURL,
                outputURLs: savedURLs
            )
        }
    }

    private func archiveSelectedRAW(as format: RAWArchiveFormat) {
        performAfterMetadataFileOperation { archiveSelectedRAWAfterMetadataFlush(as: format) }
    }

    private func archiveSelectedRAWAfterMetadataFlush(as format: RAWArchiveFormat) {
        guard !isRenderingEditedFolder else { return }
        let selectedRAW = browserViewModel.selectedImages
            .filter { SupportedImageFormats.isRaw(url: $0.url) }
        let urls = selectedRAW.map(\.url)
        guard !urls.isEmpty else { return }

        let c2paRAWURLs = Set(
            selectedRAW.lazy
                .filter(\.hasC2PA)
                .map(\.url)
        )
        let archiveSigningConfiguration: C2PAArchiveSigningConfiguration?
        if c2paRAWURLs.isEmpty {
            archiveSigningConfiguration = nil
        } else {
            archiveSigningConfiguration = makeC2PAArchiveSigningConfiguration()
            if archiveSigningConfiguration == nil,
               !confirmUnsignedC2PAArchive(count: c2paRAWURLs.count) {
                return
            }
        }

        let locationMode = RAWArchiveService.currentLocationMode
        var askedFolder: URL?
        if locationMode == .askEveryTime {
            guard let chosen = promptForExportDestination(
                message: "Choose a destination folder for this RAW archive batch"
            ) else { return }
            askedFolder = chosen
        }

        let configuredIngestRoot: URL?
        let configuredArchiveRoot: URL?
        if locationMode == .mirroredArchiveRoot {
            configuredIngestRoot = RAWArchiveService.ingestRootURL
            configuredArchiveRoot = RAWArchiveService.archiveRootURL
        } else {
            configuredIngestRoot = nil
            configuredArchiveRoot = nil
        }

        do {
            for url in urls {
                _ = try RAWArchiveService.destinationFolder(
                    for: url,
                    manualDestination: askedFolder,
                    mode: locationMode,
                    ingestRoot: configuredIngestRoot,
                    archiveRoot: configuredArchiveRoot
                )
            }
        } catch {
            browserViewModel.errorMessage = error.localizedDescription
            return
        }

        // Capture the pane and its folder now (see Save As): the active pane can change
        // while the batch runs.
        let browser = browserViewModel
        let sourceFolderURL = browser.currentFolderURL

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = urls.count

        renderExportTask = Task {
            defer { renderExportTask = nil }
            let dngConverterURL: URL?
            if format.requiresAdobeDNGConverter {
                let discovery = await AdobeDNGDiscoveryStore.shared.refresh()
                guard !Task.isCancelled else {
                    isRenderingEditedFolder = false
                    return
                }
                guard case .complete(let installedURL?) = discovery else {
                    isRenderingEditedFolder = false
                    browser.errorMessage = "Adobe DNG Converter is required for DNG archiving. Install the free converter from Adobe, then try again."
                    return
                }
                dngConverterURL = installedURL
            } else {
                dngConverterURL = nil
            }
            let securityScopeRequest = RAWArchiveSecurityScopeRequest(
                ingestRoot: configuredIngestRoot,
                archiveRoot: configuredArchiveRoot
            )
            let securityScopeAcquisition = await RAWArchiveSecurityScopeService.shared.acquire(
                securityScopeRequest
            )
            let securityScopeClaim: RAWArchiveSecurityScopeClaim?
            switch securityScopeAcquisition {
            case .acquired(let claim):
                securityScopeClaim = claim
            case .cancelledBeforeAccess, .cancelledAfterAccess:
                securityScopeClaim = nil
            }
            let failureTracker = MetadataFailureTracker()
            var createdFolders: Set<String> = []

            var convertedURLs: [URL] = []
            var archiveFailures: [BatchOperationResult.Failure] = []
            var cleanupFailurePaths: [String] = []
            for (index, url) in urls.enumerated() where securityScopeClaim != nil {
                guard !Task.isCancelled else { break }
                renderExportCurrent = index + 1
                do {
                    let destinationFolder = try RAWArchiveService.destinationFolder(
                        for: url,
                        manualDestination: askedFolder,
                        mode: locationMode,
                        ingestRoot: configuredIngestRoot,
                        archiveRoot: configuredArchiveRoot
                    )
                    if !createdFolders.contains(destinationFolder.path) {
                        _ = try await ExportDirectoryService.shared.ensureDirectory(at: destinationFolder)
                        createdFolders.insert(destinationFolder.path)
                    }

                    let renderKind: RenderKind
                    switch format {
                    case .jpegXLLinear:
                        renderKind = .rawJXL16(.linear)
                    case .jpegXLCamera:
                        renderKind = .rawJXL16(.camera)
                    case .tiffLinear:
                        renderKind = .rawTIFF16(.linear)
                    case .tiffCamera:
                        renderKind = .rawTIFF16(.camera)
                    case .dngLossless:
                        guard let dngConverterURL else {
                            throw AdobeDNGConverterError.notInstalled
                        }
                        renderKind = .rawDNG(
                            .lossless,
                            executableURL: dngConverterURL
                        )
                    case .dngLossy:
                        guard let dngConverterURL else {
                            throw AdobeDNGConverterError.notInstalled
                        }
                        renderKind = .rawDNG(
                            .lossy,
                            executableURL: dngConverterURL
                        )
                    }

                    let currentFolderURL = sourceFolderURL
                    let writeEngine = browser.writeEngine
                    let signer: RAWArchiveTransactionRequest.Sign?
                    if c2paRAWURLs.contains(url), let archiveSigningConfiguration {
                        signer = { archiveURL, parentURL in
                            try await archiveSigningConfiguration.sign(
                                archiveURL: archiveURL,
                                parentURL: parentURL,
                                format: format
                            )
                        }
                    } else {
                        signer = nil
                    }
                    let receipt = try await RAWArchiveTransactionService.shared.archive(
                        RAWArchiveTransactionRequest(
                            sourceURL: url,
                            destinationFolder: destinationFolder,
                            fileExtension: format.fileExtension,
                            render: { sourceURL, stagingDirectory in
                                try await EditExportPipeline.renderItem(
                                    sourceURL: sourceURL,
                                    cameraRaw: nil,
                                    kind: renderKind,
                                    outputFolder: stagingDirectory,
                                    folderURL: currentFolderURL,
                                    writeEngine: writeEngine,
                                    failureTracker: failureTracker
                                )
                            },
                            sign: signer
                        )
                    )
                    convertedURLs.append(receipt.archiveURL)
                    cleanupFailurePaths.append(contentsOf: receipt.cleanupResidualURLs.map(\.path))
                } catch {
                    archiveFailures.append(.init(filename: url.lastPathComponent, error: error))
                }
            }

            if let securityScopeClaim {
                _ = await RAWArchiveSecurityScopeService.shared.release(securityScopeClaim)
            }

            isRenderingEditedFolder = false

            let destinationFolders = Set(convertedURLs.map { $0.deletingLastPathComponent() })
            if let folderURL = sourceFolderURL {
                if destinationFolders.contains(folderURL), browser.currentFolderURL == folderURL {
                    browser.refreshCurrentFolderIfNeeded()
                }
                for subfolder in destinationFolders where subfolder != folderURL {
                    browser.revealExportedSubfolder(subfolder)
                }
            } else {
                for subfolder in destinationFolders {
                    browser.revealExportedSubfolder(subfolder)
                }
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let watermarkWarnings = await failureTracker.missingWatermarkWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if !archiveFailures.isEmpty || !copyFailures.isEmpty
                        || !overlayFailures.isEmpty || !cleanupFailurePaths.isEmpty
                        || !staleWarnings.isEmpty || !watermarkWarnings.isEmpty {
                outcome = .partial
            } else {
                outcome = .success
            }
            isBatchResultExpanded = false
            lastBatchResult = BatchOperationResult(
                title: format.batchTitle,
                outcome: outcome,
                successCount: convertedURLs.count,
                totalCount: urls.count,
                failures: archiveFailures,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                cleanupFailurePaths: cleanupFailurePaths,
                staleSidecarFilenames: staleWarnings,
                missingWatermarkFilenames: watermarkWarnings,
                sourceFolderURL: sourceFolderURL,
                outputURLs: convertedURLs
            )
        }
    }

    private func makeC2PAArchiveSigningConfiguration()
        -> C2PAArchiveSigningConfiguration? {
        guard C2PASigningService.isAvailable,
              settingsViewModel.c2paHasCertificate
        else {
            return nil
        }

        let usesTestCertificate = settingsViewModel.c2paUseTestCertificate
        let privateKeyPEM: String
        if usesTestCertificate {
            privateKeyPEM = ""
        } else {
            guard let storedKey = KeychainService.load(
                forKey: "c2pa_private_key"
            ), !storedKey.isEmpty else {
                return nil
            }
            privateKeyPEM = storedKey
        }

        return C2PAArchiveSigningConfiguration(
            certificatePath: settingsViewModel.c2paCertificatePath,
            privateKeyPEM: privateKeyPEM,
            author: settingsViewModel.c2paDefaultAuthor,
            usesTestCertificate: usesTestCertificate
        )
    }

    @MainActor
    private func confirmUnsignedC2PAArchive(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Archive Files Will Be Unsigned"
        let noun = count == 1 ? "RAW file contains" : "RAW files contain"
        alert.informativeText = """
        \(count) selected \(noun) C2PA Content Credentials. Creating an archive produces a new file, so the original signature cannot simply be copied.

        No usable signing identity is configured. The archive file will be unsigned and will not carry the original provenance chain. The source RAW remains unchanged.

        Configure a certificate or test signature in Settings → Signing to sign archives and link each source as its parent ingredient.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Archive Unsigned")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func renderAndSaveEditedFolder(
        urls: [URL]? = nil,
        configurations: [AdvancedExportConfiguration]? = nil
    ) {
        performAfterMetadataFileOperation {
            renderAndSaveEditedFolderAfterMetadataFlush(urls: urls, configurations: configurations)
        }
    }

    private func renderAndSaveEditedFolderAfterMetadataFlush(
        urls: [URL]?,
        configurations: [AdvancedExportConfiguration]?
    ) {
        guard !isRenderingEditedFolder,
              let folderURL = browserViewModel.currentFolderURL else { return }
        let urls = urls ?? browserViewModel.images.map(\.url)
        guard !urls.isEmpty else { return }

        let exportConfigurations: [AdvancedExportConfiguration?]
        if let configurations, !configurations.isEmpty {
            exportConfigurations = configurations.map(Optional.some)
        } else {
            exportConfigurations = [nil]
        }

        var askedFolders: [Int: URL] = [:]
        for (index, configuration) in exportConfigurations.enumerated()
        where (configuration?.locationMode ?? EditedImageRenderer.currentLocationMode) == .askOnSave {
            let exportName = index == 0 ? "primary" : "secondary"
            guard let chosen = promptForExportDestination(
                message: "Choose a destination folder for the \(exportName) export"
            ) else { return }
            askedFolders[index] = chosen
        }

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = urls.count * exportConfigurations.count
        renderEditedFolderSuccessCount = 0
        renderEditedFolderFailureCount = 0

        // Capture the pane that started the export so the final refresh targets it.
        let browserViewModel = browserViewModel
        renderExportTask = Task {
            defer { renderExportTask = nil }
            let failureTracker = MetadataFailureTracker()

            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.metadataReadService.readBatchFullMetadata(urls: urls)
                try await EditExportPipeline.resolveCameraRaw(
                    into: &metadataByURL,
                    urls: urls,
                    inMemory: browserViewModel.currentCameraRawSettings
                )
            } catch is CancellationError {
                // Release the export gate, or every later Export/Save As/Sign is a no-op.
                isRenderingEditedFolder = false
                return
            } catch {
                isRenderingEditedFolder = false
                browserViewModel.errorMessage = "Failed to read metadata for export: \(error.localizedDescription)"
                return
            }

            var successCount = 0
            var failureCount = 0
            var renderFailures: [BatchOperationResult.Failure] = []
            var exportedURLs: [URL] = []
            var createdFolders: Set<String> = []
            var lastOutputFolder: URL?

            for (urlIndex, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                let cameraRaw = metadataByURL[url]?.cameraRaw
                let isHDR = cameraRaw?.hdrEditMode == 1

                for (configurationIndex, configuration) in exportConfigurations.enumerated() {
                    guard !Task.isCancelled else { break }
                    renderExportCurrent =
                        urlIndex * exportConfigurations.count + configurationIndex + 1
                    let isSecondary = configurationIndex > 0
                    let failureDisplayName = isSecondary
                        ? "\(url.lastPathComponent) (Secondary)"
                        : url.lastPathComponent
                    let outputFolder = EditedImageRenderer.resolveOutputFolder(
                        sourceURL: url,
                        rootFolder: folderURL,
                        isHDR: isHDR,
                        formatPrefix: isSecondary ? "Edited_Secondary" : "Edited",
                        askedFolder: askedFolders[configurationIndex],
                        configuration: configuration
                    )

                    if !createdFolders.contains(outputFolder.path) {
                        do {
                            _ = try await ExportDirectoryService.shared.ensureDirectory(at: outputFolder)
                            createdFolders.insert(outputFolder.path)
                            lastOutputFolder = outputFolder
                        } catch {
                            browserViewModel.errorMessage = "Failed to create \(outputFolder.lastPathComponent) folder: \(error.localizedDescription)"
                            failureCount += 1
                            renderFailures.append(.init(
                                displayName: failureDisplayName,
                                filename: url.lastPathComponent,
                                reason: error.localizedDescription
                            ))
                            continue
                        }
                    }

                    do {
                        let outputURL = try await EditExportPipeline.renderItem(
                            sourceURL: url,
                            cameraRaw: cameraRaw,
                            kind: .format,
                            outputFolder: outputFolder,
                            folderURL: folderURL,
                            writeEngine: browserViewModel.writeEngine,
                            failureTracker: failureTracker,
                            configuration: configuration,
                            outputFilenameSuffix: isSecondary ? " Secondary" : "",
                            collisionPolicy: .appendNumber
                        )
                        successCount += 1
                        exportedURLs.append(outputURL)
                    } catch {
                        failureCount += 1
                        renderFailures.append(.init(
                            displayName: failureDisplayName,
                            filename: url.lastPathComponent,
                            reason: error.localizedDescription
                        ))
                    }
                }
            }

            renderEditedFolderSuccessCount = successCount
            renderEditedFolderFailureCount = failureCount
            isRenderingEditedFolder = false

            // Files written next to the originals land in the current folder — refresh to show them.
            let exportedBesideOriginals = exportConfigurations.contains {
                ($0?.locationMode ?? EditedImageRenderer.currentLocationMode) == .sameAsOriginal
            }
            if exportedBesideOriginals {
                browserViewModel.refreshCurrentFolderIfNeeded()
            } else if let outputFolder = lastOutputFolder, outputFolder != folderURL {
                // Files went into a sub-folder — surface it in the sidebar tree.
                browserViewModel.revealExportedSubfolder(outputFolder)
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let watermarkWarnings = await failureTracker.missingWatermarkWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if failureCount > 0 || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty || !watermarkWarnings.isEmpty {
                outcome = .partial
            } else {
                outcome = .success
            }
            isBatchResultExpanded = false
            lastBatchResult = BatchOperationResult(
                title: "Export",
                outcome: outcome,
                successCount: successCount,
                totalCount: urls.count * exportConfigurations.count,
                failures: renderFailures,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                missingWatermarkFilenames: watermarkWarnings,
                sourceFolderURL: folderURL,
                outputURLs: exportedURLs
            )
        }
    }

}

struct ContentViewModifiers: ViewModifier {
    let panes: BrowserPanesModel
    let browserViewModel: BrowserViewModel
    let metadataViewModel: MetadataViewModel
    let ftpViewModel: FTPViewModel
    let faceRecognitionViewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    let importViewModel: ImportViewModel
    let mainViewMode: MainViewMode
    /// Compare's focused photo, read when a rating/label command arrives (not in `body`).
    let comparisonFocusedURL: () -> URL?
    let commandRouter: AppCommandRouter
    let loadTechnicalMetadata: () -> Void
    let performAfterMetadataFlush: (@escaping @MainActor () -> Void) -> Void
    /// Previous/Next Image while Image Analysis is shown (offset -1 or 1).
    let selectAdjacentAnalysisImage: (Int) -> Void
    @Binding var technicalMetadataCache: [URL: TechnicalMetadata]
    @Binding var technicalMetadata: TechnicalMetadata?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @State private var selectionLoadTask: Task<Void, Never>?
    private let selectionDebounceNanoseconds: UInt64 = 200_000_000
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")

    private var comparisonFocusedImage: ImageFile? {
        guard mainViewMode == .comparison, let url = comparisonFocusedURL() else { return nil }
        return browserViewModel.image(at: url)
    }

    /// Kept out of `body` so the modifier chain stays within the type-checker budget.
    private func handleBrowserCommand(_ delivery: AppCommandDelivery?) {
        guard let delivery, !CaptionWorkspaceFlushCoordinator.shared.isTransitioning,
              !mainViewMode.suppressesHiddenSelectionCommand(delivery.command) else { return }
        // A vanished folder's hidden rows must not be rated, labelled or templated.
        if browserViewModel.isCurrentFolderUnavailable, delivery.command.requiresAvailableFolder { return }
        // Full-screen actions affect the photo on screen, not the hidden kept selection.
        if delivery.command.actsOnBrowserSelection {
            browserViewModel.collapseSelectionToFullScreenImage()
        }
        switch delivery.command {
        case .openFolder:
            performAfterMetadataFlush { browserViewModel.openFolder() }
        case .openRecentFolder(let url):
            let targetPane = panes.active
            performAfterMetadataFlush { targetPane.loadFolder(url: url, addToOpenFolders: true) }
        // Full screen shows one photo of a possibly larger selection; menu key
        // equivalents reach here instead of the full-screen window's key handler.
        // Compare likewise rates only its focused photo, which can have left the filter.
        case .setRating(let rating):
            if browserViewModel.isFullScreen {
                browserViewModel.setRatingOnFullScreenImage(rating)
            } else if let image = comparisonFocusedImage {
                browserViewModel.setRating(rating, imagesToMutate: [image])
            } else {
                browserViewModel.setRating(rating)
            }
        case .setLabel(let label):
            if browserViewModel.isFullScreen {
                browserViewModel.setLabelOnFullScreenImage(label)
            } else if let image = comparisonFocusedImage {
                browserViewModel.setLabel(label, imagesToMutate: [image])
            } else {
                browserViewModel.setLabel(label)
            }
        case .selectPreviousImage:
            if mainViewMode == .imageAnalysis {
                selectAdjacentAnalysisImage(-1)
            } else if browserViewModel.isFullScreen {
                browserViewModel.stepFullScreen(by: -1)
            } else if mainViewMode != .caption {
                browserViewModel.selectPrevious()
            }
        case .selectNextImage:
            if mainViewMode == .imageAnalysis {
                selectAdjacentAnalysisImage(1)
            } else if browserViewModel.isFullScreen {
                browserViewModel.stepFullScreen(by: 1)
            } else if mainViewMode != .caption {
                browserViewModel.selectNext()
            }
        case .rotateClockwise:
            if browserViewModel.isFullScreen {
                browserViewModel.rotateFullScreenImage(clockwise: true)
            } else {
                browserViewModel.rotateClockwise()
            }
        case .rotateCounterclockwise:
            if browserViewModel.isFullScreen {
                browserViewModel.rotateFullScreenImage(clockwise: false)
            } else {
                browserViewModel.rotateCounterclockwise()
            }
        case .openInExternalEditor:
            openSelectedInExternalEditor()
        case .deleteSelected:
            performAfterMetadataFlush {
                if browserViewModel.isFullScreen {
                    browserViewModel.confirmDeleteFullScreenImage()
                } else {
                    browserViewModel.confirmDeleteSelectedImages()
                }
            }
        case .renderSelected, .advancedExportSelected, .renderAll,
             .saveAsJPEG, .saveAsPNG, .archiveRAW,
             .renameSelected, .duplicateSelected,
             .resetAllEdits, .removeAllIPTC,
             .showImport, .showWebImport, .backupEditedFiles, .backupEditedFilesForFolder,
             .openInInternalEditor,
             .moveRejectedToFolder,
             .addNewMask, .removeOrResetSelectedEditLayer, .toggleHDR,
             .setScopeMode, .toggleGamutClipping,
             .uploadSelected, .uploadAll,
             .processVariablesSelected, .processVariablesAll, .transcribeVoiceMemosSelected,
             .showTemplatePalette, .applyTemplateShortcut, .applyDevelopTemplate,
             .writeAllPendingMetadata, .openCaptionWorkspace,
             .renderAndSignSelected, .copyIPTCMetadata, .pasteIPTCMetadata,
             .showVariableReference, .showRawMetadata, .showStructuredKeywords,
             .showKnownPeopleDatabase, .registerOpenFolderForSidebar,
             .restoreCaptionEditorFocus:
            break
        }
    }

    func body(content: Content) -> some View {
        let base = content
            .onChange(of: browserViewModel.selectedImageIDs) { oldValue, _ in
                if !oldValue.isEmpty {
                    MetadataAutomaticSaveBoundary.perform(.selectionChange, in: mainViewMode,
                        viewModel: metadataViewModel, captionFlush: {}) {
                        // The editor's own photos, C2PA facts and load folder decide the save: a
                        // folder or pane switch has already replaced the browser's arrays.
                        let previousURLs = metadataViewModel.selectedURLs
                        let browser = browserViewModel
                        // Admit the save before scheduling the next selection load; its I/O
                        // is already asynchronous. A failure keeps a pending draft and is shown
                        // in the browser, because the editor has moved on to the next photo.
                        metadataViewModel.commitDepartingEditor(
                            knownC2PAURLs: browser.c2paURLs(among: previousURLs)
                        ) { outcome in
                            browser.refreshPendingStatusBatch(for: previousURLs)
                            if case .proceed(let attention?) = EditorBoundaryDecision.resolve(outcome, canStay: false) {
                                browser.errorMessage = attention
                            }
                        }
                    }
                }
                selectionLoadTask?.cancel()
                let selected = browserViewModel.selectedImages
                selectionLoadTask = Task {
                    let selectionStart = ContinuousClock.now
                    perfLog.info("[Selection] onChange — \(selected.count) image(s)")
                    try? await Task.sleep(nanoseconds: selectionDebounceNanoseconds)
                    guard !Task.isCancelled else { return }
                    let debounceMs = selectionStart.elapsedMilliseconds()
                    perfLog.info("[Selection] debounce done — \(debounceMs)ms, dispatching loadMetadata")
                    metadataViewModel.loadSelectionMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                    loadTechnicalMetadata()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                guard oldPhase == .active, newPhase != .active else { return }
                do {
                    try MetadataAutomaticSaveBoundary.perform(.deactivation, in: mainViewMode,
                        viewModel: metadataViewModel, captionFlush: {
                            let coordinator = CaptionWorkspaceFlushCoordinator.shared
                            if coordinator.hasRegisteredHandler {
                                try coordinator.enqueueFlushAll()
                            } else if mainViewMode == .metadataReview || metadataViewModel.hasUnpersistedEditorChanges {
                                throw CaptionWorkspaceFlushError.handlerUnavailable
                            }
                        }, commitConfigured: {
                            let model = metadataViewModel
                            let browser = browserViewModel
                            let commit = {
                                guard model.hasUnpersistedEditorChanges else { return }
                                model.commitEdits(mode: model.editorWriteMode(
                                    knownC2PAURLs: browser.c2paURLs(among: model.selectedURLs)))
                            }
                            // A running save may already carry these edits; superseding it would
                            // write the same change twice.
                            guard model.isSaving else { commit(); return }
                            Task { @MainActor in
                                await model.waitForPendingWrites()
                                commit()
                            }
                        })
                } catch {
                    if mainViewMode == .metadataReview {
                        browserViewModel.errorMessage = error.localizedDescription
                    } else {
                        metadataViewModel.saveError = error.localizedDescription
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .onChange(of: commandRouter.latestDelivery) { _, delivery in
                handleBrowserCommand(delivery)
            }
            .onReceive(NotificationCenter.default.publisher(for: .automationDraftDidChange)) { notification in
                guard let photoURL = notification.object as? URL,
                      photoURL.deletingLastPathComponent().standardizedFileURL == browserViewModel.currentFolderURL?.standardizedFileURL else { return }
                browserViewModel.refreshPendingStatusBatch(for: [photoURL])
                guard metadataViewModel.selectedURLs.contains(photoURL) else { return }
                guard !metadataViewModel.hasUnpersistedEditorChanges, !metadataViewModel.isSaving else {
                    metadataViewModel.saveError = "An automation draft was saved for this photo. Your current editor changes remain open; reload and reconcile the pending draft before publishing."
                    return
                }
                metadataViewModel.loadMetadata(for: browserViewModel.selectedImages,
                    folderURL: browserViewModel.currentFolderURL)
            }
            .onReceive(NotificationCenter.default.publisher(for: .faceMetadataDidChange)) { notification in
                // The writer names the photos it changed; re-read only those sidecars.
                if let written = notification.userInfo?["imageURLs"] as? [URL] {
                    browserViewModel.refreshPendingStatusBatch(for: written)
                } else {
                    browserViewModel.refreshPendingStatus()
                }
                // A loaded pending draft sets `hasChanges` but is not an unsaved edit; the face
                // write lands in that draft, so the editor must reload to show the names.
                guard !metadataViewModel.hasUnpersistedEditorChanges else { return }
                let selected = browserViewModel.selectedImages
                // Only reload when the written photos are selected: a reload invalidates the
                // focused field's buffer, so an unrelated photo must not be disturbed.
                if let changed = notification.userInfo?["imageURLs"] as? [URL] {
                    let changedPaths = Set(changed.map(\.standardizedFileURL))
                    guard selected.contains(where: { changedPaths.contains($0.url.standardizedFileURL) }) else { return }
                }
                metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL,
                    preservingUnsavedEdits: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAllFilesChanged)) { _ in
                // Settings' "Show" is global; apply it to every split pane. Only panes whose
                // value differs reload their folder.
                let visibility = settingsViewModel.fileVisibility
                for pane in panes.panes where pane.fileVisibility != visibility {
                    pane.fileVisibility = visibility
                }
            }
            .onChange(of: browserViewModel.currentFolderURL) {
                technicalMetadataCache.removeAll()
                technicalMetadata = nil
                if let folderURL = browserViewModel.currentFolderURL {
                    faceRecognitionViewModel.loadFaceData(
                        for: folderURL,
                        cleanupPolicy: settingsViewModel.faceCleanupPolicy
                    )
                    metadataViewModel.currentFolderURL = folderURL
                } else {
                    // The active pane has no folder (e.g. an empty second pane).
                    faceRecognitionViewModel.clearDisplayedFolder()
                }
            }
            .onChange(of: metadataViewModel.variableBatchOutcome?.requestID) { _, requestID in
                guard let attention = metadataViewModel.variableBatchOutcome?.attention,
                      attention.id == requestID else { return }
                OperationIssueDetailsPresenter.present(title: attention.title, message: attention.message)
            }
            .onChange(of: metadataViewModel.pendingWriteBatchOutcome?.requestID) { _, requestID in
                guard let attention = metadataViewModel.pendingWriteBatchOutcome?.attention,
                      attention.id == requestID else { return }
                // Folder writes can outlive the original selection. Present their own scoped
                // outcome without replacing the newly selected editor's message or metadata.
                OperationIssueDetailsPresenter.present(title: attention.title, message: attention.message)
            }
            .onChange(of: metadataViewModel.isProcessingFolder) { _, isProcessing in
                if !isProcessing {
                    browserViewModel.refreshPendingStatus()
                }
            }
        return base
            .modifier(PersonShownUpdatePromptModifier(viewModel: faceRecognitionViewModel,
                                                      isEnabled: !browserViewModel.isFullScreen,
                                                      images: { browserViewModel.images }))
            .modifier(AutoRefreshModifier(
                panes: panes,
                metadataViewModel: metadataViewModel,
                importDeferralFolder: importViewModel.importRefreshDeferralFolder,
                unfinishedImportURLs: { [importViewModel] in importViewModel.unfinishedImportDestinations }
            ))
            .onChange(of: settingsViewModel.rawDecodeProfile) { _, _ in
                discardRAWDecodeCaches(browserViewModel)
            }
            .onChange(of: settingsViewModel.rawDecoderVersionPreference) { _, _ in
                discardRAWDecodeCaches(browserViewModel)
            }
            .onChange(of: ftpViewModel.uploadCompleted) { _, completed in
                // When an upload that rendered files finishes, re-scan and expand each source
                // folder that got a new `Uploaded/` sub-folder so the user discovers it (the
                // sidecar tree otherwise only builds child lists on first manual expand).
                guard completed else { return }
                for folder in ftpViewModel.renderedUploadedFolders {
                    browserViewModel.revealExportedSubfolder(folder)
                }
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    guard let snapshot = try? await browserViewModel.fileSystemService
                        .dropSourceSnapshot(for: [url]),
                          snapshot.directories.first == url
                    else { return }
                    let targetPane = panes.active
                    performAfterMetadataFlush { targetPane.loadFolder(url: url, addToOpenFolders: true) }
                }
            }
        }
        return true
    }

    private func openSelectedInExternalEditor() {
        let urls = browserViewModel.selectedImages.map(\.url)
        guard !urls.isEmpty else { return }
        let editorPath = AppDefaults.store.string(forKey: UserDefaultsKeys.defaultExternalEditor) ?? ""
        guard !editorPath.isEmpty else {
            offerExternalEditorSettings("No external editor is set.")
            return
        }
        let editorURL = URL(fileURLWithPath: editorPath)
        let editorName = editorURL.deletingPathExtension().lastPathComponent
        guard FileManager.default.fileExists(atPath: editorPath) else {
            offerExternalEditorSettings("The external editor “\(editorName)” is no longer at \(editorPath).")
            return
        }
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.open(
                    urls,
                    withApplicationAt: editorURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                offerExternalEditorSettings("“\(editorName)” could not open the selected photos: \(error.localizedDescription)")
            }
        }
    }

    /// Open in Editor used to do nothing when the editor was unset or stale; explain why and
    /// offer the Settings window where the editor is chosen.
    @MainActor
    private func offerExternalEditorSettings(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Can’t Open in External Editor"
        alert.informativeText = message + "\n\nChoose an external editor in Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }
}

struct AutoRefreshModifier: ViewModifier {
    let panes: BrowserPanesModel
    let metadataViewModel: MetadataViewModel
    /// The running import's destination; its auto-refresh is throttled until the import ends.
    var importDeferralFolder: URL? = nil
    @State private var coordinator: BrowserAutoRefreshCoordinator

    init(
        panes: BrowserPanesModel,
        metadataViewModel: MetadataViewModel,
        importDeferralFolder: URL? = nil,
        unfinishedImportURLs: @escaping @MainActor () -> Set<URL> = { [] }
    ) {
        self.panes = panes
        self.metadataViewModel = metadataViewModel
        self.importDeferralFolder = importDeferralFolder
        _coordinator = State(
            initialValue: BrowserAutoRefreshCoordinator(
                panes: panes,
                metadataViewModel: metadataViewModel,
                unfinishedImportURLs: unfinishedImportURLs
            )
        )
    }

    func body(content: Content) -> some View {
        let folderURLs = panes.panes.map(\.currentFolderURL)
        content
            .onAppear {
                coordinator.setImportDeferralFolder(importDeferralFolder)
                coordinator.start()
            }
            .onChange(of: importDeferralFolder) { _, folder in
                coordinator.setImportDeferralFolder(folder)
            }
            .onChange(of: folderURLs) {
                coordinator.synchronizeMonitors()
            }
            .onChange(of: panes.layout) {
                coordinator.synchronizeMonitors()
            }
            .onChange(of: panes.activePaneIndex) {
                coordinator.synchronizeMonitors()
            }
            .onDisappear {
                coordinator.stop()
            }
    }
}

struct MetadataPanelDivider: View {
    private let hitWidth: CGFloat = 7
    private let visibleWidth: CGFloat = 1
    private let minPanelWidth: Double = 280
    private let maxPanelWidth: Double = 500

    @Binding var panelWidth: Double
    @State private var isDragging = false
    @State private var dragStartWidth: Double = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isDragging ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
                .frame(width: visibleWidth)
        }
            .frame(width: hitWidth)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = panelWidth
                        }
                        let newWidth = dragStartWidth - Double(value.translation.width)
                        panelWidth = min(max(newWidth, minPanelWidth), maxPanelWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .zIndex(1)
    }
}

/// Full-screen decodes, edited thumbnails and Develop's adjacent textures are all keyed by URL
/// alone (shared by every pane), so a new RAW decode profile or decoder version must drop them.
@MainActor
private func discardRAWDecodeCaches(_ browserViewModel: BrowserViewModel) {
    browserViewModel.fullScreenImageCache.clearAll()
    browserViewModel.thumbnailService.clearEditedCache()
    NotificationCenter.default.post(name: .rawDecodeSettingsDidChange, object: nil)
}
