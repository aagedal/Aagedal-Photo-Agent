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
        uploadTask = Task {
            for url in urls {
                guard !Task.isCancelled else { break }
                do {
                    try await ftpService.uploadFile(
                        localURL: url,
                        connection: connection,
                        password: password
                    ) { progress in
                        Task { @MainActor in
                            let wasComplete = self.uploadProgress[progress.fileName]?.isComplete ?? false
                            self.uploadProgress[progress.fileName] = progress
                            if !wasComplete && progress.isComplete {
                                self.completedCount += 1
                            }
                            self.updateSmoothedProgress()
                        }
                    }
                } catch {
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.recordUploadCompletion(id: historyID)
            self.showCompletionBriefly()
        }
    }

    func renderAndUploadFiles(_ urls: [URL], to connection: FTPConnection, exifToolService: ExifToolService, writeEngine: any MetadataWriteEngine) {
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
        uploadTask = Task {
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
                metadataMap = try await exifToolService.readBatchFullMetadata(urls: urls)
            } catch {
                // Continue without camera raw — renders will use defaults
            }

            // ExifTool reads the RAW file directly but not the adjacent .xmp sidecar
            // where CameraRaw edits are stored. Overlay XMP sidecar settings for RAW files.
            let xmpService = XMPSidecarService()
            for url in urls {
                if SupportedImageFormats.isRaw(url: url),
                   let xmpMeta = xmpService.loadSidecar(for: url),
                   let xmpCRS = xmpMeta.cameraRaw, !xmpCRS.isEmpty {
                    metadataMap[url]?.cameraRaw = xmpCRS
                }
            }

            // Render phase (0–50% of overall progress)
            let failureTracker = MetadataFailureTracker()
            var renderedURLs: [URL] = []
            for url in urls {
                guard !Task.isCancelled else { break }
                do {
                    let cameraRaw = metadataMap[url]?.cameraRaw
                    let copier: EditedImageRenderer.MetadataCopier = { src, dst in
                        do {
                            try await writeEngine.copyMetadataToRenderedFile(from: src, to: dst)
                        } catch {
                            await failureTracker.recordCopyFailure(src.lastPathComponent)
                        }
                    }
                    try await EditedImageRenderer.renderJPEG(from: url, cameraRaw: cameraRaw, outputFolder: tempDir, metadataCopier: copier)
                    let outputURL = EditedImageRenderer.outputURL(for: url, in: tempDir, extension: "jpg")
                    renderedURLs.append(outputURL)
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
                            let wasComplete = self.uploadProgress[progress.fileName]?.isComplete ?? false
                            self.uploadProgress[progress.fileName] = progress
                            if !wasComplete && progress.isComplete {
                                self.completedCount += 1
                            }
                            self.updateSmoothedProgress(uploadWeightOffset: 0.5, uploadWeightRange: 0.5)
                        }
                    }
                } catch {
                    self.errorMessages.append("Failed to upload \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            self.recordUploadCompletion(id: historyID)
            self.showCompletionBriefly()
        }
    }

    // MARK: - Progress Helpers

    /// Computes smooth overall progress by interpolating per-file fractions.
    private func updateSmoothedProgress(uploadWeightOffset: Double = 0, uploadWeightRange: Double = 1.0) {
        let count = Double(max(totalCount, 1))
        let perFileContribution = uploadProgress.values.reduce(0.0) { $0 + $1.fractionCompleted }
        overallProgress = uploadWeightOffset + (perFileContribution / count) * uploadWeightRange
    }

    /// Shows a brief completion state before hiding the overlay.
    private func showCompletionBriefly() {
        isUploading = false
        isRendering = false
        uploadCompleted = true
        overallProgress = 1.0

        completionTask?.cancel()
        completionTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !isUploading, !isRendering else { return }
            uploadCompleted = false
        }
    }
}
