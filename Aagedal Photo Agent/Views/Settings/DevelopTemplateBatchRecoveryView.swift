import AppKit
import SwiftUI

struct DevelopTemplateBatchRecoveryView: View {
    @State private var directory: URL?
    @State private var reviews: [DevelopTemplateBatchRecoveryReview] = []
    @State private var message: String?
    @State private var inspection: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose the retained checkpoint folder to review interrupted Develop batches. Review preserves evidence. Applying edits again requires a new operation after checking the saved photos and metadata.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Develop Recovery Folder…", action: choose)
                    .accessibilityIdentifier("develop.batchRecovery.chooseFolder")
                if let directory {
                    Button("Refresh") { inspect(directory) }
                        .accessibilityIdentifier("develop.batchRecovery.refresh")
                }
            }.disabled(isLoading)
            if let directory { Text(verbatim: directory.path).font(.caption).textSelection(.enabled) }
            if isLoading { ProgressView().controlSize(.small) }
            if let message { Text(verbatim: message).accessibilityIdentifier("develop.batchRecovery.status") }
            ForEach(reviews) { review in
                DisclosureGroup {
                    if let issue = review.issue {
                        Text(verbatim: issueMessage(issue)).foregroundStyle(.orange)
                    } else {
                        if let templateID = review.templateID, let revision = review.templateRevision {
                            Text("Template \(templateID.uuidString), revision \(revision)").font(.caption)
                        }
                        if let sequence = review.sequence { Text("Checkpoint \(sequence)").font(.caption) }
                        if let unexpected = review.unexpectedReceiptID {
                            Text("Unexpected writer receipt: \(unexpected). Physical effects may have occurred; inspect the saved files before applying edits again.")
                                .foregroundStyle(.orange)
                            ForEach(review.unexpectedPhysicalEvidence, id: \.self) {
                                Text(verbatim: $0).font(.caption).foregroundStyle(.orange)
                            }
                            if let failure = review.unexpectedFailure { Text(verbatim: failure).font(.caption) }
                        }
                        if let failure = review.failure { Text(verbatim: failure).textSelection(.enabled) }
                        if let failure = review.retentionFailure {
                            Text("Checkpoint retention failed: \(failure)").foregroundStyle(.orange).textSelection(.enabled)
                        }
                        ForEach(review.photos) { photo in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: photo.imageURL.path).font(.caption).textSelection(.enabled)
                                Text(photoStatus(photo))
                                ForEach(photo.physicalEvidence, id: \.self) { Text(verbatim: $0).font(.caption) }
                                if let failure = photo.failure { Text(verbatim: failure).font(.caption) }
                            }.padding(.vertical, 4)
                        }
                    }
                } label: {
                    Text(verbatim: reviewLabel(review))
                        .font(.caption).textSelection(.enabled)
                }
                .accessibilityLabel(Text(verbatim: reviewLabel(review)))
                .accessibilityIdentifier("develop.batchRecovery.entry.\(review.id)")
            }
        }
        .onDisappear {
            generation = UUID(); inspection?.cancel(); inspection = nil; isLoading = false
            reviews = []; message = nil
        }
    }

    private func reviewLabel(_ review: DevelopTemplateBatchRecoveryReview) -> String {
        "\(review.id) — \(review.issue == nil ? review.outcome?.rawValue ?? "unknown" : "Inspection blocked")\(review.needsReview ? " · Review required" : "")"
    }

    private func choose() {
        let expected = generation
        let panel = NSOpenPanel()
        panel.title = "Choose Retained Develop Checkpoints"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard generation == expected, response == .OK, let selected = panel.url else { return }
            directory = selected; inspect(selected)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func inspect(_ selected: URL) {
        guard !isLoading else { return }
        let request = UUID(); generation = request; isLoading = true; reviews = []; message = nil
        inspection = Task { @MainActor in
            let scoped = selected.startAccessingSecurityScopedResource()
            defer {
                if scoped { selected.stopAccessingSecurityScopedResource() }
                if generation == request { isLoading = false; inspection = nil }
            }
            do {
                let service = DevelopTemplateBatchRecoveryService(store: .init(directory: selected))
                let result = try await service.inspect()
                guard generation == request, !Task.isCancelled else { return }
                reviews = result
                message = result.isEmpty ? "No retained Develop checkpoints found in this folder." : "Evidence inspected. Saved files have not been checked for changes since these checkpoints."
            } catch AutomationOperationRegistry.Failure.capacity {
                guard generation == request, !Task.isCancelled else { return }
                message = "This folder contains too many or too large retained checkpoints to inspect together. Retained evidence is unchanged."
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                message = "Cannot inspect this checkpoint folder. It must be the original private folder, with no symbolic links. Check access and try again. Retained evidence is unchanged."
            }
        }
    }

    private func issueMessage(_ issue: DevelopTemplateBatchCheckpointInventoryEntry.Issue) -> String {
        switch issue {
        case .corrupt: "Unreadable or corrupt checkpoint evidence. Keep this entry for investigation."
        case .newerVersion: "This checkpoint requires another app version. Keep this entry for investigation."
        case .unavailable: "Checkpoint inspection blocked by access, a symbolic link, or an active writer. Keep this entry and try again when writing stops."
        }
    }

    private func photoStatus(_ photo: DevelopTemplateBatchRecoveryReview.Photo) -> String {
        if photo.active { return "Write was in progress; physical effects are uncertain." }
        if photo.completed == true { return "Completed at checkpoint time." }
        if photo.completed == false { return "Writer returned without verified completion." }
        return "No writer receipt retained."
    }
}
