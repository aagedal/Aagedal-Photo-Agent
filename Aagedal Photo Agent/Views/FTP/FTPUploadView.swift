import SwiftUI

struct FTPUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: FTPViewModel
    let selectedFiles: [URL]
    let allFiles: [URL]
    let exifToolService: ExifToolService

    @State private var processVariablesBeforeUpload = false
    @State private var isProcessingVariables = false
    @State private var variablesProcessProgress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Upload Files")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            Text("\(selectedFiles.count) file(s) selected · \(allFiles.count) total in folder")
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

            // Process metadata variables option
            Toggle("Process metadata variables before upload", isOn: $processVariablesBeforeUpload)
                .font(.subheadline)

            if isProcessingVariables {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing variables… \(variablesProcessProgress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button("Upload Selected") {
                    startUpload(files: selectedFiles)
                }
                .buttonStyle(.bordered)
                .disabled(uploadDisabled || selectedFiles.isEmpty)

                Button("Upload All") {
                    startUpload(files: allFiles)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadDisabled || allFiles.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 400)
        .onAppear {
            viewModel.loadConnections()
        }
    }

    private var uploadDisabled: Bool {
        viewModel.selectedConnection == nil || viewModel.isUploading || isProcessingVariables
    }

    private func startUpload(files: [URL]) {
        guard let connection = viewModel.selectedConnection else { return }

        if processVariablesBeforeUpload {
            isProcessingVariables = true
            variablesProcessProgress = "0/\(files.count)"

            Task {
                await processVariables(for: files)
                isProcessingVariables = false
                variablesProcessProgress = ""
                viewModel.uploadFiles(files, to: connection)
            }
        } else {
            viewModel.uploadFiles(files, to: connection)
        }
    }

    private func processVariables(for files: [URL]) async {
        let interpolator = PresetVariableInterpolator()
        var processed = 0

        for url in files {
            do {
                let meta = try await exifToolService.readFullMetadata(url: url)
                let snapshot = meta
                let filename = url.lastPathComponent

                var changed = false
                var resolved = meta

                resolved.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)

                if changed {
                    var fields: [String: String] = [:]
                    if resolved.title != meta.title { fields["XMP:Title"] = resolved.title ?? "" }
                    if resolved.description != meta.description { fields["XMP:Description"] = resolved.description ?? "" }
                    if resolved.creator != meta.creator { fields["XMP:Creator"] = resolved.creator ?? "" }
                    if resolved.credit != meta.credit { fields["XMP-photoshop:Credit"] = resolved.credit ?? "" }
                    if resolved.copyright != meta.copyright { fields["XMP:Rights"] = resolved.copyright ?? "" }
                    if resolved.dateCreated != meta.dateCreated { fields["XMP:DateCreated"] = resolved.dateCreated ?? "" }
                    if resolved.city != meta.city { fields["XMP-photoshop:City"] = resolved.city ?? "" }
                    if resolved.country != meta.country { fields["XMP-photoshop:Country"] = resolved.country ?? "" }
                    if resolved.event != meta.event { fields["XMP-iptcExt:Event"] = resolved.event ?? "" }

                    if !fields.isEmpty {
                        try await exifToolService.writeFields(fields, to: [url])
                    }
                }
            } catch {
                // Continue with next file
            }

            processed += 1
            variablesProcessProgress = "\(processed)/\(files.count)"
        }
    }

    private func resolveIfChanged(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, changed: inout Bool) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref)
        if resolved != value { changed = true }
        return resolved.isEmpty ? nil : resolved
    }
}
