import SwiftUI

/// Captures the editor before recording so a transcript cannot replace another photo's text.
struct DescriptionTranscriptionSource: Identifiable {
    let id = UUID()
    let imageURL: URL
    let editorLoadID: UUID?
    let originalDescription: String
}

struct DescriptionTranscriptionView: View {
    let source: DescriptionTranscriptionSource
    var compact = false
    let apply: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var dictation = DescriptionDictationModel()
    @State private var whisperSetup = FFmpegWhisperSetupModel.shared
    @State private var reviewedText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcribe Description").font(compact ? .headline : .title2)
            if !compact { Text(source.imageURL.lastPathComponent).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !compact && !source.originalDescription.isEmpty {
                        DisclosureGroup("Current description") {
                            Text(source.originalDescription).textSelection(.enabled)
                        }
                    }
                    dictationPanel
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Button("Close") { dictation.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to Description") {
                    if apply(reviewedText) { dismiss() }
                    else { errorMessage = "The selected photo or description changed. Close this window and start again." }
                }
                .disabled(dictation.isWorking || dictation.isRecording
                    || reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("descriptionTranscription.apply")
            }
        }
        .padding(compact ? 16 : 24)
        .frame(width: compact ? 420 : 620, height: compact ? 340 : 520)
        .onChange(of: dictation.transcript) { _, text in reviewedText = text }
        .onDisappear { dictation.cancel() }
    }

    private var isDictationWhisperReady: Bool {
        whisperSetup.choice == .whisper ? ManagedWhisperSetupModel.shared.isReady
            : whisperSetup.isReady && whisperSetup.executionConsent
    }

    private var dictationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider: " + whisperSetup.choice.title + ". Record, stop, then review the transcript. Configure the provider in Transcription Settings.")
                .font(.caption).foregroundStyle(.secondary)
            if whisperSetup.choice == .appleSpeech {
                Picker("Speech language", selection: $dictation.localeIdentifier) {
                    ForEach(dictation.availability?.supportedLocales ?? [], id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
                    }
                }.disabled(dictation.isRecording || dictation.isWorking)
                    .task { await dictation.refresh() }
                    .onChange(of: dictation.localeIdentifier) { _, _ in Task { await dictation.refresh() } }
                if let availability = dictation.availability, availability.status != .installed {
                    Text(availability.status == .needsDownload ? "Download this speech language before recording." : "This speech language is not ready. Check Transcription Settings.").font(.caption)
                    if availability.status == .needsDownload {
                        Button("Download Speech Language") { dictation.downloadLanguage() }
                            .disabled(dictation.isWorking)
                    }
                }
            }
            if whisperSetup.choice != .appleSpeech, !isDictationWhisperReady {
                Text("Set up the selected Whisper provider in Transcription Settings before recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if dictation.isRecording {
                    Label("Recording", systemImage: "mic.fill").foregroundStyle(.red)
                    Button("Stop and Transcribe") { dictation.stopAndTranscribe() }
                } else {
                    Button("Start Recording", systemImage: "mic") { dictation.start() }
                        .disabled(dictation.isWorking
                            || (whisperSetup.choice == .appleSpeech && dictation.availability?.status != .installed)
                            || (whisperSetup.choice != .appleSpeech && !isDictationWhisperReady))
                }
                if dictation.isWorking { ProgressView().controlSize(.small) }
                if dictation.isRecording || dictation.isWorking {
                    Button("Cancel") { dictation.cancel() }
                }
            }
            if let message = dictation.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
            if !dictation.transcript.isEmpty {
                Text("Transcript — review and edit").font(.headline)
                TextEditor(text: $reviewedText).frame(minHeight: 130)
                    .accessibilityLabel("Dictation transcript")
                    .disabled(dictation.isWorking || dictation.isRecording)
            }
        }
    }

}
