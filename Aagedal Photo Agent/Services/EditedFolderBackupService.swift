import Foundation
import os

private nonisolated let backupLog = Logger(subsystem: "com.aagedal.photo-agent", category: "EditedFolderBackup")

/// Builds an `[ImportCopyService.CopyJob]` from a working folder by collecting
/// every rendered output (`Edited_*` and `Signed_*` subfolders), the IPTC
/// sidecar dir (`.photo_metadata/`) and the face-data dir (`.face_data/`).
///
/// The actual copy + verify is handled by `ImportCopyService`, so the same
/// SHA-256 verification path runs here as during import.
nonisolated struct EditedFolderBackupService: Sendable {

    struct DiscoveredFolder: Sendable, Identifiable {
        var id: URL { sourceURL }
        let sourceURL: URL
        let relativePath: String
        let fileCount: Int
        let totalBytes: Int64
        let kind: Kind

        enum Kind: String, Sendable {
            case editedRender
            case signedRender
            case metadataSidecars
            case faceData
        }
    }

    struct DiscoveryResult: Sendable {
        let folders: [DiscoveredFolder]
        var totalFiles: Int { folders.reduce(0) { $0 + $1.fileCount } }
        var totalBytes: Int64 { folders.reduce(0) { $0 + $1.totalBytes } }
    }

    /// Scan a working folder for backup-eligible content. Safe to call off the main actor.
    static func discover(in folderURL: URL) -> DiscoveryResult {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return DiscoveryResult(folders: [])
        }

        var found: [DiscoveredFolder] = []

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let name = child.lastPathComponent
            let kind: DiscoveredFolder.Kind?
            if name.hasPrefix("Edited_") {
                kind = .editedRender
            } else if name.hasPrefix("Signed_") {
                kind = .signedRender
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

        return DiscoveryResult(folders: found.sorted { $0.relativePath < $1.relativePath })
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
