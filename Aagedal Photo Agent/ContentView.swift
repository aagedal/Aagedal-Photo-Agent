import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main View Mode

enum MainViewMode {
    case browser           // Normal photo browsing
    case editing           // Dedicated image editing workspace
    case faceManagement    // Expanded face management (existing)
    case peopleDatabase    // Known People database view
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
    @State private var isShowingFTPUpload = false
    @State private var isShowingSaveTemplateName = false
    @State private var isShowingImport = false
    @State private var isShowingC2PADetail = false
    @State private var isShowingWriteAllC2PAWarning = false
    @State private var c2paMetadata: C2PAMetadata?
    @State private var pendingWriteAllC2PACount = 0
    @State private var saveTemplateName = ""
    @State private var metadataPanelWidth: CGFloat = 320
    @State private var mainViewMode: MainViewMode = .browser
    @State private var lastNonPeopleViewMode: MainViewMode = .browser
    @State private var faceSelectionState = FaceSelectionState()
    @State private var technicalMetadata: TechnicalMetadata?
    @State private var technicalMetadataCache: [URL: TechnicalMetadata] = [:]
    @State private var technicalMetadataTask: Task<Void, Never>?
    @State private var isRenderingEditedFolder = false
    @State private var renderEditedFolderProgress = ""
    @State private var renderEditedFolderSuccessCount = 0
    @State private var renderEditedFolderFailureCount = 0
    @State private var renderedOutputFolderURL: URL?
    @State private var isShowingRenderEditedFolderResult = false

    init() {
        let browser = BrowserViewModel()
        let faceRecognition = FaceRecognitionViewModel(exifToolService: browser.exifToolService)
        browser.onImagesDeleted = { [weak faceRecognition] urls in
            faceRecognition?.deleteFaces(forImageURLs: urls)
        }
        _browserViewModel = State(initialValue: browser)
        _metadataViewModel = State(initialValue: MetadataViewModel(exifToolService: browser.exifToolService))
        _faceRecognitionViewModel = State(initialValue: faceRecognition)
        _importViewModel = State(initialValue: ImportViewModel(exifToolService: browser.exifToolService))
    }

    var body: some View {
        contentWithStateHandlers
    }

    private var contentBase: some View {
        mainContent
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
            .sheet(isPresented: $isShowingFTPUpload) { ftpUploadSheet }
            .sheet(isPresented: $isShowingImport) { importSheet }
            .sheet(isPresented: $isShowingC2PADetail) { c2paSheet }
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
            .alert("Render Complete", isPresented: $isShowingRenderEditedFolderResult) {
                if let outputURL = renderedOutputFolderURL {
                    Button("Show Edited Folder") {
                        NSWorkspace.shared.open(outputURL)
                    }
                }
                Button("OK", role: .cancel) { }
            } message: {
                let success = renderEditedFolderSuccessCount
                let failures = renderEditedFolderFailureCount
                Text("Saved \(success) image\(success == 1 ? "" : "s") to Edited as sRGB JPEG.\(failures > 0 ? " Failed: \(failures)." : "")")
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

    private var contentWithNotificationHandlers: some View {
        contentWithOverlay
            .onReceive(NotificationCenter.default.publisher(for: .showImport)) { _ in
                isShowingImport = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .importCompleted)) { notification in
                handleImportCompleted(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .processVariablesSelected)) { _ in
                let selectedURLs = browserViewModel.selectedImages.map(\.url)
                if !selectedURLs.isEmpty {
                    metadataViewModel.processVariablesForImages(selectedURLs)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .processVariablesAll)) { _ in
                metadataViewModel.processVariablesInFolder(images: browserViewModel.images)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showTemplatePalette)) { _ in
                isShowingTemplatePalette = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadSelected)) { _ in
                if !browserViewModel.selectedImageIDs.isEmpty {
                    isShowingFTPUpload = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .uploadAll)) { _ in
                if !browserViewModel.images.isEmpty {
                    isShowingFTPUpload = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showKnownPeopleDatabase)) { _ in
                openPeopleDatabase()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openInInternalEditor)) { _ in
                openEditWorkspace()
            }
    }

    private var contentWithStateHandlers: some View {
        contentWithNotificationHandlers
            .onChange(of: browserViewModel.isFullScreen) { _, isFullScreen in
                guard isFullScreen, browserViewModel.fullScreenFaceContext == nil else { return }
                browserViewModel.fullScreenFaceContext = BrowserViewModel.FullScreenFaceContext(
                    faceRecognitionViewModel: faceRecognitionViewModel,
                    highlightedFaceID: nil,
                    navigationItems: nil,
                    onNavigateToFace: nil
                )
            }
            .fullScreenImagePresenter(viewModel: browserViewModel)
            .onAppear {
                browserViewModel.loadFavorites()
                templateViewModel.loadTemplates()
                ftpViewModel.loadConnections()
                Task { await UpdateChecker.shared.checkIfNeeded() }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            if !browserViewModel.images.isEmpty, mainViewMode != .editing {
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
        mainViewMode = .editing
    }

    @ViewBuilder
    private var browserAndMetadataPanel: some View {
        HStack(spacing: 0) {
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

            MetadataPanelDivider(panelWidth: $metadataPanelWidth)

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
            .frame(width: metadataPanelWidth)
        }
    }

    @ViewBuilder
    private var editingWorkspaceView: some View {
        EditWorkspaceView(
            metadataViewModel: metadataViewModel,
            browserViewModel: browserViewModel,
            settingsViewModel: settingsViewModel,
            onExit: {
                mainViewMode = .browser
            },
            onPendingStatusChanged: {
                browserViewModel.refreshPendingStatus()
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if isRenderingEditedFolder {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(renderEditedFolderProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if metadataViewModel.isProcessingFolder {
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

    @ViewBuilder
    private var ftpUploadSheet: some View {
        FTPUploadView(
            viewModel: ftpViewModel,
            selectedFiles: browserViewModel.selectedImages.map(\.url),
            allFiles: browserViewModel.images.map(\.url),
            exifToolService: browserViewModel.exifToolService
        )
    }

    @ViewBuilder
    private var importSheet: some View {
        ImportView(
            viewModel: importViewModel,
            templates: templateViewModel.templates,
            onDismiss: { isShowingImport = false }
        )
    }

    @ViewBuilder
    private var c2paSheet: some View {
        if let c2paMetadata {
            C2PADetailSheet(metadata: c2paMetadata)
        }
    }

    private func handleImportCompleted(_ notification: NotificationCenter.Publisher.Output) {
        if let folderURL = notification.object as? URL,
           importViewModel.configuration.openFolderAfterImport {
            isShowingImport = false
            browserViewModel.loadFolder(url: folderURL)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Button {
                        browserViewModel.openFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        isShowingImport = true
                    } label: {
                        Label("Import...", systemImage: "square.and.arrow.down")
                    }
                }

                if !browserViewModel.favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(browserViewModel.favoriteFolders) { favorite in
                            Button {
                                browserViewModel.loadFolder(url: favorite.url)
                            } label: {
                                Label(favorite.name, systemImage: "folder.fill")
                            }
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    revealInFinder(favorite.url)
                                }

                                Divider()

                                Button("Remove from Favorites", role: .destructive) {
                                    browserViewModel.removeFavorite(favorite)
                                }
                            }
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
                            let isCurrent = folderURL == browserViewModel.currentFolderURL
                            let subfolders = browserViewModel.subfoldersByOpenFolder[folderURL] ?? []
                            let hasSubfolders = !subfolders.isEmpty
                            let isExpanded = browserViewModel.expandedFolders.contains(folderURL)

                            VStack(alignment: .leading, spacing: 2) {
                                // Parent folder row
                                HStack(spacing: 4) {
                                    if hasSubfolders {
                                        Image(systemName: "chevron.right")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.secondary)
                                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                            .animation(.easeInOut(duration: 0.15), value: isExpanded)
                                            .frame(width: 12, alignment: .center)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                if isExpanded {
                                                    browserViewModel.expandedFolders.remove(folderURL)
                                                } else {
                                                    browserViewModel.expandedFolders.insert(folderURL)
                                                }
                                            }
                                    } else {
                                        Spacer()
                                            .frame(width: 12)
                                    }

                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                                    Text(folderURL.lastPathComponent)
                                        .font(.callout)
                                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                                    Spacer()

                                    Button {
                                        browserViewModel.closeOpenFolder(folderURL)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Close Folder")
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    browserViewModel.loadFolder(url: folderURL)
                                }

                                // Subfolders
                                if isExpanded {
                                    ForEach(subfolders, id: \.self) { subfolderURL in
                                        let isSubCurrent = subfolderURL == browserViewModel.currentFolderURL
                                        let subSubfolders = browserViewModel.subfoldersByOpenFolder[subfolderURL] ?? []

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Image(systemName: isSubCurrent ? "folder.fill" : "folder")
                                                    .foregroundStyle(isSubCurrent ? Color.accentColor : Color.secondary)
                                                Text(subfolderURL.lastPathComponent)
                                                    .foregroundStyle(isSubCurrent ? Color.accentColor : Color.primary)
                                                Spacer()
                                            }
                                            .font(.callout)
                                            .padding(.leading, 22)
                                            .padding(.vertical, 3)
                                            .padding(.trailing, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(isSubCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
                                            )
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                browserViewModel.loadFolder(url: subfolderURL)
                                            }
                                            .contextMenu {
                                                Button("Reveal in Finder") {
                                                    revealInFinder(subfolderURL)
                                                }
                                            }

                                            // Sub-subfolders shown when this subfolder is active
                                            if isSubCurrent, !subSubfolders.isEmpty {
                                                ForEach(subSubfolders, id: \.self) { subSubURL in
                                                    HStack(spacing: 6) {
                                                        Image(systemName: "folder")
                                                            .foregroundStyle(.secondary)
                                                        Text(subSubURL.lastPathComponent)
                                                        Spacer()
                                                    }
                                                    .font(.callout)
                                                    .padding(.leading, 42)
                                                    .padding(.vertical, 2)
                                                    .contentShape(Rectangle())
                                                    .onTapGesture {
                                                        browserViewModel.loadFolder(url: subSubURL)
                                                    }
                                                    .contextMenu {
                                                        Button("Reveal in Finder") {
                                                            revealInFinder(subSubURL)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    revealInFinder(folderURL)
                                }

                                Divider()

                                Button {
                                    browserViewModel.addCurrentFolderToFavorites()
                                } label: {
                                    Label("Add to Favorites", systemImage: "star")
                                }
                                .disabled(browserViewModel.favoriteFolders.contains { $0.url == folderURL })

                                Divider()

                                Button("Close", role: .destructive) {
                                    browserViewModel.closeOpenFolder(folderURL)
                                }
                            }
                        }
                    }
                }

                if !browserViewModel.images.isEmpty {
                    Divider()

                    Section("Folder Info") {
                        LabeledContent("Images", value: "\(browserViewModel.images.count)")
                        LabeledContent("Selected", value: "\(browserViewModel.selectedImageIDs.count)")
                    }

                    Section {
                        Button {
                            isShowingFTPUpload = true
                        } label: {
                            Label("Upload...", systemImage: "arrow.up.to.line")
                        }
                    }
                }

                if !browserViewModel.exifToolService.isAvailable {
                    Section {
                        Label("ExifTool not found", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Install ExifTool via Homebrew:\nbrew install exiftool")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)

            if browserViewModel.selectedImageIDs.count == 1,
               let selectedImage = browserViewModel.selectedImages.first {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    UpdatePillButton()
                    if let meta = technicalMetadata, meta.hasC2PA {
                        C2PAMetadataView(metadata: meta) {
                            loadC2PADetail()
                        }
                        Divider()
                    }
                    TechnicalMetadataView(
                        metadata: technicalMetadata,
                        fileSize: selectedImage.fileSize
                    )
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        revealInFinder(selectedImage.url)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

    // MARK: - Helpers

    private func applyTemplate(_ template: MetadataTemplate, append: Bool = false) {
        // Apply raw template values — variables like {date} and {persons}
        // stay as-is until the user clicks "Process Variables"
        var raw: [String: String] = [:]
        for field in template.fields {
            raw[field.fieldKey] = field.templateValue
        }
        metadataViewModel.applyTemplateFields(raw, append: append)
    }

    private func loadTechnicalMetadata() {
        technicalMetadataTask?.cancel()
        technicalMetadataTask = nil

        guard browserViewModel.selectedImageIDs.count == 1,
              let image = browserViewModel.selectedImages.first else {
            technicalMetadata = nil
            return
        }

        if let cached = technicalMetadataCache[image.url] {
            technicalMetadata = cached
            return
        }

        let url = image.url
        let service = browserViewModel.exifToolService
        technicalMetadataTask = Task {
            do {
                let result = try await service.readTechnicalMetadata(url: url)
                guard !Task.isCancelled else { return }
                technicalMetadataCache[url] = result
                technicalMetadata = result
            } catch {
                guard !Task.isCancelled else { return }
                technicalMetadata = nil
            }
        }
    }

    private func loadC2PADetail() {
        guard let image = browserViewModel.selectedImages.first else { return }
        let service = browserViewModel.exifToolService
        Task {
            do {
                let result = try await service.readC2PAMetadata(url: image.url)
                c2paMetadata = result
                isShowingC2PADetail = true
            } catch {
                c2paMetadata = nil
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func renderAndSaveEditedFolder() {
        guard !isRenderingEditedFolder,
              let folderURL = browserViewModel.currentFolderURL else { return }
        let urls = browserViewModel.images.map(\.url)
        guard !urls.isEmpty else { return }

        isRenderingEditedFolder = true
        renderEditedFolderProgress = "Preparing export..."
        renderEditedFolderSuccessCount = 0
        renderEditedFolderFailureCount = 0
        renderedOutputFolderURL = nil

        Task {
            let outputFolder = folderURL.appendingPathComponent("Edited", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            } catch {
                isRenderingEditedFolder = false
                renderEditedFolderProgress = ""
                browserViewModel.errorMessage = "Failed to create Edited folder: \(error.localizedDescription)"
                return
            }

            let metadataByURL: [URL: IPTCMetadata]
            do {
                metadataByURL = try await browserViewModel.exifToolService.readBatchFullMetadata(urls: urls)
            } catch {
                isRenderingEditedFolder = false
                renderEditedFolderProgress = ""
                browserViewModel.errorMessage = "Failed to read metadata for export: \(error.localizedDescription)"
                return
            }

            var successCount = 0
            var failureCount = 0

            for (index, url) in urls.enumerated() {
                renderEditedFolderProgress = "Rendering \(index + 1)/\(urls.count)..."
                let cameraRaw = metadataByURL[url]?.cameraRaw
                do {
                    try EditedImageRenderer.renderJPEG(from: url, cameraRaw: cameraRaw, outputFolder: outputFolder)
                    successCount += 1
                } catch {
                    failureCount += 1
                }
            }

            renderEditedFolderSuccessCount = successCount
            renderEditedFolderFailureCount = failureCount
            renderedOutputFolderURL = outputFolder
            renderEditedFolderProgress = ""
            isRenderingEditedFolder = false
            isShowingRenderEditedFolderResult = true
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
    @State private var selectionLoadTask: Task<Void, Never>?
    private let selectionDebounceNanoseconds: UInt64 = 200_000_000

    func body(content: Content) -> some View {
        let base = content
            .onChange(of: browserViewModel.selectedImageIDs) { oldValue, _ in
                if !oldValue.isEmpty && metadataViewModel.hasChanges {
                    let hadC2PA = browserViewModel.images.contains { image in
                        metadataViewModel.selectedURLs.contains(image.url) && image.hasC2PA
                    }
                    let mode = hadC2PA ? settingsViewModel.metadataWriteModeC2PA : settingsViewModel.metadataWriteModeNonC2PA
                    if hadC2PA, mode == .writeToFile {
                        metadataViewModel.saveToSidecar()
                        browserViewModel.refreshPendingStatus()
                    } else {
                        metadataViewModel.commitEdits(
                            mode: mode,
                            hasC2PA: hadC2PA
                        ) {
                            browserViewModel.refreshPendingStatus()
                        }
                    }
                }
                selectionLoadTask?.cancel()
                let selected = browserViewModel.selectedImages
                selectionLoadTask = Task {
                    try? await Task.sleep(nanoseconds: selectionDebounceNanoseconds)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                        loadTechnicalMetadata()
                    }
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
                let selected = browserViewModel.selectedImages
                metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                browserViewModel.refreshPendingStatus()
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
            .modifier(AutoRefreshModifier(browserViewModel: browserViewModel))
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
    @State private var autoRefreshTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if autoRefreshTask == nil {
                    autoRefreshTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 10_000_000_000)
                            await MainActor.run {
                                browserViewModel.refreshCurrentFolderIfNeeded()
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
    @Binding var panelWidth: CGFloat
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

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
                        let newWidth = dragStartWidth - value.translation.width
                        panelWidth = min(max(newWidth, 280), 500)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
