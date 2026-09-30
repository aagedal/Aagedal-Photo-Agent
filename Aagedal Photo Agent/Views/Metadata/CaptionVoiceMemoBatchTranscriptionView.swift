import SwiftUI

/// An explicit consent boundary for a captured, ordered set of photos and one provider.
struct CaptionVoiceMemoBatchTranscriptionView: View {
    @Bindable var model: CaptionVoiceMemoBatchTranscriptionModel
    let reviewOrSaveBusy: Bool
    let providerBusy: Bool
    let onClose: () -> Void
    @State private var consent = false

    private var imageURLs: [URL] { model.snapshot?.imageURLs ?? model.activeImageURLs }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.snapshot == nil ? "Voice Memo Batch Results" : "Transcribe Selected Voice Memos")
                .font(.title2.weight(.semibold))
            Text("Provider: \(model.snapshot?.providerTitle ?? model.activeProviderTitle ?? "Selected provider")")
                .accessibilityIdentifier("caption.voiceMemo.batch.provider")
            Text("Language: \(model.snapshot?.languageTitle ?? model.activeLanguageTitle ?? "Captured language")")
                .accessibilityIdentifier("caption.voiceMemo.batch.language")
            Text("\(imageURLs.count) photos, in the captured Browser order")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1). \(url.lastPathComponent)")
                                .textSelection(.enabled)
                                .help(url.path)
                                .accessibilityIdentifier("caption.voiceMemo.batch.target.\(index)")
                            Spacer()
                            if model.snapshot == nil {
                                Text(itemStatus(at: index))
                                    .foregroundStyle(itemColor(at: index))
                                    .accessibilityIdentifier("caption.voiceMemo.batch.result.\(index)")
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 240)
            if model.snapshot != nil {
                Text("This batch uses the provider and language shown above for every photo. It saves generated drafts in app sidecars. Review and approval remain separate; IPTC fields are unchanged.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Toggle("I approve local transcription of these selected voice memos", isOn: $consent)
                    .accessibilityIdentifier("caption.voiceMemo.batch.consent")
                if reviewOrSaveBusy || providerBusy {
                    Text("Finish the active review or transcription before confirming this batch.")
                        .foregroundStyle(.orange)
                }
            } else {
                if model.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.isRequestingCancellation ? "Cancellation requested. Waiting for the active item…"
                             : "Transcribing selected voice memos…")
                    }
                    .accessibilityIdentifier("caption.voiceMemo.batch.progress")
                }
                Text(model.statusMessage)
                    .textSelection(.enabled)
                    .accessibilityLabel("Batch transcription status")
                    .accessibilityValue(model.statusMessage)
                    .accessibilityIdentifier("caption.voiceMemo.batch.summary")
                Text("Saved drafts remain available for individual review in Caption. No transcript was approved automatically.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("caption.voiceMemo.batch.sheet.error")
            }
            Divider()
            HStack {
                Spacer()
                if model.snapshot != nil {
                    Button("Cancel", role: .cancel) {
                        model.dismissConfirmation()
                        onClose()
                    }
                    .accessibilityIdentifier("caption.voiceMemo.batch.cancelConfirmation")
                    Button("Transcribe \(imageURLs.count) Photos") {
                        Task {
                            await model.confirm(consent: consent,
                                reviewOrSaveBusy: reviewOrSaveBusy, providerBusy: providerBusy)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!consent || reviewOrSaveBusy || providerBusy || model.isChecking || model.isRunning)
                    .accessibilityIdentifier("caption.voiceMemo.batch.confirm")
                } else if model.isRunning {
                    Button("Cancel Batch", role: .cancel) {
                        Task { await model.requestCancellation() }
                    }
                    .disabled(model.isRequestingCancellation)
                    .accessibilityIdentifier("caption.voiceMemo.batch.cancel")
                } else {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("caption.voiceMemo.batch.close")
                }
            }
        }
        .padding(22)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption.voiceMemo.batch.sheet")
        .interactiveDismissDisabled(model.isRunning)
        .onDisappear { model.dismissConfirmation() }
    }

    private func itemStatus(at index: Int) -> String {
        guard let item = model.record?.batchProgress?.items.first(where: { $0.index == index }) else {
            return model.isRunning ? "Waiting for admission" : "No result recorded"
        }
        switch item.outcome {
        case .draftSaved: return "Draft saved · review required"
        case .failed: return "Failed · no draft saved"
        case .stale: return "Source changed · no draft saved"
        case .cancelled: return "Cancelled · no draft saved"
        case .recoveryRequired: return "Recovery required · check saved draft"
        case nil:
            switch item.state {
            case .queued:
                return model.record?.state == .cancelled ? "Not started · cancelled" : "Not started"
            case .running:
                return model.isRunning ? "Transcribing" : "Outcome uncertain"
            case .completed:
                return "No outcome recorded"
            }
        }
    }

    private func itemColor(at index: Int) -> Color {
        guard let outcome = model.record?.batchProgress?.items.first(where: { $0.index == index })?.outcome else {
            return .secondary
        }
        switch outcome {
        case .draftSaved: return .green
        case .failed: return .red
        case .stale, .recoveryRequired: return .orange
        case .cancelled: return .secondary
        }
    }
}
