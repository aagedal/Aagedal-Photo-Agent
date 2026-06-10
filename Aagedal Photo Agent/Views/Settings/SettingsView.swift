import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage(UserDefaultsKeys.creatorInitials) private var creatorInitials = ""
    @State private var ftpViewModel = FTPViewModel()
    @State private var templateViewModel = TemplateViewModel()
    @StateObject private var sparkle = SparkleUpdaterService.shared

    // Known People state
    @State private var knownPeopleStats: (peopleCount: Int, embeddingCount: Int) = (0, 0)
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var showClearConfirmation = false
    @State private var knownPeopleMessage: String?

    // Approved Keywords state
    @State private var approvedKeywordsErrorMessage: String?
    @State private var editingApprovedKeywords = false

    // Structured Keywords state
    @State private var structuredKeywordsErrorMessage: String?
    @State private var editingStructuredKeywords = false

    // Structured Person Shown state
    @State private var structuredPersonShownErrorMessage: String?
    @State private var editingStructuredPersonShown = false

    // Quick Lists state
    @State private var editingQuickList: QuickListType?
    @State private var quickListsArchiveMessage: String?
    @State private var showingExportSheet = false
    @State private var importSource: ImportSource?
    @State private var showingBackupsSheet = false

    /// Wrapper so we can drive `.sheet(item:)` from a URL, which is not
    /// Identifiable on its own.
    private struct ImportSource: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    // MARK: - Sidebar Sections

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case metadata
        case keywordLists
        case quickLists
        case faceRecognition
        case knownPeople
        case locations
        case format
        case templates
        case ftp
        case signing
        case sync
        case updates
        case shortcuts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .metadata: return "Metadata"
            case .keywordLists: return "Keywords"
            case .quickLists: return "Quick Lists"
            case .faceRecognition: return "Face Recognition"
            case .knownPeople: return "Known People"
            case .locations: return "Locations"
            case .format: return "Format"
            case .templates: return "Templates"
            case .ftp: return "FTP"
            case .signing: return "Signing"
            case .sync: return "iCloud Sync"
            case .updates: return "Updates"
            case .shortcuts: return "Shortcuts"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .metadata: return "tag"
            case .keywordLists: return "list.bullet.rectangle"
            case .quickLists: return "bolt"
            case .faceRecognition: return "person.crop.rectangle.stack"
            case .knownPeople: return "person.crop.square"
            case .locations: return "folder"
            case .format: return "doc.richtext"
            case .templates: return "doc.on.clipboard"
            case .ftp: return "arrow.up.to.line"
            case .signing: return "signature"
            case .sync: return "icloud"
            case .updates: return "arrow.triangle.2.circlepath"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                Section("General") {
                    row(.general)
                }
                Section("Library & Metadata") {
                    row(.metadata)
                    row(.keywordLists)
                    row(.quickLists)
                    row(.templates)
                }
                Section("People and Groups") {
                    row(.faceRecognition)
                    row(.knownPeople)
                }
                Section("Export & Publishing") {
                    row(.locations)
                    row(.format)
                    row(.ftp)
                    row(.signing)
                }
                Section("Application") {
                    row(.sync)
                    row(.updates)
                    row(.shortcuts)
                }
            }
            .navigationSplitViewColumnWidth(210)
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView(for: selection ?? .general)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 620)
        .onAppear {
            ftpViewModel.loadConnections()
            templateViewModel.loadTemplates()
        }
    }

    @ViewBuilder
    private func row(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.icon)
            .tag(section)
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general: generalTab
        case .metadata: metadataTab
        case .keywordLists: keywordsTab
        case .quickLists: quickListsTab
        case .faceRecognition: faceRecognitionTab
        case .knownPeople: knownPeopleTab
        case .locations: locationsTab
        case .format: formatTab
        case .templates: templatesTab
        case .ftp: ftpTab
        case .signing: signingTab
        case .sync: syncTab
        case .updates: updatesTab
        case .shortcuts: KeyboardShortcutsSettingsView()
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section("External Editor") {
                Picker("Command+E", selection: $settingsViewModel.defaultEditDestination) {
                    ForEach(DefaultEditDestination.allCases) { destination in
                        Text(destination.displayName).tag(destination)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Default Editor", selection: $settingsViewModel.defaultExternalEditor) {
                    Text("Not set").tag("")
                    if !settingsViewModel.detectedEditors.isEmpty {
                        Divider()
                        ForEach(settingsViewModel.detectedEditors) { editor in
                            Text(editor.name).tag(editor.path)
                        }
                    }
                    if !settingsViewModel.defaultExternalEditor.isEmpty,
                       !settingsViewModel.detectedEditors.contains(where: { $0.path == settingsViewModel.defaultExternalEditor }) {
                        Divider()
                        Text(settingsViewModel.defaultExternalEditorName).tag(settingsViewModel.defaultExternalEditor)
                    }
                }
                .disabled(settingsViewModel.defaultEditDestination == .internalEditor)
                HStack {
                    Spacer()
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [.application]
                        if panel.runModal() == .OK, let url = panel.url {
                            settingsViewModel.defaultExternalEditor = url.path
                        }
                    }
                }
                .disabled(settingsViewModel.defaultEditDestination == .internalEditor)
            }

            Section("Browser") {
                Toggle("Show all files", isOn: $settingsViewModel.showAllFiles)
                Text("Show non-image files in the thumbnail grid with their system icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                Toggle("Always show original thumbnails", isOn: $settingsViewModel.showOriginalThumbnails)
                Text("When enabled, browser thumbnails always show the original image without develop edits. Edited thumbnails are still rendered in the background for quick toggling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Render RAW images as HDR", isOn: $settingsViewModel.rawRenderAsHDR)
                Text("Display RAW files using Extended Dynamic Range. Requires re-opening the folder to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Face Recognition Tab

    @ViewBuilder
    private var faceRecognitionTab: some View {
        Form {
            Section("Grouping") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Grouping Sensitivity")
                        Spacer()
                        Text(String(format: "%.2f", settingsViewModel.visionClusteringThreshold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $settingsViewModel.visionClusteringThreshold,
                        in: Double(FaceRecognitionDefaults.sensitivityMin)...Double(FaceRecognitionDefaults.sensitivityMax),
                        step: 0.01
                    )
                    HStack {
                        Text("Stricter (more groups)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Looser (fewer groups)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("If one person is split across several groups, move toward Looser. If different people are merged, move toward Stricter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Detection") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min Detection Confidence")
                        Spacer()
                        Text(String(format: "%.2f", settingsViewModel.faceMinConfidence))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settingsViewModel.faceMinConfidence, in: 0.5...0.95, step: 0.01)
                    Text("Higher values filter out uncertain detections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min Face Size (pixels)")
                        Spacer()
                        Text("\(settingsViewModel.faceMinFaceSize)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(settingsViewModel.faceMinFaceSize) },
                        set: { settingsViewModel.faceMinFaceSize = Int($0) }
                    ), in: 30...150, step: 5)
                    Text("Faces smaller than this will be ignored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data Management") {
                Picker("Auto-delete face data", selection: $settingsViewModel.faceCleanupPolicy) {
                    ForEach(FaceCleanupPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Known People Tab

    @ViewBuilder
    private var knownPeopleTab: some View {
        Form {
            Section("Known People Database") {
                Text("After each scan, face groups are matched against your known people automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Auto-match Min Confidence")
                            Spacer()
                            Text(String(format: "%.2f", settingsViewModel.knownPeopleMinConfidence))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.knownPeopleMinConfidence, in: 0.20...0.65, step: 0.01)
                        Text("Lower values match more often; higher values reduce false matches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Database") {
                        HStack {
                            if knownPeopleStats.peopleCount == 0 {
                                Text("Empty")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(knownPeopleStats.peopleCount) people, \(knownPeopleStats.embeddingCount) samples")
                                    .foregroundStyle(.secondary)
                            }

                            Button("Browse...") {
                                NSApp.activate(ignoringOtherApps: true)
                                NotificationCenter.default.post(name: .showKnownPeopleDatabase, object: nil)
                            }
                            .disabled(knownPeopleStats.peopleCount == 0)
                        }
                    }

                    HStack {
                        Button("Import...") {
                            importKnownPeople()
                        }
                        .disabled(isImporting)

                        Button("Export...") {
                            exportKnownPeople()
                        }
                        .disabled(isExporting || knownPeopleStats.peopleCount == 0)

                        Spacer()

                        Button("Clear Database", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .disabled(knownPeopleStats.peopleCount == 0)
                    }

                    Text("Import is additive and does not replace or merge existing people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let message = knownPeopleMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            structuredPersonShownSection
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $editingStructuredPersonShown) {
            StructuredKeywordEditor(
                service: .personShown,
                title: "Structured Person Shown",
                leafNoun: "Name",
                exportFilename: "Structured Person Shown.txt"
            )
        }
        .onAppear {
            refreshKnownPeopleStats()
        }
        .alert("Clear Known People Database?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearKnownPeopleDatabase()
            }
        } message: {
            Text("This will permanently delete all \(knownPeopleStats.peopleCount) known people and their reference images. This cannot be undone.")
        }
    }

    // MARK: - Locations Tab

    @ViewBuilder
    private var locationsTab: some View {
        Form {
            Section("Export Location") {
                Picker("Save Exported Files", selection: $settingsViewModel.exportLocationMode) {
                    ForEach(ExportLocationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(settingsViewModel.exportLocationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsViewModel.exportLocationMode == .customSubfolder {
                    TextField("Sub-folder Name", text: $settingsViewModel.exportCustomSubfolderName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Format Tab

    @ViewBuilder
    private var formatTab: some View {
        Form {
            Section("SDR Format") {
                Picker("Default Format", selection: $settingsViewModel.exportFormatSDR) {
                    ForEach(ExportFormatSDR.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Text(settingsViewModel.exportFormatSDR.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsViewModel.exportFormatSDR.supportsQuality {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text("\(Int(settingsViewModel.exportQualitySDR * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.exportQualitySDR, in: 0.5...1.0, step: 0.01)
                        HStack {
                            Text("Smaller file")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Higher quality")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Color Gamut", selection: $settingsViewModel.exportColorGamutSDR) {
                    ForEach(TargetColorGamut.allCases) { gamut in
                        Text(gamut.displayName).tag(gamut)
                    }
                }

                Text(settingsViewModel.exportColorGamutSDR.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("HDR Format") {
                Picker("Default Format", selection: $settingsViewModel.exportFormatHDR) {
                    ForEach(ExportFormatHDR.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Text(settingsViewModel.exportFormatHDR.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("HDR brightness may vary across viewers due to inconsistent HDR support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsViewModel.exportFormatHDR.supportsQuality {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text("\(Int(settingsViewModel.exportQualityHDR * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.exportQualityHDR, in: 0.5...1.0, step: 0.01)
                        HStack {
                            Text("Smaller file")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Higher quality")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Color Gamut", selection: $settingsViewModel.exportColorGamutHDR) {
                    ForEach(TargetColorGamut.allCases) { gamut in
                        Text(gamut.displayName).tag(gamut)
                    }
                }

                Text(settingsViewModel.exportColorGamutHDR.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settingsViewModel.exportFormatSDR == .tiff || settingsViewModel.exportFormatHDR == .tiff16bit {
                Section("TIFF Options") {
                    Picker("Compression", selection: $settingsViewModel.exportTIFFCompression) {
                        ForEach(TIFFCompression.allCases) { compression in
                            Text(compression.displayName).tag(compression)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(settingsViewModel.exportTIFFCompression.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Metadata Tab

    @ViewBuilder
    private var metadataTab: some View {
        Form {
            Section("Multi-Select Behavior") {
                Picker("Keywords", selection: $settingsViewModel.multiSelectKeywordsMode) {
                    ForEach(MultiSelectFieldMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Person Shown", selection: $settingsViewModel.multiSelectPersonShownMode) {
                    ForEach(MultiSelectFieldMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("Add: new items are merged into each image's existing values. Overwrite: all images get exactly the entered values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Write Behavior") {
                Picker("Mode", selection: $settingsViewModel.metadataWritePreset) {
                    ForEach(MetadataWritePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsViewModel.metadataWritePreset.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settingsViewModel.metadataWritePreset == .custom {
                Section("RAW Images") {
                    Picker("RAW Images", selection: $settingsViewModel.metadataWriteModeRaw) {
                        ForEach(MetadataWriteMode.standardOptions) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(settingsViewModel.metadataWriteModeRaw.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Non-C2PA Images") {
                    Picker("Non-C2PA Images", selection: $settingsViewModel.metadataWriteModeNonC2PA) {
                        ForEach(MetadataWriteMode.standardOptions) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(settingsViewModel.metadataWriteModeNonC2PA.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("C2PA-Protected Images") {
                    Picker("C2PA-Protected Images", selection: $settingsViewModel.metadataWriteModeC2PA) {
                        ForEach(MetadataWriteMode.c2paOptions) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(settingsViewModel.metadataWriteModeC2PA.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("C2PA content credentials can be invalidated by writing to the image file. You will be prompted before overwriting.")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Toggle("Prefer XMP sidecar when available", isOn: $settingsViewModel.preferXMPSidecar)
                Text("When an XMP sidecar exists, use it as the primary metadata source for viewing and comparisons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Ask when multiple metadata sources exist", isOn: $settingsViewModel.askOnMultipleMetadataSources)
                Text("When both embedded and XMP sidecar metadata exist with different values, prompt to choose which source to use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Variable Processing") {
                TextField("Initials", text: $creatorInitials)
                Text("Used by the {initials} variable in metadata fields and keywords (e.g. a keyword {initials}{date:yyMMdd}).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Approved Keywords Section

    @ViewBuilder
    private var approvedKeywordsSection: some View {
        let field = ApprovedListField.keywords
        let service = settingsViewModel.approvedLists
        let enabled = service.isEnabled(field)
        let listConfigured = service.hasListConfigured(for: field)
        let displayPath = service.displayPath(for: field)
        let count = service.entryCount(for: field)

        Section("Approved Keywords") {
            Toggle("Use approved keywords list", isOn: Binding(
                get: { service.isEnabled(field) },
                set: { service.setEnabled($0, for: field) }
            ))

            HStack {
                if let displayPath {
                    Text((displayPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(displayPath)
                } else {
                    Text("No file chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit…") {
                    editingApprovedKeywords = true
                }
                .help("Edit the approved keywords list in-app")
                Button(listConfigured ? "Import…" : "Import File…") {
                    chooseApprovedKeywordsFile()
                }
                if listConfigured {
                    Button(role: .destructive) {
                        service.clearList(for: field)
                        approvedKeywordsErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear approved list")
                }
            }
            .disabled(!enabled)

            if listConfigured, count > 0 {
                Text("\(count.formatted()) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Always allow keywords from a structured list", isOn: Binding(
                get: { service.allowStructuredBypass(field) },
                set: { service.setAllowStructuredBypass($0, for: field) }
            ))
            .disabled(!enabled)
            Text("When on, keywords picked from the structured-keywords tree bypass approved-list validation. When off, they are validated like any other source.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let loadError = service.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            if let approvedKeywordsErrorMessage {
                Text(approvedKeywordsErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("When typing a non-approved keyword", selection: Binding(
                get: { service.mode(for: field) },
                set: { service.setMode($0, for: field) }
            )) {
                ForEach(ApprovedListMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(!enabled)

            Text(service.mode(for: field).description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Accepts .txt (one keyword per line) and .csv (first column only). Lines starting with # are treated as comments.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseApprovedKeywordsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.message = "Choose an approved keywords list (.txt or .csv)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsViewModel.approvedLists.importListURL(url, for: .keywords)
            approvedKeywordsErrorMessage = nil
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            approvedKeywordsErrorMessage = description
        }
    }

    // MARK: - Structured Keywords Section

    @ViewBuilder
    private var structuredKeywordsSection: some View {
        let service = settingsViewModel.structuredKeywords
        let displayPath = service.sourcePath
        let isLoaded = service.isLoaded
        let keywordCount = service.keywordCount

        Section("Structured Keywords") {
            HStack {
                if let displayPath {
                    Text((displayPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(displayPath)
                } else {
                    Text("No file chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit…") {
                    editingStructuredKeywords = true
                }
                .help("Edit the structured keywords tree in-app")
                Button(isLoaded ? "Import…" : "Import File…") {
                    chooseStructuredKeywordsFile()
                }
                if isLoaded {
                    Button(role: .destructive) {
                        service.clearList()
                        structuredKeywordsErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear structured keywords")
                }
            }

            if isLoaded, keywordCount > 0 {
                Text("\(keywordCount.formatted()) keywords")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadError = service.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            if let structuredKeywordsErrorMessage {
                Text(structuredKeywordsErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("PhotoMechanic-style tree file. Use tabs to indent children, {braces} for synonyms, and [brackets] for non-keyword category headers. Open the picker via the tree icon next to the Keywords field or via Metadata → Structured Keywords.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseStructuredKeywordsFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a structured keywords file (.txt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsViewModel.structuredKeywords.importListURL(url)
            structuredKeywordsErrorMessage = nil
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            structuredKeywordsErrorMessage = description
        }
    }

    // MARK: - Structured Person Shown Section

    @ViewBuilder
    private var structuredPersonShownSection: some View {
        let service = settingsViewModel.structuredPersonShown
        let displayPath = service.sourcePath
        let isLoaded = service.isLoaded
        let nameCount = service.keywordCount

        Section("Structured Person Shown") {
            HStack {
                if let displayPath {
                    Text((displayPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(displayPath)
                } else {
                    Text("No file chosen").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit…") {
                    editingStructuredPersonShown = true
                }
                .help("Edit the structured Person Shown tree in-app")
                Button(isLoaded ? "Import…" : "Import File…") {
                    chooseStructuredPersonShownFile()
                }
                if isLoaded {
                    Button(role: .destructive) {
                        service.clearList()
                        structuredPersonShownErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear structured Person Shown")
                }
            }

            if isLoaded, nameCount > 0 {
                Text("\(nameCount.formatted()) names")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadError = service.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            if let structuredPersonShownErrorMessage {
                Text(structuredPersonShownErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("A PhotoMechanic-style tree of people — group names under [brackets] like [Politicians] or [Athletes], and add {braces} for alternate spellings or nicknames so they're easy to search. Picking a name writes it (plus any synonyms) but never the category. Open the picker via the tree icon next to the Person Shown field.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseStructuredPersonShownFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Choose a structured Person Shown file (.txt)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settingsViewModel.structuredPersonShown.importListURL(url)
            structuredPersonShownErrorMessage = nil
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            structuredPersonShownErrorMessage = description
        }
    }

    // MARK: - Keywords Tab

    @ViewBuilder
    private var keywordsTab: some View {
        Form {
            approvedKeywordsSection

            structuredKeywordsSection

            Section("Import / Export") {
                HStack {
                    Button("Export Lists…") {
                        showingExportSheet = true
                    }
                    Button("Import Lists…") {
                        chooseImportSource()
                    }
                    Button("Restore from Backup…") {
                        showingBackupsSheet = true
                    }
                    if let quickListsArchiveMessage {
                        Text(quickListsArchiveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                Text("Bundles your approved keywords and structured keyword/Person Shown trees into a single .zip with a manifest. On import you can replace or append per list — useful for merging collaborators' lists or restoring from a backup. Quick lists have their own Import / Export on the Quick Lists tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Restore from Backup recovers earlier versions of any list (including quick lists) from automatic local backups kept on this Mac — handy if a list ever comes back empty after an iCloud sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showingBackupsSheet) {
            KeywordListBackupsSheet()
        }
        .sheet(isPresented: $editingApprovedKeywords) {
            KeywordListEditor(
                title: "Approved Keywords",
                storeKey: .approved(.keywords)
            )
        }
        .sheet(isPresented: $editingStructuredKeywords) {
            StructuredKeywordEditor()
        }
        .sheet(isPresented: $showingExportSheet) {
            KeywordListsExportSheet(scope: .keywords) { result in
                switch result {
                case .success(let count):
                    quickListsArchiveMessage = "Exported \(count) \(count == 1 ? "list" : "lists")"
                case .failure(let error):
                    quickListsArchiveMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $importSource) { source in
            KeywordListsImportSheet(source: source.url, scope: .keywords) { result in
                switch result {
                case .success(let count):
                    quickListsArchiveMessage = "Imported \(count) \(count == 1 ? "list" : "lists")"
                case .failure(let error):
                    quickListsArchiveMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Quick Lists Tab

    @ViewBuilder
    private var quickListsTab: some View {
        Form {
            Section("Quick Lists") {
                ForEach(QuickListType.allCases, id: \.self) { type in
                    HStack {
                        Text(type.displayName)
                        Spacer()
                        Text("\(settingsViewModel.entries(for: type).count) entries")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Edit…") {
                            editingQuickList = type
                        }
                    }
                }
            }

            Section("Import / Export") {
                HStack {
                    Button("Export Lists…") {
                        showingExportSheet = true
                    }
                    Button("Import Lists…") {
                        chooseImportSource()
                    }
                    if let quickListsArchiveMessage {
                        Text(quickListsArchiveMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                Text("Bundles the selected quick lists into a single .zip with a manifest. On import you can replace or append per list — useful for merging collaborators' lists or restoring from a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(item: $editingQuickList) { type in
            KeywordListEditor(
                title: "\(type.displayName) Quick List",
                storeKey: .quick(type)
            )
        }
        .sheet(isPresented: $showingExportSheet) {
            KeywordListsExportSheet(scope: .quickLists) { result in
                switch result {
                case .success(let count):
                    quickListsArchiveMessage = "Exported \(count) \(count == 1 ? "list" : "lists")"
                case .failure(let error):
                    quickListsArchiveMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
        .sheet(item: $importSource) { source in
            KeywordListsImportSheet(source: source.url, scope: .quickLists) { result in
                switch result {
                case .success(let count):
                    quickListsArchiveMessage = "Imported \(count) \(count == 1 ? "list" : "lists")"
                case .failure(let error):
                    quickListsArchiveMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func chooseImportSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a keyword list bundle (.zip) to import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSource = ImportSource(url: url)
    }

    // MARK: - iCloud Sync Tab

    @ViewBuilder
    private var syncTab: some View {
        let coordinator = ICloudSyncCoordinator.shared
        Form {
            Section {
                Toggle("Sync everything", isOn: Binding(
                    get: { coordinator.allEnabled },
                    set: {
                        coordinator.setAllEnabled($0)
                        templateViewModel.loadTemplates()
                    }
                ))
                .toggleStyle(.switch)
                Text("Turn every category below on or off at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("App preferences", isOn: Binding(
                    get: { coordinator.preferencesEnabled },
                    set: { coordinator.setPreferencesEnabled($0) }
                ))
                Text("Portable settings like browser, metadata, face-recognition, and export options. Machine-specific values (file paths, certificates, FTP servers) are never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Keyword lists", isOn: Binding(
                    get: { coordinator.keywordListsEnabled },
                    set: { coordinator.setKeywordListsEnabled($0) }
                ))
                Text("Approved, structured, and all quick lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Templates", isOn: Binding(
                    get: { coordinator.templatesEnabled },
                    set: {
                        coordinator.setTemplatesEnabled($0)
                        templateViewModel.loadTemplates()
                    }
                ))
                Text("Metadata templates. Overrides any custom templates folder while enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Known People database", isOn: Binding(
                    get: { coordinator.knownPeopleEnabled },
                    set: { coordinator.setKnownPeopleEnabled($0) }
                ))
                Text("Reference faces and clothing samples used for auto-matching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sync with iCloud")
            } footer: {
                if let error = coordinator.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !coordinator.iCloudAvailable {
                    Label(
                        "iCloud Drive is not available. Sign in to iCloud in System Settings and enable iCloud Drive for this app.",
                        systemImage: "icloud.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Each category is stored in this app's iCloud Drive container so it follows you to your other Macs. Passwords and signing keys stay on this device and are never synced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Known People Actions

    private func refreshKnownPeopleStats() {
        knownPeopleStats = KnownPeopleService.shared.getStatistics()
    }

    private func importKnownPeople() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Select a Known People database (.zip)"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        knownPeopleMessage = nil

        Task {
            do {
                let count = try await KnownPeopleService.shared.importFromZip(sourceURL: url)
                isImporting = false
                knownPeopleMessage = "Imported \(count) people"
                refreshKnownPeopleStats()

                try? await Task.sleep(for: .seconds(3))
                knownPeopleMessage = nil
            } catch {
                isImporting = false
                knownPeopleMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func exportKnownPeople() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "KnownPeople.zip"
        panel.message = "Export Known People database"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        knownPeopleMessage = nil

        Task {
            do {
                try await KnownPeopleService.shared.exportToZip(destinationURL: url)
                isExporting = false
                knownPeopleMessage = "Export complete"
                refreshKnownPeopleStats()

                try? await Task.sleep(for: .seconds(3))
                knownPeopleMessage = nil
            } catch {
                isExporting = false
                knownPeopleMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func clearKnownPeopleDatabase() {
        do {
            try KnownPeopleService.shared.clearDatabase()
            refreshKnownPeopleStats()
            knownPeopleMessage = "Database cleared"

            // Clear message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                knownPeopleMessage = nil
            }
        } catch {
            knownPeopleMessage = "Clear failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Signing Tab

    @State private var isImportingCertificate = false
    @State private var p12Password = ""
    @State private var showP12PasswordPrompt = false
    @State private var pendingP12URL: URL?
    @State private var signingMessage: String?

    @ViewBuilder
    private var signingTab: some View {
        Form {
            Section {
                Label("C2PA signing is experimental and may change in a future release.", systemImage: "flask")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Signing Certificate") {
                if settingsViewModel.c2paHasCertificate {
                    LabeledContent("Subject") {
                        Text(settingsViewModel.c2paCertificateSubject)
                            .foregroundStyle(.secondary)
                    }

                    if !settingsViewModel.c2paCertificateExpiry.isEmpty {
                        LabeledContent("Expires") {
                            Text(settingsViewModel.c2paCertificateExpiry)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("File") {
                        Text(settingsViewModel.c2paCertificatePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack {
                        Button("Replace...") {
                            isImportingCertificate = true
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            settingsViewModel.removeC2PACertificate()
                            signingMessage = "Certificate removed"
                        }
                    }
                } else {
                    Text("No signing certificate configured")
                        .foregroundStyle(.secondary)
                    Button("Import Certificate...") {
                        isImportingCertificate = true
                    }
                }

                Text("Import a .pem or .p12 certificate for C2PA signing. Private keys are stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claim Defaults") {
                TextField("Default Author", text: $settingsViewModel.c2paDefaultAuthor)
                    .textFieldStyle(.roundedBorder)
                Text("Author name embedded in C2PA claims. Falls back to the Creator IPTC field if empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let signingMessage {
                Section {
                    Text(signingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(
            isPresented: $isImportingCertificate,
            allowedContentTypes: [.x509Certificate, .pkcs12, .data],
            allowsMultipleSelection: false
        ) { result in
            handleCertificateImport(result)
        }
        .alert("PKCS#12 Password", isPresented: $showP12PasswordPrompt) {
            SecureField("Password", text: $p12Password)
            Button("Import") {
                guard let url = pendingP12URL else { return }
                do {
                    try settingsViewModel.importC2PACertificate(from: url, password: p12Password)
                    signingMessage = "Certificate imported successfully"
                } catch {
                    signingMessage = "Import failed: \(error.localizedDescription)"
                }
                p12Password = ""
                pendingP12URL = nil
            }
            Button("Cancel", role: .cancel) {
                p12Password = ""
                pendingP12URL = nil
            }
        } message: {
            Text("Enter the password for the PKCS#12 file.")
        }
    }

    private func handleCertificateImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "p12" || ext == "pfx" {
                pendingP12URL = url
                showP12PasswordPrompt = true
            } else {
                do {
                    try settingsViewModel.importC2PACertificate(from: url)
                    signingMessage = "Certificate imported successfully"
                } catch {
                    signingMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            signingMessage = "File selection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Updates Tab

    @ViewBuilder
    private var updatesTab: some View {
        if SparkleUpdaterService.isHomebrewInstall {
            VStack(alignment: .leading, spacing: 12) {
                Text("Installed via Homebrew")
                    .font(.headline)
                Text("This copy was installed with Homebrew, which is the source of truth for updates. In-app updating is disabled.")
                    .foregroundStyle(.secondary)
                Text("Run `brew upgrade --cask aagedal-photo-agent` in Terminal to update.")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !SparkleUpdaterService.hasValidPublicKey {
            VStack(alignment: .leading, spacing: 12) {
                Text("Auto-updates not configured")
                    .font(.headline)
                Text("This build has no EdDSA public key embedded, so the updater is disabled. Run Sparkle's generate_keys tool and paste the public key into Info.plist before shipping.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Form {
                Section("Current Version") {
                    LabeledContent("Installed") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Automatic Updates") {
                    Toggle("Automatically check for updates", isOn: $sparkle.automaticallyChecksForUpdates)

                    Picker("Check frequency", selection: $sparkle.updateCheckInterval) {
                        Text("Daily").tag(TimeInterval(24 * 60 * 60))
                        Text("Weekly").tag(TimeInterval(7 * 24 * 60 * 60))
                        Text("Monthly").tag(TimeInterval(30 * 24 * 60 * 60))
                    }
                    .pickerStyle(.segmented)
                    .disabled(!sparkle.automaticallyChecksForUpdates)
                }

                Section {
                    Button("Check Now") {
                        sparkle.checkForUpdates()
                    }
                    .disabled(!sparkle.canCheckForUpdates)
                }
            }
            .formStyle(.grouped)
            .padding()
        }
    }

    // MARK: - FTP Tab

    @ViewBuilder
    private var ftpTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FTP Servers")
                    .font(.headline)
                Spacer()
                Button {
                    ftpViewModel.startEditingConnection()
                } label: {
                    Image(systemName: "plus")
                }
            }

            if ftpViewModel.connections.isEmpty {
                Text("No FTP servers configured")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(ftpViewModel.connections) { conn in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conn.name)
                                    .font(.body)
                                Text("\(conn.useSFTP ? "sftp" : (conn.useTLS ? "ftps" : "ftp"))://\(conn.host):\(conn.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                ftpViewModel.startEditingConnection(conn)
                            }
                            Button("Delete", role: .destructive) {
                                ftpViewModel.deleteConnection(conn)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $ftpViewModel.isShowingServerForm) {
            FTPServerForm(viewModel: ftpViewModel)
        }
    }

    // MARK: - Templates Tab

    @ViewBuilder
    private var templatesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(settingsViewModel.templatesFolderPath.isEmpty
                             ? "Default (Application Support)"
                             : settingsViewModel.templatesFolderPath)
                            .font(.callout)
                            .foregroundStyle(settingsViewModel.templatesFolderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") {
                            chooseTemplatesFolder()
                        }
                        if !settingsViewModel.templatesFolderPath.isEmpty {
                            Button("Reset") {
                                settingsViewModel.clearTemplatesFolder()
                                templateViewModel.loadTemplates()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            TemplateListView(viewModel: templateViewModel)

            GroupBox("Import / Export") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Export All…") {
                            exportTemplates()
                        }
                        .disabled(templateViewModel.templates.isEmpty)
                        Button("Import…") {
                            importTemplates()
                        }
                        Spacer()
                    }
                    Text("Exports all templates as a single .json bundle, or imports templates from one. Importing merges by template, with a confirmation showing how many are new or will be overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .sheet(isPresented: $templateViewModel.isEditing) {
            TemplateEditorView(viewModel: templateViewModel)
        }
        .sheet(item: $templateViewModel.pendingImportPreview) { preview in
            TemplateImportConfirmationView(
                preview: preview,
                onConfirm: {
                    templateViewModel.commitPendingImport()
                },
                onCancel: {
                    templateViewModel.cancelPendingImport()
                }
            )
        }
    }

    private func chooseTemplatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to store templates. Pick a folder inside iCloud Drive to sync between Macs."
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsViewModel.setTemplatesFolderURL(url)
        templateViewModel.loadTemplates()
    }

    private func exportTemplates() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AagedalTemplates.json"
        panel.message = "Export all templates as a JSON bundle"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        templateViewModel.exportAll(to: url)
    }

    private func importTemplates() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Select a templates bundle (.json)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        templateViewModel.preparePreview(from: url)
    }
}

private struct TemplateImportConfirmationView: View {
    let preview: TemplateImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Templates")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("From: \(preview.source.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(preview.bundle.templates.count) templates in bundle")
                    .font(.callout)
                Text("\(preview.newCount) new")
                    .font(.callout)
                    .foregroundStyle(.green)
                Text("\(preview.overwriteCount) will overwrite existing templates")
                    .font(.callout)
                    .foregroundStyle(preview.overwriteCount > 0 ? .orange : .secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Import") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
