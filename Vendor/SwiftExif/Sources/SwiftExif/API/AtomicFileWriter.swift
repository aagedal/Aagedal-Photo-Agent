import Foundation

/// Installs rewritten metadata bytes without changing whether the destination is visible.
///
/// `FileManager.replaceItemAt` normally carries the destination's metadata forward, but
/// providers such as iCloud Drive can intermittently retain the hidden state of our
/// dot-prefixed staging file instead. Capture and restore visibility explicitly so an
/// ordinary image, audio file, or video cannot disappear from Finder after a metadata write.
enum AtomicFileWriter {
    static func replaceContents(
        of destinationURL: URL,
        with data: Data
    ) throws {
        let fileManager = FileManager.default
        let wasHidden = try destinationURL.resourceValues(
            forKeys: [.isHiddenKey]
        ).isHidden ?? false
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".swiftexif_tmp_\(UUID().uuidString)")

        do {
            try data.write(to: temporaryURL)
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )

            var visibility = URLResourceValues()
            visibility.isHidden = wasHidden
            var installedURL = destinationURL
            try installedURL.setResourceValues(visibility)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
