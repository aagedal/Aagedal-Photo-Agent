import SwiftUI
import AppKit

/// Completion / mismatch summary shown after import or "Back Up Edited Files" finishes.
/// Renders a hero green count when everything verified, or a red banner with a
/// scrollable list of mismatched/failed files.
struct VerificationSummaryView: View {
    let title: String
    let succeededLabel: String
    let copiedFiles: Int
    let totalFiles: Int
    let renamedFiles: Int
    let skippedFiles: Int
    let failedFiles: Int
    let verifiedFiles: Int
    let mismatchedFiles: Int
    let backupCopiedFiles: Int
    let backupFailedFiles: Int
    let backupEnabled: Bool
    let failureRecords: [ImportFailureRecord]
    let summaryLine: String
    let cancelled: Bool

    var body: some View {
        VStack(spacing: 14) {
            heroIcon
            Text(cancelled ? "Import Cancelled" : title)
                .font(.title2.bold())

            heroLine

            if backupEnabled {
                backupLine
            }

            if !summaryLine.isEmpty {
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !failureRecords.isEmpty {
                failureList
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var heroIcon: some View {
        if cancelled {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
        } else if mismatchedFiles > 0 || failedFiles > 0 {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var heroLine: some View {
        if mismatchedFiles == 0 && failedFiles == 0 {
            if verifiedFiles > 0 {
                Text("\(verifiedFiles) of \(totalFiles) \(succeededLabel) — all verified")
                    .font(.body)
                    .foregroundStyle(.primary)
            } else {
                Text("\(copiedFiles) of \(totalFiles) \(succeededLabel)")
                    .font(.body)
                    .foregroundStyle(.primary)
            }
        } else {
            Text("\(copiedFiles) of \(totalFiles) \(succeededLabel) — \(mismatchedFiles + failedFiles) needing attention")
                .font(.body)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var backupLine: some View {
        let total = backupCopiedFiles + backupFailedFiles
        if backupFailedFiles > 0 {
            Label("Backup: \(backupCopiedFiles) of \(total) — \(backupFailedFiles) failed", systemImage: "externaldrive.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.orange)
        } else if total > 0 {
            Label("Backup: \(backupCopiedFiles) of \(total)", systemImage: "externaldrive.badge.checkmark")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var failureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files needing attention")
                    .font(.caption.bold())
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(failureRecords) { record in
                        failureRow(record)
                    }
                }
            }
            .frame(maxHeight: 140)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func failureRow(_ record: ImportFailureRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: record.kind))
                .foregroundStyle(color(for: record.kind))
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.source.lastPathComponent)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(record.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([record.source])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Reveal source in Finder")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func iconName(for kind: ImportFailureRecord.Kind) -> String {
        switch kind {
        case .copyFailed: return "xmark.circle.fill"
        case .verificationMismatch: return "exclamationmark.shield.fill"
        case .backupFailed: return "externaldrive.badge.exclamationmark"
        }
    }

    private func color(for kind: ImportFailureRecord.Kind) -> Color {
        switch kind {
        case .copyFailed, .verificationMismatch: return .red
        case .backupFailed: return .orange
        }
    }
}
