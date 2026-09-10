import SwiftUI

/// Review is deliberately independent of the FIFO flush barrier it helps the user resolve.
struct CaptionConflictRecoveryView: View {
    let photoURL: URL
    let reason: String
    let requestCount: Int
    let exportURL: URL?
    let isBusy: Bool
    let errorMessage: String?
    let onExport: () -> Void
    let onDiscard: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Queued Caption Conflict")
                .font(.title2.bold())
            Text(photoURL.lastPathComponent)
                .font(.headline)
            Text(photoURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(reason)
                .textSelection(.enabled)
            Text("\(requestCount) queued \(requestCount == 1 ? "edit" : "edits") for this photo will be included in the recovery file.")
            Text("Export the queued metadata and history before discarding these edits. The saved photo, metadata files, and queued edits for other photos will be kept.")
            if let exportURL {
                Label("Recovery export verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(exportURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
            } else {
                Text("Discard becomes available after the recovery JSON has been saved and verified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("caption.conflictReview.error")
            }
            if isBusy { ProgressView().controlSize(.small) }
            Divider()
            Text("After discard, this photo's saved metadata will be reloaded if it is still open and its editor has not changed during review.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export Recovery JSON…", action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("caption.conflictReview.export")
                Button("Discard Exported Queued Edits", role: .destructive, action: onDiscard)
                    .disabled(exportURL == nil)
                    .accessibilityIdentifier("caption.conflictReview.discard")
            }
            .disabled(isBusy)
        }
        .padding(24)
        .frame(width: 650)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isBusy)
        .accessibilityIdentifier("caption.conflictReview")
    }
}
