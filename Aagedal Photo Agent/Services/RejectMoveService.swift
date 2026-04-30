import Foundation
import os

private nonisolated let rejectLog = Logger(subsystem: "com.aagedal.photo-agent", category: "RejectMove")

/// Moves images flagged with `ColorLabel.trash` (and any image-specific sidecar
/// artifacts that live alongside them) into a `.Rejected/` subfolder of the
/// working folder. PhotoMechanic-style "ship the rejects" cleanup so the user
/// can focus on picks before metadata work.
nonisolated struct RejectMoveService: Sendable {

    static let rejectedFolderName = ".Rejected"

    struct MoveResult: Sendable {
        let rejectedFolder: URL
        let movedFiles: [URL]
        let failedFiles: [(URL, String)]
    }

    /// Move the given image URLs (and per-image sidecars) into `.Rejected/` under
    /// `folderURL`. The destination folder is created lazily.
    static func moveRejected(
        urls: [URL],
        in folderURL: URL
    ) -> MoveResult {
        let fm = FileManager.default
        let rejectedFolder = folderURL.appendingPathComponent(rejectedFolderName)

        var moved: [URL] = []
        var failed: [(URL, String)] = []

        guard !urls.isEmpty else {
            return MoveResult(rejectedFolder: rejectedFolder, movedFiles: [], failedFiles: [])
        }

        do {
            try fm.createDirectory(at: rejectedFolder, withIntermediateDirectories: true)
        } catch {
            return MoveResult(
                rejectedFolder: rejectedFolder,
                movedFiles: [],
                failedFiles: urls.map { ($0, "Could not create .Rejected folder: \(error.localizedDescription)") }
            )
        }

        // Sidecar files we move alongside the image:
        // - JSON sidecar at <folder>/.photo_metadata/<file>.meta.json
        // - XMP sidecar at <folder>/<basename>.xmp
        let sidecarRoot = folderURL.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        let rejectedSidecarRoot = rejectedFolder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)

        for url in urls {
            let dest = uniqueDestination(for: url.lastPathComponent, in: rejectedFolder, fm: fm)
            do {
                try fm.moveItem(at: url, to: dest)
                moved.append(dest)
            } catch {
                failed.append((url, error.localizedDescription))
                rejectLog.error("Failed to move \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // JSON sidecar
            let jsonName = "\(url.lastPathComponent).meta.json"
            let jsonSource = sidecarRoot.appendingPathComponent(jsonName)
            if fm.fileExists(atPath: jsonSource.path) {
                try? fm.createDirectory(at: rejectedSidecarRoot, withIntermediateDirectories: true)
                let jsonDest = uniqueDestination(for: jsonName, in: rejectedSidecarRoot, fm: fm)
                try? fm.moveItem(at: jsonSource, to: jsonDest)
            }

            // XMP sidecar (DNG/RAW workflow)
            let xmpSource = url.deletingPathExtension().appendingPathExtension("xmp")
            if fm.fileExists(atPath: xmpSource.path) {
                let xmpDest = uniqueDestination(for: xmpSource.lastPathComponent, in: rejectedFolder, fm: fm)
                try? fm.moveItem(at: xmpSource, to: xmpDest)
            }
        }

        rejectLog.info("Rejected move complete: \(moved.count) moved, \(failed.count) failed")
        return MoveResult(rejectedFolder: rejectedFolder, movedFiles: moved, failedFiles: failed)
    }

    /// Append `-1`, `-2`, etc. if a file with the same name already exists in dest.
    private static func uniqueDestination(for filename: String, in folder: URL, fm: FileManager) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let asURL = URL(fileURLWithPath: filename)
        let basename = asURL.deletingPathExtension().lastPathComponent
        let ext = asURL.pathExtension
        for index in 1..<10_000 {
            let next = ext.isEmpty
                ? folder.appendingPathComponent("\(basename)-\(index)")
                : folder.appendingPathComponent("\(basename)-\(index).\(ext)")
            if !fm.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }
}
