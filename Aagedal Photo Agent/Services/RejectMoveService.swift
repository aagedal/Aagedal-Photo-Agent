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
        let cancellationStoppedRemainingItems: Bool
    }

    /// Move the given image URLs (and per-image sidecars) into `.Rejected/` under
    /// `folderURL`. The destination folder is created lazily.
    static func moveRejected(
        urls: [URL],
        in folderURL: URL,
        bundleDidCommit: @Sendable (URL) -> Void = { _ in },
        voiceMemoRepository: VoiceMemoCompanionRepository = VoiceMemoCompanionRepository()
    ) -> MoveResult {
        let fm = FileManager.default
        let sidecarService = MetadataSidecarService()
        let rejectedFolder = folderURL.appendingPathComponent(rejectedFolderName)

        var moved: [URL] = []
        var failed: [(URL, String)] = []
        var cancellationStoppedRemainingItems = false

        guard !urls.isEmpty else {
            return MoveResult(
                rejectedFolder: rejectedFolder,
                movedFiles: [],
                failedFiles: [],
                cancellationStoppedRemainingItems: false
            )
        }

        // Do not create an otherwise-empty destination when the caller was cancelled before
        // this serialized operation began. Once a bundle move starts it runs through commit or
        // rollback; cancellation is observed between bundles so disk state remains explicit.
        guard !Task.isCancelled else {
            return MoveResult(
                rejectedFolder: rejectedFolder,
                movedFiles: [],
                failedFiles: [],
                cancellationStoppedRemainingItems: true
            )
        }

        do {
            try fm.createDirectory(at: rejectedFolder, withIntermediateDirectories: true)
        } catch {
            return MoveResult(
                rejectedFolder: rejectedFolder,
                movedFiles: [],
                failedFiles: urls.map { ($0, "Could not create .Rejected folder: \(error.localizedDescription)") },
                cancellationStoppedRemainingItems: false
            )
        }

        // Sidecar files we move alongside the image:
        // - JSON sidecar at <folder>/.photo_metadata/<file>.meta.json
        // - XMP sidecar at <folder>/<basename>.xmp
        for url in urls {
            if Task.isCancelled {
                cancellationStoppedRemainingItems = true
                break
            }
            let dest: URL
            do {
                guard let available = try uniqueBundleDestination(
                    for: url, in: rejectedFolder, fm: fm,
                    voiceMemoRepository: voiceMemoRepository
                ) else {
                    failed.append((url, "Could not find an available name in .Rejected"))
                    continue
                }
                dest = available
            } catch {
                failed.append((url, error.localizedDescription))
                continue
            }

            let xmpSource = url.deletingPathExtension().appendingPathExtension("xmp")
            let xmpDestination = dest.deletingPathExtension().appendingPathExtension("xmp")
            var xmpMoved = false
            var xmpCopied = false

            do {
                let receipt = try voiceMemoRepository.moveImagePreservingCompanion(from: url, to: dest) {
                    do {
                        if fm.fileExists(atPath: xmpSource.path) {
                            let sharedStem = try PhotoSidecarOwnership.hasSurvivingStemSibling(of: url, in: folderURL)
                            if sharedStem {
                                try PhotoSidecarOwnership.copyPreservingSource(from: xmpSource, to: xmpDestination)
                                xmpCopied = true
                            } else {
                                try fm.moveItem(at: xmpSource, to: xmpDestination)
                                xmpMoved = true
                            }
                        }
                        try sidecarService.relocateSidecar(
                            for: url, to: dest, from: folderURL, to: rejectedFolder
                        )
                    } catch {
                        let originalError = error
                        if xmpMoved || xmpCopied {
                            do {
                                if xmpCopied { try fm.removeItem(at: xmpDestination) }
                                else { try fm.moveItem(at: xmpDestination, to: xmpSource) }
                            }
                            catch {
                                throw NSError(domain: "RejectMoveService", code: 1, userInfo: [
                                    NSLocalizedDescriptionKey: originalError.localizedDescription
                                        + " (XMP rollback failed at \(xmpDestination.path): \(error.localizedDescription))"
                                ])
                            }
                        }
                        throw originalError
                    }
                }
                if !receipt.cleanupResidualURLs.isEmpty {
                    failed.append((url, "Photo moved successfully; private source backups need cleanup: "
                        + receipt.cleanupResidualURLs.map(\.path).joined(separator: ", ")))
                }
            } catch is CancellationError {
                cancellationStoppedRemainingItems = true
                break
            } catch {
                let message = error.localizedDescription
                failed.append((url, message))
                rejectLog.error("Failed to move \(url.lastPathComponent, privacy: .private(mask: .hash)): \(message, privacy: .private)")
                continue
            }
            moved.append(dest)
            // A synchronous seam lets cancellation tests pause after a complete bundle commits.
            // Production uses the no-op default, so cancellation remains observable only between
            // transactional bundles and can never interrupt image/sidecar commit or rollback.
            bundleDidCommit(dest)
        }

        rejectLog.info("Rejected move complete: \(moved.count) moved, \(failed.count) failed")
        return MoveResult(
            rejectedFolder: rejectedFolder,
            movedFiles: moved,
            failedFiles: failed,
            cancellationStoppedRemainingItems: cancellationStoppedRemainingItems
        )
    }

    /// Append `-1`, `-2`, etc. until the image and every sidecar name are all
    /// available. Reserving the complete bundle prevents a stale sidecar from
    /// becoming associated with the newly moved image.
    private static func uniqueBundleDestination(
        for sourceImageURL: URL,
        in folder: URL,
        fm: FileManager,
        voiceMemoRepository: VoiceMemoCompanionRepository
    ) throws -> URL? {
        let asURL = sourceImageURL
        let basename = asURL.deletingPathExtension().lastPathComponent
        let ext = asURL.pathExtension
        for index in 0..<10_000 {
            let numberedBasename = index == 0 ? basename : "\(basename)-\(index)"
            let candidate = ext.isEmpty
                ? folder.appendingPathComponent(numberedBasename)
                : folder.appendingPathComponent(numberedBasename).appendingPathExtension(ext)
            let voiceMemoDestinations = try voiceMemoRepository.moveDestinationURLs(for: sourceImageURL, to: candidate)
            if bundleDestinations(for: candidate, in: folder).union(voiceMemoDestinations).allSatisfy({
                !fm.fileExists(atPath: $0.path)
            }) {
                return candidate
            }
        }
        return nil
    }

    private static func bundleDestinations(for imageURL: URL, in folder: URL) -> Set<URL> {
        let sidecarFolder = folder.appendingPathComponent(MetadataSidecarService.sidecarDirectoryName)
        let currentJSON = sidecarFolder.appendingPathComponent("\(imageURL.lastPathComponent).meta.json")
        let legacyJSON = sidecarFolder.appendingPathComponent(
            "\(imageURL.deletingPathExtension().lastPathComponent).meta.json"
        )
        return [
            imageURL,
            imageURL.deletingPathExtension().appendingPathExtension("xmp"),
            currentJSON,
            legacyJSON,
        ]
    }
}
