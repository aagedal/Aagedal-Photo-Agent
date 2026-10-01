import SwiftUI

struct AutomationTranscriptionReviewView: View {
    @State private var model: AutomationTranscriptionReviewModel

    init(service: (any AutomationTranscriptionReviewServing)? = nil) {
        _model = State(initialValue: AutomationTranscriptionReviewModel(service:
            service ?? UITestTranscriptionReviewFixture.currentServiceForModel() ?? AutomationTranscriptionReviewService()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Helper requests retain ordered transcription intent for native review. Reviewing grants no consent. Provider readiness, runtime and model identity, exact execution binding and provider admission remain unavailable here. No transcription, download or transcript draft is created.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("automation.transcriptionReviewNotice")
            HStack {
                Button("Refresh Transcription Requests") { model.refresh() }
                    .accessibilityIdentifier("automation.refreshTranscriptionRequests")
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .accessibilityElement(children: .contain)
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
                        .disabled(model.message != nil)
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
                    Text("Preview expires \(review.expiresAt.formatted(date: .abbreviated, time: .standard)). This review is an intent snapshot and supplies no provider execution authority.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .accessibilityElement(children: .contain)
        .task { model.refresh() }
        .onDisappear { model.clear() }
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
