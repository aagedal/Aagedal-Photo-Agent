import Foundation

@Observable
final class FTPViewModel {
    var connections: [FTPConnection] = []
    var selectedConnection: FTPConnection?
    var isUploading = false
    var uploadProgress: [String: FTPUploadProgress] = [:]
    var overallProgress: Double = 0
    var errorMessage: String?
    var completedCount = 0
    var totalCount = 0

    var isShowingServerForm = false
    var editingConnection = FTPConnection()
    var editingPassword = ""

    private let ftpService = FTPService()
    private let connectionsKey = "ftpConnections"

    func loadConnections() {
        guard let data = UserDefaults.standard.data(forKey: connectionsKey),
              let decoded = try? JSONDecoder().decode([FTPConnection].self, from: data) else {
            return
        }
        connections = decoded
    }

    func saveConnections() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: connectionsKey)
        }
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
        saveConnections()
        isShowingServerForm = false
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
        errorMessage = nil
        completedCount = 0
        totalCount = urls.count
        uploadProgress = [:]
        overallProgress = 0

        Task {
            for url in urls {
                do {
                    try await ftpService.uploadFile(
                        localURL: url,
                        connection: connection,
                        password: password
                    ) { progress in
                        Task { @MainActor in
                            self.uploadProgress[progress.fileName] = progress
                            if progress.isComplete {
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
}
