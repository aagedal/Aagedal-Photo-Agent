import Foundation
import os

private nonisolated let backupLog = Logger(subsystem: "com.aagedal.photo-agent", category: "EditedFolderBackup")

/// Builds an `[ImportCopyService.CopyJob]` from a working folder by collecting
/// every rendered output (`Edited_*`/`Signed_*` subfolders, Develop's `Edited/`, the
/// configured custom export sub-folder and FTP's `Uploaded/`), the IPTC sidecar dir
/// (`.photo_metadata/`), the face-data dir (`.face_data/`) and the folder's `.xmp`
/// sidecars (which hold RAW develop edits).
///
/// The actual copy + verify is handled by `ImportCopyService`, so the same
/// SHA-256 verification path runs here as during import.
nonisolated struct EditedFolderBackupService: Sendable {

    struct DiscoveredFolder: Sendable, Identifiable {
        var id: String { relativePath }
        let sourceURL: URL
        let relativePath: String
        let fileCount: Int
        let totalBytes: Int64
        let kind: Kind
        /// When set, only these files are backed up instead of the whole directory
        /// (used for the loose `.xmp` sidecars next to the originals).
        var files: [URL]? = nil

        enum Kind: String, Sendable {
            case editedRender
            case signedRender
            case uploadedRender
            case metadataSidecars
            case faceData
            case xmpSidecars
        }
    }

    /// Develop's "Save" folder from earlier versions, and FTP's rendered-upload folder.
    static let developEditedFolderName = "Edited"
    static let uploadedFolderName = "Uploaded"
    static let xmpSidecarsRelativePath = "*.xmp"

    struct DiscoveryResult: Sendable {
        let folders: [DiscoveredFolder]
        var totalFiles: Int { folders.reduce(0) { $0 + $1.fileCount } }
        var totalBytes: Int64 { folders.reduce(0) { $0 + $1.totalBytes } }
    }

    /// Scan a working folder for backup-eligible content. Safe to call off the main actor.
    /// - Parameter customExportSubfolderName: the Export Location "Sub-folder Name" setting;
    ///   its top-level folder inside `folderURL` is treated as rendered output.
    static func discover(in folderURL: URL, customExportSubfolderName: String? = nil) -> DiscoveryResult {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return DiscoveryResult(folders: [])
        }

        let customFolderName = customExportSubfolderName.flatMap {
            topLevelFolderName(of: EditedImageRenderer.customSubfolder(in: folderURL, name: $0), under: folderURL)
        }

        var found: [DiscoveredFolder] = []
        var xmpSidecars: [URL] = []

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else {
                if child.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame,
                   (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    xmpSidecars.append(child)
                }
                continue
            }

            let name = child.lastPathComponent
            let kind: DiscoveredFolder.Kind?
            if name.hasPrefix("Edited_") || name == developEditedFolderName || name == customFolderName {
                kind = .editedRender
            } else if name.hasPrefix("Signed_") {
                kind = .signedRender
            } else if name == uploadedFolderName {
                kind = .uploadedRender
            } else if name == MetadataSidecarService.sidecarDirectoryName {
                kind = .metadataSidecars
            } else if name == FaceDataStorageService.faceDataDirectoryName {
                kind = .faceData
            } else {
                kind = nil
            }
            guard let kind else { continue }

            let stats = directoryStats(at: child)
            found.append(DiscoveredFolder(
                sourceURL: child,
                relativePath: name,
                fileCount: stats.fileCount,
                totalBytes: stats.totalBytes,
                kind: kind
            ))
        }

        if !xmpSidecars.isEmpty {
            let sorted = xmpSidecars.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let bytes = sorted.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            found.append(DiscoveredFolder(
                sourceURL: folderURL,
                relativePath: xmpSidecarsRelativePath,
                fileCount: sorted.count,
                totalBytes: bytes,
                kind: .xmpSidecars,
                files: sorted
            ))
        }

        return DiscoveryResult(folders: found.sorted { $0.relativePath < $1.relativePath })
    }

    /// The first path component of `url` below `root`, or nil when `url` is not inside it.
    private static func topLevelFolderName(of url: URL, under root: URL) -> String? {
        guard let relative = relativePath(of: url, under: root) else { return nil }
        return relative.split(separator: "/").first.map(String.init)
    }

    /// Build the flat list of `CopyJob`s mirroring `discovered` under `destinationRoot`.
    /// Each source file maps to a destination at the same relative path.
    static func buildJobs(
        from discovered: DiscoveryResult,
        sourceRoot: URL,
        destinationRoot: URL
    ) -> [ImportCopyService.CopyJob] {
        let fm = FileManager.default
        var jobs: [ImportCopyService.CopyJob] = []

        for folder in discovered.folders {
            if let files = folder.files {
                for file in files {
                    guard let relative = relativePath(of: file, under: sourceRoot) else { continue }
                    jobs.append(ImportCopyService.CopyJob(
                        source: file,
                        desiredPrimaryDest: destinationRoot.appendingPathComponent(relative),
                        desiredBackupDest: nil
                    ))
                }
                continue
            }
            guard let enumerator = fm.enumerator(
                at: folder.sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            while let item = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir), !isDir.boolValue else { continue }

                guard let relative = relativePath(of: item, under: sourceRoot) else { continue }
                let dest = destinationRoot.appendingPathComponent(relative)

                jobs.append(ImportCopyService.CopyJob(
                    source: item,
                    desiredPrimaryDest: dest,
                    desiredBackupDest: nil
                ))
            }
        }

        return jobs
    }

    // MARK: - Helpers

    private static func directoryStats(at url: URL) -> (fileCount: Int, totalBytes: Int64) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return (0, 0)
        }

        var count = 0
        var bytes: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                count += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (count, bytes)
    }

    private static func relativePath(of url: URL, under root: URL) -> String? {
        let urlComponents = url.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard urlComponents.count > rootComponents.count else { return nil }
        for (i, c) in rootComponents.enumerated() where urlComponents[i] != c {
            return nil
        }
        return urlComponents[rootComponents.count..<urlComponents.count].joined(separator: "/")
    }
}
