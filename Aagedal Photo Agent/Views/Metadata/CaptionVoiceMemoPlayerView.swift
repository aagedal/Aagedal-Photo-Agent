import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Playback is explicit and separate from Caption's metadata editing/flush path.
struct CaptionVoiceMemoPlayerView: View {
    let imageURL: URL?
    let isMetadataReviewOrSaveBusy: Bool
    var onVoiceMemoChange: () -> Void = {}
    let openTranscriptionSettings: () -> Void
    @State private var model = CaptionVoiceMemoPlaybackModel()
    @State private var recoveryModel = CaptionVoiceMemoRecoveryModel()
    @State private var associationModel = CaptionVoiceMemoAssociationModel()
    @State private var reassociationModel = CaptionVoiceMemoReassociationModel()
    @State private var transcriptModel = CaptionVoiceMemoTranscriptModel(
        service: UITestVoiceTranscriptionBatchFixture.currentTranscriptService()
            ?? VoiceMemoTranscriptionService()
    )
    @State private var whisperSetup = FFmpegWhisperSetupModel.shared
    @State private var managedWhisper = ManagedWhisperSetupModel.shared
    @State private var refreshID = UUID()
    @State private var scrubPosition: TimeInterval?
    @State private var isSelectingRecoveryMemo = false
    @State private var isSelectingRelationshipFolder = false
    @State private var recoveryImageURL: URL?
    @State private var reassociationImageURL: URL?
    @State private var resetTranscriptURL: URL?

    private struct Request: Equatable {
        let imageURL: URL?
        let refreshID: UUID
    }

    private struct AutomaticAssociationRequest: Equatable {
        let imageURL: URL?
        let refreshID: UUID
        let canAssociate: Bool
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
                    associationModel.cancel()
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
                    Button("Find matching voice memo…", systemImage: "waveform.badge.plus") {
                        guard let imageURL else { return }
                        Task { await associationModel.discover(imageURL: imageURL) }
                    }
                    .disabled(associationModel.isWorking || reassociationModel.isWorking || imageURL == nil
                              || isMetadataReviewOrSaveBusy)
                    .accessibilityIdentifier("caption.voiceMemo.findMatching")
                    Button("Find moved relationship…", systemImage: "folder.badge.questionmark") {
                        reassociationImageURL = imageURL
                        isSelectingRelationshipFolder = true
                    }
                    .disabled(reassociationModel.isWorking || associationModel.isWorking || imageURL == nil)
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
                        Slider(value: Binding(
                            get: { scrubPosition ?? playback.position },
                            set: { scrubPosition = $0 }
                        ), in: 0...playback.duration, onEditingChanged: { editing in
                            if !editing, let position = scrubPosition {
                                Task {
                                    await model.seek(to: position)
                                    scrubPosition = nil
                                }
                            }
                        })
                        .disabled(model.isChangingPlayback)
                        .accessibilityLabel("Voice memo playhead")
                        .accessibilityValue("\(time(playback.position)) of \(time(playback.duration))")
                        .accessibilityIdentifier("caption.voiceMemo.playhead")
                    }
                    transcriptionPanel
                }
            }
            if associationModel.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking matching voice memo…").foregroundStyle(.secondary)
                }
            } else if let error = associationModel.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
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
            scrubPosition = nil
            await model.load(imageURL)
        }
        .task(id: AutomaticAssociationRequest(imageURL: imageURL, refreshID: refreshID,
            canAssociate: !isMetadataReviewOrSaveBusy
                && !recoveryModel.isWorking && !reassociationModel.isWorking)) {
            guard let requestedURL = imageURL, !isMetadataReviewOrSaveBusy,
                  !recoveryModel.isWorking, !reassociationModel.isWorking else { return }
            if await associationModel.associateAutomatically(imageURL: requestedURL),
               !Task.isCancelled, imageURL == requestedURL {
                refreshID = UUID()
            }
        }
        .task(id: Request(imageURL: imageURL, refreshID: refreshID)) {
            await transcriptModel.load(imageURL)
        }
        .task { await whisperSetup.restoreSelections() }
        .task(id: whisperSetup.choice) {
            if whisperSetup.choice == .whisper { await managedWhisper.refresh() }
        }
        .task(id: isPlaying) { await model.pollWhilePlaying() }
        .onReceive(NotificationCenter.default.publisher(for: MetadataSidecarService.voiceMemoTranscriptDidChange)
            .receive(on: DispatchQueue.main)) { notification in
            guard let url = notification.object as? URL, url.standardizedFileURL.path == imageURL?.standardizedFileURL.path,
                  !transcriptModel.isChecking, !transcriptModel.isTranscribing,
                  !transcriptModel.isSavingTranscript, !transcriptModel.isDownloading else { return }
            Task { await transcriptModel.reloadPersistedDraftIfIdle(for: url) }
        }
        .onChange(of: transcriptModel.draft) { _, _ in onVoiceMemoChange() }
        .onChange(of: refreshID) { _, _ in onVoiceMemoChange() }
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
        .alert(
            "Link matching voice memo?",
            isPresented: Binding(
                get: { associationModel.pendingAssociation != nil },
                // Buttons own dismissal so SwiftUI cannot clear the preview before the async confirmation starts.
                set: { _ in }
            )
        ) {
            Button("Cancel", role: .cancel) { associationModel.cancel() }
            Button("Link Voice Memo") {
                Task {
                    if await associationModel.confirm() { refreshID = UUID() }
                }
            }
        } message: {
            if let pair = associationModel.pendingAssociation {
                Text("Link \(pair.memoURL.lastPathComponent) to \(pair.imageURL.lastPathComponent)? Camera capture evidence and the matching WAV were checked. This saves a relationship record in this folder; the photo and audio remain unchanged.")
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
                     ? "The current photo or selected WAV does not match the previously recorded bytes. Using it will create a new association and invalidate any transcript tied to the old audio."
                     : "This older relationship has no historical content identity, so the selected WAV cannot be proven to be the original. Using it will record a new replacement association and revoke any audio-bound approval.")
            }
        }
        .confirmationDialog("Reset this transcript?", isPresented: Binding(
            get: { resetTranscriptURL != nil }, set: { if !$0 { resetTranscriptURL = nil } }
        ), titleVisibility: .visible) {
            Button("Reset Transcript", role: .destructive) {
                guard let url = resetTranscriptURL else { return }
                resetTranscriptURL = nil
                Task { await transcriptModel.resetTranscript(for: url) }
            }
        } message: {
            Text("This removes the saved transcript so you can transcribe the voice memo again. The WAV and text already inserted into metadata are kept.")
        }
        .onChange(of: imageURL) {
            resetTranscriptURL = nil
            recoveryModel.cancel()
            associationModel.cancel()
            reassociationModel.cancel()
            transcriptModel.cancel(resetDraft: true)
            isSelectingRecoveryMemo = false
            isSelectingRelationshipFolder = false
            recoveryImageURL = nil
            reassociationImageURL = nil
        }
        .onDisappear {
            model.stop()
            recoveryModel.cancel()
            associationModel.cancel()
            reassociationModel.cancel()
            transcriptModel.cancel(resetDraft: true)
            recoveryImageURL = nil
            reassociationImageURL = nil
        }
    }

    private var transcriptionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            HStack(spacing: 8) {
                if whisperSetup.choice == .appleSpeech {
                    appleTranscriptionControls
                } else {
                    whisperPanel
                }
                if transcriptModel.isTranscribing || transcriptModel.isDownloading {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { transcriptModel.cancel() }
                        .accessibilityIdentifier("caption.voiceMemo.cancelTranscription")
                }
                Spacer(minLength: 0)
                Button("Reset Transcript", systemImage: "arrow.counterclockwise") {
                    resetTranscriptURL = imageURL
                }
                .labelStyle(.iconOnly)
                .help("Reset the saved transcript to transcribe this voice memo again")
                .disabled(whisperSetup.isTranscribing || transcriptModel.isSavingTranscript
                    || transcriptModel.isChecking || isMetadataReviewOrSaveBusy)
                .accessibilityIdentifier("caption.voiceMemo.resetTranscript")
                Button("Transcription Settings", systemImage: "gearshape", action: openTranscriptionSettings)
                    .labelStyle(.iconOnly)
                    .help("Transcription Settings")
                    .accessibilityIdentifier("caption.voiceMemo.transcriptionSettings")
            }
            .frame(height: 26)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if let error = transcriptModel.errorMessage {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if transcriptModel.isTranscribing || transcriptModel.isDownloading {
                        Text(transcriptModel.isTranscribing ? "Transcribing locally…" : "Downloading speech language…")
                            .foregroundStyle(.secondary)
                    }
                    if let draft = transcriptModel.draft {
                        Text(draft.reviewedText).textSelection(.enabled).font(.body)
                    } else if transcriptModel.errorMessage == nil && !transcriptModel.isTranscribing && !transcriptModel.isDownloading {
                        Text("The voice memo transcript will appear here.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 64)
            .help("Use {voiceMemoTranscript} in a metadata field to insert this text.")
            .accessibilityLabel("Voice memo transcript")
            .accessibilityIdentifier("caption.voiceMemo.transcriptDraft")
        }
        .frame(height: 105)
    }

    @ViewBuilder
    private var appleTranscriptionControls: some View {
        if transcriptModel.isChecking {
            ProgressView().controlSize(.small)
            Text("Checking on-device speech…").foregroundStyle(.secondary)
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
                    .disabled(whisperSetup.isTranscribing)
                    .accessibilityIdentifier("caption.voiceMemo.transcriptionLanguage")
                }
                Spacer(minLength: 0)
                switch availability.status {
                case .installed:
                    Button("Transcribe", systemImage: "text.bubble") {
                        guard whisperSetup.beginTranscription() else { return }
                        Task {
                            defer { whisperSetup.finishTranscription() }
                            await transcriptModel.transcribe()
                        }
                    }
                    .disabled(whisperSetup.isTranscribing || transcriptModel.isTranscribing || transcriptModel.isSavingTranscript)
                    .accessibilityIdentifier("caption.voiceMemo.transcribe")
                case .needsDownload:
                    Button("Download Language", systemImage: "arrow.down.circle") {
                        guard whisperSetup.beginTranscription() else { return }
                        Task {
                            defer { whisperSetup.finishTranscription() }
                            await transcriptModel.downloadLanguage()
                        }
                    }
                    .disabled(whisperSetup.isTranscribing || transcriptModel.isDownloading)
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
                    .disabled(whisperSetup.isTranscribing)
                    .accessibilityIdentifier("caption.voiceMemo.releaseLanguage")
                case .downloading:
                    Text("Language downloading…").foregroundStyle(.secondary)
                case .unsupported:
                    Text("On-device transcription unavailable").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isWhisperReady: Bool {
        whisperSetup.choice == .whisper ? managedWhisper.isReady
            : whisperSetup.isReady && whisperSetup.executionConsent
    }

    private var whisperPanel: some View {
        HStack {
            WhisperLanguagePicker(selection: $whisperSetup.language)
                .frame(width: 310)
                .disabled(whisperSetup.isTranscribing || transcriptModel.isTranscribing)
            Button("Transcribe", systemImage: "text.bubble") {
                let provider = whisperSetup.choice == .whisper
                    ? managedWhisper.provider(language: whisperSetup.language, useGPU: whisperSetup.useGPU, translate: whisperSetup.translate)
                    : whisperSetup.provider()
                guard let provider, whisperSetup.beginTranscription() else { return }
                Task {
                    defer { whisperSetup.finishTranscription() }
                    await transcriptModel.transcribe(provider: provider)
                }
            }
            .disabled(whisperSetup.isTranscribing || !isWhisperReady || !whisperSetup.isLanguageValid

                      || transcriptModel.isTranscribing || transcriptModel.isChecking || transcriptModel.isSavingTranscript)
            .accessibilityIdentifier("caption.voiceMemo.transcribe")
            if !isWhisperReady {
                Text("Set up Whisper in Settings.").foregroundStyle(.secondary)
            }
        }
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
