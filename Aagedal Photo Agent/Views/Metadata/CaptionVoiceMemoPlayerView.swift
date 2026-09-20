import SwiftUI
import UniformTypeIdentifiers

/// Playback is explicit and separate from Caption's metadata editing/flush path.
struct CaptionVoiceMemoPlayerView: View {
    let imageURL: URL?
    @State private var model = CaptionVoiceMemoPlaybackModel()
    @State private var recoveryModel = CaptionVoiceMemoRecoveryModel()
    @State private var reassociationModel = CaptionVoiceMemoReassociationModel()
    @State private var transcriptModel = CaptionVoiceMemoTranscriptModel()
    @State private var whisperSetup = FFmpegWhisperSetupModel()
    @State private var isSelectingWhisperExecutable = false
    @State private var isSelectingWhisperModel = false
    @State private var refreshID = UUID()
    @State private var isSelectingRecoveryMemo = false
    @State private var isSelectingRelationshipFolder = false
    @State private var recoveryImageURL: URL?
    @State private var reassociationImageURL: URL?

    private struct Request: Equatable {
        let imageURL: URL?
        let refreshID: UUID
    }

    private var isPlaying: Bool {
        if case .available(let playback) = model.state { return playback.isPlaying }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Voice memo", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Refresh voice memo", systemImage: "arrow.clockwise") {
                    refreshID = UUID()
                }
                .labelStyle(.iconOnly)
                .help("Reload the saved voice-memo relationship for this photo")
                .accessibilityIdentifier("caption.voiceMemo.refresh")
                .disabled(imageURL == nil)
            }
            switch model.state {
            case .idle, .loading:
                Text("Checking voice memo…").foregroundStyle(.secondary)
            case .none:
                VStack(alignment: .leading, spacing: 5) {
                    Text("No associated voice memo").foregroundStyle(.secondary)
                    Button("Find moved relationship…", systemImage: "folder.badge.questionmark") {
                        reassociationImageURL = imageURL
                        isSelectingRelationshipFolder = true
                    }
                    .disabled(reassociationModel.isWorking || imageURL == nil)
                    .accessibilityIdentifier("caption.voiceMemo.findRelationship")
                }
            case .missing(let filename):
                VStack(alignment: .leading, spacing: 5) {
                    Text("Voice memo missing: \(filename).")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button("Locate or replace voice memo…", systemImage: "waveform.badge.plus") {
                        recoveryImageURL = imageURL
                        isSelectingRecoveryMemo = true
                    }
                    .disabled(recoveryModel.isWorking || imageURL == nil)
                    .accessibilityIdentifier("caption.voiceMemo.recover")
                }
            case .unavailable(let message):
                Text(message).foregroundStyle(.orange)
            case .available(let playback):
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Button(playback.isPlaying ? "Pause voice memo" : "Play voice memo",
                               systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                            Task { await model.toggle() }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(model.isChangingPlayback)
                        .accessibilityIdentifier("caption.voiceMemo.playPause")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playback.association.memoURL.lastPathComponent)
                                .lineLimit(1)
                                .help(playback.association.memoURL.path)
                            Text("\(time(playback.position)) / \(time(playback.duration))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Voice memo playback time")
                                .accessibilityValue("\(time(playback.position)) of \(time(playback.duration))")
                        }
                        Spacer(minLength: 0)
                    }
                    transcriptionPanel
                }
            }
            if recoveryModel.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Verifying selected WAV…").foregroundStyle(.secondary)
                }
            } else if let error = recoveryModel.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if reassociationModel.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking selected folder…").foregroundStyle(.secondary)
                }
            } else if let message = reassociationStatusMessage {
                Text(message)
                    .foregroundStyle(reassociationModel.errorMessage == nil ? .orange : .red)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("caption.voiceMemo")
        .task(id: Request(imageURL: imageURL, refreshID: refreshID)) {
            await model.load(imageURL)
        }
        .task(id: Request(imageURL: imageURL, refreshID: refreshID)) {
            await transcriptModel.load(imageURL)
        }
        .task { await whisperSetup.restoreSelections() }
        .task(id: isPlaying) { await model.pollWhilePlaying() }
        .fileImporter(
            isPresented: $isSelectingRecoveryMemo,
            allowedContentTypes: [UTType(filenameExtension: "wav") ?? .audio],
            allowsMultipleSelection: false
        ) { result in
            guard let requestedImageURL = recoveryImageURL else { return }
            recoveryImageURL = nil
            switch result {
            case .success(let urls):
                guard let candidate = urls.first else { return }
                Task {
                    if await recoveryModel.select(candidateURL: candidate, for: requestedImageURL) {
                        refreshID = UUID()
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    recoveryModel.reportPickerError(error)
                }
            }
        }
        .fileImporter(
            isPresented: $isSelectingRelationshipFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let requestedImageURL = reassociationImageURL else { return }
            reassociationImageURL = nil
            switch result {
            case .success(let urls):
                guard let location = urls.first else { return }
                Task {
                    if await reassociationModel.search(location, for: requestedImageURL) {
                        refreshID = UUID()
                    }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    reassociationModel.reportPickerError(error)
                }
            }
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
        .alert(
            "Use replacement voice memo?",
            isPresented: Binding(
                get: { recoveryModel.pendingReplacement != nil },
                set: { if !$0 { recoveryModel.dismissReplacement() } }
            )
        ) {
            Button("Cancel", role: .cancel) { recoveryModel.dismissReplacement() }
            Button("Use Replacement", role: .destructive) {
                Task {
                    if await recoveryModel.confirmReplacement() {
                        refreshID = UUID()
                    }
                }
            }
        } message: {
            if case .explicitReplacement(let hadIdentity) = recoveryModel.pendingReplacement?.kind {
                Text(hadIdentity
                     ? "The current photo or selected WAV does not match the previously recorded bytes. Using it will create a new association and revoke any transcript approval tied to the old audio."
                     : "This older relationship has no historical content identity, so the selected WAV cannot be proven to be the original. Using it will record a new replacement association and revoke any audio-bound approval.")
            }
        }
        .onChange(of: imageURL) {
            recoveryModel.cancel()
            reassociationModel.cancel()
            transcriptModel.cancel(resetDraft: true)
            isSelectingRecoveryMemo = false
            isSelectingRelationshipFolder = false
            recoveryImageURL = nil
            reassociationImageURL = nil
        }
        .onDisappear {
            whisperSetup.endSession()
            model.stop()
            recoveryModel.cancel()
            reassociationModel.cancel()
            transcriptModel.cancel(resetDraft: true)
            recoveryImageURL = nil
            reassociationImageURL = nil
        }
    }

    @ViewBuilder
    private var transcriptionPanel: some View {
        Divider()
        Picker("Transcription provider", selection: $whisperSetup.choice) {
            ForEach(VoiceMemoTranscriptionProviderChoice.allCases, id: \.rawValue) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .accessibilityIdentifier("caption.voiceMemo.transcriptionProvider")
        .disabled(transcriptModel.isTranscribing || transcriptModel.isDownloading || whisperSetup.isPreparing)
        if whisperSetup.choice == .customWhisper {
            customWhisperPanel
        } else if transcriptModel.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking on-device speech…").foregroundStyle(.secondary)
            }
        } else if let availability = transcriptModel.availability {
            HStack(spacing: 8) {
                if !availability.supportedLocales.isEmpty {
                    Picker("Transcription language", selection: Binding(
                        get: { transcriptModel.selectedLocaleIdentifier },
                        set: { identifier in
                            Task { await transcriptModel.selectLocale(identifier: identifier) }
                        }
                    )) {
                        ForEach(availability.supportedLocales, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier)
                                 ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("caption.voiceMemo.transcriptionLanguage")
                }
                Spacer(minLength: 0)
                switch availability.status {
                case .installed:
                    Button("Transcribe", systemImage: "text.bubble") {
                        Task { await transcriptModel.transcribe() }
                    }
                    .disabled(transcriptModel.isTranscribing || transcriptModel.isSavingReview)
                    .accessibilityIdentifier("caption.voiceMemo.transcribe")
                case .needsDownload:
                    Button("Download Language", systemImage: "arrow.down.circle") {
                        Task { await transcriptModel.downloadLanguage() }
                    }
                    .disabled(transcriptModel.isDownloading)
                    .accessibilityIdentifier("caption.voiceMemo.downloadLanguage")
                case .reservationLimitReached:
                    Menu("Release Speech Language", systemImage: "externaldrive.badge.minus") {
                        ForEach(availability.reservedLocales, id: \.identifier) { locale in
                            Button("Release \(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)") {
                                Task {
                                    await transcriptModel.releaseLanguage(identifier: locale.identifier)
                                }
                            }
                        }
                    }
                    .help("Apple on-device speech has no free language reservation for this app")
                    .accessibilityIdentifier("caption.voiceMemo.releaseLanguage")
                case .downloading:
                    Text("Language downloading…").foregroundStyle(.secondary)
                case .unsupported:
                    Text("On-device transcription unavailable").foregroundStyle(.secondary)
                }
            }

            if transcriptModel.isTranscribing || transcriptModel.isDownloading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(transcriptModel.isTranscribing
                         ? "Transcribing locally with Apple on-device speech…"
                         : "Downloading the selected on-device language…")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Cancel") { transcriptModel.cancel() }
                        .accessibilityIdentifier("caption.voiceMemo.cancelTranscription")
                }
            }
        }

        if whisperSetup.choice == .customWhisper && transcriptModel.isTranscribing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing locally with custom FFmpeg Whisper…")
                Button("Cancel") { transcriptModel.cancel() }
                    .accessibilityIdentifier("caption.voiceMemo.cancelTranscription")
            }
        }
        if let error = transcriptModel.errorMessage {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }

        if let draft = transcriptModel.draft {
            if draft.whisperProvenance?.buildIdentifier.hasPrefix("custom-unverified-sha256:") == true {
                Text("Custom, unverified FFmpeg Whisper transcript. Artifact hashes record identity, not trust or compatibility.")
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Transcript draft")
                .font(.caption.weight(.semibold))
            TextEditor(text: Binding(
                get: { draft.reviewedText },
                set: { transcriptModel.updateReviewedText($0) }
            ))
            .font(.body)
            .frame(minHeight: 70, maxHeight: 130)
            .disabled(transcriptModel.isSavingReview)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator, lineWidth: 1)
            }
            .accessibilityLabel("Voice memo transcript draft")
            .accessibilityIdentifier("caption.voiceMemo.transcriptDraft")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.isApproved
                     ? "Reviewed and approved for this exact WAV. Editing revokes approval."
                     : "Generated locally in \(draft.localeIdentifier). Review the text, then approve it explicitly.")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if transcriptModel.isSavingReview {
                    ProgressView().controlSize(.small)
                }
                Button(draft.isApproved ? "Approved" : "Approve Transcript",
                       systemImage: draft.isApproved ? "checkmark.seal.fill" : "checkmark.seal") {
                    Task { await transcriptModel.approve() }
                }
                .disabled(draft.isApproved || transcriptModel.isSavingReview
                          || draft.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("caption.voiceMemo.approveTranscript")
            }
            Text("Approval stores transcript provenance in the app sidecar only. It does not change Description or any other IPTC field.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var customWhisperPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Custom files are unverified. Choose a compatible FFmpeg build with the patched Whisper JSON filter and a compatible model. No downloads occur.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("Provider choice and file access are saved. Each Caption session requires fresh execution consent and file identity checks. Clear Custom Files forgets the saved files.")
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
            Toggle("I allow this unverified executable to run locally on my voice memo when I press Transcribe.",
                   isOn: $whisperSetup.executionConsent)
                .accessibilityIdentifier("caption.voiceMemo.whisper.executionConsent")
            Text("Identity checks do not verify signing, licensing, safety, or compatibility. Language is detected automatically; inference uses CPU.")
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                if whisperSetup.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Recording custom artifact identities…")
                    Button("Cancel Setup") { whisperSetup.cancelPreparation() }
                } else if whisperSetup.isReady {
                    Button("Transcribe", systemImage: "text.bubble") {
                        guard let provider = whisperSetup.provider() else { return }
                        Task { await transcriptModel.transcribe(provider: provider) }
                    }
                    .disabled(transcriptModel.isChecking || transcriptModel.isSavingReview)
                    .accessibilityIdentifier("caption.voiceMemo.transcribe")
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
        .disabled(transcriptModel.isTranscribing)
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(0, seconds), 86_400 * 365))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var reassociationStatusMessage: String? {
        if let error = reassociationModel.errorMessage { return error }
        switch reassociationModel.result {
        case .reassociated:
            return "The moved voice-memo relationship was verified and restored."
        case .ambiguous(let count):
            return "Found \(count) exact relationship candidates. Choose a narrower folder so one location owns the relationship."
        case .sourceChanged:
            return "The selected relationship points to different photo bytes. It was not attached."
        case .notFound:
            return "No relationship with the exact photo and WAV bytes was found in the selected folder."
        case nil:
            return nil
        }
    }
}
