import SwiftUI
import AppKit

/// Render-relevant facts about a queued upload file, resolved once the dialog opens.
struct UploadFileInfo: Equatable {
    var isRaw: Bool
    var hasDevelop: Bool
    var hasCrop: Bool
    /// Any visible edit (develop adjustment or effective crop) that warrants a JPEG render.
    var hasAnyEdit: Bool { hasDevelop || hasCrop }
}

/// Per-file metadata-requirement evaluation for the upload list: which non-optional fields are
/// empty, split by severity. `error` (a missing Require field) blocks upload; `warn` does not.
struct UploadMetadataStatus: Equatable {
    var missingRequired: [String]
    var missingWarn: [String]

    enum Severity { case ok, warn, error }
    var severity: Severity {
        if !missingRequired.isEmpty { return .error }
        if !missingWarn.isEmpty { return .warn }
        return .ok
    }
}

/// Per-file face-scan facts used by the Person Shown requirement rule.
private struct FaceInfo {
    var scanned: Bool
    var faceCount: Int
}

struct FTPUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: FTPViewModel
    let files: [URL]
    let readService: SwiftExifReadService
    let writeEngine: any MetadataWriteEngine
    let inMemoryCameraRaw: @MainActor (URL) -> CameraRawSettings?
    let thumbnailService: ThumbnailService
    var onStartUpload: (() -> Void)?

    @AppStorage(UserDefaultsKeys.ftpAlwaysRenderRAW) private var alwaysRenderRAW = true

    @State private var activeFiles: [URL]
    @State private var selectedServerID: UUID?
    @State private var skipRenderingEdited = false
    /// Per-file render-relevant facts (RAW?, edited?, cropped?), resolved once the dialog opens.
    @State private var fileInfo: [URL: UploadFileInfo] = [:]
    /// Per-file metadata-requirement evaluation (missing Require / Warn fields), resolved on open
    /// against the global config with the Person Shown face-scan rule applied.
    @State private var metadataStatus: [URL: UploadMetadataStatus] = [:]
    @State private var processVariablesBeforeUpload = false
    @State private var signWithC2PABeforeUpload = false
    @State private var isProcessingVariables = false
    @State private var isSigningC2PA = false
    @State private var variablesProcessProgress = ""
    @State private var c2paSignProgress = ""
    @State private var expandedHistoryID: UUID?
    @State private var preprocessErrors: [String] = []
    /// Files that will upload as-is and whose `.xmp` sidecar holds non-optional metadata the
    /// embedded file is missing — the row offers a one-click sync from sidecar into the file.
    @State private var sidecarMergeableURLs: Set<URL> = []

    init(viewModel: FTPViewModel, files: [URL], readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine, inMemoryCameraRaw: @escaping @MainActor (URL) -> CameraRawSettings?, thumbnailService: ThumbnailService, onStartUpload: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.files = files
        self.readService = readService
        self.writeEngine = writeEngine
        self.inMemoryCameraRaw = inMemoryCameraRaw
        self.thumbnailService = thumbnailService
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

            // Current Upload section — two columns: file list (left) + options/action (right)
            GroupBox {
                HStack(alignment: .top, spacing: 16) {
                    fileListColumn
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        uploadOptions
                        Spacer(minLength: 0)
                        uploadActionBar
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(minWidth: 720)
        .onAppear {
            activeFiles = files
            // Don't carry errors from a previous upload session into a fresh dialog.
            viewModel.errorMessages = []
            viewModel.loadConnections()
            viewModel.loadHistory()
            selectedServerID = viewModel.selectedConnectionID
        }
        .task(id: activeFiles) {
            await detectFileInfo()
        }
        .onChange(of: files) { _, newFiles in
            activeFiles = newFiles
        }
        .onChange(of: skipRenderingEdited) {
            // The render decision flips which metadata source the check evaluates
            // (embedded-only as-is vs embedded∪sidecar when rendered), so re-evaluate.
            Task { await detectFileInfo() }
        }
        .onChange(of: viewModel.isShowingServerForm) { _, showing in
            // When the server form closes after adding a server from this dialog, the
            // freshly-saved connection is in editingConnection. Auto-select it so the
            // Upload button isn't left disabled (uploadDisabled requires a selection).
            guard !showing,
                  selectedServerID == nil,
                  viewModel.connections.contains(where: { $0.id == viewModel.editingConnection.id }) else { return }
            selectedServerID = viewModel.editingConnection.id
            viewModel.selectedConnectionID = selectedServerID
        }
        .sheet(isPresented: $viewModel.isShowingServerForm) {
            FTPServerForm(viewModel: viewModel)
        }
    }

    // MARK: - File List (left column)

    private var fileListColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(.secondary)
                Text("\(activeFiles.count) file\(activeFiles.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(activeFiles, id: \.self) { url in
                        UploadFileRow(
                            url: url,
                            info: fileInfo[url],
                            status: metadataStatus[url],
                            willRender: needsRender(url),
                            canMergeSidecar: sidecarMergeableURLs.contains(url),
                            onMergeSidecar: { mergeSidecar(for: url) },
                            thumbnailService: thumbnailService
                        )
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))

            Toggle("Skip automatic rendering of edited files", isOn: $skipRenderingEdited)
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("When on, edited files upload as their originals instead of being rendered to JPEG. RAW files still render unless changed in Settings ▸ FTP.")
        }
        .frame(width: 300)
    }

    // MARK: - Options (right column)

    @ViewBuilder
    private var uploadOptions: some View {
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
            progressRow("Processing variables... \(variablesProcessProgress)")
        }

        // C2PA signing option (hidden if no certificate)
        if SettingsViewModel.hasC2PASigningCertificate {
            Toggle("Sign with C2PA before upload", isOn: $signWithC2PABeforeUpload)
                .font(.subheadline)
            if isSigningC2PA {
                progressRow("Signing... \(c2paSignProgress)")
            }
        }

        // Metadata-requirement rules are configured globally; the file list shows per-image
        // warnings and Upload is blocked while any Require field is empty.
        Label("Required-metadata rules are set in Settings ▸ Library & Metadata.", systemImage: "checkmark.seal")
            .font(.caption)
            .foregroundStyle(.secondary)

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
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action

    private var uploadActionBar: some View {
        let renderCount = activeFiles.reduce(into: 0) { $0 += needsRender($1) ? 1 : 0 }
        let requiredMissing = metadataViolationCount(.error)
        let warnMissing = metadataViolationCount(.warn)
        return VStack(alignment: .trailing, spacing: 4) {
            if requiredMissing > 0 {
                Label("\(requiredMissing) file\(requiredMissing == 1 ? "" : "s") missing required metadata", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if warnMissing > 0 {
                Label("\(warnMissing) file\(warnMissing == 1 ? "" : "s") missing recommended metadata", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !activeFiles.isEmpty {
                Text(uploadSummary(renderCount: renderCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Button("Upload") {
                startUpload(renderURLs: Set(activeFiles.filter { needsRender($0) }))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(uploadDisabled)
        }
    }

    private func metadataViolationCount(_ severity: UploadMetadataStatus.Severity) -> Int {
        activeFiles.reduce(into: 0) { $0 += (metadataStatus[$1]?.severity == severity ? 1 : 0) }
    }

    private func uploadSummary(renderCount: Int) -> String {
        let total = activeFiles.count
        if renderCount == 0 {
            return "Upload \(total) file\(total == 1 ? "" : "s") as-is"
        } else if renderCount == total {
            return "Render \(total) file\(total == 1 ? "" : "s") to JPEG, then upload"
        } else {
            return "Render \(renderCount), upload \(total - renderCount) as-is"
        }
    }

    // MARK: - Render Decision

    /// A file is rendered to JPEG before upload when it's a RAW (and the always-render-RAW
    /// setting is on) or when it carries visible develop/crop edits (unless the user opted to
    /// skip rendering edited files). Already-finished JPEGs with no edits upload untouched.
    private func needsRender(_ url: URL) -> Bool {
        let info = fileInfo[url] ?? UploadFileInfo(isRaw: SupportedImageFormats.isRaw(url: url), hasDevelop: false, hasCrop: false)
        return Self.willRender(info: info, alwaysRenderRAW: alwaysRenderRAW, skipRenderingEdited: skipRenderingEdited)
    }

    /// Pure render-decision rule, shared by `needsRender` (view) and `detectFileInfo`
    /// (metadata evaluation) so the warning logic and the badges can't disagree.
    private static func willRender(info: UploadFileInfo, alwaysRenderRAW: Bool, skipRenderingEdited: Bool) -> Bool {
        if info.isRaw && alwaysRenderRAW { return true }
        return info.hasAnyEdit && !skipRenderingEdited
    }

    /// Resolves RAW/edit/crop facts for every queued file using the same camera-raw resolution
    /// the render pipeline uses (batch metadata read + in-memory override + RAW sidecar), so the
    /// dialog's badges and render decisions match exactly what an upload would produce.
    @MainActor
    private func detectFileInfo() async {
        let urls = activeFiles
        var metadataMap = (try? await readService.readBatchFullMetadata(urls: urls)) ?? [:]
        EditExportPipeline.resolveCameraRaw(into: &metadataMap, urls: urls, inMemory: inMemoryCameraRaw)
        guard !Task.isCancelled else { return }

        var info: [URL: UploadFileInfo] = [:]
        info.reserveCapacity(urls.count)
        for url in urls {
            let settings = metadataMap[url]?.cameraRaw ?? inMemoryCameraRaw(url)
            let hasCrop = settings?.crop?.isEffectiveCrop ?? false
            var hasDevelop = false
            if var noCrop = settings {
                noCrop.crop = nil
                hasDevelop = !noCrop.isEmpty
            }
            info[url] = UploadFileInfo(isRaw: SupportedImageFormats.isRaw(url: url), hasDevelop: hasDevelop, hasCrop: hasCrop)
        }
        fileInfo = info

        // Evaluate metadata requirements against the global config, with the Person Shown
        // face-scan rule. Face data and XMP sidecars are loaded off the main actor (file I/O).
        let levels = MetadataRequirements.load()
        let faceInfo = await Self.loadFaceInfo(for: urls)
        let sidecars = Self.loadSidecars(for: urls)
        guard !Task.isCancelled else { return }
        var status: [URL: UploadMetadataStatus] = [:]
        status.reserveCapacity(urls.count)
        var mergeable: Set<URL> = []
        for url in urls {
            let embedded = metadataMap[url]
            let sidecar = sidecars[url]
            // Render-aware: a rendered file inherits the sidecar's descriptive metadata via
            // the export overlay (SidecarIPTCOverlay), so evaluate against embedded ∪ sidecar.
            // A file uploaded as-is carries only its embedded metadata over FTP (the sidecar
            // doesn't travel), so evaluate against embedded alone.
            let renders = Self.willRender(info: info[url] ?? UploadFileInfo(isRaw: SupportedImageFormats.isRaw(url: url), hasDevelop: false, hasCrop: false),
                                          alwaysRenderRAW: alwaysRenderRAW, skipRenderingEdited: skipRenderingEdited)
            status[url] = Self.evaluateRequirements(url: url, embedded: embedded, sidecar: sidecar, willRender: renders, levels: levels, face: faceInfo[url])
            // Offer a sidecar→file sync for as-is files whose sidecar holds non-optional
            // fields the embedded copy is missing (the JXL/JPEG drift case).
            if !renders, let sidecar, Self.sidecarFillsMissing(embedded: embedded, sidecar: sidecar, levels: levels, face: faceInfo[url]) {
                mergeable.insert(url)
            }
        }
        metadataStatus = status
        sidecarMergeableURLs = mergeable
    }

    /// Loads the `.xmp` sidecar metadata for each file (descriptive IPTC + rating/label),
    /// grouped off the main actor. Mirrors how the panel and export pipeline source sidecars.
    private static func loadSidecars(for urls: [URL]) -> [URL: IPTCMetadata] {
        let service = XMPSidecarService()
        var result: [URL: IPTCMetadata] = [:]
        for url in urls {
            if let meta = service.loadSidecar(for: url) { result[url] = meta }
        }
        return result
    }

    /// True when the sidecar carries a value for a non-optional field that the embedded
    /// file is missing — i.e. syncing the sidecar into the file would reduce the warnings.
    nonisolated private static func sidecarFillsMissing(embedded: IPTCMetadata?, sidecar: IPTCMetadata, levels: MetadataRequirements.Levels, face: FaceInfo?) -> Bool {
        for field in IPTCMetadata.FieldKey.userSelectable {
            guard let level = levels[field], level != .optional else { continue }
            if field == .personShown, let face, face.scanned, face.faceCount == 0 { continue }
            let embeddedEmpty = embedded.map { field.isEmpty(in: $0) } ?? true
            if embeddedEmpty && !field.isEmpty(in: sidecar) { return true }
        }
        return false
    }

    /// Writes the `.xmp` sidecar's authoritative descriptive metadata into the image file so an
    /// as-is upload carries what the metadata panel shows. Uses the same overwrite semantics as
    /// the export overlay (`toOverwriteFields` + rating/label), so the file ends up consistent
    /// with the sidecar rather than just gap-filled. Re-evaluates afterward.
    private func mergeSidecar(for url: URL) {
        Task {
            let service = XMPSidecarService()
            guard let sidecar = service.loadSidecar(for: url),
                  sidecar.hasDescriptiveContent || sidecar.rating != nil || sidecar.label != nil else { return }
            var fields = sidecar.hasDescriptiveContent ? sidecar.toOverwriteFields() : [:]
            if let rating = sidecar.rating { fields[.rating] = String(rating) }
            if let label = sidecar.label, !label.isEmpty { fields[.label] = label }
            guard !fields.isEmpty else { return }
            do {
                try await writeEngine.writeFields(fields, to: [url])
            } catch {
                preprocessErrors.append("Failed to sync sidecar metadata into \(url.lastPathComponent): \(error.localizedDescription)")
            }
            await detectFileInfo()
        }
    }

    /// Loads per-file face-scan facts (was it scanned, how many faces) for the Person Shown rule.
    /// Groups by parent folder so each folder's `.face_data/face_data.json` is read once.
    nonisolated private static func loadFaceInfo(for urls: [URL]) async -> [URL: FaceInfo] {
        let storage = FaceDataStorageService()
        var byFolder: [URL: FolderFaceData?] = [:]
        var result: [URL: FaceInfo] = [:]
        for url in urls {
            let folder = url.deletingLastPathComponent()
            let data: FolderFaceData?
            if let cached = byFolder[folder] {
                data = cached
            } else {
                data = storage.loadFaceData(for: folder)
                byFolder[folder] = data
            }
            guard let data else { result[url] = FaceInfo(scanned: false, faceCount: 0); continue }
            let count = data.faces.reduce(into: 0) { $0 += ($1.imageURL.path == url.path ? 1 : 0) }
            // A scannedFiles entry marks "examined" even when zero faces were found; legacy data may
            // only carry faces, so treat any detected face as proof the file was scanned too.
            let scanned = data.scannedFiles[url.path] != nil || count > 0
            result[url] = FaceInfo(scanned: scanned, faceCount: count)
        }
        return result
    }

    /// Computes which non-optional fields are empty for one file. Person Shown is suppressed when the
    /// image was scanned and has no faces — requiring a name on a faceless photo is meaningless and
    /// would otherwise permanently block its upload.
    nonisolated private static func evaluateRequirements(url: URL, embedded: IPTCMetadata?, sidecar: IPTCMetadata?, willRender: Bool, levels: MetadataRequirements.Levels, face: FaceInfo?) -> UploadMetadataStatus {
        var missingRequired: [String] = []
        var missingWarn: [String] = []
        for field in IPTCMetadata.FieldKey.userSelectable {
            guard let level = levels[field], level != .optional else { continue }
            let embeddedEmpty = embedded.map { field.isEmpty(in: $0) } ?? true
            // For a rendered upload the sidecar's value reaches the output, so the field is
            // satisfied if either source has it. For an as-is upload only the embedded value
            // ships, so the sidecar can't satisfy the requirement.
            let empty: Bool
            if willRender, let sidecar {
                empty = embeddedEmpty && field.isEmpty(in: sidecar)
            } else {
                empty = embeddedEmpty
            }
            guard empty else { continue }
            if field == .personShown, let face, face.scanned, face.faceCount == 0 { continue }
            switch level {
            case .require: missingRequired.append(field.displayName)
            case .warnOnEmpty: missingWarn.append(field.displayName)
            case .optional: break
            }
        }
        return UploadMetadataStatus(missingRequired: missingRequired, missingWarn: missingWarn)
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
        selectedServerID == nil || viewModel.isUploading || viewModel.isRendering
            || isProcessingVariables || isSigningC2PA || activeFiles.isEmpty
            || metadataViolationCount(.error) > 0
    }

    private func startUpload(renderURLs: Set<URL>) {
        guard let id = selectedServerID,
              let connection = viewModel.connections.first(where: { $0.id == id }) else { return }

        viewModel.saveLastUsedConnectionID(connection.id)

        Task {
            preprocessErrors = []
            await continueUpload(renderURLs: renderURLs, connection: connection)
        }
    }

    private func continueUpload(renderURLs: Set<URL>, connection: FTPConnection) async {
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

        beginUpload(files: activeFiles, connection: connection, renderURLs: renderURLs)
    }

    private func signFilesWithC2PA(_ files: [URL]) async {
        let certPath = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paCertificatePath) ?? ""
        let author = UserDefaults.standard.string(forKey: UserDefaultsKeys.c2paDefaultAuthor)
        let usesTestCertificate = UserDefaults.standard.bool(forKey: UserDefaultsKeys.c2paUseTestCertificate)
        let privateKeyPEM = usesTestCertificate ? "" : KeychainService.load(forKey: "c2pa_private_key")
        guard (usesTestCertificate || !certPath.isEmpty),
              let privateKeyPEM,
              C2PASigningService.isAvailable else { return }

        isSigningC2PA = true
        c2paSignProgress = "0/\(files.count)"
        var signed = 0

        for url in files {
            do {
                try await C2PASigningService.sign(
                    imageURL: url,
                    certificatePath: usesTestCertificate ? "" : certPath,
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

    private func beginUpload(files: [URL], connection: FTPConnection, renderURLs: Set<URL>) {
        // The view model renders only the files in renderURLs and uploads the rest as-is
        // (and short-circuits to the plain upload path when nothing needs rendering).
        viewModel.uploadFiles(files, renderURLs: renderURLs, to: connection, readService: readService, writeEngine: writeEngine, inMemoryCameraRaw: inMemoryCameraRaw)
        onStartUpload?()
    }

    private func processVariables(for files: [URL]) async {
        let interpolator = PresetVariableInterpolator()
        var processed = 0
        var sequenceNumber = 1

        for url in files {
            do {
                let unresolvedMeta = try await readService.readFullMetadata(url: url)
                let meta = await interpolator.resolvingGPSPlaceVariables(in: unresolvedMeta)
                let snapshot = meta
                let filename = url.lastPathComponent

                var changed = meta != unresolvedMeta
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
                    var fields: [MetadataFieldKey: String] = [:]
                    if resolved.title != meta.title { fields[.headline] = resolved.title ?? "" }
                    if resolved.description != meta.description { fields[.description] = resolved.description ?? "" }
                    if resolved.extendedDescription != meta.extendedDescription {
                        fields[.extendedDescription] = resolved.extendedDescription ?? ""
                    }
                    if resolved.creator != meta.creator { fields[.creator] = resolved.creator ?? "" }
                    if resolved.credit != meta.credit { fields[.credit] = resolved.credit ?? "" }
                    if resolved.copyright != meta.copyright { fields[.rights] = resolved.copyright ?? "" }
                    if resolved.jobId != meta.jobId {
                        fields[.transmissionReference] = resolved.jobId ?? ""
                    }
                    if resolved.dateCreated != meta.dateCreated { fields[.dateCreated] = resolved.dateCreated ?? "" }
                    if resolved.city != meta.city { fields[.city] = resolved.city ?? "" }
                    if resolved.country != meta.country { fields[.country] = resolved.country ?? "" }
                    if resolved.event != meta.event { fields[.event] = resolved.event ?? "" }

                    if !fields.isEmpty {
                        try await writeEngine.writeFields(fields, to: [url])
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

// MARK: - Upload File Row

/// One row in the upload file list: a tiny square thumbnail, the filename, and badges
/// indicating RAW / develop edits / crop, plus whether the file will be rendered to JPEG.
private struct UploadFileRow: View {
    let url: URL
    let info: UploadFileInfo?
    let status: UploadMetadataStatus?
    let willRender: Bool
    let canMergeSidecar: Bool
    let onMergeSidecar: () -> Void
    let thumbnailService: ThumbnailService

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            thumbView
            metadataIcon
                .frame(width: 14)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if canMergeSidecar {
                Button(action: onMergeSidecar) {
                    Label("Sync from sidecar", systemImage: "arrow.down.doc")
                        .font(.system(size: 9))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Write the .xmp sidecar's metadata (shown in the panel) into this file, so an as-is upload carries it.")
            }
            badges
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .task(id: url) {
            thumbnail = await thumbnailService.loadThumbnail(for: url)
        }
    }

    @ViewBuilder
    private var metadataIcon: some View {
        switch status?.severity {
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .help("Missing required metadata: \(status?.missingRequired.joined(separator: ", ") ?? "")")
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help("Missing recommended metadata: \(status?.missingWarn.joined(separator: ", ") ?? "")")
        case .ok, .none:
            EmptyView()
        }
    }

    private var thumbView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if info?.isRaw == true {
                Text("RAW")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if info?.hasDevelop == true {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Has develop edits")
            }
            if info?.hasCrop == true {
                Image(systemName: "crop")
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
                    .help("Cropped")
            }
            if willRender {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .help("Will be rendered to JPEG before upload")
            }
        }
    }
}
