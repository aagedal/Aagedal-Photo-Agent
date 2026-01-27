import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var browserViewModel: BrowserViewModel
    @State private var metadataViewModel: MetadataViewModel
    @State private var faceRecognitionViewModel: FaceRecognitionViewModel
    @State private var presetViewModel = PresetViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var settingsViewModel = SettingsViewModel()

    @State private var isShowingPresetEditor = false
    @State private var isShowingPresetPicker = false
    @State private var isShowingFTPUpload = false
    @State private var isShowingSavePresetName = false
    @State private var savePresetName = ""
    @State private var metadataPanelWidth: CGFloat = 320
    @State private var isFaceManagerExpanded = false

    init() {
        let browser = BrowserViewModel()
        _browserViewModel = State(initialValue: browser)
        _metadataViewModel = State(initialValue: MetadataViewModel(exifToolService: browser.exifToolService))
        _faceRecognitionViewModel = State(initialValue: FaceRecognitionViewModel(exifToolService: browser.exifToolService))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
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
                        onToggleExpanded: {
                            isFaceManagerExpanded.toggle()
                        }
                    )
                    Divider()
                }

                if isFaceManagerExpanded {
                    ExpandedFaceManagementView(
                        viewModel: faceRecognitionViewModel,
                        onClose: { isFaceManagerExpanded = false }
                    )
                } else {
                    HStack(spacing: 0) {
                        BrowserView(viewModel: browserViewModel)
                            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)

                        MetadataPanelDivider(panelWidth: $metadataPanelWidth)

                        MetadataPanel(
                            viewModel: metadataViewModel,
                            browserViewModel: browserViewModel,
                            onApplyPreset: { isShowingPresetPicker = true },
                            onSavePreset: { isShowingSavePresetName = true }
                        )
                        .frame(width: metadataPanelWidth)
                    }
                }
            }
        }
        .toolbar {
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
        .navigationTitle(browserViewModel.currentFolderName ?? "Aagedal Photo Agent")
        .onChange(of: browserViewModel.selectedImageIDs) {
            let selected = browserViewModel.selectedImages
            metadataViewModel.loadMetadata(for: selected)
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
        .onReceive(NotificationCenter.default.publisher(for: .faceMetadataDidChange)) { _ in
            let selected = browserViewModel.selectedImages
            metadataViewModel.loadMetadata(for: selected)
        }
        .onChange(of: browserViewModel.currentFolderURL) {
            if let folderURL = browserViewModel.currentFolderURL {
                faceRecognitionViewModel.loadFaceData(
                    for: folderURL,
                    cleanupPolicy: settingsViewModel.faceCleanupPolicy
                )
            }
        }
        .sheet(isPresented: $isShowingPresetPicker) {
            presetPickerSheet
        }
        .sheet(isPresented: $isShowingSavePresetName) {
            savePresetSheet
        }
        .sheet(isPresented: $isShowingFTPUpload) {
            FTPUploadView(
                viewModel: ftpViewModel,
                filesToUpload: browserViewModel.selectedImages.map(\.url)
            )
        }
        .fullScreenImagePresenter(viewModel: browserViewModel)
        .onAppear {
            browserViewModel.loadFavorites()
            presetViewModel.loadPresets()
            ftpViewModel.loadConnections()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List {
            Section {
                Button {
                    browserViewModel.openFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
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

            if let folderName = browserViewModel.currentFolderName {
                Section("Current Folder") {
                    Label(folderName, systemImage: "folder.fill")
                    if !browserViewModel.isCurrentFolderFavorited {
                        Button {
                            browserViewModel.addCurrentFolderToFavorites()
                        } label: {
                            Label("Add to Favorites", systemImage: "star")
                        }
                    }
                }
            }

            if !browserViewModel.images.isEmpty {
                Section("Info") {
                    LabeledContent("Images", value: "\(browserViewModel.images.count)")
                    LabeledContent("Selected", value: "\(browserViewModel.selectedImageIDs.count)")
                }

                Section {
                    Button {
                        isShowingFTPUpload = true
                    } label: {
                        Label("Upload Selected...", systemImage: "arrow.up.to.line")
                    }
                    .disabled(browserViewModel.selectedImageIDs.isEmpty)
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
        .frame(minWidth: 180)
    }

    // MARK: - Preset Picker Sheet

    @ViewBuilder
    private var presetPickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apply Preset")
                .font(.headline)

            if presetViewModel.presets.isEmpty {
                Text("No presets available. Create one first.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presetViewModel.presets) { preset in
                    HStack {
                        Button {
                            applyPreset(preset)
                            isShowingPresetPicker = false
                        } label: {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text("\(preset.fields.count) fields")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(role: .destructive) {
                            presetViewModel.deletePreset(preset)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Delete preset")
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingPresetPicker = false
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    // MARK: - Save Preset Sheet

    @ViewBuilder
    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Preset")
                .font(.headline)
            TextField("Preset Name", text: $savePresetName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingSavePresetName = false
                    savePresetName = ""
                }
                Button("Save") {
                    presetViewModel.createPresetFromMetadata(
                        metadataViewModel.editingMetadata,
                        name: savePresetName
                    )
                    isShowingSavePresetName = false
                    savePresetName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(savePresetName.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    // MARK: - Helpers

    private func applyPreset(_ preset: MetadataPreset) {
        // Apply raw template values — variables like {date} and {persons}
        // stay as-is until the user clicks "Process Variables"
        var raw: [String: String] = [:]
        for field in preset.fields {
            raw[field.fieldKey] = field.templateValue
        }
        metadataViewModel.applyPresetFields(raw)
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

    private static let minPanelWidth: CGFloat = 280
    private static let maxPanelWidth: CGFloat = 500

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
