import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var c2paMetadata: C2PAMetadata?
    @State private var saveTemplateName = ""
    @State private var metadataPanelWidth: CGFloat = 320
    @State private var isFaceManagerExpanded = false
    @State private var technicalMetadata: TechnicalMetadata?
    @State private var technicalMetadataCache: [URL: TechnicalMetadata] = [:]
    @State private var technicalMetadataTask: Task<Void, Never>?

    init() {
        let browser = BrowserViewModel()
        _browserViewModel = State(initialValue: browser)
        _metadataViewModel = State(initialValue: MetadataViewModel(exifToolService: browser.exifToolService))
        _faceRecognitionViewModel = State(initialValue: FaceRecognitionViewModel(exifToolService: browser.exifToolService))
        _importViewModel = State(initialValue: ImportViewModel(exifToolService: browser.exifToolService))
    }

    var body: some View {
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
            .sheet(isPresented: $isShowingTemplatePicker) { templatePickerSheet }
            .sheet(isPresented: $isShowingSaveTemplateName) { saveTemplateSheet }
            .sheet(isPresented: $isShowingFTPUpload) { ftpUploadSheet }
            .sheet(isPresented: $isShowingImport) { importSheet }
            .sheet(isPresented: $isShowingC2PADetail) { c2paSheet }
            .overlay {
                if isShowingTemplatePalette {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingTemplatePalette = false
                        }
                    TemplatePaletteView(
                        templates: templateViewModel.templates,
                        onApply: { template in
                            applyTemplate(template)
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
            .fullScreenImagePresenter(viewModel: browserViewModel)
            .onAppear {
                browserViewModel.loadFavorites()
                templateViewModel.loadTemplates()
                ftpViewModel.loadConnections()
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
            if !browserViewModel.images.isEmpty {
                FaceBarView(
                    viewModel: faceRecognitionViewModel,
                    folderURL: browserViewModel.currentFolderURL,
                    imageURLs: browserViewModel.images.map(\.url),
                    isExpanded: isFaceManagerExpanded,
                    onSelectImages: { urls in
                        browserViewModel.selectedImageIDs = urls
                    },
                    onPhotosDeleted: { trashedURLs in
                        browserViewModel.images.removeAll { trashedURLs.contains($0.url) }
                        browserViewModel.selectedImageIDs.subtract(trashedURLs)
                    },
                    onToggleExpanded: {
                        isFaceManagerExpanded.toggle()
                    }
                )
                Divider()
            }

            if isFaceManagerExpanded {
                ExpandedFaceManagementView(
                    viewModel: faceRecognitionViewModel,
                    onClose: { isFaceManagerExpanded = false },
                    onPhotosDeleted: { trashedURLs in
                        browserViewModel.images.removeAll { trashedURLs.contains($0.url) }
                        browserViewModel.selectedImageIDs.subtract(trashedURLs)
                    }
                )
            } else {
                browserAndMetadataPanel
            }
        }
    }

    @ViewBuilder
    private var browserAndMetadataPanel: some View {
        HStack(spacing: 0) {
            BrowserView(viewModel: browserViewModel)
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)

            MetadataPanelDivider(panelWidth: $metadataPanelWidth)

            MetadataPanel(
                viewModel: metadataViewModel,
                browserViewModel: browserViewModel,
                onApplyTemplate: { isShowingTemplatePicker = true },
                onSaveTemplate: { isShowingSaveTemplateName = true },
                onPendingStatusChanged: {
                    browserViewModel.refreshPendingStatus()
                }
            )
            .frame(width: metadataPanelWidth)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
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
                        metadataViewModel.writeAllPendingChanges(
                            in: browserViewModel.currentFolderURL,
                            images: browserViewModel.images
                        )
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

                if !browserViewModel.openFolders.isEmpty {
                    Section("Open Folders") {
                        ForEach(browserViewModel.openFolders, id: \.self) { folderURL in
                            Button {
                                browserViewModel.loadFolder(url: folderURL)
                            } label: {
                                HStack {
                                    Label(folderURL.lastPathComponent, systemImage: "folder.fill")
                                    Spacer()
                                    if folderURL == browserViewModel.currentFolderURL {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .contextMenu {
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

                if !browserViewModel.favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(browserViewModel.favoriteFolders) { favorite in
                            Button {
                                browserViewModel.loadFolder(url: favorite.url)
                            } label: {
                                Label(favorite.name, systemImage: "folder.fill")
                            }
                            .contextMenu {
                                Button("Remove from Favorites", role: .destructive) {
                                    browserViewModel.removeFavorite(favorite)
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

    private func applyTemplate(_ template: MetadataTemplate) {
        // Apply raw template values — variables like {date} and {persons}
        // stay as-is until the user clicks "Process Variables"
        var raw: [String: String] = [:]
        for field in template.fields {
            raw[field.fieldKey] = field.templateValue
        }
        metadataViewModel.applyTemplateFields(raw)
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

    func body(content: Content) -> some View {
        content
            .onChange(of: browserViewModel.selectedImageIDs) { oldValue, _ in
                if !oldValue.isEmpty && metadataViewModel.hasChanges {
                    metadataViewModel.saveToSidecar()
                }
                let selected = browserViewModel.selectedImages
                metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
                loadTechnicalMetadata()
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
                browserViewModel.deleteSelectedImages()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectPreviousImage)) { _ in
                browserViewModel.selectPrevious()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectNextImage)) { _ in
                browserViewModel.selectNext()
            }
            .onReceive(NotificationCenter.default.publisher(for: .faceMetadataDidChange)) { _ in
                let selected = browserViewModel.selectedImages
                metadataViewModel.loadMetadata(for: selected, folderURL: browserViewModel.currentFolderURL)
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
        guard let editorPath = UserDefaults.standard.string(forKey: "defaultExternalEditor"),
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
