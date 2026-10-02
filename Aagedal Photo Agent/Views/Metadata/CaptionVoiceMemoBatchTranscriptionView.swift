import SwiftUI

/// Confirms the captured selection; admitted work continues in the Activity panel.
struct CaptionVoiceMemoBatchTranscriptionView: View {
    @Bindable var model: CaptionVoiceMemoBatchTranscriptionModel
    let reviewOrSaveBusy: Bool
    let providerBusy: Bool
    let onClose: () -> Void
    let onReset: () -> Void
    @State private var consent = false
    @State private var isConfirmingReset = false

    private var imageURLs: [URL] { model.snapshot?.imageURLs ?? model.selectedImageURLs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.isChecking ? "Checking Selected Voice Memos" : "Transcribe Selected Voice Memos")
                .font(.title2.weight(.semibold))
            Text("\(imageURLs.count) photos, in the captured Browser order")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                        Text("\(index + 1). \(url.lastPathComponent)")
                        .textSelection(.enabled).help(url.path)
                        .accessibilityIdentifier("caption.voiceMemo.batch.target.\(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 240)
            if let snapshot = model.snapshot {
                Text("Provider: \(snapshot.providerTitle)")
                    .accessibilityIdentifier("caption.voiceMemo.batch.provider")
                Text("Language: \(snapshot.languageTitle)")
                    .accessibilityIdentifier("caption.voiceMemo.batch.language")
                Text("Transcription runs in the background. View progress, cancel the batch, and check results in Activity in the sidebar. Saved transcripts are available in Caption through {voiceMemoTranscript}.")
                    .foregroundStyle(.secondary)
                Toggle("Allow local transcription of these selected voice memos", isOn: $consent)
                    .accessibilityIdentifier("caption.voiceMemo.batch.consent")
                if reviewOrSaveBusy || providerBusy {
                    Text("Finish the active review or transcription before confirming this batch.")
                        .foregroundStyle(.orange)
                }
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("caption.voiceMemo.batch.sheet.error")
            }
            Divider()
            HStack {
                Button("Reset Selected Transcripts…", systemImage: "arrow.counterclockwise") {
                    isConfirmingReset = true
                }
                .disabled(!(1...8).contains(imageURLs.count) || model.isChecking || model.isResetting
                    || model.isRunning || providerBusy || reviewOrSaveBusy)
                .accessibilityIdentifier("caption.voiceMemo.batch.resetTranscripts")
                if model.isResetting { ProgressView().controlSize(.small) }
                Spacer()
                Button(model.snapshot == nil ? "Close" : "Cancel", role: .cancel) {
                    model.dismissConfirmation()
                    onClose()
                }
                .disabled(model.isResetting)
                .accessibilityIdentifier("caption.voiceMemo.batch.cancelConfirmation")
                if model.snapshot != nil {
                    Button("Transcribe \(imageURLs.count) Photos") {
                        if model.start(consent: consent, reviewOrSaveBusy: reviewOrSaveBusy, providerBusy: providerBusy) {
                            onClose()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!consent || reviewOrSaveBusy || providerBusy || model.isChecking || model.isRunning || model.isResetting)
                    .accessibilityIdentifier("caption.voiceMemo.batch.confirm")
                }
            }
        }
        .padding(22)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption.voiceMemo.batch.sheet")
        .interactiveDismissDisabled(model.isResetting)
        .confirmationDialog("Reset transcripts for \(imageURLs.count) selected photos?",
            isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset Selected Transcripts", role: .destructive) {
                let selectedImageURLs = imageURLs
                consent = false
                Task {
                    if await model.resetTranscripts(imageURLs: selectedImageURLs) { onReset() }
                }
            }
        } message: {
            Text("Saved transcripts will be removed so these voice memos can be transcribed again. The WAV files and text already inserted into metadata are kept.")
        }
        .onDisappear { model.dismissConfirmation() }
    }
}
