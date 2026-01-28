import Foundation

struct MetadataSidecarService: Sendable {

    private static let sidecarDirectoryName = ".photo_metadata"

    // MARK: - Directory Helpers

    private func sidecarDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(Self.sidecarDirectoryName)
    }

    private func sidecarFileURL(for imageURL: URL, in folderURL: URL) -> URL {
        let filename = imageURL.deletingPathExtension().lastPathComponent
        return sidecarDirectory(for: folderURL).appendingPathComponent("\(filename).meta.json")
    }

    // MARK: - Load

    func loadSidecar(for imageURL: URL, in folderURL: URL) -> MetadataSidecar? {
        let fileURL = sidecarFileURL(for: imageURL, in: folderURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let sidecar = try decoder.decode(MetadataSidecar.self, from: data)
            return sidecar
        } catch {
            return nil
        }
    }

    func loadAllSidecars(in folderURL: URL) -> [URL: MetadataSidecar] {
        let dir = sidecarDirectory(for: folderURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }

        var result: [URL: MetadataSidecar] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return [:]
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let sidecar = try? decoder.decode(MetadataSidecar.self, from: data) else {
                continue
            }
            let imageURL = folderURL.appendingPathComponent(sidecar.sourceFile)
            result[imageURL] = sidecar
        }

        return result
    }

    func imagesWithPendingChanges(in folderURL: URL) -> Set<URL> {
        let sidecars = loadAllSidecars(in: folderURL)
        return Set(sidecars.filter { $0.value.pendingChanges }.keys)
    }

    // MARK: - Save

    func saveSidecar(_ sidecar: MetadataSidecar, for imageURL: URL, in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var updatedSidecar = sidecar
        updatedSidecar.lastModified = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updatedSidecar)
        try data.write(to: sidecarFileURL(for: imageURL, in: folderURL))
    }

    // MARK: - Delete

    func deleteSidecar(for imageURL: URL, in folderURL: URL) throws {
        let fileURL = sidecarFileURL(for: imageURL, in: folderURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func deleteAllSidecars(in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
