import SwiftUI

struct AutomationTranscriptionReviewView: View {
    @State private var model: AutomationTranscriptionReviewModel
    @State private var whisperSetup = FFmpegWhisperSetupModel.shared
    @State private var managedWhisper = ManagedWhisperSetupModel.shared
    @State private var appleLocaleIdentifier = Locale.current.identifier
    @State private var confirmsRequestCleanup = false
    @State private var cancelledRequestCleanupEpoch: UUID?

    init(service: (any AutomationTranscriptionReviewServing)? = nil) {
        _model = State(initialValue: AutomationTranscriptionReviewModel(service:
            service ?? UITestTranscriptionReviewFixture.currentServiceForModel() ?? AutomationTranscriptionReviewService()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Helper requests retain ordered transcription intent. Inspect the intent, then review the exact provider selected in Transcription Settings. Only explicit confirmation starts local transcription and saves editable transcript drafts. Reviewing starts no download and requests no permissions. Photo metadata requires separate approval.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("automation.transcriptionReviewNotice")
            HStack {
                Button("Refresh Transcription Requests") { model.refresh() }
                    .disabled(model.isRecoveringCapacity || model.isCancelling || model.isRunning)
                    .accessibilityIdentifier("automation.refreshTranscriptionRequests")
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .contain)
            Button("Review transcription request capacity") { model.inspectRequestCapacity() }
                .disabled(model.isBusyWithCapacity || model.isCancelling || model.isRunning)
                .accessibilityIdentifier("automation.inspectTranscriptionRequestCapacity")
            if model.isBusyWithCapacity { ProgressView().controlSize(.small) }
            if let capacity = model.capacity {
                Text("Retained transcription requests: \(capacity.retainedCount) of \(capacity.maximumRecords). Cancelled before admission: \(capacity.cancelledBeforeAdmissionCount).")
                    .font(.caption)
                    .accessibilityIdentifier("automation.transcriptionRequestCapacity")
                Button("Remove cancelled transcription requests", role: .destructive) {
                    cancelledRequestCleanupEpoch = capacity.epoch
                    confirmsRequestCleanup = true
                }
                .disabled(!model.canRecoverCancelledCapacity)
                .accessibilityIdentifier("automation.removeCancelledTranscriptionRequests")
                Text("Removes only transcription requests cancelled before admission. Awaiting intent, admitted, linked and uncertain evidence remains retained. Removed requests cannot be retried. New intents need a new request ID and current epoch; retained requests keep their original epoch. Cleanup grants no consent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.capacityMessage {
                Text(verbatim: message).font(.caption)
                    .accessibilityIdentifier("automation.transcriptionRequestCapacityMessage")
            }
            if let message = model.message {
                Text(verbatim: message).foregroundStyle(.red)
                    .accessibilityIdentifier("automation.transcriptionReviewError")
            }
            if model.requests.isEmpty && !model.isLoading && model.message == nil {
                Text("No retained transcription review requests").foregroundStyle(.secondary)
            }
            ForEach(model.requests, id: \.requestID) { request in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcription review request").font(.headline)
                    privateSelectableText(request.requestID, label: "Transcription request identifier")
                    Text(verbatim: AutomationTranscriptionReviewModel.status(request))
                        .accessibilityIdentifier("automation.transcriptionRequestStatus.\(request.requestID)")
                    Text("\(request.intent.photoCount) ordered photo(s)").font(.caption).foregroundStyle(.secondary)
                    if request.state == .awaitingReview {
                        HStack {
                            Button("Inspect Transcription Intent") { model.inspect(request) }
                                .accessibilityIdentifier("automation.inspectTranscriptionRequest.\(request.requestID)")
                            Button("Cancel Before Admission", role: .destructive) { model.cancel(request) }
                                .accessibilityIdentifier("automation.cancelTranscriptionRequest.\(request.requestID)")
                        }
                        .accessibilityElement(children: .contain)
                        .disabled(model.message != nil || model.isRecoveringCapacity || model.isCancelling || model.isRunning)
                    }
                    if (request.state == .admitted || request.state == .linked) && request.cancellationRequestedAt == nil {
                        Button("Request Cancellation of Retained Work", role: .destructive) { model.cancelRetainedExecution(request) }
                            .disabled(model.message != nil || model.isCancelling || model.isRunning || model.isRecoveringCapacity)
                            .accessibilityIdentifier("automation.cancelRetainedTranscriptionExecution.\(request.requestID)")
                    }
                    Divider()
                }
                .accessibilityElement(children: .contain)
            }
            if let review = model.review {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Revalidated transcription intent").font(.headline)
                    LabeledContent("Provider intent") {
                        Text(verbatim: review.providerDisplayName)
                            .accessibilityIdentifier("automation.transcriptionReviewProvider")
                    }
                    LabeledContent("Language intent") {
                        Text(verbatim: review.language).accessibilityIdentifier("automation.transcriptionReviewLanguage")
                    }
                    LabeledContent("Translate to English") {
                        Text(review.translate ? "Requested" : "Not requested")
                            .accessibilityIdentifier("automation.transcriptionReviewTranslate")
                    }
                    LabeledContent("GPU intent") {
                        Text(review.useGPU ? "Requested" : "Not requested")
                            .accessibilityIdentifier("automation.transcriptionReviewGPU")
                    }
                    Text("Requested photo order").font(.subheadline)
                    ForEach(Array(review.paths.enumerated()), id: \.offset) { index, path in
                        HStack(alignment: .top) {
                            Text("Photo \(index + 1)")
                            privateSelectableText(path, label: "Photo \(index + 1) path")
                                .accessibilityIdentifier("automation.transcriptionReviewPhoto.\(index)")
                        }
                        .accessibilityElement(children: .contain)
                    }
                    Text("Preview expires \(review.expiresAt.formatted(date: .abbreviated, time: .standard)). Inspecting intent grants no consent.")
                        .font(.caption).foregroundStyle(.secondary)
                    if whisperSetup.choice == .appleSpeech {
                        TextField("Native Apple Speech locale", text: $appleLocaleIdentifier)
                            .accessibilityIdentifier("automation.transcriptionNativeAppleLocale")
                            .disabled(model.isRunning || model.isPreparingExecution)
                        Text("Choose the exact installed Apple Speech locale. Availability is checked without downloading a language or requesting permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Current Settings provider: \(whisperSetup.choice.title)")
                        .font(.caption)
                    Button("Review Selected Provider") {
                        model.prepareExecution(provider: selectedProvider, whisperKind: selectedWhisperKind)
                    }
                    .disabled(model.isRunning || model.isPreparingExecution || whisperSetup.isPreparing
                              || managedWhisper.isDownloading || managedWhisper.isRefreshing)
                    .accessibilityIdentifier("automation.prepareTranscriptionExecution")
                }
                .accessibilityElement(children: .contain)
            }
            if model.isPreparingExecution { ProgressView("Checking exact provider and photos…") }
            if let prepared = model.executionReview {
                executionReview(prepared)
            }
            if model.isRunning {
                Text(model.isRequestingCancellation ? "Cancellation requested. Waiting for transcription to stop safely." : "Transcription is active. Editable drafts are saved as each photo finishes.")
                    .accessibilityIdentifier("automation.transcriptionExecutionStatus")
                Button("Request Transcription Cancellation", role: .destructive) { model.requestExecutionCancellation() }
                    .disabled(model.isRequestingCancellation)
                    .accessibilityIdentifier("automation.cancelTranscriptionExecution")
            }
            if let operation = model.operation {
                privateSelectableText(operation.id.uuidString.lowercased(), label: "Transcription operation identifier")
                    .accessibilityIdentifier("automation.transcriptionExecutionOperation")
            }
            if let message = model.executionMessage {
                Text(verbatim: message).font(.caption)
                    .accessibilityIdentifier("automation.transcriptionExecutionMessage")
            }
        }
        .accessibilityElement(children: .contain)
        .task {
            model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard !Task.isCancelled else { return }
                model.refreshRequestEvidence()
            }
        }
        .confirmationDialog("Remove cancelled transcription requests?", isPresented: $confirmsRequestCleanup) {
            Button("Remove cancelled transcription requests", role: .destructive) {
                if let epoch = cancelledRequestCleanupEpoch { model.recoverCancelledCapacity(expectedEpoch: epoch) }
                cancelledRequestCleanupEpoch = nil
            }
        } message: {
            Text("Only transcription requests cancelled before admission will be removed. Awaiting intent, admitted, linked and uncertain evidence stays retained. Removed requests cannot be retried; new intents need a new request ID and current epoch. Retained requests keep their original epoch. Current intent reviews will be cleared. This grants no consent, starts no transcription and changes no photo metadata.")
        }
        .onChange(of: providerSelectionIdentity) { _, _ in model.invalidateExecutionReview() }
        .onDisappear { model.clear() }
    }

    private var selectedProvider: AutomationVoiceTranscriptionBatchService.Provider? {
        if let fixture = UITestTranscriptionReviewFixture.currentProviderForReview() { return .whisper(fixture) }
        switch whisperSetup.choice {
        case .appleSpeech: return .apple(Locale(identifier: appleLocaleIdentifier))
        case .whisper:
            guard whisperSetup.isLanguageValid,
                  let provider = managedWhisper.provider(language: whisperSetup.language,
                    useGPU: whisperSetup.useGPU, translate: whisperSetup.translate) else { return nil }
            return .whisper(provider)
        case .customWhisper: return whisperSetup.provider().map { .whisper($0) }
        }
    }
    private var selectedWhisperKind: AutomationVoiceTranscriptionProviderBinding.WhisperKind? {
        if UITestTranscriptionReviewFixture.currentProviderForReview() != nil { return .curated }
        switch whisperSetup.choice {
        case .appleSpeech: return nil
        case .whisper: return .curated
        case .customWhisper: return .custom
        }
    }
    private var providerSelectionIdentity: String {
        [whisperSetup.choice.rawValue, whisperSetup.language, String(whisperSetup.translate),
         String(whisperSetup.useGPU), String(whisperSetup.isReady), String(whisperSetup.executionConsent),
         whisperSetup.executableURL?.path ?? "", whisperSetup.modelURL?.path ?? "",
         managedWhisper.selectedModelID, String(managedWhisper.isReady), appleLocaleIdentifier].joined(separator: "|")
    }
    private func executionReview(_ prepared: MCPNativeVoiceTranscriptionBindingService.PreparedBinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exact native execution review").font(.headline)
            switch prepared.providerBinding.identity {
            case .apple(let locale):
                Text("Apple Speech · installed on-device locale \(locale)")
                    .accessibilityIdentifier("automation.transcriptionExecutionProvider")
            case .whisper(let kind, let configuration):
                Text(kind == .curated ? "Whisper · curated artifacts" : "Custom Whisper · unverified artifacts")
                    .accessibilityIdentifier("automation.transcriptionExecutionProvider")
                Text(verbatim: "Runtime: \(configuration.buildIdentifier)")
                privateSelectableText(configuration.executable.url.path, label: "Transcription runtime path")
                privateSelectableText(configuration.executable.sha256, label: "Transcription runtime SHA-256")
                Text(verbatim: "Model: \(configuration.modelIdentifier)")
                    .accessibilityIdentifier("automation.transcriptionExecutionModel")
                privateSelectableText(configuration.model.url.path, label: "Transcription model path")
                privateSelectableText(configuration.model.sha256, label: "Transcription model SHA-256")
                Text("Language: \(configuration.language). Translation: \(configuration.translate ? "English" : "Original language"). GPU: \(configuration.useGPU ? "Requested" : "Off"). Timeout: \(configuration.timeoutSeconds.formatted()) seconds.")
                    .accessibilityIdentifier("automation.transcriptionExecutionOptions")
            }
            Text("This exact provider and the ordered photos above will be checked again before admission. Existing transcript reviews are kept. Each generated transcript is saved as an editable app draft; caption approval remains separate.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I consent to local transcription of these ordered photos using the exact provider, model and options shown.", isOn: $model.executionConsent)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("automation.transcriptionExecutionConsent")
            Button("Start Confirmed Transcription") { model.confirmExecution() }
                .disabled(!model.executionConsent || model.isRefreshingEvidence || model.isRunning)
                .accessibilityIdentifier("automation.confirmTranscriptionExecution")
        }
        .accessibilityElement(children: .contain)
    }

    /// Selectable Text has a native AppKit accessibility backing. Override the
    /// enclosing virtual element instead, so label resolution cannot recurse through
    /// that backing while a Form collects descendant labels. The visible text remains
    /// selectable; a fixed label names the field while its value exposes the same
    /// literal evidence to a user who deliberately focuses it, without an announcement.
    private func privateSelectableText(_ text: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: text))
    }
}
