import SwiftUI

struct AutomationRecoveryView: View {
    @State private var model: AutomationRecoveryModel?
    @State private var initializationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspect interrupted XMP publication before retrying. Unchanged staging can be resolved after checking the original photo and both metadata files again. Partial writes and external changes remain blocked for restoration.")
                .font(.caption).foregroundStyle(.secondary)
            if let model {
                @Bindable var model = model
                TextField("Original photo path (older records only)", text: $model.legacyPhotoPath)
                    .accessibilityIdentifier("automation.recoveryPhotoPath")
                    .disabled(model.isLoading)
                Button("Inspect Retained Recovery") { Task { await model.inspect() } }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("automation.inspectRecovery")
                if model.isLoading { ProgressView().controlSize(.small) }
                if let review = model.review {
                    Text(verbatim: review.photoPath).font(.caption).textSelection(.enabled)
                    Text(verbatim: review.message)
                        .accessibilityIdentifier("automation.recoveryReview")
                    Text("Deselect the photo in all metadata editors before resolving. This retains a disposition receipt and does not undo a publication.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resolve Unchanged Staging") { Task { await model.resolveUnchanged() } }
                        .disabled(model.isLoading || !review.canResolveUnchanged)
                        .accessibilityIdentifier("automation.resolveUnchangedRecovery")
                }
                if let message = model.message {
                    Text(verbatim: message).accessibilityIdentifier("automation.recoveryStatus")
                }
            } else if initializationFailed {
                Text("Recovery inspection is unavailable. Close and reopen Settings to retry.")
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let service = try UITestPatchReviewFixture.currentRecoveryServiceForModel() ?? AutomationPatchReviewService()
                model = AutomationRecoveryModel(service: service)
            } catch { initializationFailed = true }
        }
        .onDisappear { model?.clear() }
    }
}
