import AppKit
import CoreImage
import os.log
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main View Mode

enum MainViewMode {
    case browser           // Normal photo browsing
    case editing           // Dedicated image editing workspace
    case faceManagement    // Expanded face management (existing)
    case peopleDatabase    // Known People database view
}

struct FTPUploadItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct BackupEditedItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Pulls the new safety and culling notification handlers out of the main
/// `contentWithNotificationHandlers` chain so the type-checker can finish
/// inside its time budget.
private struct SafetyAndCullingHandlers: ViewModifier {
    let browserViewModel: BrowserViewModel
    @Binding var backupEditedFolderItem: BackupEditedItem?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .backupEditedFiles)) { _ in
                if let folder = browserViewModel.currentFolderURL {
                    backupEditedFolderItem = BackupEditedItem(url: folder)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .backupEditedFilesForFolder)) { notification in
                if let url = notification.object as? URL {
                    backupEditedFolderItem = BackupEditedItem(url: url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveRejectedToFolder)) { _ in
                browserViewModel.moveRejectedToFolder()
            }
    }
}

struct ContentView: View {
    @State private var browserViewModel: BrowserViewModel
    @State private var metadataViewModel: MetadataViewModel
    @State private var faceRecognitionViewModel: FaceRecognitionViewModel
    @State private var templateViewModel = TemplateViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var settingsViewModel = SettingsViewModel()
    @State private var importViewModel: ImportViewModel

    @State private var isShowingTemplateEditor = false
    @State private var isShowingTemplatePicker = false
    @State private var isShowingTemplatePalette = false
    @State private var ftpUploadItem: FTPUploadItem?
    @State private var isShowingSaveTemplateName = false
    @State private var isShowingImport = false
    /// Height of the main window's content area, used to cap sheet heights.
    @State private var windowContentHeight: CGFloat = 0
    @State private var backupEditedFolderItem: BackupEditedItem?
    @State private var isShowingWriteAllC2PAWarning = false
    @State private var c2paMetadata: C2PAMetadata?
    @State private var pendingWriteAllC2PACount = 0
    @State private var saveTemplateName = ""
    @AppStorage(UserDefaultsKeys.metadataPanelWidth) private var metadataPanelWidth: Double = 320
    @State private var mainViewMode: MainViewMode = .browser
    @State private var lastNonPeopleViewMode: MainViewMode = .browser
    @State private var faceSelectionState = FaceSelectionState()
    @State private var technicalMetadata: TechnicalMetadata?
    @State private var technicalMetadataCache: [URL: TechnicalMetadata] = [:]
    @State private var technicalMetadataTask: Task<Void, Never>?
    @State private var isRenderingEditedFolder = false
    @State private var renderExportCurrent = 0
    @State private var renderExportTotal = 0
    @State private var renderEditedFolderSuccessCount = 0
    @State private var renderEditedFolderFailureCount = 0
    @State private var renderedOutputFolderURL: URL?
    @State private var renderExportTask: Task<Void, Never>?
    @State private var lastBatchResult: BatchOperationResult?
    @State private var isBatchResultExpanded = false
    @State private var scopeViewModel = ScopeViewModel()
    @State private var scopeImageTask: Task<Void, Never>?

    // Keyword-list backup recovery (prompts when a list comes back empty at launch).
    @State private var isShowingListRecoveryPrompt = false
    @State private var isShowingListBackups = false
    @State private var listRecoveryHandled = false

    init() {
        let browser = BrowserViewModel()
        let faceRecognition = FaceRecognitionViewModel(readService: browser.metadataReadService, writeEngine: browser.writeEngine)
        browser.onImagesDeleted = { [weak faceRecognition] urls in
            faceRecognition?.deleteFaces(forImageURLs: urls)
        }
        _browserViewModel = State(initialValue: browser)
        _metadataViewModel = State(initialValue: MetadataViewModel(readService: browser.metadataReadService, writeEngine: browser.writeEngine))
        _faceRecognitionViewModel = State(initialValue: faceRecognition)
        _importViewModel = State(initialValue: ImportViewModel(readService: browser.metadataReadService, writeEngine: browser.writeEngine))
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        contentWithStateHandlers
            .onReceive(NotificationCenter.default.publisher(for: .showStructuredKeywords)) { _ in
                openWindow(id: "structuredKeywords")
            }
            .onChange(of: KeywordListsBackupService.shared.recoverableKeys.map(\.relativePath)) { _, keys in
                // A keyword list read empty at launch while a backup exists.
                // Offer to restore — once per launch, and never auto-write.
                if !keys.isEmpty && !listRecoveryHandled {
                    listRecoveryHandled = true
                    isShowingListRecoveryPrompt = true
                }
            }
            .alert("Some keyword lists look empty", isPresented: $isShowingListRecoveryPrompt) {
                Button("Not Now", role: .cancel) { }
                Button("Restore…") { isShowingListBackups = true }
            } message: {
                Text("One or more keyword lists came back empty, but local backups are available. You can restore an earlier version.")
            }
            .sheet(isPresented: $isShowingListBackups) {
                KeywordListBackupsSheet(initialKey: KeywordListsBackupService.shared.recoverableKeys.first)
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
                browserViewModel: browserViewModel,
                metadataViewModel: metadataViewModel,
                faceRecognitionViewModel: faceRecognitionViewModel,
                settingsViewModel: settingsViewModel,
                importViewModel: importViewModel,
                loadTechnicalMetadata: loadTechnicalMetadata,
                technicalMetadataCache: $technicalMetadataCache,
                technicalMetadata: $technicalMetadata
            ))
    }

    private var contentWithSheets: some View {
        contentBase
            .sheet(isPresented: $isShowingTemplatePicker) { templatePickerSheet }
            .sheet(isPresented: $isShowingSaveTemplateName) { saveTemplateSheet }
            .sheet(item: $ftpUploadItem) { item in
                FTPUploadView(
                    viewModel: ftpViewModel,
                    files: item.urls,
                    readService: browserViewModel.metadataReadService,
                    writeEngine: browserViewModel.writeEngine,
                    inMemoryCameraRaw: browserViewModel.currentCameraRawSettings,
                    onStartUpload: { ftpUploadItem = nil }
                )
            }
            .sheet(isPresented: $isShowingImport) { importSheet }
            .sheet(item: $backupEditedFolderItem) { item in
                BackupEditedFilesSheet(
                    sourceFolder: item.url,
                    onDismiss: { backupEditedFolderItem = nil }
                )
            }
            .sheet(item: $c2paMetadata) { metadata in
                C2PADetailSheet(metadata: metadata)
            }
    }

    private var contentWithAlerts: some View {
        contentWithSheets
            .alert("C2PA Protected Images", isPresented: $isShowingWriteAllC2PAWarning) {
                Button("Cancel", role: .cancel) { }
                Button("Skip C2PA") {
                    metadataViewModel.writeAllPendingChanges(
                        in: browserViewModel.currentFolderURL,
                        images: browserViewModel.images,
                        skipC2PA: true
                    )
                }
                Button("Write Anyway") {
                    metadataViewModel.writeAllPendingChanges(
                        in: browserViewModel.currentFolderURL,
                        images: browserViewModel.images,
                        skipC2PA: false
                    )
                }
            } message: {
                let count = pendingWriteAllC2PACount
                let suffix = count == 1 ? "image has" : "images have"
                Text("\(count) pending \(suffix) C2PA content credentials in this folder. Writing metadata will invalidate the authenticity chain.")
            }
            .alert("Move to Trash", isPresented: $browserViewModel.showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Move to Trash", role: .destructive) {
                    browserViewModel.deleteSelectedImages()
                }
            } message: {
                let count = browserViewModel.selectedImageIDs.count
                Text("Are you sure you want to move \(count) \(count == 1 ? "image" : "images") to the Trash?")
            }
            .alert("Move Folder to Trash", isPresented: $browserViewModel.showTrashSubfolderConfirmation) {
                Button("Cancel", role: .cancel) {
                    browserViewModel.pendingTrashSubfolderURL = nil
                }
                Button("Move to Trash", role: .destructive) {
                    browserViewModel.trashPendingSubfolder()
                }
            } message: {
                if let url = browserViewModel.pendingTrashSubfolderURL {
                    Text("Are you sure you want to move \"\(url.lastPathComponent)\" and all its contents to the Trash?")
                }
            }
            .sheet(isPresented: $browserViewModel.showRenameSubfolderAlert) {
                RenameFolderSheet(viewModel: browserViewModel)
            }
            .alert("New Subfolder", isPresented: $browserViewModel.showNewSubfolderAlert) {
                TextField("Name", text: $browserViewModel.newSubfolderName)
                Button("Cancel", role: .cancel) {
                    browserViewModel.pendingNewSubfolderParentURL = nil
                }
                Button("Create") {
                    browserViewModel.createPendingSubfolder()
                }
            } message: {
                Text("Enter a name for the new subfolder.")
            }
            .alert("Reset All Edits", isPresented: $browserViewModel.showResetEditsConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    browserViewModel.resetAllEditsOnSelected()
                }
            } message: {
                let count = browserViewModel.selectedImageIDs.count
                Text("Reset camera raw edits and crop on \(count) \(count == 1 ? "image" : "images")? This cannot be undone.")
            }
            .alert("Remove All IPTC Metadata", isPresented: $browserViewModel.showRemoveIPTCConfirmation) {
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
                isPresented: $browserViewModel.showRemoveIPTCSidecarChoice,
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
                            isShowingTemplatePalette = false
                        }
                        .onAppear {
                            templateViewModel.loadTemplates()
                        }
                    TemplatePaletteView(
                        templates: templateViewModel.templates,
                        onApply: { template, append in
                            applyTemplate(template, append: append)
                            isShowingTemplatePalette = false
                        },
                        onSaveNew: {
                            isShowingTemplatePalette = false
                            isShowingSaveTemplateName = true
                        },
                        onDismiss: {
                            isShowingTemplatePalette = false
                        }
                    )
                }
            }
    }

    private var contentWithFileOperationHandlers: some View {
        contentWithOverlay
            .onReceive(NotificationCenter.default.publisher(for: .renderSelected)) { _ in
                let urls = browserViewModel.selectedImages.map(\.url)
                renderAndSaveEditedFolder(urls: urls)
            }
            .onReceive(NotificationCenter.default.publisher(for: .renderAll)) { _ in
                renderAndSaveEditedFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveAsJPEG)) { _ in
                saveSelectedAs(format: .jpeg)
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveAsPNG)) { _ in
                saveSelectedAs(format: .png)
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameSelected)) { _ in
                browserViewModel.renameSelected()
            }
            .onReceive(NotificationCenter.default.publisher(for: .duplicateSelected)) { _ in
                browserViewModel.duplicateSelectedImages()
            }
            .onReceive(NotificationCenter.default.publisher(for: .resetAllEdits)) { _ in
                browserViewModel.confirmResetAllEdits()
            }
            .onReceive(NotificationCenter.default.publisher(for: .removeAllIPTC)) { _ in
                browserViewModel.confirmRemoveAllIPTC()
            }
    }

    private var contentWithNotificationHandlers: some View {
        contentWithFileOperationHandlers
            .modifier(SafetyAndCullingHandlers(
                browserViewModel: browserViewModel,
                backupEditedFolderItem: $backupEditedFolderItem
            ))
            .onReceive(NotificationCenter.default.publisher(for: .showImport)) { _ in
                importViewModel.prepareForNewSession()
                isShowingImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .importStarted)) { notification in
                handleImportStarted(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .importCompleted)) { notification in
                handleImportCompleted(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .processVariablesSelected)) { _ in
                let selected = browserViewModel.selectedImages
                if !selected.isEmpty {
                    metadataViewModel.processVariablesForImages(selected)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .processVariablesAll)) { _ in
                metadataViewModel.processVariablesInFolder(images: browserViewModel.images)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTemplatePalette)) { _ in
                isShowingTemplatePalette = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .applyTemplateShortcut)) { notification in
                if let slot = notification.object as? Int,
                   let template = templateViewModel.template(forSlot: slot) {
                    applyTemplate(template)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadSelected)) { _ in
                let urls = browserViewModel.selectedImages.map(\.url)
                if !urls.isEmpty {
                    ftpUploadItem = FTPUploadItem(urls: urls)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadAll)) { _ in
                let urls = browserViewModel.images.map(\.url)
                if !urls.isEmpty {
                    ftpUploadItem = FTPUploadItem(urls: urls)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showKnownPeopleDatabase)) { _ in
                openPeopleDatabase()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInInternalEditor)) { _ in
                openEditWorkspace()
            }
            .onReceive(NotificationCenter.default.publisher(for: .renderAndSignSelected)) { _ in
                renderAndSignSelected()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyIPTCMetadata)) { _ in
                copyIPTCMetadata()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteIPTCMetadata)) { _ in
                pasteIPTCMetadata()
            }
            .onReceive(NotificationCenter.default.publisher(for: .writeAllPendingMetadata)) { _ in
                let c2paPending = browserViewModel.images.filter { image in
                    image.hasPendingMetadataChanges && image.hasC2PA
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
            .fullScreenImagePresenter(viewModel: browserViewModel, scopeViewModel: scopeViewModel)
            .cleanFeedPresenter(controller: CleanFeedController.shared, browserViewModel: browserViewModel)
            .onAppear {
                browserViewModel.loadFavorites()
                browserViewModel.loadFavoriteTopLevelSubfolders()
                templateViewModel.loadTemplates()
                ftpViewModel.loadConnections()
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
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
            if !browserViewModel.images.isEmpty, mainViewMode != .editing, mainViewMode != .browser {
                faceBar
                Divider()
            }

            switch mainViewMode {
            case .browser:
                browserAndMetadataPanel
            case .editing:
                editingWorkspaceView
            case .faceManagement:
                ExpandedFaceManagementView(
                    viewModel: faceRecognitionViewModel,
                    settingsViewModel: settingsViewModel,
                    selectionState: faceSelectionState,
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
            openPeopleDatabase()
        }
    }

    private func toggleEditWorkspace() {
        if mainViewMode == .editing {
            mainViewMode = .browser
            browserViewModel.shouldRestoreGridFocus = true
            return
        }
        openEditWorkspace()
    }

    private func openEditWorkspace() {
        if browserViewModel.selectedImageIDs.isEmpty,
           let firstVisible = browserViewModel.visibleImages.first {
            browserViewModel.selectedImageIDs = [firstVisible.url]
            browserViewModel.lastClickedImageURL = firstVisible.url
        }
        // Don't open edit mode for non-image files (visible when "Show all files" is on)
        guard let selectedURL = browserViewModel.lastClickedImageURL ?? browserViewModel.selectedImageIDs.first,
              SupportedImageFormats.isSupported(url: selectedURL) else {
            return
        }
        mainViewMode = .editing
    }

    @ViewBuilder
    private var browserAndMetadataPanel: some View {
        HStack(spacing: 0) {
            // Left column: face bar + browser
            VStack(spacing: 0) {
                if !browserViewModel.images.isEmpty {
                    faceBar
                    Divider()
                }

                BrowserView(
                    viewModel: browserViewModel,
                    faceCount: faceRecognitionViewModel.faceData?.faces.count ?? 0,
                    faceGroupCount: faceRecognitionViewModel.faceData?.groups.count ?? 0
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
            images: browserViewModel.images,
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
            onExit: {
                mainViewMode = .browser
                browserViewModel.shouldRestoreGridFocus = true
            },
            onPendingStatusChanged: {
                browserViewModel.refreshPendingStatus()
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Show filter and sort controls in the toolbar when in edit mode
        // (BrowserView provides these in browser mode, but isn't in the hierarchy during editing)
        if mainViewMode == .editing {
            ToolbarItemGroup(placement: .automatic) {
                ColorLabelFilterBar(selectedLabels: $browserViewModel.selectedColorLabels)
                    .disabled(browserViewModel.images.isEmpty)
                    .padding(8)
            }

            ToolbarItemGroup(placement: .automatic) {
                StarRatingFilterBar(minimumRating: $browserViewModel.minimumStarRating)
                    .disabled(browserViewModel.images.isEmpty)
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

                Picker("Sort", selection: Binding(
                    get: { browserViewModel.sortOrder },
                    set: { newValue in
                        if newValue == .manual && browserViewModel.sortOrder != .manual {
                            browserViewModel.initializeManualOrder(from: browserViewModel.sortedImages)
                        }
                        browserViewModel.sortOrder = newValue
                    }
                )) {
                    ForEach(BrowserViewModel.SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        ToolbarItem(placement: .secondaryAction) {
            if metadataViewModel.isProcessingFolder {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(metadataViewModel.folderProcessProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button {
                        let c2paPending = browserViewModel.images.filter { image in
                            image.hasPendingMetadataChanges && image.hasC2PA
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
                    } label: {
                        Label("Write All Pending", systemImage: "square.and.arrow.down.on.square")
                    }
                    .help("Write all pending sidecar changes to image files")
                    .disabled(browserViewModel.images.isEmpty)

                    Button {
                        metadataViewModel.processVariablesInFolder(images: browserViewModel.images)
                    } label: {
                        Label("Process Variables in Folder", systemImage: "curlybraces")
                    }
                    .help("Resolve all {variable} placeholders in metadata across every image in the folder")
                    .disabled(browserViewModel.images.isEmpty)

                    Button {
                        togglePeopleDatabase()
                    } label: {
                        Label("People Database", systemImage: "person.text.rectangle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Open Known People database")

                    Button {
                        toggleEditWorkspace()
                    } label: {
                        Label(
                            "Edit Workspace",
                            systemImage: mainViewMode == .editing
                                ? "xmark.circle.fill"
                                : "slider.horizontal.3"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .help(mainViewMode == .editing ? "Return to browser workspace" : "Open edit workspace")
                    .disabled(browserViewModel.visibleImages.isEmpty)

                    Button {
                        renderAndSaveEditedFolder()
                    } label: {
                        Label("Render and Save Folder", systemImage: "photo.badge.arrow.down")
                    }
                    .help("Render all images in the folder to Edited/ as sRGB JPEG")
                    .disabled(browserViewModel.images.isEmpty || isRenderingEditedFolder)
                }
            }
        }
    }

    private var editFilterMenu: some View {
        Menu {
            Picker("Person Shown", selection: $browserViewModel.personShownFilter) {
                ForEach(BrowserViewModel.PersonShownFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Picker("Edited", selection: $browserViewModel.editedFilter) {
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
        .disabled(browserViewModel.images.isEmpty)
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
    }

    private func handleImportStarted(_ notification: NotificationCenter.Publisher.Output) {
        isShowingImport = false
        if let folderURL = notification.object as? URL {
            browserViewModel.loadFolder(url: folderURL)
        }
    }

    private func handleImportCompleted(_ notification: NotificationCenter.Publisher.Output) {
        // Import already opened the folder on start — nothing else needed.
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                if !browserViewModel.favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(browserViewModel.favoriteFolders) { favorite in
                            FolderTreeRow(
                                url: favorite.url,
                                depth: 0,
                                section: .favoriteRoot,
                                isRootOfSection: true,
                                viewModel: browserViewModel,
                                revealInFinder: revealInFinder
                            )
                        }
                    }
                }

                if !browserViewModel.favoriteFolders.isEmpty && !browserViewModel.openFolders.isEmpty {
                    HStack {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                }

                if !browserViewModel.openFolders.isEmpty {
                    Section("Open Folders") {
                        ForEach(browserViewModel.openFolders, id: \.self) { folderURL in
                            FolderTreeRow(
                                url: folderURL,
                                depth: 0,
                                section: .openRoot,
                                isRootOfSection: true,
                                viewModel: browserViewModel,
                                revealInFinder: revealInFinder
                            )
                        }
                    }
                }

            }
            .listStyle(.sidebar)
            // The sidebar list's default min row height (~24pt) would undo the
            // compact row padding in FolderTreeRow; rows are 22pt themselves.
            .environment(\.defaultMinListRowHeight, 22)

            if ftpViewModel.isUploading || ftpViewModel.isRendering || ftpViewModel.uploadCompleted {
                Divider()
                FTPUploadProgressView(viewModel: ftpViewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if importViewModel.isImporting {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if importViewModel.importPhase == .copying {
                        Text("Importing \(importViewModel.copiedFiles) of \(importViewModel.totalFiles)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(importViewModel.copiedFiles), total: Double(max(importViewModel.totalFiles, 1)))
                    } else if importViewModel.importPhase == .applyingMetadata {
                        Text("Writing metadata…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.small)
                    }
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
                    ScopeDisplayView(scopeViewModel: scopeViewModel)
                    Divider()
                    if let meta = technicalMetadata, meta.hasC2PA {
                        C2PAMetadataView(metadata: meta) {
                            loadC2PADetail()
                        }
                        Divider()
                    }
                    TechnicalMetadataView(
                        metadata: technicalMetadata,
                        fileSize: selectedImage.fileSize,
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
                    if let info = notification.userInfo, let image = info["cgImage"] {
                        // Force cast is safe: internal notification always sends CGImage
                        scopeViewModel.updateImage((image as! CGImage))
                    } else {
                        scopeViewModel.updateImage(nil)
                    }
                    // Auto-select waveform scale and display gamut from settings
                    if let isHDR = notification.userInfo?["isHDR"] as? Bool {
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
                .onReceive(NotificationCenter.default.publisher(for: .setScopeMode)) { notification in
                    if let mode = notification.object as? ScopeViewModel.ScopeMode {
                        scopeViewModel.scopeMode = mode
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
                    browserViewModel.showOriginalThumbnails = newValue
                }
                .onReceive(NotificationCenter.default.publisher(for: .toggleGamutClipping)) { _ in
                    scopeViewModel.showClippedGamut.toggle()
                }
            }
        }
        .frame(minWidth: 180)
    }

    // MARK: - Template Picker Sheet

    @ViewBuilder
    private var templatePickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply Template")
                .font(.headline)

            if templateViewModel.templates.isEmpty {
                Text("No templates available. Create one first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(templateViewModel.templates) { template in
                    HStack {
                        Button {
                            applyTemplate(template)
                            isShowingTemplatePicker = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                Text("\(template.fields.count) fields")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(role: .destructive) {
                            templateViewModel.deleteTemplate(template)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete template")
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingTemplatePicker = false
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
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
                    templateViewModel.createTemplateFromMetadata(
                        metadataViewModel.editingMetadata,
                        name: saveTemplateName
                    )
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

    // MARK: - Render and Sign

    /// Prompts the user to pick a destination folder for `.askOnSave` exports.
    /// Returns nil if the user cancels.
    @MainActor
    private func promptForExportDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a destination folder for exported files"
        panel.directoryURL = browserViewModel.currentFolderURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func renderAndSignSelected() {
        guard C2PASigningService.isAvailable else {
            browserViewModel.errorMessage = "c2patool not found in app bundle"
            return
        }
        guard !isRenderingEditedFolder else { return }

        let certPath = settingsViewModel.c2paCertificatePath
        guard settingsViewModel.c2paHasCertificate else {
            browserViewModel.errorMessage = "No signing certificate configured. Import one in Settings → Signing."
            return
        }

        let selected = browserViewModel.selectedImages
        guard !selected.isEmpty else {
            browserViewModel.errorMessage = "No images selected"
            return
        }

        guard let privateKeyPEM = KeychainService.load(forKey: "c2pa_private_key") else {
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
        renderedOutputFolderURL = nil

        renderExportTask = Task {
            defer { renderExportTask = nil }
            let urls = selected.map(\.url)
            let failureTracker = MetadataFailureTracker()

            // Read metadata and overlay CameraRawSettings
            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.metadataReadService.readBatchFullMetadata(urls: urls)
            } catch {
                isRenderingEditedFolder = false
                browserViewModel.errorMessage = "Failed to read metadata: \(error.localizedDescription)"
                return
            }
            EditExportPipeline.resolveCameraRaw(into: &metadataByURL, urls: urls,
                                                inMemory: browserViewModel.currentCameraRawSettings)

            var successCount = 0
            var failureCount = 0
            var signFailedNames: [String] = []
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
                        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                        createdFolders.insert(outputFolder.path)
                        lastOutputFolder = outputFolder
                    } catch {
                        failureCount += 1
                        signFailedNames.append(image.url.lastPathComponent)
                        continue
                    }
                }

                do {
                    // Step 1: Render + copy source metadata + overlay pending IPTC edits
                    let renderedURL = try await EditExportPipeline.renderItem(
                        sourceURL: image.url, cameraRaw: cameraRaw, kind: .format,
                        outputFolder: outputFolder, folderURL: folderURL,
                        writeEngine: browserViewModel.writeEngine, failureTracker: failureTracker)

                    // Step 2: Build C2PA actions from edit settings
                    let actions = C2PAAction.fromSettings(cameraRaw)

                    // Step 3: Sign — preserve history if source already had C2PA
                    if image.hasC2PA {
                        try await C2PASigningService.signWithParentIngredient(
                            imageURL: renderedURL,
                            parentURL: image.url,
                            certificatePath: certPath,
                            privateKeyPEM: privateKeyPEM,
                            author: author,
                            actions: actions
                        )
                    } else {
                        try await C2PASigningService.sign(
                            imageURL: renderedURL,
                            certificatePath: certPath,
                            privateKeyPEM: privateKeyPEM,
                            author: author,
                            actions: actions
                        )
                    }

                    successCount += 1
                } catch {
                    failureCount += 1
                    signFailedNames.append(image.url.lastPathComponent)
                }
            }

            renderEditedFolderSuccessCount = successCount
            renderEditedFolderFailureCount = failureCount
            renderedOutputFolderURL = lastOutputFolder
            isRenderingEditedFolder = false

            // Files written next to the originals land in the current folder — refresh to show them.
            if locationMode == .sameAsOriginal {
                browserViewModel.refreshCurrentFolderIfNeeded()
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if failureCount > 0 || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty {
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
                failedFilenames: signFailedNames,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                sourceFolderURL: folderURL
            )
        }
    }

    // MARK: - Copy & Paste IPTC

    private func copyIPTCMetadata() {
        guard browserViewModel.selectedImages.count == 1 else {
            browserViewModel.errorMessage = "Select a single image to copy IPTC metadata from."
            return
        }

        let source = metadataViewModel.editingMetadata
        browserViewModel.copiedIPTCMetadata = IPTCMetadata(
            title: source.title,
            description: source.description,
            extendedDescription: source.extendedDescription,
            keywords: source.keywords,
            personShown: source.personShown,
            digitalSourceType: source.digitalSourceType,
            latitude: source.latitude,
            longitude: source.longitude,
            creator: source.creator,
            credit: source.credit,
            copyright: source.copyright,
            jobId: source.jobId,
            dateCreated: source.dateCreated,
            city: source.city,
            country: source.country,
            event: source.event
        )
    }

    private func pasteIPTCMetadata() {
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

        let fields = copied.toWriteFields()
        guard !fields.isEmpty else { return }

        let c2paImages = selected.filter { $0.hasC2PA }
        let normalImages = selected.filter { !$0.hasC2PA }

        Task {
            // Write directly to non-C2PA images
            if !normalImages.isEmpty {
                let normalURLs = normalImages.map(\.url)
                do {
                    try await browserViewModel.writeEngine.writeFields(fields, to: normalURLs)
                } catch {
                    browserViewModel.errorMessage = "Failed to paste IPTC: \(error.localizedDescription)"
                }
            }

            // For C2PA images, write to XMP sidecar (preserving camera raw edits)
            let xmpService = XMPSidecarService()
            for image in c2paImages {
                let existing = xmpService.loadSidecar(for: image.url) ?? IPTCMetadata()
                let merged = existing.merged(preferring: copied)
                do {
                    try xmpService.saveSidecar(metadata: merged, for: image.url)
                } catch {
                    browserViewModel.errorMessage = "Failed to save XMP sidecar for \(image.url.lastPathComponent): \(error.localizedDescription)"
                }
            }

            // Reload metadata panel to reflect changes
            reloadMetadataForSelection()
        }
    }

    // MARK: - Helpers

    private func reloadMetadataForSelection() {
        let selected = browserViewModel.selectedImages
        metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
    }

    private func applyTemplate(_ template: MetadataTemplate, append: Bool = false) {
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
            let appliedImages = browserViewModel.selectedImages
            metadataViewModel.applyTemplateFieldsAndProcessVariables(raw, to: appliedImages, append: append)
        } else {
            metadataViewModel.applyTemplateFields(raw, append: append)
        }
    }

    private func loadTechnicalMetadata() {
        technicalMetadataTask?.cancel()
        technicalMetadataTask = nil

        guard browserViewModel.selectedImageIDs.count == 1,
              let image = browserViewModel.selectedImages.first else {
            technicalMetadata = nil
            loadScopeImage(for: nil)
            return
        }

        // Load scope for browse mode (edit mode posts its own notification)
        if mainViewMode != .editing {
            loadScopeImage(for: image.url, isNativeHDR: image.isNativeHDR)
        }

        if let cached = technicalMetadataCache[image.url] {
            technicalMetadata = cached
            return
        }

        // Fast path: ImageIO. Reads dimensions / bit depth / color profile correctly for all
        // formats, but Apple's ImageIO does not surface EXIF for some containers (notably
        // JPEG XL and AVIF), so camera/exposure fields come back empty for those.
        let fast = TechnicalMetadata.fromImageIO(url: image.url, hasC2PA: image.hasC2PA)
        technicalMetadata = fast

        // Always enrich from the SwiftExif reader. It parses EXIF from formats ImageIO can't
        // (e.g. JPEG XL), and — even when ImageIO already supplied camera/exposure data — it
        // surfaces MakerNote-only technical fields (shutter count, camera temperature, CR3
        // lens model) that ImageIO never reads. We keep the fast path's reliable
        // dimensions/bit depth/color space throughout. Cache only the final (enriched) result.
        let url = image.url
        let readService = browserViewModel.metadataReadService
        technicalMetadataTask = Task {
            guard let exifMeta = try? await readService.readTechnicalMetadata(url: url),
                  !Task.isCancelled else {
                technicalMetadataCache[url] = fast
                return
            }
            // When ImageIO already supplied camera fields, keep them and overlay only the
            // MakerNote extras; otherwise take exifMeta's camera/exposure fields wholesale.
            let merged = fast.hasCameraInfo
                ? fast.mergingTechnicalExtras(from: exifMeta)
                : fast.mergingCameraFields(from: exifMeta)
            technicalMetadataCache[url] = merged
            // Only apply if this is still the selected image.
            if browserViewModel.selectedImages.first?.url == url {
                technicalMetadata = merged
            }
        }
    }

    private func loadScopeImage(for url: URL?, isNativeHDR: Bool = false) {
        scopeImageTask?.cancel()
        scopeImageTask = nil
        scopeViewModel.waveformScale = isNativeHDR ? .nits : .percentage
        scopeViewModel.targetGamut = isNativeHDR ? settingsViewModel.exportColorGamutHDR : settingsViewModel.exportColorGamutSDR

        guard let url else {
            scopeViewModel.updateImage(nil)
            return
        }

        scopeImageTask = Task {
            let cgImage: CGImage? = await Task.detached(priority: .utility) {
                if isNativeHDR {
                    // HDR-preserving path: keeps float values >1.0 for correct nits waveform
                    if let ciImage = FullScreenImageCache.loadHDRPreview(from: url, maxPixelSize: 720) {
                        return CameraRawApproximation.ciContext.createCGImage(
                            ciImage, from: ciImage.extent,
                            format: .RGBAh,
                            colorSpace: CameraRawApproximation.workingColorSpace
                        )
                    }
                }
                return FullScreenImageCache.loadDownsampled(from: url, maxPixelSize: 720)
            }.value
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
        let service = browserViewModel.metadataReadService
        Task {
            do {
                var result = try await service.readC2PAMetadata(url: image.url)
                // Best-effort thumbnail extraction — don't fail the sheet if this errors
                let thumbnails = try? await service.readC2PAThumbnails(url: image.url)
                result.thumbnails = thumbnails
                c2paMetadata = result
            } catch {
                c2paMetadata = nil
            }
        }
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
                        bannerFailureSection(label: "Failed", names: result.failedFilenames, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "Metadata copy failed", names: result.copyFailureFilenames, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "IPTC overlay failed", names: result.overlayFailureFilenames, folder: result.sourceFolderURL)
                        bannerFailureSection(label: "Used embedded metadata (.xmp sidecar stale)", names: result.staleSidecarFilenames, folder: result.sourceFolderURL)
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
            // Auto-dismiss success-without-failures after 4 seconds
            guard !result.hasFailures, result.outcome == .success else { return }
            try? await Task.sleep(for: .seconds(4))
            if lastBatchResult?.id == result.id {
                lastBatchResult = nil
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
        guard !isRenderingEditedFolder else { return }
        let urls = browserViewModel.selectedImages.map(\.url)
        guard !urls.isEmpty else { return }

        let locationMode = EditedImageRenderer.currentLocationMode
        var askedFolder: URL?
        if locationMode == .askOnSave {
            guard let chosen = promptForExportDestination() else { return }
            askedFolder = chosen
        }

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = urls.count

        renderExportTask = Task {
            defer { renderExportTask = nil }
            let failureTracker = MetadataFailureTracker()
            var createdFolders: Set<String> = []

            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.metadataReadService.readBatchFullMetadata(urls: urls)
            } catch {
                isRenderingEditedFolder = false
                browserViewModel.errorMessage = "Failed to read metadata: \(error.localizedDescription)"
                return
            }
            EditExportPipeline.resolveCameraRaw(into: &metadataByURL, urls: urls,
                                                inMemory: browserViewModel.currentCameraRawSettings)

            var savedURLs: [URL] = []
            var saveFailedNames: [String] = []
            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                renderExportCurrent = index + 1
                let cameraRaw = metadataByURL[url]?.cameraRaw
                do {
                    // Resolve destination folder per the configured export location mode.
                    // Save As always renders SDR (JPEG/PNG), so use isHDR: false for naming.
                    let rootFolder = browserViewModel.currentFolderURL ?? url.deletingLastPathComponent()
                    let destinationFolder = EditedImageRenderer.resolveOutputFolder(
                        sourceURL: url, rootFolder: rootFolder,
                        isHDR: false, formatPrefix: "Edited", askedFolder: askedFolder)
                    if !createdFolders.contains(destinationFolder.path) {
                        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                        createdFolders.insert(destinationFolder.path)
                    }

                    let outputURL = try await EditExportPipeline.renderItem(
                        sourceURL: url, cameraRaw: cameraRaw, kind: .saveAs(format),
                        outputFolder: destinationFolder, folderURL: browserViewModel.currentFolderURL,
                        writeEngine: browserViewModel.writeEngine, failureTracker: failureTracker)
                    savedURLs.append(outputURL)
                } catch {
                    saveFailedNames.append(url.lastPathComponent)
                }
            }

            isRenderingEditedFolder = false

            // Add saved files to browser if they're in the same folder
            if let folderURL = browserViewModel.currentFolderURL {
                let newFiles = savedURLs.filter { $0.deletingLastPathComponent() == folderURL }
                if !newFiles.isEmpty {
                    browserViewModel.refreshCurrentFolderIfNeeded()
                }
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if !saveFailedNames.isEmpty || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty {
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
                failedFilenames: saveFailedNames,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                sourceFolderURL: browserViewModel.currentFolderURL
            )
        }
    }

    private func renderAndSaveEditedFolder(urls: [URL]? = nil) {
        guard !isRenderingEditedFolder,
              let folderURL = browserViewModel.currentFolderURL else { return }
        let urls = urls ?? browserViewModel.images.map(\.url)
        guard !urls.isEmpty else { return }

        let locationMode = EditedImageRenderer.currentLocationMode
        var askedFolder: URL?
        if locationMode == .askOnSave {
            guard let chosen = promptForExportDestination() else { return }
            askedFolder = chosen
        }

        isRenderingEditedFolder = true
        renderExportCurrent = 0
        renderExportTotal = urls.count
        renderEditedFolderSuccessCount = 0
        renderEditedFolderFailureCount = 0
        renderedOutputFolderURL = nil

        renderExportTask = Task {
            defer { renderExportTask = nil }
            let failureTracker = MetadataFailureTracker()

            var metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.metadataReadService.readBatchFullMetadata(urls: urls)
            } catch {
                isRenderingEditedFolder = false
                browserViewModel.errorMessage = "Failed to read metadata for export: \(error.localizedDescription)"
                return
            }
            EditExportPipeline.resolveCameraRaw(into: &metadataByURL, urls: urls,
                                                inMemory: browserViewModel.currentCameraRawSettings)

            var successCount = 0
            var failureCount = 0
            var renderFailedNames: [String] = []
            var createdFolders: Set<String> = []
            var lastOutputFolder: URL?

            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                renderExportCurrent = index + 1
                let cameraRaw = metadataByURL[url]?.cameraRaw
                let isHDR = cameraRaw?.hdrEditMode == 1

                // Resolve output folder per the configured export location mode
                let outputFolder = EditedImageRenderer.resolveOutputFolder(
                    sourceURL: url, rootFolder: folderURL,
                    isHDR: isHDR, formatPrefix: "Edited", askedFolder: askedFolder)

                if !createdFolders.contains(outputFolder.path) {
                    do {
                        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                        createdFolders.insert(outputFolder.path)
                        lastOutputFolder = outputFolder
                    } catch {
                        browserViewModel.errorMessage = "Failed to create \(outputFolder.lastPathComponent) folder: \(error.localizedDescription)"
                        failureCount += 1
                        renderFailedNames.append(url.lastPathComponent)
                        continue
                    }
                }

                do {
                    _ = try await EditExportPipeline.renderItem(
                        sourceURL: url, cameraRaw: cameraRaw, kind: .format,
                        outputFolder: outputFolder, folderURL: folderURL,
                        writeEngine: browserViewModel.writeEngine, failureTracker: failureTracker)
                    successCount += 1
                } catch {
                    failureCount += 1
                    renderFailedNames.append(url.lastPathComponent)
                }
            }

            renderEditedFolderSuccessCount = successCount
            renderEditedFolderFailureCount = failureCount
            renderedOutputFolderURL = lastOutputFolder
            isRenderingEditedFolder = false

            // Files written next to the originals land in the current folder — refresh to show them.
            if locationMode == .sameAsOriginal {
                browserViewModel.refreshCurrentFolderIfNeeded()
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let outcome: BatchOperationResult.Outcome
            if Task.isCancelled {
                outcome = .cancelled
            } else if failureCount > 0 || !copyFailures.isEmpty || !overlayFailures.isEmpty || !staleWarnings.isEmpty {
                outcome = .partial
            } else {
                outcome = .success
            }
            isBatchResultExpanded = false
            lastBatchResult = BatchOperationResult(
                title: "Export",
                outcome: outcome,
                successCount: successCount,
                totalCount: urls.count,
                failedFilenames: renderFailedNames,
                copyFailureFilenames: copyFailures,
                overlayFailureFilenames: overlayFailures,
                staleSidecarFilenames: staleWarnings,
                sourceFolderURL: folderURL
            )
        }
    }

}

struct ContentViewModifiers: ViewModifier {
    let browserViewModel: BrowserViewModel
    let metadataViewModel: MetadataViewModel
    let faceRecognitionViewModel: FaceRecognitionViewModel
    let settingsViewModel: SettingsViewModel
    let importViewModel: ImportViewModel
    let loadTechnicalMetadata: () -> Void
    @Binding var technicalMetadataCache: [URL: TechnicalMetadata]
    @Binding var technicalMetadata: TechnicalMetadata?
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectionLoadTask: Task<Void, Never>?
    private let selectionDebounceNanoseconds: UInt64 = 200_000_000
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")

    func body(content: Content) -> some View {
        let base = content
            .onChange(of: browserViewModel.selectedImageIDs) { oldValue, _ in
                // Defer save of previous selection to a fire-and-forget task so the
                // selection border renders immediately without waiting for disk I/O.
                if !oldValue.isEmpty && metadataViewModel.hasChanges {
                    let hadC2PA = browserViewModel.images.contains { image in
                        metadataViewModel.selectedURLs.contains(image.url) && image.hasC2PA
                    }
                    let hadRaw = browserViewModel.images.contains { image in
                        metadataViewModel.selectedURLs.contains(image.url) && SupportedImageFormats.isRaw(url: image.url)
                    }
                    let mode = MetadataWriteMode.current(forC2PA: hadC2PA, isRaw: hadRaw)
                    let previousURLs = metadataViewModel.selectedURLs
                    Task { @MainActor in
                        // Simple resolves C2PA to .writeToFile and deliberately
                        // ignores content credentials — commit the mode as-is.
                        metadataViewModel.commitEdits(mode: mode) {
                            browserViewModel.refreshPendingStatusBatch(for: previousURLs)
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
                    metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                    loadTechnicalMetadata()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if oldPhase == .active, newPhase != .active,
                   metadataViewModel.hasChanges {
                    let hasC2PA = browserViewModel.selectedImages.contains { $0.hasC2PA }
                    let isRaw = browserViewModel.selectedImages.contains { SupportedImageFormats.isRaw(url: $0.url) }
                    let mode = MetadataWriteMode.current(forC2PA: hasC2PA, isRaw: isRaw)
                    metadataViewModel.commitEdits(mode: mode)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
                browserViewModel.openFolder()
            }
            .onReceive(NotificationCenter.default.publisher(for: .setRating)) { notification in
                if let rating = notification.object as? StarRating {
                    browserViewModel.setRating(rating)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .setLabel)) { notification in
                if let label = notification.object as? ColorLabel {
                    browserViewModel.setLabel(label)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInExternalEditor)) { _ in
                openSelectedInExternalEditor()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteSelected)) { _ in
                browserViewModel.confirmDeleteSelectedImages()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectPreviousImage)) { _ in
                browserViewModel.selectPrevious()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectNextImage)) { _ in
                browserViewModel.selectNext()
            }
            .onReceive(NotificationCenter.default.publisher(for: .rotateClockwise)) { _ in
                browserViewModel.rotateClockwise()
            }
            .onReceive(NotificationCenter.default.publisher(for: .rotateCounterclockwise)) { _ in
                browserViewModel.rotateCounterclockwise()
            }
            .onReceive(NotificationCenter.default.publisher(for: .faceMetadataDidChange)) { _ in
                guard !metadataViewModel.hasChanges else { return }
                let selected = browserViewModel.selectedImages
                metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                browserViewModel.refreshPendingStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAllFilesChanged)) { _ in
                browserViewModel.showAllFiles = UserDefaults.standard.bool(forKey: UserDefaultsKeys.showAllFiles)
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
                }
            }
            .onChange(of: metadataViewModel.isProcessingFolder) { _, isProcessing in
                if !isProcessing {
                    browserViewModel.refreshPendingStatus()
                }
            }
        return base
            .modifier(AutoRefreshModifier(browserViewModel: browserViewModel, metadataViewModel: metadataViewModel))
            // Lives outside `base`: that modifier chain is at the
            // type-checker's expression-complexity limit already.
            .onReceive(NotificationCenter.default.publisher(for: .openRecentFolder)) { notification in
                guard let url = notification.object as? URL else { return }
                browserViewModel.loadFolder(url: url)
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in
                        browserViewModel.loadFolder(url: url)
                    }
                }
            }
        }
        return true
    }

    private func openSelectedInExternalEditor() {
        guard let editorPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultExternalEditor),
              !editorPath.isEmpty else { return }
        let urls = browserViewModel.selectedImages.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: URL(fileURLWithPath: editorPath),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

struct AutoRefreshModifier: ViewModifier {
    let browserViewModel: BrowserViewModel
    let metadataViewModel: MetadataViewModel
    @State private var autoRefreshTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if autoRefreshTask == nil {
                    autoRefreshTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run {
                                // Skip the entire folder refresh while in the edit
                                // view — reassigning `images`/`visibleImages` causes
                                // @Observable to re-render the edit workspace (filmstrip,
                                // metadata panel) even when content hasn't changed,
                                // disturbing the user's in-progress edits.
                                guard !metadataViewModel.isInEditView else { return }

                                // Skip while the user is typing in the search field —
                                // the rebuild cascade steals TextField focus.
                                guard browserViewModel.searchText.isEmpty else { return }

                                // Skip the folder refresh while the user has unsaved
                                // metadata edits — the rebuildVisibleCache cascade can
                                // change selectedImageIDs (via the filter intersection
                                // check), which triggers onChange → loadMetadata and
                                // overwrites the in-progress edits.  The refresh will
                                // run on the next cycle after the user saves/commits.
                                guard !metadataViewModel.hasChanges else { return }

                                browserViewModel.refreshCurrentFolderIfNeeded()

                                // If any currently selected file was modified externally,
                                // reload full metadata so the browser reflects the changes.
                                let selectedURLs = Set(metadataViewModel.selectedURLs)
                                if !selectedURLs.isEmpty,
                                   !metadataViewModel.isSaving,
                                   !browserViewModel.lastRefreshModifiedURLs.isDisjoint(with: selectedURLs) {
                                    metadataViewModel.loadMetadata(
                                        for: browserViewModel.selectedImages,
                                        folderURL: browserViewModel.currentFolderURL
                                    )
                                }
                                // Clear after processing so stale URLs don't trigger
                                // repeated reloads on every subsequent 5-second cycle.
                                browserViewModel.clearLastRefreshModifiedURLs()
                            }
                        }
                    }
                }
            }
            .onDisappear {
                autoRefreshTask?.cancel()
                autoRefreshTask = nil
            }
    }
}

struct MetadataPanelDivider: View {
    @Binding var panelWidth: Double
    @State private var isDragging = false
    @State private var dragStartWidth: Double = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.5) : Color.clear)
            .frame(width: 5)
            .background(Divider())
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = panelWidth
                        }
                        let newWidth = dragStartWidth - Double(value.translation.width)
                        panelWidth = min(max(newWidth, 280), 500)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
