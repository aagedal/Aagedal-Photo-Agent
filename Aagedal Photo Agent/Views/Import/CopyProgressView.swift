import SwiftUI

/// Progress UI shared by the import sheet and the "Back Up Edited Files" sheet.
/// Shows split progress bars when a backup leg is active.
struct CopyProgressView: View {
    let title: String
    let primaryCopied: Int
    let totalFiles: Int
    let backupCopied: Int?
    let backupTotal: Int?
    let backupFailed: Int
    let verifiedCount: Int
    let mismatchedCount: Int
    let currentFile: String
    let isApplyingMetadata: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text(isApplyingMetadata ? "Applying metadata…" : title)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                primaryRow
                if let backupCopied, let backupTotal {
                    backupRow(copied: backupCopied, total: backupTotal)
                }
                if verifiedCount > 0 || mismatchedCount > 0 {
                    verificationRow
                }
                if !currentFile.isEmpty && !isApplyingMetadata {
                    Text(currentFile)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: 360)

            Spacer()

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private var primaryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Primary")
                    .font(.caption.bold())
                Spacer()
                Text("\(primaryCopied) of \(totalFiles)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: progress(primaryCopied, totalFiles))
        }
    }

    @ViewBuilder
    private func backupRow(copied: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Backup")
                    .font(.caption.bold())
                Spacer()
                if backupFailed > 0 {
                    Text("\(copied) of \(total) — \(backupFailed) failed")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                } else {
                    Text("\(copied) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: progress(copied, total))
                .tint(backupFailed > 0 ? .orange : .accentColor)
        }
    }

    @ViewBuilder
    private var verificationRow: some View {
        HStack(spacing: 6) {
            if mismatchedCount > 0 {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.red)
                Text("\(verifiedCount) verified, \(mismatchedCount) mismatch")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("\(verifiedCount) verified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func progress(_ value: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }
}
