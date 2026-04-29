import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var settingsViewModel = SettingsViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var templateViewModel = TemplateViewModel()
    @State private var isCheckingForUpdates = false
    @State private var updateStatusMessage: String?

    // Known People state
    @State private var knownPeopleStats: (peopleCount: Int, embeddingCount: Int) = (0, 0)
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var showClearConfirmation = false
    @State private var knownPeopleMessage: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            formatTab
                .tabItem {
                    Label("Format", systemImage: "doc.richtext")
                }

            metadataTab
                .tabItem {
                    Label("Metadata", systemImage: "tag")
                }

            facesTab
                .tabItem {
                    Label("Faces", systemImage: "person.crop.rectangle.stack")
                }

            ftpTab
                .tabItem {
                    Label("FTP", systemImage: "arrow.up.to.line")
                }

            templatesTab
                .tabItem {
                    Label("Templates", systemImage: "doc.on.clipboard")
                }

            signingTab
                .tabItem {
                    Label("Signing", systemImage: "signature")
                }

            updatesTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            KeyboardShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
        }
        .frame(width: 560, height: 580)
        .onAppear {
            ftpViewModel.loadConnections()
            templateViewModel.loadTemplates()
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

    // MARK: - Faces Tab

    @ViewBuilder
    private var facesTab: some View {
        Form {
            Section("Recognition Mode") {
                Picker("Mode", selection: $settingsViewModel.faceRecognitionMode) {
                    ForEach(FaceRecognitionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsViewModel.faceRecognitionMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsViewModel.faceRecognitionMode == .faceAndClothing {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Face Weight")
                            Spacer()
                            Text(String(format: "%.0f%%", settingsViewModel.faceFaceWeight * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.faceFaceWeight, in: 0.3...0.9, step: 0.05)
                        HStack {
                            Text("Face: \(Int(settingsViewModel.faceFaceWeight * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Clothing: \(Int(settingsViewModel.faceClothingWeight * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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

            Section("Clustering") {
                Picker("Algorithm", selection: $settingsViewModel.faceClusteringAlgorithm) {
                    ForEach(FaceClusteringAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }

                Text(settingsViewModel.faceClusteringAlgorithm.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Clustering Sensitivity (\(settingsViewModel.faceRecognitionMode.displayName))")
                        Spacer()
                        Text(String(format: "%.2f", settingsViewModel.effectiveClusteringThreshold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if settingsViewModel.faceRecognitionMode == .visionFeaturePrint {
                        Slider(value: $settingsViewModel.visionClusteringThreshold, in: 0.3...0.8, step: 0.01)
                    } else {
                        Slider(value: $settingsViewModel.faceClothingClusteringThreshold, in: 0.3...0.8, step: 0.01)
                    }
                HStack {
                    Text("Strict (fewer matches)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Loose (more matches)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settingsViewModel.faceRecognitionMode == .faceAndClothing {
                    Toggle("Second-pass can join existing groups", isOn: $settingsViewModel.faceClothingSecondPassAttachToExisting)
                    Text("If off, leftover singletons only cluster among themselves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

                if settingsViewModel.faceClusteringAlgorithm == .chineseWhispers ||
                   settingsViewModel.faceClusteringAlgorithm == .qualityGatedTwoPass {
                    Toggle("Quality-weighted edges", isOn: $settingsViewModel.faceUseQualityWeightedEdges)
                    Text("Higher quality faces have more influence on clustering")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settingsViewModel.faceClusteringAlgorithm == .qualityGatedTwoPass {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Quality Gate Threshold")
                            Spacer()
                            Text(String(format: "%.2f", settingsViewModel.faceQualityGateThreshold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.faceQualityGateThreshold, in: 0.3...0.9, step: 0.05)
                        Text("Faces below this quality are assigned after initial clustering")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Data Management") {
                Picker("Auto-delete face data", selection: $settingsViewModel.faceCleanupPolicy) {
                    ForEach(FaceCleanupPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }

            Section("Known People Database") {
                Picker("Mode", selection: $settingsViewModel.knownPeopleMode) {
                    ForEach(KnownPeopleMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settingsViewModel.knownPeopleMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settingsViewModel.knownPeopleMode != .off {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Auto-match Min Confidence")
                            Spacer()
                            Text(String(format: "%.2f", settingsViewModel.knownPeopleMinConfidence))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settingsViewModel.knownPeopleMinConfidence, in: 0.50...0.95, step: 0.01)
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
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshKnownPeopleStats()
        }
        .onChange(of: settingsViewModel.knownPeopleMode) {
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
                Picker("Non-C2PA Images", selection: $settingsViewModel.metadataWriteModeNonC2PA) {
                    ForEach(MetadataWriteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settingsViewModel.metadataWriteModeNonC2PA.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Picker("C2PA-Protected Images", selection: $settingsViewModel.metadataWriteModeC2PA) {
                    ForEach(MetadataWriteMode.c2paOptions) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(settingsViewModel.metadataWriteModeC2PA.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        Form {
            Section("Current Version") {
                LabeledContent("Installed") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                        .foregroundStyle(.secondary)
                }

                if UpdateChecker.shared.isUpdateAvailable, !UpdateChecker.shared.latestVersion.isEmpty {
                    LabeledContent("Latest") {
                        Text(UpdateChecker.shared.latestVersion)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Check Frequency") {
                Picker("Check for updates", selection: $settingsViewModel.updateCheckFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Check Now") {
                    guard !isCheckingForUpdates else { return }
                    isCheckingForUpdates = true
                    updateStatusMessage = "Checking..."
                    Task {
                        await UpdateChecker.shared.checkNow()
                        let latestVersion = UpdateChecker.shared.latestVersion
                        if UpdateChecker.shared.isUpdateAvailable {
                            if latestVersion.isEmpty {
                                updateStatusMessage = "Update available"
                            } else {
                                updateStatusMessage = "Update available — version \(latestVersion)"
                            }
                        } else {
                            updateStatusMessage = "You're up to date"
                        }
                        isCheckingForUpdates = false
                    }
                }
                .disabled(isCheckingForUpdates)

                if let updateStatusMessage {
                    Text(updateStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if UpdateChecker.shared.isUpdateAvailable {
                    Button("Download Latest Release") {
                        UpdateChecker.shared.openReleasesPage()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
                                Text("\(conn.useSFTP ? "sftp" : "ftp")://\(conn.host):\(conn.port)")
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
            TemplateListView(viewModel: templateViewModel)
        }
        .padding()
        .sheet(isPresented: $templateViewModel.isEditing) {
            TemplateEditorView(viewModel: templateViewModel)
        }
    }
}
