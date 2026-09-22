import SwiftUI

struct AutomationRecoveryView: View {
    @State private var model: AutomationRecoveryModel?
    @State private var initializationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspect interrupted XMP publication before retrying. Unchanged staging can be resolved after checking the original photo and both metadata files again. Identified partial writes can be restored after explicit confirmation; external or uncertain changes remain blocked.")
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
                    Text("Deselect the photo in all metadata editors before resolving or restoring. Recovery evidence remains retained.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Resolve Unchanged Staging") { Task { await model.resolveUnchanged() } }
                        .disabled(model.isLoading || !review.canResolveUnchanged)
                        .accessibilityIdentifier("automation.resolveUnchangedRecovery")
                    Button("Restore Original Metadata…") { model.requestRestoration() }
                        .disabled(model.isLoading || !review.canRestorePartialPublication)
                        .accessibilityIdentifier("automation.restoreOriginalMetadata")
                }
                if let message = model.message {
                    Text(verbatim: message).accessibilityIdentifier("automation.recoveryStatus")
                }
                Color.clear.frame(height: 0)
                    .alert(item: Binding(get: { model.restorationConfirmation }, set: { _ in })) { confirmation in
                        Alert(title: Text("Restore original metadata?"),
                            message: Text("Restore the retained original XMP and app metadata for \(confirmation.photoPath)? Metadata files created by the interrupted publication will be removed. The photo itself is unchanged. Recovery evidence remains retained."),
                            primaryButton: .destructive(Text("Restore Original Metadata")) {
                                Task { await model.confirmRestoration(confirmation.id) }
                            }, secondaryButton: .cancel { model.cancelRestoration() })
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
