import SwiftUI
import UniformTypeIdentifiers

/// Playback is explicit and separate from Caption's metadata editing/flush path.
struct CaptionVoiceMemoPlayerView: View {
    let imageURL: URL?
    let batchImageURLs: [URL]
    let isMetadataReviewOrSaveBusy: Bool
    let openTranscriptionSettings: () -> Void
    @State private var model = CaptionVoiceMemoPlaybackModel()
    @State private var recoveryModel = CaptionVoiceMemoRecoveryModel()
    @State private var associationModel = CaptionVoiceMemoAssociationModel()
    @State private var reassociationModel = CaptionVoiceMemoReassociationModel()
    @State private var transcriptModel = CaptionVoiceMemoTranscriptModel(
        service: UITestVoiceTranscriptionBatchFixture.currentTranscriptService()
            ?? VoiceMemoTranscriptionService()
    )
    @State private var batchModel = CaptionVoiceMemoBatchTranscriptionModel()
    @State private var isShowingBatchTranscription = false
    @State private var whisperSetup = FFmpegWhisperSetupModel.shared
    @State private var managedWhisper = ManagedWhisperSetupModel.shared
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
                    associationModel.cancel()
                    refreshID = UUID()
                }
                .labelStyle(.iconOnly)
                .help("Reload the saved voice-memo relationship for this photo")
                .accessibilityIdentifier("caption.voiceMemo.refresh")
                .disabled(imageURL == nil || isBatchPresentationActive)
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
                    .disabled(associationModel.isWorking || reassociationModel.isWorking || imageURL == nil || isBatchPresentationActive
                              || isMetadataReviewOrSaveBusy)
                    .accessibilityIdentifier("caption.voiceMemo.findMatching")
                    Button("Find moved relationship…", systemImage: "folder.badge.questionmark") {
                        reassociationImageURL = imageURL
                        isSelectingRelationshipFolder = true
                    }
                    .disabled(reassociationModel.isWorking || associationModel.isWorking || imageURL == nil || isBatchPresentationActive)
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
                    .disabled(recoveryModel.isWorking || imageURL == nil || isBatchPresentationActive)
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
            batchTranscriptionPanel
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
        .task(id: whisperSetup.choice) {
            if whisperSetup.choice == .whisper { await managedWhisper.refresh() }
        }
        .task(id: isPlaying) { await model.pollWhilePlaying() }
        .sheet(isPresented: $isShowingBatchTranscription) {
            CaptionVoiceMemoBatchTranscriptionView(
                model: batchModel,
                reviewOrSaveBusy: isBatchReviewOrSaveBusy,
                providerBusy: whisperSetup.isTranscribing,
                onClose: { isShowingBatchTranscription = false }
            )
        }
        .onChange(of: batchModel.completionToken) { _, _ in
            // A saved batch draft may be loaded only when there is no local review to lose.
            guard let imageURL, batchModel.savedDraftImageURLs.contains(imageURL.standardizedFileURL),
                  transcriptModel.draft == nil, !transcriptModel.isSavingReview,
                  !transcriptModel.isTranscribing, !transcriptModel.isDownloading else { return }
            Task { await transcriptModel.refreshPersistedDraftIfEmpty(for: imageURL) }
        }
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
                     ? "The current photo or selected WAV does not match the previously recorded bytes. Using it will create a new association and revoke any transcript approval tied to the old audio."
                     : "This older relationship has no historical content identity, so the selected WAV cannot be proven to be the original. Using it will record a new replacement association and revoke any audio-bound approval.")
            }
        }
        .onChange(of: imageURL) {
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
            batchModel.dismissConfirmation()
            if batchModel.isRunning {
                Task { await batchModel.requestCancellation() }
            }
            recoveryImageURL = nil
            reassociationImageURL = nil
        }
    }

    @ViewBuilder
    private var transcriptionPanel: some View {
        Divider()
        HStack {
            Text(whisperSetup.choice.title).foregroundStyle(.secondary)
            Spacer()
            Button("Transcription Settings…", action: openTranscriptionSettings)
                .accessibilityIdentifier("caption.voiceMemo.transcriptionSettings")
        }
        if whisperSetup.choice != .appleSpeech {
            whisperPanel
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
                    .disabled(whisperSetup.isTranscribing || isBatchPresentationActive)
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
                    .disabled(whisperSetup.isTranscribing || transcriptModel.isTranscribing || transcriptModel.isSavingReview || isBatchPresentationActive)
                    .accessibilityIdentifier("caption.voiceMemo.transcribe")
                case .needsDownload:
                    Button("Download Language", systemImage: "arrow.down.circle") {
                        guard whisperSetup.beginTranscription() else { return }
                        Task {
                            defer { whisperSetup.finishTranscription() }
                            await transcriptModel.downloadLanguage()
                        }
                    }
                    .disabled(whisperSetup.isTranscribing || transcriptModel.isDownloading || isBatchPresentationActive)
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
                    .disabled(whisperSetup.isTranscribing || isBatchPresentationActive)
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

        if whisperSetup.choice != .appleSpeech && transcriptModel.isTranscribing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing locally with Whisper…")
                Button("Cancel") { transcriptModel.cancel() }
                    .accessibilityIdentifier("caption.voiceMemo.cancelTranscription")
            }
        }
        if let error = transcriptModel.errorMessage {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }

        if let draft = transcriptModel.draft {
            if let evidence = draft.whisperProvenance {
                DisclosureGroup("Transcription details") {
                    if evidence.buildIdentifier.hasPrefix("custom-unverified-sha256:") {
                        Text("Custom, unverified FFmpeg Whisper transcript. Artifact hashes record identity, not trust or compatibility.")
                    }
                    Text("Requested language: \(evidence.requestedLanguage). \(evidence.translate ? "Translation into English requested." : "Original-language transcription requested.") \(evidence.useGPU ? "GPU acceleration requested." : "CPU inference requested.")")
                        .accessibilityIdentifier("caption.voiceMemo.whisper.requestEvidence")
                }
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
            .disabled(transcriptModel.isSavingReview || isBatchPresentationActive)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.separator, lineWidth: 1)
            }
            .accessibilityLabel("Voice memo transcript draft")
            .accessibilityIdentifier("caption.voiceMemo.transcriptDraft")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(draft.isApproved
                     ? "Reviewed and approved for this exact WAV. Editing revokes approval."
                     : draft.whisperProvenance != nil
                        ? "Generated locally. Review the text, then approve it explicitly."
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
                          || isBatchPresentationActive
                          || draft.reviewedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("caption.voiceMemo.approveTranscript")
            }
            Text("Approval stores transcript provenance in the app sidecar only. It does not change Description or any other IPTC field.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var isWhisperReady: Bool {
        whisperSetup.choice == .whisper ? managedWhisper.isReady
            : whisperSetup.isReady && whisperSetup.executionConsent
    }

    private var isBatchPresentationActive: Bool {
        batchModel.isChecking || batchModel.isRunning || batchModel.snapshot != nil
    }

    private var isBatchReviewOrSaveBusy: Bool {
        isMetadataReviewOrSaveBusy || recoveryModel.isWorking || reassociationModel.isWorking
            || transcriptModel.isChecking || transcriptModel.isTranscribing
            || transcriptModel.isDownloading || transcriptModel.isSavingReview
            || transcriptModel.draft != nil
    }

    private var batchProvider: AutomationVoiceTranscriptionBatchService.Provider? {
        switch whisperSetup.choice {
        case .appleSpeech:
            guard transcriptModel.availability?.status == .installed else { return nil }
            return .apple(Locale(identifier: transcriptModel.selectedLocaleIdentifier))
        case .whisper:
            guard whisperSetup.isLanguageValid,
                  let provider = managedWhisper.provider(language: whisperSetup.language,
                    useGPU: whisperSetup.useGPU, translate: whisperSetup.translate) else { return nil }
            return .whisper(provider)
        case .customWhisper:
            guard whisperSetup.isLanguageValid, let provider = whisperSetup.provider() else { return nil }
            return .whisper(provider)
        }
    }

    private var batchLanguageTitle: String {
        if whisperSetup.choice == .appleSpeech {
            return Locale.current.localizedString(forIdentifier: transcriptModel.selectedLocaleIdentifier)
                ?? transcriptModel.selectedLocaleIdentifier
        }
        let language = whisperSetup.language == "auto" ? "Automatic language detection" : whisperSetup.language
        return language + (whisperSetup.translate ? " · Translate into English" : " · Original language")
    }

    private var batchTranscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            HStack(spacing: 8) {
                Button("Transcribe Selected…", systemImage: "waveform.badge.plus") {
                    // All values are captured before awaiting preparation or showing consent.
                    let urls = batchImageURLs
                    let provider = batchProvider
                    let providerTitle = whisperSetup.choice.title
                    let languageTitle = batchLanguageTitle
                    let reviewBusy = isBatchReviewOrSaveBusy
                    let providerBusy = whisperSetup.isTranscribing
                    Task {
                        await batchModel.prepare(imageURLs: urls, provider: provider,
                            providerTitle: providerTitle, languageTitle: languageTitle,
                            reviewOrSaveBusy: reviewBusy, providerBusy: providerBusy)
                        if batchModel.snapshot != nil { isShowingBatchTranscription = true }
                    }
                }
                .disabled(!(1...AutomationVoiceTranscriptionBatchService.maximumPhotos).contains(batchImageURLs.count)
                          || isBatchReviewOrSaveBusy || whisperSetup.isTranscribing || isBatchPresentationActive)
                .accessibilityIdentifier("caption.voiceMemo.batch.prepare")
                if batchModel.isChecking { ProgressView().controlSize(.small) }
                if batchModel.record != nil {
                    Button(batchModel.isRunning ? "View Batch Progress…" : "View Batch Results…") {
                        isShowingBatchTranscription = true
                    }
                    .accessibilityIdentifier("caption.voiceMemo.batch.results")
                }
                Spacer(minLength: 0)
            }
            Text("\(batchImageURLs.count) photos selected when Caption opened. Batch limit: 8.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("caption.voiceMemo.batch.scope")
            if batchImageURLs.isEmpty || batchImageURLs.count > AutomationVoiceTranscriptionBatchService.maximumPhotos {
                Text("Select 1–8 photos in Browser, then reopen Caption to transcribe their voice memos.")
                    .foregroundStyle(.secondary)
            } else if transcriptModel.draft != nil {
                Text("The current transcript review is kept. Open a photo without a transcript draft to prepare a batch.")
                    .foregroundStyle(.secondary)
            } else if isBatchReviewOrSaveBusy {
                Text("Finish the current review or save before preparing a batch.")
                    .foregroundStyle(.secondary)
            }
            if let error = batchModel.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("caption.voiceMemo.batch.error")
            }
        }
    }

    private var whisperPanel: some View {
        HStack {
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
                      || isBatchPresentationActive
                      || transcriptModel.isTranscribing || transcriptModel.isChecking || transcriptModel.isSavingReview)
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
