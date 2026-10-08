import SwiftUI
import UniformTypeIdentifiers

/// Application-wide setup; no photo or transcript is mutated by this view.
struct TranscriptionSettingsView: View {
    @State private var whisperSetup = FFmpegWhisperSetupModel.shared
    @State private var managedWhisper = ManagedWhisperSetupModel.shared
    @State private var isSelectingWhisperExecutable = false
    @State private var isSelectingWhisperModel = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Transcription provider", selection: $whisperSetup.choice) {
                    ForEach(VoiceMemoTranscriptionProviderChoice.allCases, id: \.rawValue) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .accessibilityIdentifier("caption.voiceMemo.transcriptionProvider")
                .disabled(whisperSetup.isPreparing)
            }
            if whisperSetup.choice == .whisper {
                Section("Whisper") { managedWhisperPanel }
                Section("Transcription Options") { whisperOptions }
            } else if whisperSetup.choice == .customWhisper {
                Section("Custom FFmpeg Whisper") { customWhisperPanel }
            } else {
                Section {
                    Text("Apple Speech uses on-device recognition. Select the speech language in Caption before transcribing a voice memo.")
                }
            }
        }
        .disabled(whisperSetup.isTranscribing)
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .navigationTitle("Transcription")
        .task { await whisperSetup.restoreSelections() }
        .task(id: whisperSetup.choice.rawValue + ":" + managedWhisper.selectedModelID) {
            if whisperSetup.choice == .whisper { await managedWhisper.refresh() }
        }
        .fileImporter(isPresented: $isSelectingWhisperExecutable,
                      allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await whisperSetup.select(url, executable: true) } }
            case .failure(let error): whisperSetup.reportPickerError(error)
            }
        }
        .fileImporter(isPresented: $isSelectingWhisperModel,
                      allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await whisperSetup.select(url, executable: false) } }
            case .failure(let error): whisperSetup.reportPickerError(error)
            }
        }
    }

    private var managedWhisperPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download a model to transcribe voice memos on your Mac.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            Picker("Whisper model", selection: Binding(
                get: { managedWhisper.selectedModelID },
                set: { managedWhisper.selectModel($0) }
            )) {
                if !managedWhisper.downloadedModels.isEmpty {
                    Section("Downloaded Models") {
                        ForEach(managedWhisper.downloadedModels) { model in
                            modelOption(model)
                        }
                    }
                }
                if !managedWhisper.downloadableModels.isEmpty {
                    Section("Available to Download") {
                        ForEach(managedWhisper.downloadableModels) { model in
                            modelOption(model)
                        }
                    }
                }
            }
            .disabled(managedWhisper.isDownloading || managedWhisper.isRefreshing)
            .accessibilityIdentifier("settings.transcription.whisper.model")
            Text("\(managedWhisper.downloadedModels.count) downloaded · \(managedWhisper.downloadableModels.count) available to download")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.transcription.whisper.inventory")
            Label(managedWhisper.localModelIDs.contains(managedWhisper.selectedModelID)
                  ? "Downloaded on this Mac" : "Available to Download",
                  systemImage: managedWhisper.localModelIDs.contains(managedWhisper.selectedModelID) ? "internaldrive" : "arrow.down.circle")
                .accessibilityIdentifier("settings.transcription.whisper.modelAvailability")
            Text("Downloaded models are verified when selected. To get another model, choose it under Available to Download, then click Download Model.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Smaller models are faster. For Norwegian, choose an NbAiLab model and select Norwegian below.")
                .font(.caption).foregroundStyle(.secondary)
            if managedWhisper.isDownloading {
                ProgressView(value: managedWhisper.progress) {
                    Text("Downloading \(managedWhisper.selectedModel.title)…")
                } currentValueLabel: {
                    Text(managedWhisper.progress, format: .percent.precision(.fractionLength(0)))
                }
                .accessibilityIdentifier("settings.transcription.whisper.downloadProgress")
                Button("Cancel Download") { managedWhisper.cancelDownload() }
                    .accessibilityIdentifier("settings.transcription.whisper.cancelDownload")
            } else if managedWhisper.isRefreshing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking transcription files…")
                }
            } else {
                if managedWhisper.needsModelReplacement {
                    Text("This model failed verification. Download a replacement or remove it to free disk space.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.transcription.whisper.recoveryHelp")
                }
                if managedWhisper.isReady {
                    Label("Ready to transcribe in Caption", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("settings.transcription.whisper.ready")
                } else {
                    Button(managedWhisper.isInstalled ? "Retry Setup" : managedWhisper.needsModelReplacement ? "Download Replacement" : "Download Model") {
                        if managedWhisper.isInstalled {
                            Task { await managedWhisper.refresh() }
                        } else {
                            managedWhisper.downloadSelectedModel()
                        }
                    }
                    .accessibilityIdentifier("settings.transcription.whisper.download")
                }
                if managedWhisper.canRemoveModel {
                    Button("Remove Downloaded Model") { Task { await managedWhisper.removeSelectedModel() } }
                        .accessibilityIdentifier("settings.transcription.whisper.removeModel")
                }
            }
            if let error = managedWhisper.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("settings.transcription.whisper.error")
            }
            if let error = managedWhisper.catalogErrorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("settings.transcription.whisper.inventoryError")
            }
        }
    }

    private func modelOption(_ model: WhisperDownloadableModel) -> some View {
        Text("\(model.title) (\(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file)))")
            .tag(model.id)
    }

    private var whisperOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            WhisperLanguagePicker(selection: $whisperSetup.language)
            Toggle("Translate speech into English", isOn: $whisperSetup.translate)
                .accessibilityIdentifier("caption.voiceMemo.whisper.translateToEnglish")
            Toggle("Request GPU acceleration", isOn: $whisperSetup.useGPU)
                .accessibilityIdentifier("caption.voiceMemo.whisper.useGPU")
            Text("Language, translation, and GPU support depend on the model and FFmpeg build. Turn off GPU acceleration if transcription cannot run with it enabled.")
                .foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var customWhisperPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Custom files are unverified. Choose a compatible FFmpeg build with the patched Whisper JSON filter and a compatible model. No downloads occur.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("Provider choice, transcription settings, and file access are saved. Each app session requires fresh execution consent and file identity checks. Clear Custom Files forgets the saved files.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Choose FFmpeg…") { isSelectingWhisperExecutable = true }
                    .accessibilityIdentifier("caption.voiceMemo.whisper.selectExecutable")
                Text(whisperSetup.executableURL?.lastPathComponent ?? "No executable selected")
                    .lineLimit(1).help(whisperSetup.executableURL?.path ?? "")
            }
            HStack {
                Button("Choose Model…") { isSelectingWhisperModel = true }
                    .accessibilityIdentifier("caption.voiceMemo.whisper.selectModel")
                Text(whisperSetup.modelURL?.lastPathComponent ?? "No model selected")
                    .lineLimit(1).help(whisperSetup.modelURL?.path ?? "")
            }
            whisperOptions
            Toggle("I allow this unverified executable to run locally on my voice memo when I press Transcribe.",
                   isOn: $whisperSetup.executionConsent)
                .accessibilityIdentifier("caption.voiceMemo.whisper.executionConsent")
            Text("Identity checks do not verify signing, licensing, safety, or compatibility.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if whisperSetup.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Recording custom artifact identities…")
                    Button("Cancel Setup") { whisperSetup.cancelPreparation() }
                } else if whisperSetup.isReady {
                    Label("Ready to transcribe in Caption", systemImage: "checkmark.circle")
                } else {
                    Button("Enable Custom Files") { Task { await whisperSetup.prepare() } }
                        .disabled(!whisperSetup.executionConsent || whisperSetup.executableURL == nil
                                  || whisperSetup.modelURL == nil)
                        .accessibilityIdentifier("caption.voiceMemo.whisper.enable")
                }
                Button("Clear Custom Files") { whisperSetup.clear() }
                    .accessibilityIdentifier("caption.voiceMemo.whisper.clear")
            }
            if let error = whisperSetup.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

}

/// Uses the same persisted choice in Settings and the Caption toolbar.
struct WhisperLanguagePicker: View {
    @Binding var selection: String

    var body: some View {
        Picker("Transcription language", selection: $selection) {
            ForEach(WhisperTranscriptionLanguage.options) { language in
                Text(language.title).tag(language.id)
            }
            if !WhisperTranscriptionLanguage.options.contains(where: { $0.id == selection }) {
                Text(WhisperTranscriptionLanguage.title(for: selection)).tag(selection)
            }
        }
        .accessibilityIdentifier("caption.voiceMemo.whisper.language")
    }
}
