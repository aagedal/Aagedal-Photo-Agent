import SwiftUI

struct FTPUploadProgressView: View {
    @Bindable var viewModel: FTPViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.isRendering {
                Text("Rendering \(viewModel.renderCompletedCount)/\(viewModel.renderTotalCount)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Uploading \(viewModel.completedCount)/\(viewModel.totalCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: viewModel.overallProgress)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.uploadProgress.values), id: \.fileName) { progress in
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

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Button("Cancel") {
                viewModel.cancelUpload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
