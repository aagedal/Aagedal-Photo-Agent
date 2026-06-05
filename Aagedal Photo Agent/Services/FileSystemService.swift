import Foundation

struct FileSystemService: Sendable {
    /// Scans a folder for image files. `nonisolated async` so the directory
    /// enumeration plus the per-file `stat` (in `ImageFile.init`) run on the
    /// cooperative pool rather than blocking the MainActor on folder open —
    /// a multi-thousand-image folder would otherwise stall the UI before the
    /// first frame.
    nonisolated func scanFolder(at url: URL, includeAllFiles: Bool = false) async throws -> [ImageFile] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        let filtered = includeAllFiles
            ? contents.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            : contents.filter { SupportedImageFormats.isSupported(url: $0) }
        return filtered.map { ImageFile(url: $0) }
    }

    nonisolated func listSubfolders(at url: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        return contents
            .filter { item in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
