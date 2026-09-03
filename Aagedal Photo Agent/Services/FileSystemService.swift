import Foundation
import ImageIO
import os

nonisolated protocol ImageTrashHandling: Sendable {
    func trashItem(at url: URL) throws
}

nonisolated struct SystemImageTrashHandler: ImageTrashHandling {
    func trashItem(at url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

actor FileSystemService {
    enum Error: Swift.Error, Sendable, Equatable {
        case destinationAlreadyExists(URL)
        case destinationIsNotDirectory(URL)
    }

    struct FolderScanResult: Sendable {
        let files: [ImageFile]
        let deferredICloudItemCount: Int

        var hasDeferredICloudItems: Bool { deferredICloudItemCount > 0 }
    }

    /// Immutable evidence that a requested folder mutation reached its commit point.
    ///
    /// Foundation folder mutations are synchronous and cannot safely be interrupted once they
    /// enter the filesystem. If cancellation arrives during that call, the completed mutation is
    /// still returned so the main actor can reconcile its model with disk instead of incorrectly
    /// presenting the operation as cancelled.
    struct FolderMutationResult: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case trash
            case rename
            case create
            case move
        }

        let kind: Kind
        let sourceURL: URL?
        let resultingURL: URL
        let cancellationRequestedAfterCommit: Bool
    }

    struct ItemFailure: Sendable, Equatable {
        enum Stage: String, Sendable, Equatable {
            case primary
            case xmpSidecar
            case metadataSidecar
        }

        let sourceURL: URL
        let stage: Stage
        let message: String
    }

    struct BatchMutationResult: Sendable, Equatable {
        let completedSourceURLs: Set<URL>
        let failures: [ItemFailure]
        let cancellationStoppedRemainingItems: Bool
    }

    struct ImageMoveResult: Sendable, Equatable {
        let movedSourceURLs: Set<URL>
        let failures: [ItemFailure]
        let destinationWasCreated: Bool
        let cancellationStoppedRemainingItems: Bool
    }

    struct DuplicateRequest: Sendable {
        let source: ImageFile
    }

    struct DuplicateCompletion: Sendable {
        let sourceURL: URL
        let duplicate: ImageFile
    }

    struct DuplicateResult: Sendable {
        let completed: [DuplicateCompletion]
        let failures: [ItemFailure]
        let cancellationStoppedRemainingItems: Bool
    }

    enum DropSourceKind: Sendable, Equatable {
        case directory
        case regularFile
        case missing
    }

    /// One immutable classification of URLs received from a sidebar drop. A dropped URL can
    /// point at a slow external, network, or iCloud volume, so the existence/type probes belong
    /// on the same serialized filesystem executor as the mutations they precede.
    struct DropSourceSnapshot: Sendable, Equatable {
        let directories: [URL]
        let regularFiles: [URL]
        let missingURLs: [URL]
    }

    /// Immutable evidence from probing a frozen set of XMP sidecar destinations. The probe can
    /// block on an external, network, or cloud volume, so cancellation is observed before and
    /// after every non-preemptible `fileExists` call. Cancelled prefixes are never used to choose
    /// a destructive confirmation path.
    struct SidecarPresenceSnapshot: Sendable, Equatable {
        enum Completion: Sendable, Equatable {
            case complete
            case cancelled
        }

        let hasAnySidecar: Bool
        let checkedCount: Int
        let requestedCount: Int
        let completion: Completion
    }

    /// Immutable display-orientation evidence for one Browser folder session. Only
    /// non-default orientations are retained so callers can apply the snapshot over
    /// the scan's upright defaults without manufacturing extra per-file state.
    struct DisplayOrientationSnapshot: Sendable, Equatable {
        enum Completion: Sendable, Equatable {
            case complete
            case cancelled(processedFileCount: Int)
        }

        let requestID: UUID
        let orientations: [URL: Int]
        let requestedFileCount: Int
        let completion: Completion
    }

    private let isLocallyAvailable: @Sendable (URL) -> Bool
    private let requestDownload: @Sendable (URL) -> Void
    private let rejectMove: @Sendable ([URL], URL) -> RejectMoveService.MoveResult
    private let supportedFilesContents: @Sendable (URL) throws -> [URL]
    private let classifyDropSource: @Sendable (URL) -> DropSourceKind
    private let sidecarExists: @Sendable (URL) -> Bool
    private let displayOrientation: @Sendable (URL) -> Int?
    /// Measures volume-facing reads without recording paths or filenames. The interval names and
    /// aggregate counts are intentionally stable so the same Instruments template can compare
    /// local, network, cloud-placeholder, and large-folder runs.
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "FileSystemRead"
    )

    init(
        isLocallyAvailable: @escaping @Sendable (URL) -> Bool = {
            FileSystemService.systemIsLocallyAvailable($0)
        },
        requestDownload: @escaping @Sendable (URL) -> Void = {
            try? FileManager.default.startDownloadingUbiquitousItem(at: $0)
        },
        rejectMove: @escaping @Sendable ([URL], URL) -> RejectMoveService.MoveResult = { urls, folderURL in
            RejectMoveService.moveRejected(urls: urls, in: folderURL)
        },
        supportedFilesContents: @escaping @Sendable (URL) throws -> [URL] = { url in
            try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        },
        classifyDropSource: @escaping @Sendable (URL) -> DropSourceKind = { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .missing
            }
            return isDirectory.boolValue ? .directory : .regularFile
        },
        sidecarExists: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        displayOrientation: @escaping @Sendable (URL) -> Int? = { url in
            FileSystemService.systemDisplayOrientation(for: url)
        }
    ) {
        self.isLocallyAvailable = isLocallyAvailable
        self.requestDownload = requestDownload
        self.rejectMove = rejectMove
        self.supportedFilesContents = supportedFilesContents
        self.classifyDropSource = classifyDropSource
        self.sidecarExists = sidecarExists
        self.displayOrientation = displayOrientation
    }

    /// Scans a folder for image files on this service's serialized actor executor. Directory
    /// enumeration plus the per-file `stat` (in `ImageFile.init`) therefore cannot block the
    /// MainActor, and overlapping scans/mutations cannot race one another.
    func scanFolder(at url: URL, includeAllFiles: Bool = false) async throws -> [ImageFile] {
        try await scanFolderWithStatus(at: url, includeAllFiles: includeAllFiles).files
    }

    func scanFolderWithStatus(at url: URL, includeAllFiles: Bool = false) async throws -> FolderScanResult {
        try Task.checkCancellation()
        let interval = signposter.beginInterval("FolderScan", id: signposter.makeSignpostID())

        do {
            guard locallyAvailableForEnumeration(url) else {
                signposter.endInterval(
                    "FolderScan",
                    interval,
                    "result=deferred itemCount=0 deferredCount=1"
                )
                return FolderScanResult(files: [], deferredICloudItemCount: 1)
            }

            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .addedToDirectoryDateKey,
                    .isRegularFileKey,
                    .ubiquitousItemDownloadingStatusKey,
                ],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )

            var deferredICloudItemCount = 0
            var files: [ImageFile] = []
            files.reserveCapacity(contents.count)
            for (index, item) in contents.enumerated() {
                if index.isMultiple(of: 32) { try Task.checkCancellation() }
                // Camera voice memos are companions, never browser photos. Keep this boundary even
                // when the user asks to show otherwise-unsupported files.
                if item.pathExtension.lowercased() == "wav" { continue }
                if locallyAvailableForEnumeration(item) {
                    let isSupported = includeAllFiles
                        ? ((try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
                        : SupportedImageFormats.isSupported(url: item)
                    guard isSupported else { continue }
                    files.append(ImageFile(url: item))
                } else {
                    guard includeAllFiles || SupportedImageFormats.isSupported(url: item) else { continue }
                    deferredICloudItemCount += 1
                    files.append(ImageFile(url: item, isICloudDownloadPending: true))
                }
            }
            let result = FolderScanResult(
                files: files,
                deferredICloudItemCount: deferredICloudItemCount
            )
            signposter.endInterval(
                "FolderScan",
                interval,
                "result=ready itemCount=\(files.count, privacy: .private) deferredCount=\(deferredICloudItemCount, privacy: .private)"
            )
            return result
        } catch is CancellationError {
            signposter.endInterval("FolderScan", interval, "result=cancelled")
            throw CancellationError()
        } catch {
            signposter.endInterval("FolderScan", interval, "result=failed")
            throw error
        }
    }

    /// Returns an immutable, name-sorted snapshot of the supported regular files directly inside
    /// a folder. This is the non-recursive boundary for workflows that need URLs rather than
    /// `ImageFile` metadata; synchronous Foundation enumeration stays on this serialized actor.
    func supportedFilesSnapshot(at url: URL) throws -> [URL] {
        try Task.checkCancellation()
        let interval = signposter.beginInterval(
            "SupportedFilesSnapshot",
            id: signposter.makeSignpostID()
        )
        do {
            let contents = try supportedFilesContents(url)

            var supportedFiles: [URL] = []
            supportedFiles.reserveCapacity(contents.count)
            for item in contents {
                try Task.checkCancellation()
                guard SupportedImageFormats.isSupported(url: item) else { continue }
                let values = try item.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                supportedFiles.append(item)
            }
            try Task.checkCancellation()
            let result = supportedFiles.sorted { lhs, rhs in
                let order = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.path < rhs.path
            }
            signposter.endInterval(
                "SupportedFilesSnapshot",
                interval,
                "result=ready itemCount=\(result.count, privacy: .private)"
            )
            return result
        } catch is CancellationError {
            signposter.endInterval("SupportedFilesSnapshot", interval, "result=cancelled")
            throw CancellationError()
        } catch {
            signposter.endInterval("SupportedFilesSnapshot", interval, "result=failed")
            throw error
        }
    }

    func dropSourceSnapshot(for urls: [URL]) throws -> DropSourceSnapshot {
        try Task.checkCancellation()
        let interval = signposter.beginInterval(
            "DropSourceClassification",
            id: signposter.makeSignpostID()
        )
        do {
            var directories: [URL] = []
            var regularFiles: [URL] = []
            var missingURLs: [URL] = []
            directories.reserveCapacity(urls.count)
            regularFiles.reserveCapacity(urls.count)

            for url in urls {
                try Task.checkCancellation()
                switch classifyDropSource(url) {
                case .directory:
                    directories.append(url)
                case .regularFile:
                    regularFiles.append(url)
                case .missing:
                    missingURLs.append(url)
                }
            }
            try Task.checkCancellation()
            let result = DropSourceSnapshot(
                directories: directories,
                regularFiles: regularFiles,
                missingURLs: missingURLs
            )
            signposter.endInterval(
                "DropSourceClassification",
                interval,
                "result=ready itemCount=\(urls.count, privacy: .private)"
            )
            return result
        } catch is CancellationError {
            signposter.endInterval("DropSourceClassification", interval, "result=cancelled")
            throw CancellationError()
        } catch {
            signposter.endInterval("DropSourceClassification", interval, "result=failed")
            throw error
        }
    }

    func sidecarPresenceSnapshot(for sidecarURLs: [URL]) -> SidecarPresenceSnapshot {
        guard !Task.isCancelled else {
            return SidecarPresenceSnapshot(
                hasAnySidecar: false,
                checkedCount: 0,
                requestedCount: sidecarURLs.count,
                completion: .cancelled
            )
        }

        var checkedCount = 0
        for url in sidecarURLs {
            guard !Task.isCancelled else {
                return SidecarPresenceSnapshot(
                    hasAnySidecar: false,
                    checkedCount: checkedCount,
                    requestedCount: sidecarURLs.count,
                    completion: .cancelled
                )
            }
            let exists = sidecarExists(url)
            checkedCount += 1
            guard !Task.isCancelled else {
                return SidecarPresenceSnapshot(
                    hasAnySidecar: false,
                    checkedCount: checkedCount,
                    requestedCount: sidecarURLs.count,
                    completion: .cancelled
                )
            }
            if exists {
                return SidecarPresenceSnapshot(
                    hasAnySidecar: true,
                    checkedCount: checkedCount,
                    requestedCount: sidecarURLs.count,
                    completion: .complete
                )
            }
        }

        return SidecarPresenceSnapshot(
            hasAnySidecar: false,
            checkedCount: checkedCount,
            requestedCount: sidecarURLs.count,
            completion: .complete
        )
    }

    /// Reads the Browser's eager display orientations on the same serialized actor as
    /// its folder scan. XMP and ImageIO access are synchronous and cannot be preempted,
    /// so cancellation is sampled on both sides of every file and the exact completed
    /// prefix is returned instead of allowing a partial snapshot to look complete.
    func displayOrientationSnapshot(
        for urls: [URL],
        requestID: UUID
    ) -> DisplayOrientationSnapshot {
        let interval = signposter.beginInterval(
            "DisplayOrientationSnapshot",
            id: signposter.makeSignpostID()
        )
        var orientations: [URL: Int] = [:]
        orientations.reserveCapacity(urls.count)
        var processedFileCount = 0

        for url in urls {
            guard !Task.isCancelled else {
                signposter.endInterval(
                    "DisplayOrientationSnapshot",
                    interval,
                    "result=cancelled processedCount=\(processedFileCount, privacy: .private) requestedCount=\(urls.count, privacy: .private)"
                )
                return DisplayOrientationSnapshot(
                    requestID: requestID,
                    orientations: orientations,
                    requestedFileCount: urls.count,
                    completion: .cancelled(processedFileCount: processedFileCount)
                )
            }

            if let orientation = displayOrientation(url), orientation != 1 {
                orientations[url] = orientation
            }
            processedFileCount += 1

            guard !Task.isCancelled else {
                signposter.endInterval(
                    "DisplayOrientationSnapshot",
                    interval,
                    "result=cancelled processedCount=\(processedFileCount, privacy: .private) requestedCount=\(urls.count, privacy: .private)"
                )
                return DisplayOrientationSnapshot(
                    requestID: requestID,
                    orientations: orientations,
                    requestedFileCount: urls.count,
                    completion: .cancelled(processedFileCount: processedFileCount)
                )
            }
        }

        signposter.endInterval(
            "DisplayOrientationSnapshot",
            interval,
            "result=ready processedCount=\(processedFileCount, privacy: .private) requestedCount=\(urls.count, privacy: .private)"
        )
        return DisplayOrientationSnapshot(
            requestID: requestID,
            orientations: orientations,
            requestedFileCount: urls.count,
            completion: .complete
        )
    }

    /// Sidecar orientation is authoritative for RAW/C2PA workflows because those
    /// rotations can be intentionally sidecar-only. Embedded ImageIO orientation is
    /// the fallback for files without that override.
    private nonisolated static func systemDisplayOrientation(for url: URL) -> Int? {
        if let sidecarOrientation = XMPSidecarService().sidecarOrientation(for: url) {
            return sidecarOrientation
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }
        return properties[kCGImagePropertyOrientation] as? Int
    }

    func listSubfolders(at url: URL) throws -> [URL] {
        try Task.checkCancellation()
        guard locallyAvailableForEnumeration(url) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .ubiquitousItemDownloadingStatusKey,
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        var subfolders: [URL] = []
        subfolders.reserveCapacity(contents.count)
        for (index, item) in contents.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            if locallyAvailableForEnumeration(item) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if values?.isDirectory == true && values?.isPackage != true {
                    subfolders.append(item)
                }
            }
        }
        return subfolders.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func trashFolder(at url: URL) throws -> FolderMutationResult {
        try Task.checkCancellation()
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return FolderMutationResult(
            kind: .trash,
            sourceURL: url,
            resultingURL: (resultingURL as URL?) ?? url,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
    }

    func renameFolder(at sourceURL: URL, to destinationURL: URL) throws -> FolderMutationResult {
        try moveFolder(
            from: sourceURL,
            to: destinationURL,
            kind: .rename
        )
    }

    func createFolder(at url: URL) throws -> FolderMutationResult {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Error.destinationAlreadyExists(url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return FolderMutationResult(
            kind: .create,
            sourceURL: nil,
            resultingURL: url,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
    }

    func moveFolder(from sourceURL: URL, to destinationURL: URL) throws -> FolderMutationResult {
        try moveFolder(from: sourceURL, to: destinationURL, kind: .move)
    }

    /// Moves rejected image bundles on the same serialized actor used by the browser's other
    /// scans and mutations. The mover observes cancellation between complete bundles so an
    /// image, XMP, and editorial sidecar are never left in an interrupted transaction.
    func moveRejectedItems(_ urls: [URL], in folderURL: URL) -> RejectMoveService.MoveResult {
        rejectMove(urls, folderURL)
    }

    /// Trashes as many items as possible. Cancellation stops before the next item; a synchronous
    /// trash already in progress is allowed to commit and is included in `completedSourceURLs`.
    func trashItems(
        _ urls: [URL],
        using handler: any ImageTrashHandling
    ) -> BatchMutationResult {
        var completed: Set<URL> = []
        var failures: [ItemFailure] = []
        var cancellationStoppedRemainingItems = false

        for url in urls {
            if Task.isCancelled {
                cancellationStoppedRemainingItems = true
                break
            }
            do {
                try handler.trashItem(at: url)
                completed.insert(url)
            } catch {
                failures.append(ItemFailure(
                    sourceURL: url,
                    stage: .primary,
                    message: error.localizedDescription
                ))
            }
        }
        return BatchMutationResult(
            completedSourceURLs: completed,
            failures: failures,
            cancellationStoppedRemainingItems: cancellationStoppedRemainingItems
        )
    }

    /// Moves primary images and their existing XMP/editorial sidecars. A primary move is a
    /// committed success even when a companion move fails, matching the browser's existing
    /// partial-success contract while making each companion failure explicit.
    func moveImageItems(
        _ sourceURLs: [URL],
        into destinationFolder: URL,
        createDestinationIfNeeded: Bool,
        xmpSidecarService: XMPSidecarService,
        metadataSidecarService: MetadataSidecarService
    ) throws -> ImageMoveResult {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        var destinationWasCreated = false
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationFolder.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw Error.destinationIsNotDirectory(destinationFolder) }
        } else if createDestinationIfNeeded {
            try Task.checkCancellation()
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            destinationWasCreated = true
        } else {
            throw CocoaError(.fileNoSuchFile)
        }

        var moved: Set<URL> = []
        var failures: [ItemFailure] = []
        var cancellationStoppedRemainingItems = false
        for sourceURL in sourceURLs {
            if Task.isCancelled {
                cancellationStoppedRemainingItems = true
                break
            }
            let destinationURL = destinationFolder.appendingPathComponent(sourceURL.lastPathComponent)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                failures.append(ItemFailure(
                    sourceURL: sourceURL,
                    stage: .primary,
                    message: "The destination already contains this filename."
                ))
                continue
            }
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                moved.insert(sourceURL)
            } catch {
                failures.append(ItemFailure(
                    sourceURL: sourceURL,
                    stage: .primary,
                    message: error.localizedDescription
                ))
                continue
            }

            let xmpSource = xmpSidecarService.sidecarURL(for: sourceURL)
            if fileManager.fileExists(atPath: xmpSource.path) {
                do {
                    try fileManager.moveItem(
                        at: xmpSource,
                        to: xmpSidecarService.sidecarURL(for: destinationURL)
                    )
                } catch {
                    failures.append(ItemFailure(
                        sourceURL: sourceURL,
                        stage: .xmpSidecar,
                        message: error.localizedDescription
                    ))
                }
            }

            do {
                try metadataSidecarService.moveSidecar(
                    for: sourceURL,
                    from: sourceURL.deletingLastPathComponent(),
                    to: destinationFolder
                )
            } catch {
                failures.append(ItemFailure(
                    sourceURL: sourceURL,
                    stage: .metadataSidecar,
                    message: error.localizedDescription
                ))
            }
        }
        return ImageMoveResult(
            movedSourceURLs: moved,
            failures: failures,
            destinationWasCreated: destinationWasCreated,
            cancellationStoppedRemainingItems: cancellationStoppedRemainingItems
        )
    }

    /// Copies primary images using collision-free names selected inside this actor, then preserves
    /// the existing editorial JSON-sidecar behavior. Sidecar failures are reported without hiding
    /// a successfully-created primary duplicate.
    func duplicateImages(
        _ requests: [DuplicateRequest],
        in folderURL: URL,
        metadataSidecarService: MetadataSidecarService
    ) -> DuplicateResult {
        let fileManager = FileManager.default
        var completed: [DuplicateCompletion] = []
        var failures: [ItemFailure] = []
        var cancellationStoppedRemainingItems = false

        for request in requests {
            if Task.isCancelled {
                cancellationStoppedRemainingItems = true
                break
            }
            let source = request.source
            let fileExtension = source.url.pathExtension
            let baseName = source.url.deletingPathExtension().lastPathComponent
            var copyName = "\(baseName) copy"
            var destinationURL = folderURL.appendingPathComponent(copyName)
                .appendingPathExtension(fileExtension)
            var counter = 2
            while fileManager.fileExists(atPath: destinationURL.path) {
                copyName = "\(baseName) copy \(counter)"
                destinationURL = folderURL.appendingPathComponent(copyName)
                    .appendingPathExtension(fileExtension)
                counter += 1
            }
            if Task.isCancelled {
                cancellationStoppedRemainingItems = true
                break
            }

            do {
                try fileManager.copyItem(at: source.url, to: destinationURL)
            } catch {
                failures.append(ItemFailure(
                    sourceURL: source.url,
                    stage: .primary,
                    message: error.localizedDescription
                ))
                continue
            }

            if let sidecar = metadataSidecarService.loadSidecar(for: source.url, in: folderURL) {
                do {
                    try metadataSidecarService.saveSidecar(
                        sidecar,
                        for: destinationURL,
                        in: folderURL
                    )
                } catch {
                    failures.append(ItemFailure(
                        sourceURL: source.url,
                        stage: .metadataSidecar,
                        message: error.localizedDescription
                    ))
                }
            }
            completed.append(DuplicateCompletion(
                sourceURL: source.url,
                duplicate: ImageFile(url: destinationURL, copyingFrom: source)
            ))
        }
        return DuplicateResult(
            completed: completed,
            failures: failures,
            cancellationStoppedRemainingItems: cancellationStoppedRemainingItems
        )
    }

    private func moveFolder(
        from sourceURL: URL,
        to destinationURL: URL,
        kind: FolderMutationResult.Kind
    ) throws -> FolderMutationResult {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw Error.destinationAlreadyExists(destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return FolderMutationResult(
            kind: kind,
            sourceURL: sourceURL,
            resultingURL: destinationURL,
            cancellationRequestedAfterCommit: Task.isCancelled
        )
    }

    /// Avoid synchronously materializing evicted iCloud files while scanning.
    /// Directory enumeration and basic `stat` calls can block on placeholders;
    /// request the download and skip them until iCloud has created a local copy.
    private func locallyAvailableForEnumeration(_ url: URL) -> Bool {
        guard isLocallyAvailable(url) else {
            requestDownload(url)
            return false
        }
        return true
    }

    nonisolated private static func systemIsLocallyAvailable(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: url) else { return true }

        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values?.ubiquitousItemDownloadingStatus != .notDownloaded
    }
}
