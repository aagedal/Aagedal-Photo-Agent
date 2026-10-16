import SwiftUI

struct AutomationFaceReviewMaintenanceView: View {
    @State private var model: AutomationFaceReviewMaintenanceModel?
    @State private var initializationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cancelled face review requests can be removed to free archive capacity. Active and expired requests remain retained. Removing cancelled requests changes the submission epoch, so clients must refresh capacity before submitting new requests.")
                .font(.caption).foregroundStyle(.secondary)
            if let model {
                Button("Inspect Face Review Capacity") { Task { await model.inspect() } }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("automation.faceMaintenance.inspect")
                if model.isLoading { ProgressView().controlSize(.small) }
                if let review = model.review {
                    Text("Retained requests: \(review.retainedCount) of \(review.maximumRecords). Cancelled requests: \(review.cancelledRecords.count).")
                        .accessibilityIdentifier("automation.faceMaintenance.capacity")
                    ScrollView {
                        LazyVStack(alignment: .leading) {
                            ForEach(review.cancelledRecords, id: \.requestID) { record in
                                VStack(alignment: .leading) {
                                    Text(verbatim: record.intent.canonicalPath)
                                    Text(verbatim: record.requestID)
                                }.font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                    Button("Remove Reviewed Cancelled Requests…") { model.requestCleanup() }
                        .disabled(model.isLoading || review.cancelledRecords.isEmpty)
                        .accessibilityIdentifier("automation.faceMaintenance.requestCleanup")
                }
                if let message = model.message {
                    Text(verbatim: message).font(.caption)
                        .accessibilityIdentifier("automation.faceMaintenance.status")
                }
                Color.clear.frame(height: 0)
                    .alert(item: Binding(get: { model.cleanupConfirmation }, set: { _ in })) { confirmation in
                        Alert(title: Text("Remove cancelled face review requests?"),
                              message: Text("Remove the \(confirmation.review.cancelledRecords.count) reviewed cancelled requests and rotate the submission epoch? Their historical status will no longer be available. Active requests, photos and saved face data remain unchanged."),
                              primaryButton: .destructive(Text("Remove Cancelled Requests")) {
                                  Task { await model.confirmCleanup(confirmation.id) }
                              }, secondaryButton: .cancel { model.cancelCleanup() })
                    }
            } else if initializationFailed {
                Text("Face review maintenance is unavailable. Close and reopen Settings to retry.")
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let requests = try UITestNativeInvocationConfiguration.current?.faceRequests
                    ?? MCPFaceScanReviewRequestStore(storageDirectory: MCPFaceScanReviewRequestStore.defaultStorageDirectory())
                model = AutomationFaceReviewMaintenanceModel(service: AutomationFaceReviewMaintenanceService(requests: requests))
            } catch { initializationFailed = true }
        }
        .onDisappear { model?.clear() }
    }
}
