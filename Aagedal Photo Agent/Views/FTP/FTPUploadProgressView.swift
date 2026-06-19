import SwiftUI

struct FTPUploadProgressView: View {
    @Bindable var viewModel: FTPViewModel
    @State private var isHoveringDismiss = false

    private var sortedProgress: [FTPUploadProgress] {
        viewModel.uploadProgress.values.sorted { a, b in
            if a.isComplete != b.isComplete { return !a.isComplete }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.uploadCompleted {
                completedHeader
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

            if !sortedProgress.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedProgress, id: \.fileName) { progress in
                            HStack {
                                Text(progress.fileName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                if progress.isComplete {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption2)
                                } else {
                                    Text("\(Int(progress.fractionCompleted * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                // Size to content (cap at ~6 rows / 120pt). A fixed maxHeight makes the
                // greedy ScrollView reserve the full height even for a few files, leaving
                // a large empty gap above the error text.
                .frame(height: min(CGFloat(sortedProgress.count) * 18 + 4, 120))
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
            Text("Upload complete")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.errorMessages.isEmpty {
                Text("(\(viewModel.errorMessages.count) error\(viewModel.errorMessages.count == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 4)
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
