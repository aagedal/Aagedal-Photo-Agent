import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var settingsViewModel = SettingsViewModel()
    @State private var ftpViewModel = FTPViewModel()
    @State private var templateViewModel = TemplateViewModel()

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
        }
        .frame(width: 500, height: 520)
        .onAppear {
            ftpViewModel.loadConnections()
            templateViewModel.loadTemplates()
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section("ExifTool") {
                Picker("Source", selection: $settingsViewModel.exifToolSource) {
                    ForEach(ExifToolSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if settingsViewModel.exifToolSource == .custom {
                    LabeledContent("Path") {
                        HStack {
                            TextField("Path to exiftool", text: $settingsViewModel.exifToolCustomPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                panel.allowsMultipleSelection = false
                                if panel.runModal() == .OK, let url = panel.url {
                                    settingsViewModel.exifToolCustomPath = url.path
                                }
                            }
                        }
                    }
                }

                if let path = settingsViewModel.selectedExifToolPath {
                    LabeledContent("Active") {
                        Text(path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    LabeledContent("Status") {
                        Text("Not found")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("External Editor") {
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

    // MARK: - Metadata Tab

    @ViewBuilder
    private var metadataTab: some View {
        Form {
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

                Divider()

                Toggle("Prefer XMP sidecar when available", isOn: $settingsViewModel.preferXMPSidecar)
                Text("When an XMP sidecar exists, use it as the primary metadata source for viewing and comparisons.")
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

        do {
            let count = try KnownPeopleService.shared.importFromZip(sourceURL: url)
            isImporting = false
            knownPeopleMessage = "Imported \(count) people"
            refreshKnownPeopleStats()

            // Clear message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                knownPeopleMessage = nil
            }
        } catch {
            isImporting = false
            knownPeopleMessage = "Import failed: \(error.localizedDescription)"
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

        do {
            try KnownPeopleService.shared.exportToZip(destinationURL: url)
            isExporting = false
            knownPeopleMessage = "Export complete"
            refreshKnownPeopleStats()

            // Clear message after delay
            Task {
                try? await Task.sleep(for: .seconds(3))
                knownPeopleMessage = nil
            }
        } catch {
            isExporting = false
            knownPeopleMessage = "Export failed: \(error.localizedDescription)"
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
