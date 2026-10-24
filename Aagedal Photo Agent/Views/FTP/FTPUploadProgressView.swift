import SwiftUI

struct FTPUploadProgressView: View {
    @Bindable var viewModel: FTPViewModel
    @State private var isHoveringDismiss = false

    private struct Row: Identifiable {
        enum Status { case inProgress(Double), complete, failed(String) }
        let fileName: String
        let status: Status
        var id: String { fileName }

        var sortRank: Int {
            switch status {
            case .failed: 0
            case .inProgress: 1
            case .complete: 2
            }
        }
    }

    /// Every file of the run: transferring, delivered, or failed with its reason — failures
    /// first so they can't hide below a long list of completed files.
    private var rows: [Row] {
        var rows: [Row] = []
        for (name, progress) in viewModel.uploadProgress where viewModel.uploadFailures[name] == nil {
            rows.append(Row(fileName: name, status: progress.isComplete
                ? .complete : .inProgress(progress.fractionCompleted)))
        }
        for (name, reason) in viewModel.uploadFailures {
            rows.append(Row(fileName: name, status: .failed(reason)))
        }
        return rows.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.uploadCompleted {
                completedHeader
            } else if viewModel.isRendering && viewModel.isUploading {
                Text("Rendering \(viewModel.renderCompletedCount)/\(viewModel.renderTotalCount) · Uploading \(viewModel.completedCount)/\(viewModel.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.isRendering {
                Text("Rendering \(viewModel.renderCompletedCount)/\(viewModel.renderTotalCount)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uploading \(viewModel.completedCount)/\(viewModel.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: viewModel.overallProgress)

            if !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            HStack {
                                Text(row.fileName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                switch row.status {
                                case .complete:
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                case .inProgress(let fraction):
                                    Text("\(Int(fraction * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .failed(let reason):
                                    Label(reason, systemImage: "xmark.circle.fill")
                                        .labelStyle(.titleAndIcon)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(reason)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                // Size to content (cap at ~6 rows / 120pt). A fixed maxHeight makes the
                // greedy ScrollView reserve the full height even for a few files, leaving
                // a large empty gap above the error text.
                .frame(height: min(CGFloat(rows.count) * 18 + 4, 120))
            }

            if !viewModel.errorMessages.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.errorMessages, id: \.self) { error in
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }

            if !viewModel.uploadCompleted {
                Button("Cancel") {
                    viewModel.cancelUpload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var completedHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.errorMessages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.errorMessages.isEmpty ? Color.green : Color.orange)
            Text(viewModel.uploadStopped ? "Upload stopped" : "Upload complete")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.errorMessages.isEmpty {
                Text("(\(viewModel.errorMessages.count) error\(viewModel.errorMessages.count == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            if viewModel.canRetryFailed {
                Button("Retry Failed") {
                    viewModel.retryFailedUploads()
                }
                .controlSize(.small)
                .help("Send only the \(viewModel.failedSourceURLs.count) file\(viewModel.failedSourceURLs.count == 1 ? "" : "s") that didn't arrive, with the same settings")
            }
            Button {
                viewModel.dismissUploadCompletion()
            } label: {
                // Swap to an "x" on hover so it reads as a close affordance.
                Image(systemName: isHoveringDismiss ? "xmark" : "checkmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isHoveringDismiss ? Color.secondary : Color.green)
            .onHover { isHoveringDismiss = $0 }
            .help("Close")
        }
    }
}
