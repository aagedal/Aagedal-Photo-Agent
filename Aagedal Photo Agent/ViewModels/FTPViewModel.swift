import Foundation

@Observable
final class FTPViewModel {
    var connections: [FTPConnection] = []
    var selectedConnection: FTPConnection?
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

    private let ftpService = FTPService()
    private let connectionsKey = UserDefaultsKeys.ftpConnections
    private var uploadTask: Task<Void, Never>?

    func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: connectionsKey),
              let decoded = try? JSONDecoder().decode([FTPConnection].self, from: data) else {
            return
        }
        connections = decoded

        // Sync selectedConnection with the reloaded array so the Picker tag matches.
        // Without this, a stale selectedConnection (e.g. from before an edit in Settings)
        // won't match any Picker tag, causing undefined Picker behavior.
        if let selected = selectedConnection {
            selectedConnection = connections.first { $0.id == selected.id }
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
        guard selectedConnection == nil,
              let idString = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastUsedFTPConnectionID),
              let id = UUID(uuidString: idString),
              let match = connections.first(where: { $0.id == id }) else {
            return
        }
        selectedConnection = match
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
        // Keep selectedConnection in sync if the user edited the currently selected one
        if selectedConnection?.id == editingConnection.id {
            selectedConnection = editingConnection
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

    func uploadFiles(_ urls: [URL], to connection: FTPConnection) {
        guard let password = KeychainService.load(forKey: connection.keychainKey) else {
            errorMessage = "No password found for \(connection.name). Edit the connection to set a password."
            return
        }

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
            self.isUploading = false
        }
    }

    func renderAndUploadFiles(_ urls: [URL], to connection: FTPConnection, exifToolService: ExifToolService) {
        guard let password = KeychainService.load(forKey: connection.keychainKey) else {
            errorMessage = "No password found for \(connection.name). Edit the connection to set a password."
            return
        }

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

            self.isUploading = false
        }
    }
}
