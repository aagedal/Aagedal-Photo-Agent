import SwiftUI

struct FTPUploadProgressView: View {
    @Bindable var viewModel: FTPViewModel

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
                .frame(maxHeight: 120)
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
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Upload complete")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.errorMessages.isEmpty {
                Text("(\(viewModel.errorMessages.count) error\(viewModel.errorMessages.count == 1 ? "" : "s"))")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
