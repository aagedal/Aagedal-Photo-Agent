import Foundation

struct MetadataSidecarService: Sendable {

    private static let sidecarDirectoryName = ".photo_metadata"

    // MARK: - Directory Helpers

    private func sidecarDirectory(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(Self.sidecarDirectoryName)
    }

    private func sidecarFileURL(for imageURL: URL, in folderURL: URL) -> URL {
        let filename = imageURL.lastPathComponent
        return sidecarDirectory(for: folderURL).appendingPathComponent("\(filename).meta.json")
    }

    private func legacySidecarFileURL(for imageURL: URL, in folderURL: URL) -> URL {
        let basename = imageURL.deletingPathExtension().lastPathComponent
        return sidecarDirectory(for: folderURL).appendingPathComponent("\(basename).meta.json")
    }

    private func sidecarCandidateURLs(for imageURL: URL, in folderURL: URL) -> [URL] {
        let current = sidecarFileURL(for: imageURL, in: folderURL)
        let legacy = legacySidecarFileURL(for: imageURL, in: folderURL)
        if current == legacy { return [current] }
        return [current, legacy]
    }

    // MARK: - Load

    func loadSidecar(for imageURL: URL, in folderURL: URL) -> MetadataSidecar? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in sidecarCandidateURLs(for: imageURL, in: folderURL) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            do {
                let data = try Data(contentsOf: fileURL)
                let sidecar = try decoder.decode(MetadataSidecar.self, from: data)
                guard !sidecar.sourceFile.contains("/"), !sidecar.sourceFile.contains("\\"), !sidecar.sourceFile.contains("..") else {
                    continue
                }
                return sidecar
            } catch {
                continue
            }
        }
        return nil
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
            guard !sidecar.sourceFile.contains("/"), !sidecar.sourceFile.contains("\\"), !sidecar.sourceFile.contains("..") else {
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

    func pendingFieldNames(for imageURL: URL, in folderURL: URL) -> [String] {
        guard let sidecar = loadSidecar(for: imageURL, in: folderURL),
              sidecar.pendingChanges,
              let original = sidecar.imageMetadataSnapshot else {
            return []
        }
        let edited = sidecar.metadata
        var names: [String] = []
        if edited.title != original.title { names.append("Headline") }
        if edited.description != original.description { names.append("Description") }
        if edited.extendedDescription != original.extendedDescription { names.append("Extended Description") }
        if edited.keywords != original.keywords { names.append("Keywords") }
        if edited.personShown != original.personShown { names.append("Person Shown") }
        if edited.rating != original.rating { names.append("Rating") }
        if edited.label != original.label { names.append("Label") }
        if edited.copyright != original.copyright { names.append("Copyright") }
        if edited.jobId != original.jobId { names.append("Job ID") }
        if edited.creator != original.creator { names.append("Creator") }
        if edited.credit != original.credit { names.append("Credit") }
        if edited.city != original.city { names.append("City") }
        if edited.country != original.country { names.append("Country") }
        if edited.event != original.event { names.append("Event") }
        if edited.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        return names
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
        let currentURL = sidecarFileURL(for: imageURL, in: folderURL)
        try data.write(to: currentURL, options: .atomic)

        let legacyURL = legacySidecarFileURL(for: imageURL, in: folderURL)
        if legacyURL != currentURL,
           FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    // MARK: - Delete

    func deleteSidecar(for imageURL: URL, in folderURL: URL) throws {
        for fileURL in sidecarCandidateURLs(for: imageURL, in: folderURL) {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func deleteAllSidecars(in folderURL: URL) throws {
        let dir = sidecarDirectory(for: folderURL)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    func moveSidecar(for imageURL: URL, from sourceFolderURL: URL, to destinationFolderURL: URL) throws {
        let fm = FileManager.default
        let sourceURLs = sidecarCandidateURLs(for: imageURL, in: sourceFolderURL).filter {
            fm.fileExists(atPath: $0.path)
        }
        guard !sourceURLs.isEmpty else { return }

        let destinationDirectory = sidecarDirectory(for: destinationFolderURL)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = sidecarFileURL(for: imageURL, in: destinationFolderURL)

        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        if let first = sourceURLs.first {
            try fm.moveItem(at: first, to: destinationURL)
        }
        for extra in sourceURLs.dropFirst() {
            try? fm.removeItem(at: extra)
        }
    }
}
