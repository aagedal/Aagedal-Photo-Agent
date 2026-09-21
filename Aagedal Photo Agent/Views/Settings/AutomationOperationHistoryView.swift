import SwiftUI

struct AutomationOperationHistoryView: View {
    @State private var model: AutomationOperationHistoryModel?
    @State private var initializationFailed = false
    @State private var removal: AutomationOperationRegistry.Record?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retained operations contain IDs, activity types, times and outcomes, without photo paths or metadata. Refresh to check their latest recorded state. A cancellation request does not confirm that work stopped.")
                .font(.caption).foregroundStyle(.secondary)
            if let model {
                HStack {
                    Button("Refresh") { Task { await model.refresh() } }
                        .accessibilityIdentifier("automation.refreshOperations")
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                .disabled(model.isLoading)
                if let message = model.message {
                    Text(verbatim: message).foregroundStyle(.red)
                        .accessibilityIdentifier("automation.operationHistoryError")
                }
                if model.records.isEmpty && !model.isLoading && model.message == nil {
                    Text("No retained operations").foregroundStyle(.secondary)
                }
                ForEach(model.records, id: \.id) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: title(record.kind)).font(.headline)
                        Text(verbatim: record.id.uuidString.lowercased())
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text(verbatim: status(record))
                            .accessibilityIdentifier("automation.operationStatus.\(record.id.uuidString.lowercased())")
                        Text("Last recorded \(record.updatedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        if record.outcome == .recoveryRequired || record.outcome == .partialUncertain {
                            Text("Inspect the affected photo and pending metadata before retrying. This record cannot establish whether a draft was saved. Automatic repair is unavailable; recovery evidence is retained.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !record.isTerminal && record.cancellationRequestedAt == nil {
                            Button("Request Cancellation") { Task { await model.requestCancellation(record.id) } }
                                .accessibilityLabel("Request cancellation of operation \(record.id.uuidString.lowercased())")
                                .disabled(model.isLoading || model.message != nil)
                        }
                        if AutomationOperationHistoryService.canRemove(record) {
                            Button("Remove Record…", role: .destructive) { removal = record }
                                .accessibilityLabel("Remove completed operation record \(record.id.uuidString.lowercased())")
                                .disabled(model.isLoading || model.message != nil)
                        }
                        Divider()
                    }
                }
            } else if initializationFailed {
                Text("Operation history is unavailable. Close and reopen Automation settings to retry.")
                    .foregroundStyle(.red)
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let registry = try UITestPatchReviewFixture.operationRegistryForHistory()
                    ?? AutomationOperationRegistry(storageDirectory: AutomationOperationRegistry.defaultStorageDirectory())
                let value = AutomationOperationHistoryModel(service: AutomationOperationHistoryService(registry: registry))
                model = value
                await value.refresh()
            } catch { initializationFailed = true }
        }
        .confirmationDialog("Remove completed operation record?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove Record", role: .destructive) {
                if let record = removal, let model {
                    Task { await model.removeFinished(record.id) }
                }
                removal = nil
            }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            Text("This removes only the retained status record. It does not undo metadata changes or remove a pending draft.")
        }
    }

    private func title(_ kind: AutomationOperationRegistry.Kind) -> String {
        switch kind {
        case .iptcDraft: "Pending metadata draft"
        case .iptcPatch: "Published metadata patch"
        case .faceScan: "Face scan"
        case .metadataTemplate: "Metadata template"
        case .developTemplate: "Develop template"
        case .voiceTranscription: "Voice transcription"
        }
    }

    private func status(_ record: AutomationOperationRegistry.Record) -> String {
        switch record.outcome {
        case .verified: record.kind == .iptcDraft ? "Pending draft saved and verified; not published to the photo or XMP." : "Completed and verified."
        case .failed: "Failed or refused."
        case .cancelled: "Cancellation confirmed with no uncertain effects."
        case .stale: "Stale operation; prepare a fresh plan."
        case .partialUncertain, .recoveryRequired: "Recovery required; effects are uncertain."
        case nil: record.cancellationRequestedAt == nil
            ? "Last recorded as \(record.state.rawValue). Current activity is not confirmed."
            : "Cancellation requested; waiting for a confirmed outcome."
        }
    }
}
