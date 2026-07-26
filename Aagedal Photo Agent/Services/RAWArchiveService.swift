import Foundation

nonisolated enum RAWArchiveLocationError: LocalizedError {
    case archiveRootNotConfigured
    case sourceOutsideIngestRoot(source: URL, ingestRoot: URL)
    case manualDestinationMissing

    var errorDescription: String? {
        switch self {
        case .archiveRootNotConfigured:
            return "Choose a separate Archive root in Settings → Locations before archiving."
        case .sourceOutsideIngestRoot(let source, let ingestRoot):
            return """
            \(source.path) is outside the configured main ingest folder (\(ingestRoot.path)). Choose the correct ingest folder in Settings → Locations or use another archive location.
            """
        case .manualDestinationMissing:
            return "No archive destination folder was selected."
        }
    }
}

nonisolated enum RAWArchiveService {
    static var currentLocationMode: RAWArchiveLocationMode {
        let raw = UserDefaults.standard.string(
            forKey: UserDefaultsKeys.rawArchiveLocationMode
        ) ?? RAWArchiveLocationMode.workFolderArchive.rawValue
        return RAWArchiveLocationMode(rawValue: raw) ?? .workFolderArchive
    }

    static var defaultIngestRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Photos", isDirectory: true)
    }

    static var ingestRootURL: URL {
        resolveBookmark(key: UserDefaultsKeys.rawArchiveSourceRootBookmark)
            ?? resolveBookmark(key: UserDefaultsKeys.importDestinationBookmark)
            ?? defaultIngestRootURL
    }

    static var archiveRootURL: URL? {
        resolveBookmark(key: UserDefaultsKeys.rawArchiveRootBookmark)
    }

    static var usesSourceRootOverride: Bool {
        UserDefaults.standard.data(
            forKey: UserDefaultsKeys.rawArchiveSourceRootBookmark
        ) != nil
    }

    static func destinationFolder(
        for sourceURL: URL,
        manualDestination: URL? = nil,
        mode: RAWArchiveLocationMode = currentLocationMode,
        ingestRoot: URL? = nil,
        archiveRoot: URL? = nil
    ) throws -> URL {
        let sourceFolder = sourceURL.deletingLastPathComponent()

        switch mode {
        case .workFolderArchive:
            return sourceFolder.appendingPathComponent("Archive", isDirectory: true)

        case .mirroredArchiveRoot:
            let effectiveIngestRoot = (ingestRoot ?? ingestRootURL).standardizedFileURL
            guard let effectiveArchiveRoot = archiveRoot ?? archiveRootURL else {
                throw RAWArchiveLocationError.archiveRootNotConfigured
            }
            let relativeComponents = try relativePathComponents(
                from: effectiveIngestRoot,
                to: sourceFolder.standardizedFileURL,
                sourceURL: sourceURL
            )
            return relativeComponents.reduce(
                effectiveArchiveRoot.standardizedFileURL
            ) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }

        case .askEveryTime:
            guard let manualDestination else {
                throw RAWArchiveLocationError.manualDestinationMissing
            }
            return manualDestination
        }
    }

    /// Chooses an image/XMP pair name without overwriting either file.
    static func uniqueDestinationURL(
        for sourceURL: URL,
        in outputFolder: URL,
        extension fileExtension: String
    ) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var counter = 1

        while true {
            let suffix = counter == 1 ? "" : " \(counter)"
            let candidate = outputFolder
                .appendingPathComponent(baseName + suffix)
                .appendingPathExtension(fileExtension)
            let sidecar = XMPSidecarService().sidecarURL(for: candidate)
            if !FileManager.default.fileExists(atPath: candidate.path),
               !FileManager.default.fileExists(atPath: sidecar.path) {
                return candidate
            }
            counter += 1
        }
    }

    /// Copies the original XMP packet unchanged so develop settings remain external
    /// to the archived pixels. A same-basename archive beside its source already
    /// shares that sidecar and needs no copy.
    static func copySidecarIfPresent(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let sidecars = XMPSidecarService()
        let sourceSidecar = sidecars.sidecarURL(for: sourceURL)
        let destinationSidecar = sidecars.sidecarURL(for: destinationURL)
        guard sourceSidecar.standardizedFileURL
                != destinationSidecar.standardizedFileURL,
              FileManager.default.fileExists(atPath: sourceSidecar.path)
        else {
            return
        }
        try FileManager.default.copyItem(
            at: sourceSidecar,
            to: destinationSidecar
        )
    }

    static func saveBookmark(for url: URL, key: String) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func resolveBookmark(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                saveBookmark(for: url, key: key)
            }
            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
    }

    private static func relativePathComponents(
        from root: URL,
        to child: URL,
        sourceURL: URL
    ) throws -> ArraySlice<String> {
        let rootComponents = root.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count >= rootComponents.count,
              Array(childComponents.prefix(rootComponents.count)) == rootComponents
        else {
            throw RAWArchiveLocationError.sourceOutsideIngestRoot(
                source: sourceURL,
                ingestRoot: root
            )
        }
        return childComponents.dropFirst(rootComponents.count)
    }
}
