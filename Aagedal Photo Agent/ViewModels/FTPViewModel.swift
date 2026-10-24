import Foundation
import os

nonisolated private let ftpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "FTPViewModel")

/// Injectable execution boundaries keep upload lifecycle tests independent of credentials,
/// network services, rendering hardware, and signing tools.
nonisolated struct FTPUploadExecutionAccess: Sendable {
    var password: @MainActor @Sendable (String) -> String? = { KeychainService.load(forKey: $0) }
    var upload: @Sendable (URL, FTPConnection, String, @escaping @Sendable (FTPUploadProgress) -> Void) async throws -> Void = { url, connection, password, progress in
        try await FTPService().uploadFile(localURL: url, connection: connection, password: password, progressHandler: progress)
    }
    var render: @MainActor @Sendable (URL, CameraRawSettings?, URL, URL?, any MetadataWriteEngine, MetadataFailureTracker) async throws -> URL = { source, raw, output, folder, engine, tracker in
        try await EditExportPipeline.renderForDelivery(sourceURL: source, cameraRaw: raw, kind: .jpeg, outputFolder: output, folderURL: folder, writeEngine: engine, failureTracker: tracker)
    }
    var sign: @Sendable (C2PAUploadSigningConfiguration, URL) async throws -> Void = { configuration, url in
        try await configuration.sign(url)
    }
}

/// Immutable file facts used to create one upload-history entry after filesystem work has
/// completed away from the main actor.
nonisolated struct FTPUploadFileInventory: Sendable {
    let records: [FTPUploadFileRecord]
    let totalBytes: Int64
}

/// Immutable evidence that a local file was prepared for upload.
nonisolated struct FTPPreparedUploadFile: Sendable, Equatable {
    let url: URL
    let wasStaged: Bool
    let usedCopyFallback: Bool
    let cancellationRequestedAfterCommit: Bool
}

/// One immutable local-availability fact collected for the Recent Uploads disclosure.
nonisolated struct FTPUploadHistoryFileAvailability: Sendable, Equatable {
    let filePath: String
    let isAvailable: Bool
}

/// Whether a history scan observed every requested path or stopped cooperatively. A cancelled
/// scan deliberately retains its checked prefix so diagnostics and tests can distinguish
/// pre-scan cancellation from cancellation after one or more non-preemptible filesystem probes.
nonisolated enum FTPUploadHistoryAvailabilityCompletion: Sendable, Equatable {
    case complete
    case cancelled(checkedFileCount: Int)
}

/// Immutable availability evidence returned across the filesystem actor boundary.
nonisolated struct FTPUploadHistoryAvailabilitySnapshot: Sendable, Equatable {
    let entryID: UUID
    let files: [FTPUploadHistoryFileAvailability]
    let completion: FTPUploadHistoryAvailabilityCompletion
}

/// Serializes potentially blocking upload-history scans and local staging mutations away from
/// the app's default MainActor. Foundation mutations are allowed to finish once started; their
/// immutable result records cancellation that arrived after commit so callers can reconcile with
/// disk rather than pretending the mutation did not happen.
actor FTPUploadFileSystemBoundary {
    private let temporaryRoot: URL
    private let fileExists: @Sendable (String) -> Bool

    init(
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.temporaryRoot = temporaryRoot
        self.fileExists = fileExists
    }

    func inventory(for urls: [URL], fallbackDate: Date) throws -> FTPUploadFileInventory {
        var records: [FTPUploadFileRecord] = []
        records.reserveCapacity(urls.count)
        var totalBytes: Int64 = 0

        for url in urls {
            try Task.checkCancellation()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date) ?? fallbackDate
            totalBytes += size
            records.append(FTPUploadFileRecord(
                filePath: url.path,
                fileName: url.lastPathComponent,
                fileSize: size,
                modifiedDate: modified
            ))
        }

        return FTPUploadFileInventory(records: records, totalBytes: totalBytes)
    }

    /// Serially resolves local-file availability without making SwiftUI's main-actor body touch
    /// the filesystem. `fileExists` is synchronous and cannot be interrupted once entered, so
    /// cancellation is checked both before and after every probe. Partial evidence is returned
    /// explicitly and must not be presented as a complete snapshot by the caller.
    func historyAvailability(
        for entryID: UUID,
        files: [FTPUploadFileRecord]
    ) -> FTPUploadHistoryAvailabilitySnapshot {
        var availability: [FTPUploadHistoryFileAvailability] = []
        availability.reserveCapacity(files.count)

        for file in files {
            guard !Task.isCancelled else {
                return FTPUploadHistoryAvailabilitySnapshot(
                    entryID: entryID,
                    files: availability,
                    completion: .cancelled(checkedFileCount: availability.count)
                )
            }

            let isAvailable = fileExists(file.filePath)
            availability.append(FTPUploadHistoryFileAvailability(
                filePath: file.filePath,
                isAvailable: isAvailable
            ))

            guard !Task.isCancelled else {
                return FTPUploadHistoryAvailabilitySnapshot(
                    entryID: entryID,
                    files: availability,
                    completion: .cancelled(checkedFileCount: availability.count)
                )
            }
        }

        return FTPUploadHistoryAvailabilitySnapshot(
            entryID: entryID,
            files: availability,
            completion: .complete
        )
    }

    func createTemporaryDirectory() throws -> URL {
        try Task.checkCancellation()
        let url = temporaryRoot.appendingPathComponent("FTPRender_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func ensureDirectory(_ url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func stageOriginal(
        _ sourceURL: URL,
        as fileName: String,
        in temporaryDirectory: URL,
        index: Int
    ) throws -> FTPPreparedUploadFile {
        try Task.checkCancellation()
        let itemDirectory = temporaryDirectory.appendingPathComponent("o\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let destinationURL = itemDirectory.appendingPathComponent(fileName)

        do {
            try FileManager.default.linkItem(at: sourceURL, to: destinationURL)
            return FTPPreparedUploadFile(
                url: destinationURL,
                wasStaged: true,
                usedCopyFallback: false,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        } catch {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return FTPPreparedUploadFile(
                url: destinationURL,
                wasStaged: true,
                usedCopyFallback: true,
                cancellationRequestedAfterCommit: Task.isCancelled
            )
        }
    }

    func sequenceRenderedFile(
        _ sourceURL: URL,
        avoiding reservedNames: Set<String>
    ) throws -> FTPPreparedUploadFile {
        let directory = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var counter = 1

        while true {
            try Task.checkCancellation()
            let name = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            let destinationURL = directory.appendingPathComponent(name)
            guard !reservedNames.contains(name),
                  !FileManager.default.fileExists(atPath: destinationURL.path) else {
                counter += 1
                continue
            }
            do {
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                return FTPPreparedUploadFile(
                    url: destinationURL,
                    wasStaged: true,
                    usedCopyFallback: false,
                    cancellationRequestedAfterCommit: Task.isCancelled
                )
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                counter += 1
            }
        }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// `defer` cannot await actor cleanup. Scheduling it here keeps removal on this serialized
    /// boundary even when the parent upload task exits through cancellation or an error.
    nonisolated func removeEventually(_ url: URL) {
        Task { try? await self.removeItem(at: url) }
    }
}

@Observable
final class FTPViewModel {
    var connections: [FTPConnection] = []
    var selectedConnectionID: UUID?

    var selectedConnection: FTPConnection? {
        guard let id = selectedConnectionID else { return nil }
        return connections.first { $0.id == id }
    }
    var isUploading = false
    var isRendering = false
    var uploadProgress: [String: FTPUploadProgress] = [:]
    var overallProgress: Double = 0
    var errorMessages: [String] = []
    var completedCount = 0
    var totalCount = 0
    var renderCompletedCount = 0
    var renderTotalCount = 0
    var uploadCompleted = false
    /// The finished run ended early (preparation or signing failed) rather than running to
    /// completion; `errorMessages` says why. Only meaningful while `uploadCompleted`.
    var uploadStopped = false
    /// Why the most recent Upload request was refused before a run started (missing password,
    /// unacknowledged insecure transport, SFTP profile). Kept apart from `errorMessages`, which
    /// belong to the last run and feed its sidebar banner, so the sheet can stay open showing
    /// the reason without rewriting a finished run's result.
    var uploadAdmissionError: String?
    /// Save failure shown inside the server form (e.g. the Keychain refused the password).
    var serverFormError: String?
    /// The profile awaiting delete confirmation in Settings.
    var pendingConnectionDeletion: FTPConnection?

    /// Distinct `Uploaded` sub-folders created by the most recent render-and-upload, so the
    /// owner (ContentView) can reveal them in the sidebar on completion — otherwise the
    /// freshly created folder stays hidden until a manual close/reopen.
    var renderedUploadedFolders: [URL] = []

    var isShowingServerForm = false
    var editingConnection = FTPConnection.secureDefault
    var editingPassword = ""

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        /// Connected; the optional note explains a caveat (e.g. the folder will be created).
        case success(String?)
        case failure(String)
    }
    var connectionTest: ConnectionTestState = .idle

    var uploadHistory = FTPUploadHistory()

    /// Shared import/upload activity log. Assigned by the owner (ContentView).
    @ObservationIgnored var activityHistory: ActivityHistoryStore?

    private let ftpService = FTPService()
    @ObservationIgnored private let fileSystem: FTPUploadFileSystemBoundary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let execution: FTPUploadExecutionAccess
    private let connectionsKey = UserDefaultsKeys.ftpConnections
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTestTask: Task<Void, Never>?
    @ObservationIgnored private var uploadGeneration = UUID()
    /// What the in-flight run will report to Activity, so a cancel can still record it.
    @ObservationIgnored private var activeRun: ActiveUploadRun?
    /// Settings and the main window each own an `FTPViewModel`; this keeps their cached
    /// `connections` in step when the other one saves.
    @ObservationIgnored nonisolated(unsafe) private var connectionsObserver: NSObjectProtocol?

    private struct ActiveUploadRun {
        let connection: FTPConnection
        let selectedCount: Int
        var plannedFileNames: [String]
        var unpreparedFileNames: [String] = []
    }

    init(
        fileSystem: FTPUploadFileSystemBoundary = FTPUploadFileSystemBoundary(),
        defaults: UserDefaults = AppDefaults.store,
        execution: FTPUploadExecutionAccess = .init()
    ) {
        self.fileSystem = fileSystem
        self.defaults = defaults
        self.execution = execution
        // Filtered on the defaults instance, so only view models sharing this store reload.
        connectionsObserver = NotificationCenter.default.addObserver(
            forName: .ftpConnectionsDidChange,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loadConnections() }
        }
    }

    /// Captures one run's completion, including cleanup, even after a restart replaces it.
    func currentUploadCompletion() -> @Sendable () async -> Void {
        let task = uploadTask
        return { await task?.value }
    }

    private func ownsUpload(_ generation: UUID) -> Bool {
        uploadGeneration == generation && !Task.isCancelled
    }

    private func applyUploadProgress(_ progress: FTPUploadProgress, generation: UUID,
                                     offset: Double = 0, range: Double = 1) {
        guard uploadGeneration == generation, isUploading, !uploadCompleted,
              uploadProgress[progress.fileName]?.isComplete != true,
              progress.fractionCompleted >= (uploadProgress[progress.fileName]?.fractionCompleted ?? 0) else { return }
        uploadProgress[progress.fileName] = progress
        updateSmoothedProgress(uploadWeightOffset: offset, uploadWeightRange: range)
    }

    deinit {
        uploadTask?.cancel()
        completionTask?.cancel()
        connectionTestTask?.cancel()
        if let connectionsObserver {
            NotificationCenter.default.removeObserver(connectionsObserver)
        }
    }

    func loadConnections() {
        guard let stored = storedConnections() else { return }
        if stored != connections { connections = stored }

        // Verify the selected connection still exists after reload
        if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
            selectedConnectionID = nil
        }

        restoreLastUsedConnection()
    }

    /// The persisted list, or `nil` when nothing is stored or it can't be decoded.
    private func storedConnections() -> [FTPConnection]? {
        guard let data = defaults.data(forKey: connectionsKey) else { return nil }
        do {
            return try JSONDecoder().decode([FTPConnection].self, from: data)
        } catch {
            ftpLog.error("Failed to decode FTP connections: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Applies one change to the freshly re-read stored list (not this instance's cache, which
    /// another window may have made stale), persists it, and tells the other instance to reload.
    private func mutateStoredConnections(_ change: (inout [FTPConnection]) -> Void) {
        var updated = storedConnections() ?? connections
        change(&updated)
        connections = updated
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: connectionsKey)
        } catch {
            ftpLog.error("Failed to encode FTP connections: \(error.localizedDescription, privacy: .private)")
            return
        }
        NotificationCenter.default.post(name: .ftpConnectionsDidChange, object: defaults)
    }

    func saveLastUsedConnectionID(_ id: UUID) {
        defaults.set(id.uuidString, forKey: UserDefaultsKeys.lastUsedFTPConnectionID)
    }

    func restoreLastUsedConnection() {
        guard selectedConnectionID == nil,
              let idString = defaults.string(forKey: UserDefaultsKeys.lastUsedFTPConnectionID),
              let id = UUID(uuidString: idString),
              connections.contains(where: { $0.id == id }) else {
            return
        }
        selectedConnectionID = id
    }

    func startEditingConnection(_ connection: FTPConnection? = nil) {
        editingConnection = connection ?? FTPConnection.secureDefault
        editingPassword = connection.flatMap { KeychainService.load(forKey: $0.keychainKey) } ?? ""
        connectionTestTask?.cancel()
        connectionTest = .idle
        serverFormError = nil
        isShowingServerForm = true
    }

    /// Clears a stale test result after the user edits a connection field, so the
    /// "Connected" / error status never lingers against changed credentials.
    func resetConnectionTest() {
        connectionTestTask?.cancel()
        connectionTest = .idle
    }

    /// Probes the connection currently being edited (connect + auth + list the remote
    /// directory) without uploading anything, updating `connectionTest` for the form UI.
    func testConnection() {
        let connection = editingConnection
        let password = editingPassword
        connectionTestTask?.cancel()
        connectionTest = .testing
        connectionTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let note = try await ftpService.testConnection(connection: connection, password: password)
                guard !Task.isCancelled else { return }
                self.connectionTest = .success(note)
            } catch is CancellationError {
                // Superseded by a newer test or cancelled — leave state to the newer run.
            } catch {
                guard !Task.isCancelled else { return }
                self.connectionTest = .failure(error.localizedDescription)
            }
        }
    }

    /// Returns `false` without persisting when the form must first present the insecure-transport
    /// acknowledgement. Secure profiles save directly.
    @discardableResult
    func saveEditingConnection(acknowledgingInsecureTransport: Bool = false) -> Bool {
        editingConnection.normalizeTransportAcknowledgement()
        if let message = editingConnection.saveValidationMessage(password: editingPassword) {
            serverFormError = message
            return false
        }
        if editingConnection.transportSecurity.isInsecure,
           !acknowledgingInsecureTransport {
            return false
        }

        // Save password to keychain
        do {
            try KeychainService.save(password: editingPassword, forKey: editingConnection.keychainKey)
        } catch {
            ftpLog.error("Keychain save failed for \(self.editingConnection.name, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            serverFormError = "Failed to save password: \(error.localizedDescription)"
            return false
        }

        let edited = editingConnection
        mutateStoredConnections { stored in
            if let index = stored.firstIndex(where: { $0.id == edited.id }) {
                var merged = edited
                // The other window may have acknowledged this exact transport since the form
                // opened; keep that unless the form changed the transport itself.
                if merged.firstUploadAcknowledgedSecurity == nil,
                   stored[index].transportSecurity == edited.transportSecurity {
                    merged.firstUploadAcknowledgedSecurity = stored[index].firstUploadAcknowledgedSecurity
                }
                stored[index] = merged
            } else {
                stored.append(edited)
            }
        }
        serverFormError = nil
        isShowingServerForm = false
        return true
    }

    /// Durably records the one-time acknowledgement for this exact insecure protocol/verification
    /// state. The connection UUID is used instead of host or user data.
    @discardableResult
    func acknowledgeFirstInsecureUpload(connectionID: UUID) -> FTPConnection? {
        var acknowledged: FTPConnection?
        mutateStoredConnections { stored in
            guard let index = stored.firstIndex(where: { $0.id == connectionID }),
                  stored[index].transportSecurity.isInsecure else { return }
            stored[index].acknowledgeFirstInsecureUpload()
            acknowledged = stored[index]
        }
        if let acknowledged, editingConnection.id == connectionID {
            editingConnection = acknowledged
        }
        return acknowledged
    }

    func cancelUpload() {
        // Record what the cancelled run managed before tearing it down, so Activity shows it.
        if let run = activeRun, isUploading || isRendering {
            recordActivity(
                connection: run.connection,
                selectedCount: run.selectedCount,
                plannedFileNames: run.plannedFileNames,
                unpreparedFileNames: run.unpreparedFileNames,
                wasCancelled: true
            )
        }
        activeRun = nil
        uploadGeneration = UUID()
        uploadTask?.cancel()
        uploadTask = nil
        completionTask?.cancel()
        completionTask = nil
        isUploading = false
        isRendering = false
        uploadCompleted = false
        uploadStopped = false
    }

    func deleteConnection(_ connection: FTPConnection) {
        KeychainService.delete(forKey: connection.keychainKey)
        mutateStoredConnections { $0.removeAll { $0.id == connection.id } }
        if selectedConnectionID == connection.id { selectedConnectionID = nil }
    }

    /// Confirms the delete requested via `pendingConnectionDeletion`.
    func confirmPendingConnectionDeletion() {
        guard let connection = pendingConnectionDeletion else { return }
        pendingConnectionDeletion = nil
        deleteConnection(connection)
    }

    // MARK: - Upload History

    func loadHistory() {
        guard let data = defaults.data(forKey: UserDefaultsKeys.ftpUploadHistory),
              let decoded = try? JSONDecoder().decode(FTPUploadHistory.self, from: data) else {
            return
        }
        uploadHistory = decoded
    }

    func saveHistory() {
        if let data = try? JSONEncoder().encode(uploadHistory) {
            defaults.set(data, forKey: UserDefaultsKeys.ftpUploadHistory)
        }
    }

    func historyAvailability(
        for entry: FTPUploadHistoryEntry
    ) async -> FTPUploadHistoryAvailabilitySnapshot {
        await fileSystem.historyAvailability(for: entry.id, files: entry.files)
    }

    func recordUploadStart(
        inventory: FTPUploadFileInventory,
        connection: FTPConnection,
        didRenderJPEG: Bool,
        id: UUID,
        startedAt: Date
    ) {
        let entry = FTPUploadHistoryEntry(
            id: id,
            serverName: connection.name,
            startedAt: startedAt,
            completedAt: nil,
            fileCount: inventory.records.count,
            totalBytes: inventory.totalBytes,
            files: inventory.records,
            didRenderJPEG: didRenderJPEG
        )

        uploadHistory.addEntry(entry)
        saveHistory()
    }

    func recordUploadCompletion(id: UUID) {
        uploadHistory.markCompleted(id: id)
        saveHistory()
    }

    // MARK: - Upload

    /// Starts uploading `urls`. Returns `false` without starting a run when the request is
    /// refused up front; `uploadAdmissionError` then says why, and the caller should keep its
    /// UI open instead of assuming an upload is underway.
    @discardableResult
    func uploadFiles(_ urls: [URL], to connection: FTPConnection) -> Bool {
        guard let password = admitUpload(to: connection) else { return false }

        let historyID = UUID()
        let historyStartedAt = Date()
        activeRun = ActiveUploadRun(
            connection: connection,
            selectedCount: urls.count,
            plannedFileNames: urls.map(\.lastPathComponent)
        )

        isUploading = true
        isRendering = false
        uploadCompleted = false
        uploadStopped = false
        errorMessages = []
        completedCount = 0
        renderCompletedCount = 0
        renderTotalCount = 0
        totalCount = urls.count
        uploadProgress = [:]
        overallProgress = 0
        renderedUploadedFolders = []

        uploadTask?.cancel()
        let generation = UUID()
        uploadGeneration = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inventory = try await fileSystem.inventory(
                    for: urls,
                    fallbackDate: historyStartedAt
                )
                guard self.ownsUpload(generation) else { return }
                self.recordUploadStart(
                    inventory: inventory,
                    connection: connection,
                    didRenderJPEG: false,
                    id: historyID,
                    startedAt: historyStartedAt
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                self.errorMessages = ["Failed to inspect upload files: \(error.localizedDescription)"]
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent))
                return
            }
            for (index, url) in urls.enumerated() {
                guard self.ownsUpload(generation) else { return }
                do {
                    try await execution.upload(url, connection, password) { progress in
                        Task { @MainActor in
                            self.applyUploadProgress(progress, generation: generation)
                        }
                    }
                    // Count completion here, on the awaited result, rather than from the
                    // background progress callback: the callback is delivered via an
                    // unstructured Task that may not have drained by the time the loop
                    // finishes and recordActivity() reads completedCount.
                    guard self.ownsUpload(generation) else { return }
                    self.markFileComplete(url.lastPathComponent)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsUpload(generation) else { return }
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                    // The server is unreachable / rejecting auth — every remaining file
                    // would fail identically, so stop rather than retrying each in turn.
                    if (error as? FTPService.FTPError)?.isServerLevel == true {
                        self.appendBatchAbortNotice(remaining: urls.count - index - 1)
                        break
                    }
                }
            }
            guard self.ownsUpload(generation) else { return }
            self.recordUploadCompletion(id: historyID)
            self.showCompletion(
                connection: connection,
                selectedCount: urls.count,
                plannedFileNames: urls.map(\.lastPathComponent)
            )
        }
        return true
    }

    /// Uploads `urls`, rendering to JPEG only the files in `renderURLs` and sending every other
    /// file as its original. Rendered output names are de-duplicated in their persistent output
    /// folders; non-rendered originals upload in place unless a name collision forces staging a
    /// safe hard-link/copy (the user's real files are never moved or renamed). Falls back to the
    /// plain `uploadFiles(_:to:)` fast path when nothing in the batch needs rendering.
    @discardableResult
    func uploadFiles(
        _ urls: [URL],
        renderURLs: Set<URL>,
        to connection: FTPConnection,
        readService: SwiftExifReadService,
        writeEngine: any MetadataWriteEngine,
        inMemoryCameraRaw: @escaping @MainActor (URL) -> CameraRawSettings?,
        signingConfiguration: C2PAUploadSigningConfiguration? = nil
    ) -> Bool {
        let renderTargets = urls.filter { renderURLs.contains($0) }
        guard !renderTargets.isEmpty else {
            return uploadFiles(urls, to: connection)
        }
        guard let password = admitUpload(to: connection) else { return false }

        let historyID = UUID()
        let historyStartedAt = Date()
        activeRun = ActiveUploadRun(
            connection: connection,
            selectedCount: urls.count,
            plannedFileNames: urls.map(\.lastPathComponent)
        )

        isRendering = true
        isUploading = false
        uploadCompleted = false
        uploadStopped = false
        errorMessages = []
        renderCompletedCount = 0
        renderTotalCount = renderTargets.count
        completedCount = 0
        totalCount = urls.count
        uploadProgress = [:]
        overallProgress = 0
        renderedUploadedFolders = []

        uploadTask?.cancel()
        let generation = UUID()
        uploadGeneration = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inventory = try await fileSystem.inventory(
                    for: urls,
                    fallbackDate: historyStartedAt
                )
                guard self.ownsUpload(generation) else { return }
                self.recordUploadStart(
                    inventory: inventory,
                    connection: connection,
                    didRenderJPEG: true,
                    id: historyID,
                    startedAt: historyStartedAt
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                self.errorMessages = ["Failed to inspect upload files: \(error.localizedDescription)"]
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent))
                return
            }

            let tempDir: URL
            do {
                tempDir = try await fileSystem.createTemporaryDirectory()
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                self.errorMessages = ["Failed to create temp directory: \(error.localizedDescription)"]
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent))
                return
            }

            defer {
                fileSystem.removeEventually(tempDir)
            }

            guard self.ownsUpload(generation) else { return }

            // Read batch metadata + resolve edit settings only for the files we'll render,
            // the same way the local export paths do: prefer the live in-memory CameraRaw,
            // falling back to the XMP sidecar for RAW files.
            var metadataMap: [URL: IPTCMetadata] = [:]
            do {
                metadataMap = try await readService.readBatchFullMetadata(urls: renderTargets)
            } catch {
                guard self.ownsUpload(generation) else { return }
                // Continue without camera raw — renders will use defaults
            }
            guard self.ownsUpload(generation) else { return }
            do {
                try await EditExportPipeline.resolveCameraRaw(
                    into: &metadataMap,
                    urls: renderTargets,
                    inMemory: inMemoryCameraRaw
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                // The production sidecar boundary is best-effort and does not throw read errors.
            }

            guard self.ownsUpload(generation) else { return }

            // Render phase (0–50% of overall progress). Files not in renderURLs are interleaved
            // in source order as their originals, so the upload list preserves the user's order.
            let failureTracker = MetadataFailureTracker()
            var uploadURLs: [URL] = []
            var renderedUploadURLs: [URL] = []
            // Tracks upload filenames already taken in this batch so two sources that
            // share a basename across folders (e.g. /A/img.jpg and /B/img.jpg, both →
            // img_jpg.jpg) don't end up overwriting each other on the remote server.
            var usedNames: Set<String> = []
            // Selected files that never reached the upload list, so the activity record
            // reports them as failed instead of silently omitting them.
            var unpreparedFileNames: [String] = []
            for (index, url) in urls.enumerated() {
                guard self.ownsUpload(generation) else { return }
                guard renderURLs.contains(url) else {
                    // Upload the untouched original (staged only on a name collision).
                    do {
                        if usedNames.insert(url.lastPathComponent).inserted {
                            uploadURLs.append(url)
                        } else {
                            let stagedName = self.reserveUploadName(
                                for: url,
                                avoiding: &usedNames
                            )
                            let staged = try await fileSystem.stageOriginal(
                                url,
                                as: stagedName,
                                in: tempDir,
                                index: index
                            )
                            guard self.ownsUpload(generation) else { return }
                            uploadURLs.append(staged.url)
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard self.ownsUpload(generation) else { return }
                        self.errorMessages.append("Failed to prepare \(url.lastPathComponent): \(error.localizedDescription)")
                        unpreparedFileNames.append(url.lastPathComponent)
                    }
                    continue
                }
                do {
                    // Render into an `Uploaded` sub-folder of the source's own folder so the
                    // rendered JPEG persists for the user (the prior temp-dir output was lost
                    // on cleanup). The render output name is derived from the source basename,
                    // so apply an always-incrementing `_N` suffix afterward: this keeps two
                    // same-named sources from clobbering each other on disk and de-duplicates
                    // the remote name (which is derived from the local filename).
                    let uploadedDir = url.deletingLastPathComponent()
                        .appendingPathComponent("Uploaded", isDirectory: true)
                    try await fileSystem.ensureDirectory(uploadedDir)
                    guard self.ownsUpload(generation) else { return }
                    let outputURL = try await execution.render(
                        url, metadataMap[url]?.cameraRaw, uploadedDir,
                        url.deletingLastPathComponent(), writeEngine, failureTracker)
                    guard self.ownsUpload(generation) else { return }
                    let prepared = try await fileSystem.sequenceRenderedFile(
                        outputURL,
                        avoiding: usedNames
                    )
                    guard self.ownsUpload(generation) else { return }
                    let renderedURL = prepared.url
                    usedNames.insert(renderedURL.lastPathComponent)
                    uploadURLs.append(renderedURL)
                    renderedUploadURLs.append(renderedURL)
                    if !self.renderedUploadedFolders.contains(uploadedDir) {
                        self.renderedUploadedFolders.append(uploadedDir)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsUpload(generation) else { return }
                    self.errorMessages.append("Failed to prepare \(url.lastPathComponent): \(error.localizedDescription)")
                    unpreparedFileNames.append(url.lastPathComponent)
                }
                self.renderCompletedCount += 1
                self.overallProgress = Double(self.renderCompletedCount) / Double(self.renderTotalCount) * 0.5
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            guard self.ownsUpload(generation) else { return }
            if !copyFailures.isEmpty {
                self.errorMessages.append("Metadata copy failed for \(copyFailures.count) \(copyFailures.count == 1 ? "image" : "images") — these renders were not uploaded")
            }
            if !overlayFailures.isEmpty {
                self.errorMessages.append("Sidecar metadata overlay failed for \(overlayFailures.count) \(overlayFailures.count == 1 ? "image" : "images") — these renders were not uploaded")
            }
            if !staleWarnings.isEmpty {
                self.errorMessages.append("\(staleWarnings.count) \(staleWarnings.count == 1 ? "image" : "images") used embedded metadata instead of the .xmp sidecar (the image file was edited more recently) — check if you expected sidecar values")
            }

            guard self.ownsUpload(generation) else { return }

            if let signingConfiguration, !renderedUploadURLs.isEmpty {
                var signingFailed = false
                for renderedURL in renderedUploadURLs {
                    do {
                        try Task.checkCancellation()
                        guard self.ownsUpload(generation) else { return }
                        try await execution.sign(signingConfiguration, renderedURL)
                        guard self.ownsUpload(generation) else { return }
                    } catch is CancellationError {
                        if self.uploadGeneration == generation { self.isRendering = false }
                        return
                    } catch {
                        guard self.ownsUpload(generation) else { return }
                        signingFailed = true
                        self.errorMessages.append("C2PA signing failed for \(renderedURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                guard !signingFailed else {
                    self.errorMessages.append("Upload stopped because every rendered file must be signed successfully.")
                    self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent))
                    return
                }
            }

            guard self.ownsUpload(generation) else { return }

            // Upload phase (50–100% of overall progress)
            self.isRendering = false
            self.isUploading = true
            self.totalCount = uploadURLs.count
            self.completedCount = 0
            self.activeRun?.plannedFileNames = uploadURLs.map(\.lastPathComponent)
            self.activeRun?.unpreparedFileNames = unpreparedFileNames

            for (index, url) in uploadURLs.enumerated() {
                guard self.ownsUpload(generation) else { return }
                do {
                    try await execution.upload(url, connection, password) { progress in
                        Task { @MainActor in
                            self.applyUploadProgress(progress, generation: generation, offset: 0.5, range: 0.5)
                        }
                    }
                    guard self.ownsUpload(generation) else { return }
                    self.markFileComplete(url.lastPathComponent, uploadWeightOffset: 0.5, uploadWeightRange: 0.5)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.ownsUpload(generation) else { return }
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                    if (error as? FTPService.FTPError)?.isServerLevel == true {
                        self.appendBatchAbortNotice(remaining: uploadURLs.count - index - 1)
                        break
                    }
                }
            }

            guard self.ownsUpload(generation) else { return }
            self.recordUploadCompletion(id: historyID)
            self.showCompletion(
                connection: connection,
                selectedCount: urls.count,
                plannedFileNames: uploadURLs.map(\.lastPathComponent),
                unpreparedFileNames: unpreparedFileNames
            )
        }
        return true
    }

    /// Admission checks that must pass before Keychain access, history creation, rendering, or
    /// network work. The insecure-transport check is intentionally below the SwiftUI
    /// confirmation so callers, future UI entry points, and restored actions can't bypass the
    /// first-use acknowledgement. Returns the password, or `nil` with `uploadAdmissionError` set.
    private func admitUpload(to connection: FTPConnection) -> String? {
        uploadAdmissionError = nil
        guard !connection.useSFTP else {
            uploadAdmissionError = FTPConnection.sftpUnavailableMessage
            return nil
        }
        guard !connection.requiresFirstInsecureUploadAcknowledgement else {
            uploadAdmissionError = "Acknowledge this insecure delivery connection before its first upload."
            return nil
        }
        guard let password = execution.password(connection.keychainKey), !password.isEmpty else {
            uploadAdmissionError = "No password found for \(connection.name). Edit the server in Settings ▸ FTP to enter it again."
            return nil
        }
        return password
    }

    /// Reserves a de-duplicated upload filename. The potentially blocking hard-link/copy that
    /// follows is owned by `FTPUploadFileSystemBoundary`.
    private func reserveUploadName(for url: URL, avoiding usedNames: inout Set<String>) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            if usedNames.insert(candidate).inserted {
                return candidate
            }
            counter += 1
        }
    }

    /// Appends a one-line notice that the batch was stopped early because the server
    /// was unreachable, so the user understands why later files show no result.
    private func appendBatchAbortNotice(remaining: Int) {
        guard remaining > 0 else { return }
        errorMessages.append("Stopped — \(remaining) more file\(remaining == 1 ? "" : "s") not uploaded because of the server error above.")
    }

    // MARK: - Progress Helpers

    /// Deterministically marks a file as fully uploaded once its `uploadFile` call has
    /// returned without throwing. Folds the per-file completion into both the visible
    /// progress map and `completedCount` synchronously on the main actor, so the activity
    /// record written right after the loop reflects every successful file — the trailing
    /// `isComplete` progress callback is delivered out-of-band and can't be relied on here.
    private func markFileComplete(_ fileName: String, uploadWeightOffset: Double = 0, uploadWeightRange: Double = 1.0) {
        let bytes = uploadProgress[fileName]?.totalBytes ?? 0
        uploadProgress[fileName] = FTPUploadProgress(
            fileName: fileName,
            bytesUploaded: bytes,
            totalBytes: bytes,
            fractionCompleted: 1.0,
            isComplete: true
        )
        completedCount += 1
        updateSmoothedProgress(uploadWeightOffset: uploadWeightOffset, uploadWeightRange: uploadWeightRange)
    }

    /// Computes smooth overall progress by interpolating per-file fractions.
    private func updateSmoothedProgress(uploadWeightOffset: Double = 0, uploadWeightRange: Double = 1.0) {
        let count = Double(max(totalCount, 1))
        let perFileContribution = uploadProgress.values.reduce(0.0) { $0 + $1.fractionCompleted }
        overallProgress = uploadWeightOffset + (perFileContribution / count) * uploadWeightRange
    }

    /// Shows the sticky completion state and records the upload to the shared
    /// activity history. The banner stays until the user confirms it (a new
    /// upload also replaces it), so the confirmation can't be missed.
    /// - Parameters:
    ///   - selectedCount: how many files the user asked to upload (not just those prepared).
    ///   - plannedFileNames: upload names that reached the transfer phase.
    ///   - unpreparedFileNames: selected files that failed before upload (render/staging).
    private func showCompletion(
        connection: FTPConnection,
        selectedCount: Int,
        plannedFileNames: [String],
        unpreparedFileNames: [String] = []
    ) {
        activeRun = nil
        isUploading = false
        isRendering = false
        uploadCompleted = true
        overallProgress = 1.0
        recordActivity(
            connection: connection,
            selectedCount: selectedCount,
            plannedFileNames: plannedFileNames,
            unpreparedFileNames: unpreparedFileNames
        )
    }

    /// Ends a run that stopped before uploading anything (inspection, staging or signing
    /// failed) in the same sticky terminal state as a finished upload, so the reasons in
    /// `errorMessages` stay visible after the sheet has closed.
    private func showStopped(connection: FTPConnection, selectedFileNames: [String]) {
        uploadStopped = true
        showCompletion(
            connection: connection,
            selectedCount: selectedFileNames.count,
            plannedFileNames: [],
            unpreparedFileNames: selectedFileNames
        )
        overallProgress = 0
    }

    /// Dismisses the sticky upload-completion banner (the green-check confirm action).
    func dismissUploadCompletion() {
        completionTask?.cancel()
        uploadCompleted = false
        uploadStopped = false
    }

    private func recordActivity(
        connection: FTPConnection,
        selectedCount: Int,
        plannedFileNames: [String],
        unpreparedFileNames: [String],
        wasCancelled: Bool = false
    ) {
        func record(_ fileName: String, succeeded: Bool) -> ActivityFileRecord {
            ActivityFileRecord(
                fileName: fileName,
                destination: connection.name,
                succeeded: succeeded,
                verification: .notApplicable
            )
        }
        // Every planned file is listed — including ones a server-level abort never reached —
        // plus the files that failed before upload, so failures aren't silently omitted.
        var seen: Set<String> = []
        var records: [ActivityFileRecord] = []
        for name in plannedFileNames where seen.insert(name).inserted {
            records.append(record(name, succeeded: uploadProgress[name]?.isComplete == true))
        }
        for name in unpreparedFileNames where seen.insert(name).inserted {
            records.append(record(name, succeeded: false))
        }
        records.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }

        let entry = ActivityEntry(
            kind: .upload,
            date: Date(),
            title: connection.name,
            successCount: completedCount,
            totalCount: max(selectedCount, records.count),
            wasCancelled: wasCancelled,
            deliveryTransportSecurity: connection.transportSecurity,
            files: records
        )
        activityHistory?.record(entry)
    }
}

extension Notification.Name {
    /// Posted (object: the `UserDefaults` store) after an `FTPViewModel` saves the server list.
    nonisolated static let ftpConnectionsDidChange = Notification.Name("FTPViewModel.connectionsDidChange")
}
