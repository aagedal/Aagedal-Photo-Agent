import SwiftUI

struct FTPUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: FTPViewModel
    let files: [URL]
    let exifToolService: ExifToolService
    var onStartUpload: (() -> Void)?

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

            Text("Upload \(files.count) file(s)")
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
                    Text("Processing variables... \(variablesProcessProgress)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    startUpload(renderFirst: false)
                }
                .buttonStyle(.bordered)
                .disabled(uploadDisabled)

                Button("Render JPEG & Upload") {
                    startUpload(renderFirst: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploadDisabled)
            }
        }
        .padding()
        .frame(minWidth: 400)
        .onAppear {
            viewModel.loadConnections()
        }
    }

    private var uploadDisabled: Bool {
        viewModel.selectedConnection == nil || viewModel.isUploading || viewModel.isRendering || isProcessingVariables || files.isEmpty
    }

    private func startUpload(renderFirst: Bool) {
        guard let connection = viewModel.selectedConnection else { return }

        viewModel.saveLastUsedConnectionID(connection.id)

        if processVariablesBeforeUpload {
            isProcessingVariables = true
            variablesProcessProgress = "0/\(files.count)"

            Task {
                await processVariables(for: files)
                isProcessingVariables = false
                variablesProcessProgress = ""
                beginUpload(files: files, connection: connection, renderFirst: renderFirst)
            }
        } else {
            beginUpload(files: files, connection: connection, renderFirst: renderFirst)
        }
    }

    private func beginUpload(files: [URL], connection: FTPConnection, renderFirst: Bool) {
        if renderFirst {
            viewModel.renderAndUploadFiles(files, to: connection, exifToolService: exifToolService)
        } else {
            viewModel.uploadFiles(files, to: connection)
        }
        onStartUpload?()
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
                resolved.extendedDescription = resolveIfChanged(meta.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.jobId = resolveIfChanged(meta.jobId, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)
                resolved.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed)

                if changed {
                    var fields: [String: String] = [:]
                    if resolved.title != meta.title { fields[ExifToolWriteTag.headline] = resolved.title ?? "" }
                    if resolved.description != meta.description { fields[ExifToolWriteTag.description] = resolved.description ?? "" }
                    if resolved.extendedDescription != meta.extendedDescription {
                        fields[ExifToolWriteTag.extendedDescription] = resolved.extendedDescription ?? ""
                    }
                    if resolved.creator != meta.creator { fields[ExifToolWriteTag.creator] = resolved.creator ?? "" }
                    if resolved.credit != meta.credit { fields[ExifToolWriteTag.credit] = resolved.credit ?? "" }
                    if resolved.copyright != meta.copyright { fields[ExifToolWriteTag.rights] = resolved.copyright ?? "" }
                    if resolved.jobId != meta.jobId {
                        fields[ExifToolWriteTag.transmissionReference] = resolved.jobId ?? ""
                    }
                    if resolved.dateCreated != meta.dateCreated { fields[ExifToolWriteTag.dateCreated] = resolved.dateCreated ?? "" }
                    if resolved.city != meta.city { fields[ExifToolWriteTag.city] = resolved.city ?? "" }
                    if resolved.country != meta.country { fields[ExifToolWriteTag.country] = resolved.country ?? "" }
                    if resolved.event != meta.event { fields[ExifToolWriteTag.event] = resolved.event ?? "" }

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
