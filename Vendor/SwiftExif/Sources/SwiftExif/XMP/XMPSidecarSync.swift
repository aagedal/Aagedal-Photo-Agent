import Foundation

/// Utilities for XMP sidecar lifecycle management.
public struct XMPSidecarSync: Sendable {

    /// Find orphan .xmp sidecar files that have no matching image file.
    public static func findOrphans(
        in directory: URL,
        recursive: Bool = false,
        imageExtensions: Set<String> = defaultImageExtensions
    ) throws -> [URL] {
        let fm = FileManager.default
        let enumerator: FileManager.DirectoryEnumerator?

        if recursive {
            enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
        } else {
            let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return findOrphansIn(files: contents, imageExtensions: imageExtensions)
        }

        guard let enumerator else { return [] }

        var allFiles: [URL] = []
        for case let url as URL in enumerator {
            allFiles.append(url)
        }

        return findOrphansIn(files: allFiles, imageExtensions: imageExtensions)
    }

    /// Remove orphan .xmp sidecar files. Returns the list of removed files.
    public static func cleanupOrphans(
        in directory: URL,
        recursive: Bool = false,
        dryRun: Bool = true
    ) throws -> [URL] {
        let orphans = try findOrphans(in: directory, recursive: recursive)
        if dryRun { return orphans }

        let fm = FileManager.default
        var removed: [URL] = []
        for url in orphans {
            try fm.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }

    // MARK: - Private

    public static let defaultImageExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "dng", "cr2", "nef", "arw",
        "jxl", "png", "avif", "heic", "heif", "webp", "cr3",
        "raf", "rw2", "orf", "pef", "psd", "psb", "pdf",
    ]

    private static func findOrphansIn(files: [URL], imageExtensions: Set<String>) -> [URL] {
        // Build set of image stems (filename without extension)
        var imageStems = Set<String>()
        for url in files {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                let stem = url.deletingPathExtension().lastPathComponent
                imageStems.insert(stem.lowercased())
            }
        }

        // Find .xmp files whose stem doesn't match any image
        var orphans: [URL] = []
        for url in files {
            if url.pathExtension.lowercased() == "xmp" {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                if !imageStems.contains(stem) {
                    orphans.append(url)
                }
            }
        }

        return orphans
    }
}
