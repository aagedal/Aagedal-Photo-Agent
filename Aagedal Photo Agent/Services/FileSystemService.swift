import Foundation

actor FileSystemService {
    enum Error: Swift.Error, Sendable, Equatable {
        case destinationAlreadyExists(URL)
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

    private let isLocallyAvailable: @Sendable (URL) -> Bool
    private let requestDownload: @Sendable (URL) -> Void

    init(
        isLocallyAvailable: @escaping @Sendable (URL) -> Bool = {
            FileSystemService.systemIsLocallyAvailable($0)
        },
        requestDownload: @escaping @Sendable (URL) -> Void = {
            try? FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
    ) {
        self.isLocallyAvailable = isLocallyAvailable
        self.requestDownload = requestDownload
    }

    /// Scans a folder for image files on this service's serialized actor executor. Directory
    /// enumeration plus the per-file `stat` (in `ImageFile.init`) therefore cannot block the
    /// MainActor, and overlapping scans/mutations cannot race one another.
    func scanFolder(at url: URL, includeAllFiles: Bool = false) async throws -> [ImageFile] {
        try await scanFolderWithStatus(at: url, includeAllFiles: includeAllFiles).files
    }

    func scanFolderWithStatus(at url: URL, includeAllFiles: Bool = false) async throws -> FolderScanResult {
        try Task.checkCancellation()
        guard locallyAvailableForEnumeration(url) else {
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
        return FolderScanResult(
            files: files,
            deferredICloudItemCount: deferredICloudItemCount
        )
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
