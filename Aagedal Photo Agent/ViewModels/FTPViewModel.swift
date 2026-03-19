import Foundation

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
    var errorMessage: String?
    var completedCount = 0
    var totalCount = 0
    var renderCompletedCount = 0
    var renderTotalCount = 0

    var isShowingServerForm = false
    var editingConnection = FTPConnection()
    var editingPassword = ""

    var uploadHistory = FTPUploadHistory()

    private let ftpService = FTPService()
    private let connectionsKey = UserDefaultsKeys.ftpConnections
    private var uploadTask: Task<Void, Never>?

    func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: connectionsKey),
              let decoded = try? JSONDecoder().decode([FTPConnection].self, from: data) else {
            return
        }
        connections = decoded

        // Verify the selected connection still exists after reload
        if let id = selectedConnectionID, !connections.contains(where: { $0.id == id }) {
            selectedConnectionID = nil
        }

        restoreLastUsedConnection()
    }

    func saveConnections() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: connectionsKey)
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
        try? KeychainService.save(password: editingPassword, forKey: editingConnection.keychainKey)

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
        isUploading = false
        isRendering = false
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
            errorMessage = "No password found for \(connection.name). Edit the connection to set a password."
            return
        }

        let historyID = recordUploadStart(files: urls, connection: connection, didRenderJPEG: false)

        isUploading = true
        isRendering = false
        errorMessage = nil
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
                            self.overallProgress = Double(self.completedCount) / Double(self.totalCount)
                        }
                    }
                } catch {
                    self.errorMessage = "Failed to upload \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            self.recordUploadCompletion(id: historyID)
            self.isUploading = false
        }
    }

    func renderAndUploadFiles(_ urls: [URL], to connection: FTPConnection, exifToolService: ExifToolService) {
        guard let password = KeychainService.load(forKey: connection.keychainKey) else {
            errorMessage = "No password found for \(connection.name). Edit the connection to set a password."
            return
        }

        let historyID = recordUploadStart(files: urls, connection: connection, didRenderJPEG: true)

        isRendering = true
        isUploading = false
        errorMessage = nil
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
                self.errorMessage = "Failed to create temp directory: \(error.localizedDescription)"
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

            // Render phase (0–50% of overall progress)
            var renderedURLs: [URL] = []
            for url in urls {
                guard !Task.isCancelled else { break }
                do {
                    let cameraRaw = metadataMap[url]?.cameraRaw
                    try await EditedImageRenderer.renderJPEG(from: url, cameraRaw: cameraRaw, outputFolder: tempDir)
                    let outputURL = EditedImageRenderer.outputURL(for: url, in: tempDir, extension: "jpg")
                    renderedURLs.append(outputURL)
                } catch {
                    self.errorMessage = "Failed to render \(url.lastPathComponent): \(error.localizedDescription)"
                }
                self.renderCompletedCount += 1
                self.overallProgress = Double(self.renderCompletedCount) / Double(self.renderTotalCount) * 0.5
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
                            self.overallProgress = 0.5 + Double(self.completedCount) / Double(max(self.totalCount, 1)) * 0.5
                        }
                    }
                } catch {
                    self.errorMessage = "Failed to upload \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }

            self.recordUploadCompletion(id: historyID)
            self.isUploading = false
        }
    }
}
