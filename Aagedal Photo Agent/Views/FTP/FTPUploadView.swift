import SwiftUI

struct FTPUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: FTPViewModel
    let files: [URL]
    let exifToolService: ExifToolService
    var onStartUpload: (() -> Void)?

    @State private var activeFiles: [URL]
    @State private var selectedServerID: UUID?
    @State private var processVariablesBeforeUpload = false
    @State private var signWithC2PABeforeUpload = false
    @State private var isProcessingVariables = false
    @State private var isSigningC2PA = false
    @State private var variablesProcessProgress = ""
    @State private var c2paSignProgress = ""
    @State private var expandedHistoryID: UUID?
    @State private var preprocessErrors: [String] = []
    @State private var isFileListExpanded = false

    init(viewModel: FTPViewModel, files: [URL], exifToolService: ExifToolService, onStartUpload: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.files = files
        self.exifToolService = exifToolService
        self.onStartUpload = onStartUpload
        self._activeFiles = State(initialValue: files)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
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

            // Current Upload section
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup(isExpanded: $isFileListExpanded) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(activeFiles, id: \.self) { url in
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(.secondary)
                            Text("\(activeFiles.count) file\(activeFiles.count == 1 ? "" : "s") selected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

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
                        Picker("Server", selection: $selectedServerID) {
                            Text("Select...").tag(nil as UUID?)
                            ForEach(viewModel.connections) { conn in
                                Text(conn.name).tag(conn.id as UUID?)
                            }
                        }
                        .onChange(of: selectedServerID) { _, newValue in
                            viewModel.selectedConnectionID = newValue
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

                    // C2PA signing option (hidden if no certificate)
                    if SettingsViewModel.hasC2PASigningCertificate {
                        Toggle("Sign with C2PA before upload", isOn: $signWithC2PABeforeUpload)
                            .font(.subheadline)

                        if isSigningC2PA {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Signing... \(c2paSignProgress)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !preprocessErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(preprocessErrors, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                    }

                    if !viewModel.errorMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.errorMessages, id: \.self) { error in
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                        }
                    }

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
            } label: {
                Label("Current Upload", systemImage: "arrow.up.circle")
                    .font(.subheadline.weight(.medium))
            }

            // Recent Uploads section
            if !viewModel.uploadHistory.entries.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.uploadHistory.entries) { entry in
                            historyEntryView(entry)
                            if entry.id != viewModel.uploadHistory.entries.last?.id {
                                Divider()
                            }
                        }
                    }
                } label: {
                    Label("Recent Uploads", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding()
        .frame(minWidth: 480)
        .onAppear {
            viewModel.loadConnections()
            viewModel.loadHistory()
            selectedServerID = viewModel.selectedConnectionID
        }
        .onChange(of: files) { _, newFiles in
            activeFiles = newFiles
        }
    }

    // MARK: - History Entry

    @ViewBuilder
    private func historyEntryView(_ entry: FTPUploadHistoryEntry) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedHistoryID == entry.id },
            set: { expandedHistoryID = $0 ? entry.id : nil }
        )) {
            historyDetailView(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.serverName)
                    if entry.didRenderJPEG {
                        Text("(JPEG)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)

                HStack(spacing: 4) {
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let completed = entry.completedAt {
                        Text("–")
                        Text(completed.formatted(date: .omitted, time: .shortened))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func historyDetailView(_ entry: FTPUploadHistoryEntry) -> some View {
        let missingFiles = entry.files.filter { !FileManager.default.fileExists(atPath: $0.filePath) }
        let availableURLs = entry.files
            .filter { FileManager.default.fileExists(atPath: $0.filePath) }
            .map { URL(fileURLWithPath: $0.filePath) }

        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.files) { file in
                        let isMissing = !FileManager.default.fileExists(atPath: file.filePath)
                        HStack {
                            Text(file.fileName)
                                .strikethrough(isMissing)
                                .foregroundStyle(isMissing ? .secondary : .primary)
                            Spacer()
                            if isMissing {
                                Text("missing")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                                    .foregroundStyle(.secondary)
                                Text(file.modifiedDate.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 150)

            if !missingFiles.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("\(missingFiles.count) file\(missingFiles.count == 1 ? "" : "s") no longer available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !availableURLs.isEmpty {
                Button("Upload these files again") {
                    activeFiles = availableURLs
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Upload Logic

    private var uploadDisabled: Bool {
        selectedServerID == nil || viewModel.isUploading || viewModel.isRendering || isProcessingVariables || isSigningC2PA || activeFiles.isEmpty
    }

    private func startUpload(renderFirst: Bool) {
        guard let id = selectedServerID,
              let connection = viewModel.connections.first(where: { $0.id == id }) else { return }

        viewModel.saveLastUsedConnectionID(connection.id)

        Task {
            preprocessErrors = []

            if processVariablesBeforeUpload {
                isProcessingVariables = true
                variablesProcessProgress = "0/\(activeFiles.count)"
                await processVariables(for: activeFiles)
                isProcessingVariables = false
                variablesProcessProgress = ""
            }

            if signWithC2PABeforeUpload {
                await signFilesWithC2PA(activeFiles)
            }

            beginUpload(files: activeFiles, connection: connection, renderFirst: renderFirst)
        }
    }

    private func signFilesWithC2PA(_ files: [URL]) async {
        let certPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificatePath) ?? ""
        let author = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paDefaultAuthor)
        guard !certPath.isEmpty,
              let privateKeyPEM = KeychainService.load(forKey: "c2pa_private_key"),
              C2PASigningService.isAvailable else { return }

        isSigningC2PA = true
        c2paSignProgress = "0/\(files.count)"
        var signed = 0

        for url in files {
            do {
                try await C2PASigningService.sign(
                    imageURL: url,
                    certificatePath: certPath,
                    privateKeyPEM: privateKeyPEM,
                    author: author?.isEmpty == true ? nil : author
                )
            } catch {
                preprocessErrors.append("C2PA signing failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
            signed += 1
            c2paSignProgress = "\(signed)/\(files.count)"
        }

        isSigningC2PA = false
        c2paSignProgress = ""
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
        var sequenceNumber = 1

        for url in files {
            do {
                let meta = try await exifToolService.readFullMetadata(url: url)
                let snapshot = meta
                let filename = url.lastPathComponent

                var changed = false
                var resolved = meta

                resolved.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.extendedDescription = resolveIfChanged(meta.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.jobId = resolveIfChanged(meta.jobId, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)
                resolved.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber)

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
                preprocessErrors.append("Variable processing failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }

            processed += 1
            sequenceNumber += 1
            variablesProcessProgress = "\(processed)/\(files.count)"
        }
    }

    private func resolveIfChanged(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, changed: inout Bool, sequenceIndex: Int = 1) -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex)
        if resolved != value { changed = true }
        return resolved.isEmpty ? nil : resolved
    }
}
