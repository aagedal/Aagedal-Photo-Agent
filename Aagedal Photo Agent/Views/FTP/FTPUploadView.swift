import SwiftUI

struct FTPUploadView: View {
    @Bindable var viewModel: FTPViewModel
    let filesToUpload: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upload Files")
                .font(.headline)

            Text("\(filesToUpload.count) file(s) selected for upload")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Server selection
            if viewModel.connections.isEmpty {
                HStack {
                    Text("No FTP servers configured")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Server") {
                        viewModel.startEditingConnection()
                    }
                }
            } else {
                Picker("Server", selection: $viewModel.selectedConnection) {
                    Text("Select...").tag(nil as FTPConnection?)
                    ForEach(viewModel.connections) { conn in
                        Text(conn.name).tag(conn as FTPConnection?)
                    }
                }
            }

            // Upload progress
            if viewModel.isUploading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: viewModel.overallProgress) {
                        Text("Uploading \(viewModel.completedCount)/\(viewModel.totalCount)")
                    }

                    ForEach(Array(viewModel.uploadProgress.values), id: \.fileName) { progress in
                        HStack {
                            Text(progress.fileName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            if progress.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            } else {
                                Text("\(Int(progress.fractionCompleted * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Upload") {
                    guard let connection = viewModel.selectedConnection else { return }
                    viewModel.uploadFiles(filesToUpload, to: connection)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedConnection == nil || viewModel.isUploading || filesToUpload.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 400)
        .onAppear {
            viewModel.loadConnections()
        }
    }
}
