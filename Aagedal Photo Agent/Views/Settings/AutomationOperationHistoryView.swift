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
                        Text(verbatim: Self.status(record))
                            .accessibilityIdentifier("automation.operationStatus.\(record.id.uuidString.lowercased())")
                        if let progress = record.batchProgress {
                            Text(verbatim: Self.batchProgressText(progress))
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("automation.operationBatchProgress.\(record.id.uuidString.lowercased())")
                        }
                        Text("Last recorded \(record.updatedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let resolution = record.recoveryResolution {
                            Text(resolution.disposition == .restored
                                ? "Original metadata restored; original publication was not verified."
                                : "Unchanged staging resolved; original publication was not verified.")
                                .accessibilityIdentifier("automation.operationRecoveryResolution.\(record.id.uuidString.lowercased())")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if record.outcome == .recoveryRequired || record.outcome == .partialUncertain {
                            Text(verbatim: Self.recoveryGuidance(record))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !record.isTerminal && record.cancellationRequestedAt == nil {
                            Button("Request Cancellation") { Task { await model.requestCancellation(record.id) } }
                                .accessibilityLabel("Request cancellation of operation \(record.id.uuidString.lowercased())")
                                .disabled(model.isLoading || model.message != nil)
                        }
                        if AutomationOperationHistoryService.canRemove(record) {
                            Button("Remove Record…", role: .destructive) { removal = record }
                                .accessibilityIdentifier("automation.removeOperation.\(record.id.uuidString.lowercased())")
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

    nonisolated static func status(_ record: AutomationOperationRegistry.Record) -> String {
        switch record.outcome {
        case .verified:
            if record.kind == .voiceTranscription {
                return "Editable transcript drafts saved and verified. Drafts remain unapproved; IPTC metadata is unchanged."
            }
            return record.kind == .iptcDraft ? "Pending draft saved and verified; not published to the photo or XMP." : "Completed and verified."
        case .failed: return "Failed or refused." + retainedTranscriptDrafts(record)
        case .cancelled: return "Cancellation confirmed with no uncertain effects." + retainedTranscriptDrafts(record)
        case .stale: return "Stale operation; prepare a fresh plan." + retainedTranscriptDrafts(record)
        case .partialUncertain, .recoveryRequired: return (record.recoveryResolution == nil
            ? "Recovery required; effects are uncertain."
            : "Recovery required at original publication; publication was not verified.") + retainedTranscriptDrafts(record)
        case nil: return (record.cancellationRequestedAt == nil
            ? "Last recorded as \(record.state.rawValue). Current activity is not confirmed."
            : "Cancellation requested; waiting for a confirmed outcome.") + retainedTranscriptDrafts(record)
        }
    }

    nonisolated private static func retainedTranscriptDrafts(_ record: AutomationOperationRegistry.Record) -> String {
        guard record.kind == .voiceTranscription, let progress = record.batchProgress else { return "" }
        let saved = progress.items.filter { $0.outcome == .draftSaved }.count
        let drafts = saved == 1 ? "1 editable transcript draft remains saved" : "\(saved) editable transcript drafts remain saved"
        return " \(drafts). Drafts remain unapproved; IPTC metadata is unchanged."
    }

    nonisolated static func recoveryGuidance(_ record: AutomationOperationRegistry.Record) -> String {
        if record.kind == .voiceTranscription, record.batchProgress != nil {
            return "Saved transcript drafts are retained. Inspect photos marked recovery required or last recorded as running before retrying; unfinished items are not confirmed as saved. Automatic repair is unavailable."
        }
        return "Inspect the affected photo and pending metadata before retrying. This record cannot establish whether a draft was saved. Automatic repair is unavailable; recovery evidence is retained."
    }

    nonisolated static func batchProgressText(_ progress: AutomationOperationRegistry.BatchProgress) -> String {
        let items = progress.items.map { item in
            let status: String
            switch item.outcome {
            case .draftSaved: status = "draft saved"
            case .failed: status = "failed"
            case .stale: status = "stale"
            case .cancelled: status = "cancelled"
            case .recoveryRequired: status = "recovery required"
            case nil: status = item.state == .running ? "last recorded running" : item.state.rawValue
            }
            return "Photo \(item.index + 1): \(status)"
        }.joined(separator: "; ")
        return "\(progress.completedCount) of \(progress.itemCount) photos finished. \(items)."
    }
}
