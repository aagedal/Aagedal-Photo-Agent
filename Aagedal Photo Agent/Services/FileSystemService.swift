import Foundation

struct FileSystemService: Sendable {
    func scanFolder(at url: URL) throws -> [ImageFile] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        return contents
            .filter { SupportedImageFormats.isSupported(url: $0) }
            .map { ImageFile(url: $0) }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
}
