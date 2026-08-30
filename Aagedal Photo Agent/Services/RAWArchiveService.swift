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

/// Immutable cleanup input captured before leaving the UI actor. Sidecar identities are resolved
/// once so the serialized filesystem operation cannot accidentally re-evaluate which source file
/// must be preserved after it starts.
nonisolated struct RAWArchiveSigningFailureCleanupRequest: Equatable, Sendable {
    let requestID: UUID
    let archiveURL: URL
    let archiveSidecarURL: URL
    let sourceSidecarURL: URL

    init(
        requestID: UUID = UUID(),
        archiveURL: URL,
        sourceURL: URL
    ) {
        let sidecars = XMPSidecarService()
        self.requestID = requestID
        self.archiveURL = archiveURL
        self.archiveSidecarURL = sidecars.sidecarURL(for: archiveURL)
        self.sourceSidecarURL = sidecars.sidecarURL(for: sourceURL)
    }
}

/// Durable per-item evidence from compensating cleanup. The two removals are deliberately
/// independent: a failure removing one artifact must not prevent removal of the other.
nonisolated enum RAWArchiveSigningFailureCleanupOutcome: Equatable, Sendable {
    case removed
    case alreadyAbsent
    case preservedSourceSidecar
    case removalFailed(String)
}

nonisolated struct RAWArchiveSigningFailureCleanupItemEvidence: Equatable, Sendable {
    let url: URL
    let outcome: RAWArchiveSigningFailureCleanupOutcome
}

/// Immutable evidence describing all durable state after a signing-failure cleanup attempt.
/// Cleanup is non-preemptible once submitted because leaving an unsigned archive behind is less
/// safe than honoring cancellation between the two compensating removals.
nonisolated struct RAWArchiveSigningFailureCleanupEvidence: Equatable, Sendable {
    let requestID: UUID
    let archive: RAWArchiveSigningFailureCleanupItemEvidence
    let archiveSidecar: RAWArchiveSigningFailureCleanupItemEvidence
    let sourceSidecarURL: URL
    let cancellationObservedBeforeCleanup: Bool
    let cancellationObservedAfterCleanup: Bool
}

nonisolated struct RAWArchiveSigningFailureCleanupIO: Sendable {
    let fileExists: @Sendable (URL) -> Bool
    let removeItem: @Sendable (URL) throws -> Void

    static let system = RAWArchiveSigningFailureCleanupIO(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        removeItem: { try FileManager.default.removeItem(at: $0) }
    )
}

/// Serializes signing-failure compensation away from MainActor. This actor intentionally has no
/// suspension point inside `cleanup`: once a request begins, both artifacts receive a removal
/// attempt and the caller gets truthful partial-cleanup evidence even if cancellation arrives.
actor RAWArchiveSigningFailureCleanupService {
    static let shared = RAWArchiveSigningFailureCleanupService()

    private let io: RAWArchiveSigningFailureCleanupIO

    init(io: RAWArchiveSigningFailureCleanupIO = .system) {
        self.io = io
    }

    func cleanup(
        _ request: RAWArchiveSigningFailureCleanupRequest
    ) async -> RAWArchiveSigningFailureCleanupEvidence {
        let cancellationObservedBeforeCleanup = Task.isCancelled
        let archive = removeEvidence(for: request.archiveURL)

        let archiveSidecar: RAWArchiveSigningFailureCleanupItemEvidence
        if request.archiveSidecarURL.standardizedFileURL
            == request.sourceSidecarURL.standardizedFileURL {
            archiveSidecar = RAWArchiveSigningFailureCleanupItemEvidence(
                url: request.archiveSidecarURL,
                outcome: .preservedSourceSidecar
            )
        } else {
            archiveSidecar = removeEvidence(for: request.archiveSidecarURL)
        }

        return RAWArchiveSigningFailureCleanupEvidence(
            requestID: request.requestID,
            archive: archive,
            archiveSidecar: archiveSidecar,
            sourceSidecarURL: request.sourceSidecarURL,
            cancellationObservedBeforeCleanup: cancellationObservedBeforeCleanup,
            cancellationObservedAfterCleanup: Task.isCancelled
        )
    }

    private func removeEvidence(
        for url: URL
    ) -> RAWArchiveSigningFailureCleanupItemEvidence {
        guard io.fileExists(url) else {
            return RAWArchiveSigningFailureCleanupItemEvidence(
                url: url,
                outcome: .alreadyAbsent
            )
        }
        do {
            try io.removeItem(url)
            return RAWArchiveSigningFailureCleanupItemEvidence(
                url: url,
                outcome: .removed
            )
        } catch {
            return RAWArchiveSigningFailureCleanupItemEvidence(
                url: url,
                outcome: .removalFailed(error.localizedDescription)
            )
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
