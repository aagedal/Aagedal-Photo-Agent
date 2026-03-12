import Foundation

struct FileSystemService: Sendable {
    func scanFolder(at url: URL, includeAllFiles: Bool = false) throws -> [ImageFile] {
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

    func listSubfolders(at url: URL) throws -> [URL] {
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
