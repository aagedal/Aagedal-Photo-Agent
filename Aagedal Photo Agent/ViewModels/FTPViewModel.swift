import Foundation
import os

nonisolated private let ftpLog = Logger(subsystem: "com.aagedal.photo-agent", category: "FTPViewModel")

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

    var isShowingServerForm = false
    var editingConnection = FTPConnection()
    var editingPassword = ""

    var uploadHistory = FTPUploadHistory()

    /// Shared import/upload activity log. Assigned by the owner (ContentView).
    @ObservationIgnored var activityHistory: ActivityHistoryStore?

    private let ftpService = FTPService()
    private let connectionsKey = UserDefaultsKeys.ftpConnections
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?

    deinit {
        uploadTask?.cancel()
        completionTask?.cancel()
    }

    func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: connectionsKey) else { return }
        do {
            connections = try JSONDecoder().decode([FTPConnection].self, from: data)
        } catch {
            ftpLog.error("Failed to decode FTP connections: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Verify the selected connection still exists after reload
        if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
            selectedConnectionID = nil
        }

        restoreLastUsedConnection()
    }

    func saveConnections() {
        do {
            let data = try JSONEncoder().encode(connections)
            UserDefaults.standard.set(data, forKey: connectionsKey)
        } catch {
            ftpLog.error("Failed to encode FTP connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveLastUsedConnectionID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: UserDefaultsKeys.lastUsedFTPConnectionID)
    }

    func restoreLastUsedConnection() {
        guard selectedConnectionID == nil,
              let idString = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastUsedFTPConnectionID),
              let id = UUID(uuidString: idString),
              connections.contains(where: { $0.id == id }) else {
            return
        }
        selectedConnectionID = id
    }

    func startEditingConnection(_ connection: FTPConnection? = nil) {
        editingConnection = connection ?? FTPConnection()
        editingPassword = connection.flatMap { KeychainService.load(forKey: $0.keychainKey) } ?? ""
        isShowingServerForm = true
    }

    func saveEditingConnection() {
        // Save password to keychain
        do {
            try KeychainService.save(password: editingPassword, forKey: editingConnection.keychainKey)
        } catch {
            ftpLog.error("Keychain save failed for \(self.editingConnection.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessages = ["Failed to save password: \(error.localizedDescription)"]
        }

        if let index = connections.firstIndex(where: { $0.id == editingConnection.id }) {
            connections[index] = editingConnection
        } else {
            connections.append(editingConnection)
        }
        // Keep selectedConnectionID in sync if the user edited the currently selected one
        if selectedConnectionID == editingConnection.id {
            selectedConnectionID = editingConnection.id
        }
        saveConnections()
        isShowingServerForm = false
    }

    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
        completionTask?.cancel()
        completionTask = nil
        isUploading = false
        isRendering = false
        uploadCompleted = false
    }

    func deleteConnection(_ connection: FTPConnection) {
        KeychainService.delete(forKey: connection.keychainKey)
        connections.removeAll { $0.id == connection.id }
        saveConnections()
    }

    // MARK: - Upload History

    func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.ftpUploadHistory),
              let decoded = try? JSONDecoder().decode(FTPUploadHistory.self, from: data) else {
            return
        }
        uploadHistory = decoded
    }

    func saveHistory() {
        if let data = try? JSONEncoder().encode(uploadHistory) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.ftpUploadHistory)
        }
    }

    func recordUploadStart(files: [URL], connection: FTPConnection, didRenderJPEG: Bool) -> UUID {
        let fm = FileManager.default
        var fileRecords: [FTPUploadFileRecord] = []
        var totalBytes: Int64 = 0

        for url in files {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? Date()
            totalBytes += size
            fileRecords.append(FTPUploadFileRecord(
                filePath: url.path,
                fileName: url.lastPathComponent,
                fileSize: size,
                modifiedDate: modified
            ))
        }

        let entry = FTPUploadHistoryEntry(
            id: UUID(),
            serverName: connection.name,
            startedAt: Date(),
            completedAt: nil,
            fileCount: files.count,
            totalBytes: totalBytes,
            files: fileRecords,
            didRenderJPEG: didRenderJPEG
        )

        uploadHistory.addEntry(entry)
        saveHistory()
        return entry.id
    }

    func recordUploadCompletion(id: UUID) {
        uploadHistory.markCompleted(id: id)
        saveHistory()
    }

    // MARK: - Upload

    func uploadFiles(_ urls: [URL], to connection: FTPConnection) {
        guard let password = KeychainService.load(forKey: connection.keychainKey) else {
            errorMessages = ["No password found for \(connection.name). Edit the connection to set a password."]
            return
        }

        let historyID = recordUploadStart(files: urls, connection: connection, didRenderJPEG: false)

        isUploading = true
        isRendering = false
        uploadCompleted = false
        errorMessages = []
        completedCount = 0
        totalCount = urls.count
        uploadProgress = [:]
        overallProgress = 0

        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard let self else { return }
            for url in urls {
                guard !Task.isCancelled else { break }
                do {
                    try await ftpService.uploadFile(
                        localURL: url,
                        connection: connection,
                        password: password
                    ) { progress in
                        Task { @MainActor in
                            self.uploadProgress[progress.fileName] = progress
                            self.updateSmoothedProgress()
                        }
                    }
                    // Count completion here, on the awaited result, rather than from the
                    // background progress callback: the callback is delivered via an
                    // unstructured Task that may not have drained by the time the loop
                    // finishes and recordActivity() reads completedCount.
                    self.markFileComplete(url.lastPathComponent)
                } catch {
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.recordUploadCompletion(id: historyID)
            self.showCompletion(serverName: connection.name)
        }
    }

    func renderAndUploadFiles(_ urls: [URL], to connection: FTPConnection, readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine, inMemoryCameraRaw: @escaping @MainActor (URL) -> CameraRawSettings?) {
        guard let password = KeychainService.load(forKey: connection.keychainKey) else {
            errorMessages = ["No password found for \(connection.name). Edit the connection to set a password."]
            return
        }

        let historyID = recordUploadStart(files: urls, connection: connection, didRenderJPEG: true)

        isRendering = true
        isUploading = false
        uploadCompleted = false
        errorMessages = []
        renderCompletedCount = 0
        renderTotalCount = urls.count
        completedCount = 0
        totalCount = urls.count
        uploadProgress = [:]
        overallProgress = 0

        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard let self else { return }
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("FTPRender_\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                self.errorMessages = ["Failed to create temp directory: \(error.localizedDescription)"]
                self.isRendering = false
                return
            }

            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            // Read batch metadata for camera raw settings
            var metadataMap: [URL: IPTCMetadata] = [:]
            do {
                metadataMap = try await readService.readBatchFullMetadata(urls: urls)
            } catch {
                // Continue without camera raw — renders will use defaults
            }

            // Resolve edit settings the same way the local export paths do: prefer the
            // live in-memory CameraRaw, falling back to the XMP sidecar for RAW files.
            EditExportPipeline.resolveCameraRaw(into: &metadataMap, urls: urls, inMemory: inMemoryCameraRaw)

            // Render phase (0–50% of overall progress)
            let failureTracker = MetadataFailureTracker()
            var renderedURLs: [URL] = []
            // Tracks upload filenames already taken in this batch so two sources that
            // share a basename across folders (e.g. /A/img.jpg and /B/img.jpg, both →
            // img_jpg.jpg) don't end up overwriting each other on the remote server.
            var usedNames: Set<String> = []
            for (index, url) in urls.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    // Render each file into its own subfolder. The render output name is
                    // derived from the source basename only, so a shared temp dir would let
                    // a later render clobber an earlier one on disk — losing the first photo
                    // and uploading the second twice. Per-item folders make every render path
                    // unique regardless of basename collisions.
                    let itemDir = tempDir.appendingPathComponent(String(index), isDirectory: true)
                    try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
                    let outputURL = try await EditExportPipeline.renderItem(
                        sourceURL: url, cameraRaw: metadataMap[url]?.cameraRaw, kind: .jpeg,
                        outputFolder: itemDir, folderURL: url.deletingLastPathComponent(),
                        writeEngine: writeEngine, failureTracker: failureTracker)
                    renderedURLs.append(try uniqueUploadName(for: outputURL, avoiding: &usedNames))
                } catch {
                    self.errorMessages.append("Failed to render \(url.lastPathComponent): \(error.localizedDescription)")
                }
                self.renderCompletedCount += 1
                self.overallProgress = Double(self.renderCompletedCount) / Double(self.renderTotalCount) * 0.5
            }

            let copyFailures = await failureTracker.metadataCopyFailures
            if !copyFailures.isEmpty {
                self.errorMessages.append("Metadata copy failed for \(copyFailures.count) \(copyFailures.count == 1 ? "image" : "images") — uploaded without IPTC data")
            }
            let overlayFailures = await failureTracker.sidecarOverlayFailures
            if !overlayFailures.isEmpty {
                self.errorMessages.append("Sidecar metadata overlay failed for \(overlayFailures.count) \(overlayFailures.count == 1 ? "image" : "images") — uploaded without pending edits")
            }
            let staleWarnings = await failureTracker.staleSidecarWarnings
            if !staleWarnings.isEmpty {
                self.errorMessages.append("\(staleWarnings.count) \(staleWarnings.count == 1 ? "image was" : "images were") uploaded from embedded metadata, not the .xmp sidecar (the image file was edited more recently) — check if you expected sidecar values")
            }

            guard !Task.isCancelled else {
                self.isRendering = false
                return
            }

            // Upload phase (50–100% of overall progress)
            self.isRendering = false
            self.isUploading = true
            self.totalCount = renderedURLs.count
            self.completedCount = 0

            for url in renderedURLs {
                guard !Task.isCancelled else { break }
                do {
                    try await ftpService.uploadFile(
                        localURL: url,
                        connection: connection,
                        password: password
                    ) { progress in
                        Task { @MainActor in
                            self.uploadProgress[progress.fileName] = progress
                            self.updateSmoothedProgress(uploadWeightOffset: 0.5, uploadWeightRange: 0.5)
                        }
                    }
                    self.markFileComplete(url.lastPathComponent, uploadWeightOffset: 0.5, uploadWeightRange: 0.5)
                } catch {
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            self.recordUploadCompletion(id: historyID)
            self.showCompletion(serverName: connection.name)
        }
    }

    /// Returns `url` renamed in place when its filename is already used in this batch,
    /// so two distinct photos that share a basename don't overwrite each other on the
    /// remote server (the remote name is derived from the local filename). The first
    /// occurrence keeps its name; later ones become `name-2.ext`, `name-3.ext`, ….
    private func uniqueUploadName(for url: URL, avoiding usedNames: inout Set<String>) throws -> URL {
        if usedNames.insert(url.lastPathComponent).inserted { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            if usedNames.insert(candidate).inserted {
                let newURL = url.deletingLastPathComponent().appendingPathComponent(candidate)
                try FileManager.default.moveItem(at: url, to: newURL)
                return newURL
            }
            counter += 1
        }
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
    private func showCompletion(serverName: String) {
        isUploading = false
        isRendering = false
        uploadCompleted = true
        overallProgress = 1.0
        recordActivity(serverName: serverName)
    }

    /// Dismisses the sticky upload-completion banner (the green-check confirm action).
    func dismissUploadCompletion() {
        completionTask?.cancel()
        uploadCompleted = false
    }

    private func recordActivity(serverName: String) {
        let records: [ActivityFileRecord] = uploadProgress.values
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            .map { progress in
                ActivityFileRecord(
                    fileName: progress.fileName,
                    destination: serverName,
                    succeeded: progress.isComplete,
                    verification: .notApplicable
                )
            }

        let entry = ActivityEntry(
            kind: .upload,
            date: Date(),
            title: serverName,
            successCount: completedCount,
            totalCount: totalCount,
            files: records
        )
        activityHistory?.record(entry)
    }
}
