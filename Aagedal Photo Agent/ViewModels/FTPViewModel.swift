import Foundation
import os

nonisolated private let ftpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "FTPViewModel")

/// Injectable execution boundaries keep upload lifecycle tests independent of credentials,
/// network services, rendering hardware, and signing tools.
nonisolated struct FTPUploadExecutionAccess: Sendable {
    var password: @MainActor @Sendable (String) -> String? = { KeychainService.load(forKey: $0) }
    var upload: @Sendable (URL, FTPConnection, String, @escaping @Sendable (FTPUploadProgress) -> Void) async throws -> FTPUploadOutcome = { url, connection, password, progress in
        try await FTPService().uploadFile(localURL: url, connection: connection, password: password, progressHandler: progress)
    }
    /// Renders `<source basename>.jpg` into the output folder, replacing the app's own earlier
    /// render of the same source, so re-sending a photo uploads it under the same name instead
    /// of a new numbered copy (which newsroom systems would ingest as a second photo).
    var render: @MainActor @Sendable (URL, CameraRawSettings?, URL, URL?, any MetadataWriteEngine, MetadataFailureTracker) async throws -> URL = { source, raw, output, folder, engine, tracker in
        try await EditExportPipeline.renderForDelivery(sourceURL: source, cameraRaw: raw, kind: .jpeg, outputFolder: output, folderURL: folder, writeEngine: engine, failureTracker: tracker, collisionPolicy: .replaceExisting)
    }
    var sign: @Sendable (C2PAUploadSigningConfiguration, URL) async throws -> Void = { configuration, url in
        try await configuration.sign(url)
    }
    /// Develop settings stored in each file's own `.xmp` sidecar (pair ownership applied), read
    /// fresh at upload time for the redaction check — independent of the browser's copy.
    var loadSidecarDevelop: @Sendable ([URL]) async -> [URL: CameraRawSettings] = { urls in
        await FTPUploadRedaction.loadSidecarDevelop(urls)
    }
    /// Applies the source's sidecar metadata (the export overlay) onto a staged private copy
    /// of an as-is upload. Never called with the user's original as the destination.
    var overlay: @MainActor @Sendable (URL, URL, any MetadataWriteEngine) async -> SidecarIPTCOverlay.Outcome = { source, staged, engine in
        await FTPUploadExecutionAccess.applyAsIsOverlay(source: source, staged: staged, engine: engine) {
            await FTPUploadView.mayCarryC2PA($0)
        }
    }

    /// Never rewrites a credentialed file's metadata (that would break its C2PA signature):
    /// the staged copy then uploads byte-identical to the signed original.
    @MainActor
    static func applyAsIsOverlay(source: URL, staged: URL, engine: any MetadataWriteEngine,
                                 isCredentialed: (URL) async -> Bool) async -> SidecarIPTCOverlay.Outcome {
        guard await !isCredentialed(source) else { return .noPendingEdits }
        return await SidecarIPTCOverlay.apply(sourceURL: source, renderedURL: staged,
            folderURL: source.deletingLastPathComponent(), writeEngine: engine)
    }
}

/// Anonymizer facts for the FTP render decision. An as-is upload sends the original pixels, so
/// a photo with an active Anonymizer (a redaction mask, the global Anonymizer, or Black Out) must
/// always be rendered — whatever "Skip automatic rendering" or "Always render RAW" say.
nonisolated enum FTPUploadRedaction {
    static func isActive(_ settings: CameraRawSettings?) -> Bool {
        guard let settings else { return false }
        if settings.anonymizer?.isEmpty == false { return true }
        return settings.localAdjustments?.contains {
            $0.enabled && $0.anonymizer?.isEmpty == false
        } ?? false
    }

    /// Any carrier counts: the settings the renderer will use, the browser's live copy, the
    /// file's embedded Develop record and its `.xmp` sidecar. A stale or partially parsed copy
    /// in one place must not turn a redacted photo into an as-is upload.
    static func isRedacted(_ carriers: [CameraRawSettings?]) -> Bool {
        carriers.contains(where: isActive)
    }

    @concurrent
    static func loadSidecarDevelop(_ urls: [URL]) async -> [URL: CameraRawSettings] {
        var result: [URL: CameraRawSettings] = [:]
        for url in urls {
            if Task.isCancelled { break }
            if let settings = PhotoSidecarOwnership.applyingDevelopOwnership(
                XMPSidecarService().loadSidecar(for: url), for: url)?.cameraRaw {
                result[url] = settings
            }
        }
        return result
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

    /// Always a real copy (an APFS clone where available), never a hard link: the staged file
    /// receives a metadata write and/or a C2PA signature, which must not reach the user's original
    /// through a shared inode.
    func stageCopyForMetadataOverlay(
        _ sourceURL: URL,
        as fileName: String,
        in temporaryDirectory: URL,
        index: Int
    ) throws -> FTPPreparedUploadFile {
        try Task.checkCancellation()
        let itemDirectory = temporaryDirectory.appendingPathComponent("m\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: true)
        let destinationURL = itemDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return FTPPreparedUploadFile(
            url: destinationURL,
            wasStaged: true,
            usedCopyFallback: true,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
    }

    /// Moves a render into its deterministic place in the `Uploaded` folder, replacing the
    /// app's own earlier render under that name. Used only when two sources in one batch would
    /// render to the same name (e.g. a RAW+JPEG pair), so the second one gets `<base>-2.jpg`.
    func moveRenderedFile(_ sourceURL: URL, to destinationURL: URL) throws -> FTPPreparedUploadFile {
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return FTPPreparedUploadFile(
            url: destinationURL,
            wasStaged: true,
            usedCopyFallback: false,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
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
    /// Why each file of the current/last run didn't arrive, keyed by the name shown in the
    /// progress list (the upload name, or the source name when it failed before upload).
    var uploadFailures: [String: String] = [:]
    /// Source files of the last finished run that didn't arrive (failed, not prepared, or not
    /// reached after a batch stop). "Retry Failed" re-sends exactly these.
    var failedSourceURLs: [URL] = []
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
    /// The user pressed "Reset Server Compatibility" in the open form.
    @ObservationIgnored private var editingCompatibilityReset = false

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
    /// The transfer running alongside the next file's render (render/upload pipelining).
    /// Cancelled with the run so Cancel stops curl immediately.
    @ObservationIgnored private var inFlightTransfer: Task<FileTransferResult, Never>?
    /// Restarts the last run's request for a subset of its sources with the same settings.
    @ObservationIgnored private var retryLauncher: ((_ sources: [URL]) -> Bool)?
    /// How `overallProgress` is computed: uploads only, or render (first half) + upload.
    @ObservationIgnored private var progressIncludesRendering = false

    private enum FileTransferResult {
        case succeeded(FTPUploadOutcome)
        case failed(any Error)
        case cancelled
    }

    var canRetryFailed: Bool {
        uploadCompleted && !failedSourceURLs.isEmpty && retryLauncher != nil
    }
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

    private func applyUploadProgress(_ progress: FTPUploadProgress, generation: UUID) {
        guard uploadGeneration == generation, isUploading, !uploadCompleted,
              uploadProgress[progress.fileName]?.isComplete != true,
              uploadFailures[progress.fileName] == nil,
              progress.fractionCompleted >= (uploadProgress[progress.fileName]?.fractionCompleted ?? 0) else { return }
        uploadProgress[progress.fileName] = progress
        updateSmoothedProgress()
    }

    deinit {
        uploadTask?.cancel()
        inFlightTransfer?.cancel()
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
        editingCompatibilityReset = false
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
        var connection = editingConnection
        // Test what Save would store ("ftp://host:2121/in" → host, port, folder).
        connection.normalizeHostInput()
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
                self.connectionTest = .failure(Self.connectionTestFailureReason(for: error))
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
        editingConnection.normalizeHostInput()
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
        let resetCompatibility = editingCompatibilityReset
        mutateStoredConnections { stored in
            if let index = stored.firstIndex(where: { $0.id == edited.id }) {
                var merged = edited
                // The other window may have acknowledged this exact transport since the form
                // opened; keep that unless the form changed the transport itself.
                if merged.firstUploadAcknowledgedSecurity == nil,
                   stored[index].transportSecurity == edited.transportSecurity {
                    merged.firstUploadAcknowledgedSecurity = stored[index].firstUploadAcknowledgedSecurity
                }
                // Rename/temporary-name support is a property of the server account: keep what
                // uploads learned meanwhile (the stored copy is newer than the form's), forget
                // it when the form points at another server/user or the user reset it.
                let sameAccount = stored[index].host.caseInsensitiveCompare(edited.host) == .orderedSame
                    && stored[index].port == edited.port
                    && stored[index].username == edited.username
                merged.resetServerCompatibility()
                if sameAccount, !resetCompatibility {
                    merged.serverRefusesRename = stored[index].serverRefusesRename
                    merged.serverRefusesTemporaryName = stored[index].serverRefusesTemporaryName
                    merged.renameRefusalCount = stored[index].renameRefusalCount
                    merged.lastRenameRefusalFileName = stored[index].lastRenameRefusalFileName
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

    /// Persists what an upload of `fileName` learned about the server's temporary-name and
    /// rename support (see `FTPConnection.learnServerCompatibility`).
    func learnServerCompatibility(connectionID: UUID, outcome: FTPUploadOutcome, fileName: String) {
        guard outcome != FTPUploadOutcome() else { return }
        var learned: FTPConnection?
        guard var probe = storedConnections()?.first(where: { $0.id == connectionID }) ?? connections.first(where: { $0.id == connectionID }),
              probe.learnServerCompatibility(from: outcome, fileName: fileName) else { return }
        mutateStoredConnections { stored in
            guard let index = stored.firstIndex(where: { $0.id == connectionID }) else { return }
            stored[index].learnServerCompatibility(from: outcome, fileName: fileName)
            learned = stored[index]
        }
        if let learned, isShowingServerForm, editingConnection.id == connectionID {
            editingConnection.serverRefusesRename = learned.serverRefusesRename
            editingConnection.serverRefusesTemporaryName = learned.serverRefusesTemporaryName
        }
    }

    /// The form's "Reset Server Compatibility": the next Save clears what uploads learned.
    func resetEditingServerCompatibility() {
        editingConnection.resetServerCompatibility()
        editingCompatibilityReset = true
    }

    /// Re-sends only the files of the last run that didn't arrive, with the same settings.
    @discardableResult
    func retryFailedUploads() -> Bool {
        guard canRetryFailed, let retryLauncher else { return false }
        return retryLauncher(failedSourceURLs)
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
        inFlightTransfer?.cancel()
        inFlightTransfer = nil
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
        let connectionID = connection.id
        retryLauncher = { [weak self] sources in
            guard let self else { return false }
            return self.uploadFiles(sources, to: self.latestConnection(connectionID, fallback: connection))
        }

        resetRunState(totalCount: urls.count, includesRendering: false)
        isUploading = true
        isRendering = false

        uploadTask?.cancel()
        inFlightTransfer?.cancel()
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
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent),
                                 sources: urls)
                return
            }
            var activeConnection = connection
            var delivered: Set<URL> = []
            uploadLoop: for (index, url) in urls.enumerated() {
                guard self.ownsUpload(generation) else { return }
                let result = await self.transfer(url, connection: activeConnection,
                                                 password: password, generation: generation)
                guard self.ownsUpload(generation) else { return }
                switch result {
                case .cancelled:
                    return
                case .succeeded(let outcome):
                    if activeConnection.learnServerCompatibility(from: outcome, fileName: url.lastPathComponent) {
                        self.learnServerCompatibility(connectionID: connection.id, outcome: outcome,
                                                      fileName: url.lastPathComponent)
                    }
                    // Count completion here, on the awaited result, rather than from the
                    // background progress callback: the callback is delivered via an
                    // unstructured Task that may not have drained by the time the loop
                    // finishes and recordActivity() reads completedCount.
                    self.markFileComplete(url.lastPathComponent)
                    delivered.insert(url)
                case .failed(let error):
                    self.recordUploadFailure(url.lastPathComponent, error: error)
                    // The server is unreachable / rejecting auth — every remaining file
                    // would fail identically, so stop rather than retrying each in turn.
                    if (error as? FTPService.FTPError)?.isServerLevel ?? false {
                        self.markNotSent(urls[(index + 1)...].map(\.lastPathComponent))
                        break uploadLoop
                    }
                }
            }
            guard self.ownsUpload(generation) else { return }
            self.recordUploadCompletion(id: historyID)
            self.failedSourceURLs = urls.filter { !delivered.contains($0) }
            self.showCompletion(
                connection: connection,
                selectedCount: urls.count,
                plannedFileNames: urls.map(\.lastPathComponent)
            )
        }
        return true
    }

    /// Uploads `urls`, rendering to JPEG the files in `renderURLs` — plus every file with an
    /// active Anonymizer, which the run re-checks itself from freshly read Develop settings — and
    /// sending every other file as its original. Non-rendered originals upload in place unless a
    /// name collision, a metadata overlay or C2PA signing forces staging a private copy (the
    /// user's real files are never moved, renamed, rewritten or signed).
    /// `sidecarOverlayURLs` are as-is files whose sidecar (or pending draft) carries descriptive
    /// metadata the embedded copy lacks: they upload as a private staged copy with the export
    /// overlay applied, so the server receives what the metadata panel shows. With signing on,
    /// that staged copy is signed after the overlay.
    ///
    /// Renders are named deterministically — `Uploaded/<source basename>.jpg`, replacing the
    /// app's own earlier render — so re-sending a photo replaces it on the server instead of
    /// adding a numbered duplicate. Only two sources of one batch that would share a name get a
    /// `-2`, `-3`… suffix.
    ///
    /// Rendering and uploading are pipelined: file N uploads while file N+1 renders and signs
    /// (a buffer of one prepared file). C2PA signing happens per file, before its upload.
    @discardableResult
    func uploadFiles(
        _ urls: [URL],
        renderURLs: Set<URL>,
        sidecarOverlayURLs: Set<URL> = [],
        to connection: FTPConnection,
        readService: SwiftExifReadService,
        writeEngine: any MetadataWriteEngine,
        inMemoryCameraRaw: @escaping @MainActor (URL) -> CameraRawSettings?,
        signingConfiguration: C2PAUploadSigningConfiguration? = nil
    ) -> Bool {
        let overlayTargets = Set(urls.filter { sidecarOverlayURLs.contains($0) && !renderURLs.contains($0)
            && !SupportedImageFormats.isRaw(url: $0) })
        // No as-is fast path: whether a file may leave as its original depends on the redaction
        // check below, which needs file reads. Retry Failed replays this request, so a photo
        // anonymized after the first attempt is rendered on retry too.
        guard let password = admitUpload(to: connection) else { return false }

        let historyID = UUID()
        let historyStartedAt = Date()
        activeRun = ActiveUploadRun(
            connection: connection,
            selectedCount: urls.count,
            plannedFileNames: []
        )
        let connectionID = connection.id
        retryLauncher = { [weak self] sources in
            guard let self else { return false }
            let subset = Set(sources)
            return self.uploadFiles(
                sources,
                renderURLs: renderURLs.intersection(subset),
                sidecarOverlayURLs: sidecarOverlayURLs.intersection(subset),
                to: self.latestConnection(connectionID, fallback: connection),
                readService: readService,
                writeEngine: writeEngine,
                inMemoryCameraRaw: inMemoryCameraRaw,
                signingConfiguration: signingConfiguration
            )
        }

        resetRunState(totalCount: urls.count, includesRendering: true)
        isRendering = true
        isUploading = false
        renderTotalCount = urls.filter { renderURLs.contains($0) }.count

        uploadTask?.cancel()
        inFlightTransfer?.cancel()
        let generation = UUID()
        uploadGeneration = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }

            // Read every file's Develop settings the way the local export paths do (live
            // in-memory CameraRaw first, the XMP sidecar for RAW files): they are the render
            // inputs, and they decide which files are redacted and must not go out as-is.
            var metadataMap: [URL: IPTCMetadata] = [:]
            do {
                metadataMap = try await readService.readBatchFullMetadata(urls: urls)
            } catch {
                guard self.ownsUpload(generation) else { return }
                // Continue without embedded metadata; live and sidecar settings still apply.
            }
            guard self.ownsUpload(generation) else { return }
            let embeddedMap = metadataMap
            do {
                try await EditExportPipeline.resolveCameraRaw(
                    into: &metadataMap,
                    urls: urls,
                    inMemory: inMemoryCameraRaw
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                // The production sidecar boundary is best-effort and does not throw read errors.
            }
            guard self.ownsUpload(generation) else { return }
            let sidecarDevelop = await self.execution.loadSidecarDevelop(urls)
            guard self.ownsUpload(generation) else { return }
            let redactedURLs = Set(urls.filter { url in
                FTPUploadRedaction.isRedacted([
                    metadataMap[url]?.cameraRaw,
                    embeddedMap[url]?.cameraRaw,
                    inMemoryCameraRaw(url),
                    sidecarDevelop[url],
                ])
            })
            let effectiveRenderURLs = renderURLs.union(redactedURLs)
            let renderTargets = urls.filter { effectiveRenderURLs.contains($0) }
            self.renderTotalCount = renderTargets.count
            if renderTargets.isEmpty {
                self.progressIncludesRendering = false
                self.isRendering = false
            }

            do {
                let inventory = try await fileSystem.inventory(
                    for: urls,
                    fallbackDate: historyStartedAt
                )
                guard self.ownsUpload(generation) else { return }
                self.recordUploadStart(
                    inventory: inventory,
                    connection: connection,
                    didRenderJPEG: !renderTargets.isEmpty,
                    id: historyID,
                    startedAt: historyStartedAt
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.ownsUpload(generation) else { return }
                self.errorMessages = ["Failed to inspect upload files: \(error.localizedDescription)"]
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent),
                                 sources: urls)
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
                self.showStopped(connection: connection, selectedFileNames: urls.map(\.lastPathComponent),
                                 sources: urls)
                return
            }

            defer {
                fileSystem.removeEventually(tempDir)
            }

            guard self.ownsUpload(generation) else { return }

            let failureTracker = MetadataFailureTracker()
            // Upload filenames already taken in this batch, so two sources that share a
            // basename across folders (e.g. /A/img.jpg and /B/img.jpg) don't overwrite each
            // other on the remote server.
            var usedNames: Set<String> = []
            // `Uploaded/<base>` render targets already claimed in this batch (lowercased: the
            // volume is usually case-insensitive), so a RAW+JPEG pair can't render onto — or
            // replace mid-upload — the same local file.
            var claimedRenderTargets: Set<String> = []
            var activeConnection = connection
            var delivered: Set<URL> = []
            var serverStopped = false
            var signingStopped = false
            // The prepared file currently uploading, if any.
            var pending: (url: URL, source: URL, task: Task<FileTransferResult, Never>)?

            /// Waits for the in-flight upload and records its result. Returns false when the
            /// run no longer owns the UI (cancelled/restarted).
            @MainActor func settlePending() async -> Bool {
                guard let current = pending else { return true }
                let result = await current.task.value
                pending = nil
                guard self.ownsUpload(generation) else { return false }
                self.inFlightTransfer = nil
                switch result {
                case .cancelled:
                    return false
                case .succeeded(let outcome):
                    let fileName = current.url.lastPathComponent
                    if activeConnection.learnServerCompatibility(from: outcome, fileName: fileName) {
                        self.learnServerCompatibility(connectionID: connection.id, outcome: outcome,
                                                      fileName: fileName)
                    }
                    self.markFileComplete(fileName)
                    delivered.insert(current.source)
                case .failed(let error):
                    self.recordUploadFailure(current.url.lastPathComponent, error: error)
                    if (error as? FTPService.FTPError)?.isServerLevel ?? false {
                        serverStopped = true
                    }
                }
                return true
            }

            @MainActor func notPrepared(_ url: URL, reason: String) {
                self.activeRun?.unpreparedFileNames.append(url.lastPathComponent)
                self.uploadFailures[url.lastPathComponent] = reason
                self.totalCount = max(self.totalCount - 1, 0)
            }

            for (index, url) in urls.enumerated() {
                guard self.ownsUpload(generation) else { return }
                if serverStopped || signingStopped {
                    notPrepared(url, reason: serverStopped
                        ? "Not sent — stopped after the server error above."
                        : "Not sent — upload stopped because a file couldn't be signed.")
                    continue
                }

                // Prepare file N (render/stage/sign) while file N-1 uploads.
                var prepared: URL?
                let isRender = effectiveRenderURLs.contains(url)
                do {
                    if isRender, redactedURLs.contains(url),
                       !RedactionUnion.covers(render: metadataMap[url]?.cameraRaw, saved: [
                           // The same reconciled saved copy export resolution uses.
                           ExportCameraRawSourcePolicy.persisted(
                               imageURL: url, sidecar: sidecarDevelop[url],
                               embedded: embeddedMap[url]?.cameraRaw),
                           inMemoryCameraRaw(url),
                       ]) {
                        // A saved Anonymizer the render inputs don't carry would publish the
                        // face un-redacted. Refuse rather than guess which copy is current.
                        // (The same check runs again inside `EditExportPipeline.renderItem`,
                        // against what is on disk at render time.)
                        self.errorMessages.append("\(url.lastPathComponent) has a saved Anonymizer that its current Develop settings don't include. It was not uploaded — open it in Develop, check the redaction, and upload again.")
                        notPrepared(url, reason: "Redaction couldn't be confirmed — not uploaded.")
                    } else if isRender {
                        prepared = try await self.renderForUpload(
                            url, index: index, tempDir: tempDir,
                            cameraRaw: metadataMap[url]?.cameraRaw,
                            writeEngine: writeEngine, failureTracker: failureTracker,
                            usedNames: &usedNames, claimedRenderTargets: &claimedRenderTargets,
                            signingConfiguration: signingConfiguration, generation: generation)
                    } else if overlayTargets.contains(url) || signingConfiguration != nil {
                        // Upload a private copy: it receives the sidecar's metadata and/or the
                        // C2PA signature (overlay first, so the credential covers it). The
                        // user's original is never rewritten or signed.
                        let stagedName = usedNames.insert(url.lastPathComponent).inserted
                            ? url.lastPathComponent
                            : self.reserveUploadName(for: url, avoiding: &usedNames)
                        let staged = try await fileSystem.stageCopyForMetadataOverlay(
                            url, as: stagedName, in: tempDir, index: index)
                        guard self.ownsUpload(generation) else { return }
                        var overlayed: URL? = staged.url
                        if overlayTargets.contains(url) {
                            switch await execution.overlay(url, staged.url, writeEngine) {
                            case .applied, .noPendingEdits:
                                break
                            case .staleSidecarSkipped:
                                await failureTracker.recordStaleSidecar(url.lastPathComponent)
                            case .failed:
                                await failureTracker.recordOverlayFailure(url.lastPathComponent)
                                guard self.ownsUpload(generation) else { return }
                                notPrepared(url, reason: "Sidecar metadata couldn't be applied — not uploaded.")
                                overlayed = nil
                            }
                            guard self.ownsUpload(generation) else { return }
                        }
                        if let overlayed, let signingConfiguration {
                            try await self.signForUpload(overlayed, configuration: signingConfiguration,
                                                         generation: generation)
                        }
                        prepared = overlayed
                    } else if usedNames.insert(url.lastPathComponent).inserted {
                        // Upload the untouched original in place.
                        prepared = url
                    } else {
                        // Name collision: stage a hard link/copy under a reserved name.
                        let stagedName = self.reserveUploadName(for: url, avoiding: &usedNames)
                        prepared = try await fileSystem.stageOriginal(
                            url, as: stagedName, in: tempDir, index: index).url
                    }
                } catch is CancellationError {
                    if self.uploadGeneration == generation { self.isRendering = false }
                    return
                } catch let error as FTPUploadSigningFailure {
                    guard self.ownsUpload(generation) else { return }
                    self.errorMessages.append("C2PA signing failed for \(error.fileName): \(error.underlying.localizedDescription)")
                    notPrepared(url, reason: "C2PA signing failed — not uploaded.")
                    signingStopped = true
                } catch {
                    guard self.ownsUpload(generation) else { return }
                    self.errorMessages.append("Failed to prepare \(url.lastPathComponent): \(error.localizedDescription)")
                    notPrepared(url, reason: "Couldn't be prepared: \(error.localizedDescription)")
                }
                guard self.ownsUpload(generation) else { return }
                if isRender {
                    self.renderCompletedCount += 1
                    self.updateSmoothedProgress()
                }

                // Hand the prepared file to the uploader once the previous upload finished.
                guard await settlePending() else { return }
                guard let prepared else { continue }
                if serverStopped || signingStopped {
                    notPrepared(url, reason: serverStopped
                        ? "Not sent — stopped after the server error above."
                        : "Not sent — upload stopped because a file couldn't be signed.")
                    continue
                }
                self.isUploading = true
                self.activeRun?.plannedFileNames.append(prepared.lastPathComponent)
                let uploadConnection = activeConnection
                let task = Task { [weak self] () -> FileTransferResult in
                    guard let self else { return .cancelled }
                    return await self.transfer(prepared, connection: uploadConnection,
                                               password: password, generation: generation)
                }
                self.inFlightTransfer = task
                pending = (prepared, url, task)
            }
            guard self.ownsUpload(generation) else { return }
            self.isRendering = false
            guard await settlePending() else { return }
            guard self.ownsUpload(generation) else { return }

            let copyFailures = await failureTracker.metadataCopyFailures
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            let staleWarnings = await failureTracker.staleSidecarWarnings
            let watermarkWarnings = await failureTracker.missingWatermarkWarnings
            guard self.ownsUpload(generation) else { return }
            if !copyFailures.isEmpty {
                self.errorMessages.append("Metadata copy failed for \(copyFailures.count) \(copyFailures.count == 1 ? "image" : "images") — these renders were not uploaded")
            }
            if !overlayFailures.isEmpty {
                self.errorMessages.append("Sidecar metadata overlay failed for \(overlayFailures.count) \(overlayFailures.count == 1 ? "image" : "images") — these files were not uploaded")
            }
            if !staleWarnings.isEmpty {
                self.errorMessages.append("\(staleWarnings.count) \(staleWarnings.count == 1 ? "image" : "images") used embedded metadata instead of the .xmp sidecar (the image file was edited more recently) — check if you expected sidecar values")
            }
            if !watermarkWarnings.isEmpty {
                self.errorMessages.append("\(watermarkWarnings.count) \(watermarkWarnings.count == 1 ? "image was" : "images were") uploaded without a watermark whose library image is missing (deleted or not yet synced): \(watermarkWarnings.joined(separator: ", "))")
            }
            if serverStopped {
                self.appendBatchAbortNotice(remaining: self.notSentCount())
            }
            if signingStopped {
                self.errorMessages.append("Upload stopped because every file must be signed successfully.")
                self.uploadStopped = true
            }

            self.recordUploadCompletion(id: historyID)
            self.failedSourceURLs = urls.filter { !delivered.contains($0) }
            let run = self.activeRun
            self.showCompletion(
                connection: connection,
                selectedCount: urls.count,
                plannedFileNames: run?.plannedFileNames ?? [],
                unpreparedFileNames: run?.unpreparedFileNames ?? []
            )
        }
        return true
    }

    /// Renders one source into its deterministic `Uploaded/<base>.jpg`, resolves batch name
    /// collisions, and signs it (before any hard-linked staging, so the link sees the signed
    /// bytes). Returns the file to upload; its last path component is the remote name.
    private func renderForUpload(
        _ url: URL,
        index: Int,
        tempDir: URL,
        cameraRaw: CameraRawSettings?,
        writeEngine: any MetadataWriteEngine,
        failureTracker: MetadataFailureTracker,
        usedNames: inout Set<String>,
        claimedRenderTargets: inout Set<String>,
        signingConfiguration: C2PAUploadSigningConfiguration?,
        generation: UUID
    ) async throws -> URL? {
        let uploadedDir = url.deletingLastPathComponent()
            .appendingPathComponent("Uploaded", isDirectory: true)
        try await fileSystem.ensureDirectory(uploadedDir)
        guard ownsUpload(generation) else { throw CancellationError() }

        let base = url.deletingPathExtension().lastPathComponent
        let renderKey = Self.renderTargetKey(folder: uploadedDir, base: base)
        let collidesLocally = !claimedRenderTargets.insert(renderKey).inserted
        // A second source with the same basename renders privately first, then moves to a
        // reserved `<base>-N.jpg`, so it never replaces the first one's render (possibly
        // while that file is still uploading).
        let renderFolder: URL
        if collidesLocally {
            renderFolder = tempDir.appendingPathComponent("r\(index)", isDirectory: true)
            try await fileSystem.ensureDirectory(renderFolder)
        } else {
            renderFolder = uploadedDir
        }
        var outputURL = try await execution.render(
            url, cameraRaw, renderFolder, url.deletingLastPathComponent(), writeEngine, failureTracker)
        guard ownsUpload(generation) else { throw CancellationError() }

        if collidesLocally {
            let name = reserveUploadName(for: outputURL, avoiding: &usedNames)
            claimedRenderTargets.insert(Self.renderTargetKey(
                folder: uploadedDir, base: (name as NSString).deletingPathExtension))
            outputURL = try await fileSystem.moveRenderedFile(
                outputURL, to: uploadedDir.appendingPathComponent(name)).url
            guard ownsUpload(generation) else { throw CancellationError() }
        }
        if !renderedUploadedFolders.contains(uploadedDir) {
            renderedUploadedFolders.append(uploadedDir)
        }

        if let signingConfiguration {
            try await signForUpload(outputURL, configuration: signingConfiguration, generation: generation)
        }

        if !collidesLocally, !usedNames.insert(outputURL.lastPathComponent).inserted {
            // Same name as a file from another folder in this batch: upload a staged link
            // under a reserved remote name; the local render keeps its deterministic name.
            let name = reserveUploadName(for: outputURL, avoiding: &usedNames)
            outputURL = try await fileSystem.stageOriginal(outputURL, as: name, in: tempDir, index: index).url
        }
        return outputURL
    }

    /// Signs an app-owned upload file (a render or a staged copy — never the user's original).
    private func signForUpload(
        _ url: URL,
        configuration: C2PAUploadSigningConfiguration,
        generation: UUID
    ) async throws {
        try Task.checkCancellation()
        do {
            try await execution.sign(configuration, url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FTPUploadSigningFailure(fileName: url.lastPathComponent, underlying: error)
        }
        guard ownsUpload(generation) else { throw CancellationError() }
    }

    private nonisolated static func renderTargetKey(folder: URL, base: String) -> String {
        folder.standardizedFileURL.path.lowercased() + "/" + base.lowercased()
    }

    /// Runs one transfer and folds late results out once the run no longer owns the UI.
    private func transfer(
        _ url: URL,
        connection: FTPConnection,
        password: String,
        generation: UUID
    ) async -> FileTransferResult {
        do {
            let outcome = try await execution.upload(url, connection, password) { [weak self] progress in
                Task { @MainActor in
                    self?.applyUploadProgress(progress, generation: generation)
                }
            }
            return .succeeded(outcome)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error)
        }
    }

    private struct FTPUploadSigningFailure: Error {
        let fileName: String
        let underlying: any Error
    }

    private func latestConnection(_ id: UUID, fallback: FTPConnection) -> FTPConnection {
        connections.first { $0.id == id } ?? fallback
    }

    private func resetRunState(totalCount: Int, includesRendering: Bool) {
        uploadCompleted = false
        uploadStopped = false
        errorMessages = []
        completedCount = 0
        renderCompletedCount = 0
        renderTotalCount = 0
        self.totalCount = totalCount
        uploadProgress = [:]
        uploadFailures = [:]
        failedSourceURLs = []
        overallProgress = 0
        renderedUploadedFolders = []
        progressIncludesRendering = includesRendering
    }

    /// Records why a file didn't arrive: shown on its row in the progress list, in the error
    /// list, and in Activity.
    private func recordUploadFailure(_ fileName: String, error: any Error) {
        let reason = Self.failureReason(for: error)
        uploadFailures[fileName] = reason
        errorMessages.append("Couldn't upload \(fileName). \(reason)")
    }

    private func markNotSent(_ fileNames: [String]) {
        for name in fileNames where uploadFailures[name] == nil && uploadProgress[name]?.isComplete != true {
            uploadFailures[name] = "Not sent — stopped after the server error above."
        }
        appendBatchAbortNotice(remaining: fileNames.count)
    }

    private func notSentCount() -> Int {
        uploadFailures.values.filter { $0.hasPrefix("Not sent") }.count
    }

    /// Like `failureReason`, but a curl failure without a connection-level category (which
    /// `failureCategory` files under `.fileRejected`, "the server did not accept the file") keeps
    /// the exit-code wording, without curl's raw diagnostic, instead of reading as a rejected file.
    private static func connectionTestFailureReason(for error: any Error) -> String {
        if let ftpError = error as? FTPService.FTPError, ftpError.category == .fileRejected,
           case .connectionTestFailed(let code, _) = ftpError {
            return FTPService.FTPError.connectionTestFailed(code, "").localizedDescription
        }
        return failureReason(for: error)
    }

    /// A short, user-facing reason for one failed file, shown on its row and in `errorMessages`.
    private static func failureReason(for error: any Error) -> String {
        if let ftpError = error as? FTPService.FTPError {
            if let category = ftpError.category { return category.userMessage }
            return ftpError.localizedDescription
        }
        return error.localizedDescription
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
    private func markFileComplete(_ fileName: String) {
        let bytes = uploadProgress[fileName]?.totalBytes ?? 0
        uploadProgress[fileName] = FTPUploadProgress(
            fileName: fileName,
            bytesUploaded: bytes,
            totalBytes: bytes,
            fractionCompleted: 1.0,
            isComplete: true
        )
        uploadFailures[fileName] = nil
        completedCount += 1
        updateSmoothedProgress()
    }

    /// Computes smooth overall progress by interpolating per-file fractions. When the run also
    /// renders, rendering fills the first half and uploading the second; with pipelining both
    /// advance together.
    private func updateSmoothedProgress() {
        let count = Double(max(totalCount, 1))
        let perFileContribution = uploadProgress.values.reduce(0.0) { $0 + $1.fractionCompleted }
        let uploadFraction = min(perFileContribution / count, 1)
        if progressIncludesRendering {
            let renderFraction = renderTotalCount == 0
                ? 1
                : Double(renderCompletedCount) / Double(renderTotalCount)
            overallProgress = renderFraction * 0.5 + uploadFraction * 0.5
        } else {
            overallProgress = uploadFraction
        }
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
        inFlightTransfer = nil
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

    /// Ends a run that stopped before uploading anything (inspection or staging failed) in
    /// the same sticky terminal state as a finished upload, so the reasons in
    /// `errorMessages` stay visible after the sheet has closed.
    private func showStopped(connection: FTPConnection, selectedFileNames: [String], sources: [URL]) {
        uploadStopped = true
        failedSourceURLs = sources
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
                verification: .notApplicable,
                statusDetail: succeeded ? nil : uploadFailures[fileName]
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
