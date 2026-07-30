import Foundation

struct FileSystemService: Sendable {
    struct FolderScanResult: Sendable {
        let files: [ImageFile]
        let deferredICloudItemCount: Int

        var hasDeferredICloudItems: Bool { deferredICloudItemCount > 0 }
    }

    private let isLocallyAvailable: @Sendable (URL) -> Bool
    private let requestDownload: @Sendable (URL) -> Void

    init(
        isLocallyAvailable: @escaping @Sendable (URL) -> Bool = {
            Self.systemIsLocallyAvailable($0)
        },
        requestDownload: @escaping @Sendable (URL) -> Void = {
            try? FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
    ) {
        self.isLocallyAvailable = isLocallyAvailable
        self.requestDownload = requestDownload
    }

    /// Scans a folder for image files. `nonisolated async` so the directory
    /// enumeration plus the per-file `stat` (in `ImageFile.init`) run on the
    /// cooperative pool rather than blocking the MainActor on folder open —
    /// a multi-thousand-image folder would otherwise stall the UI before the
    /// first frame.
    nonisolated func scanFolder(at url: URL, includeAllFiles: Bool = false) async throws -> [ImageFile] {
        try await scanFolderWithStatus(at: url, includeAllFiles: includeAllFiles).files
    }

    nonisolated func scanFolderWithStatus(at url: URL, includeAllFiles: Bool = false) async throws -> FolderScanResult {
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
        for item in contents {
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

    nonisolated func listSubfolders(at url: URL) throws -> [URL] {
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

        return contents
            .filter { item in
                guard locallyAvailableForEnumeration(item) else { return false }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Avoid synchronously materializing evicted iCloud files while scanning.
    /// Directory enumeration and basic `stat` calls can block on placeholders;
    /// request the download and skip them until iCloud has created a local copy.
    nonisolated private func locallyAvailableForEnumeration(_ url: URL) -> Bool {
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
