import Foundation
import os

struct ImportSourceDiscoveryProgress: Equatable, Sendable {
    var discoveredFileCount: Int = 0
    var supportedImageCount: Int = 0
    var wavFileCount: Int = 0
}

/// Serializes recursive import-source scans away from the main actor.
///
/// Directory enumeration is synchronous Foundation I/O, so callers cross this actor boundary
/// instead of walking a card or network volume from UI-isolated code. Results are immutable and
/// cancellation is observed throughout the walk, before any result can be published.
actor ImportSourceDiscoveryService {
    nonisolated static let defaultProgressUpdateInterval: Duration = .seconds(5)

    enum DiscoveryError: LocalizedError, Sendable, Equatable {
        case couldNotEnumerate(URL)

        var errorDescription: String? {
            switch self {
            case .couldNotEnumerate(let url):
                "The import source could not be read: \(url.lastPathComponent)"
            }
        }
    }

    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "ImportSourceDiscovery"
    )

    func discoverFiles(
        at rootURL: URL,
        progressUpdateInterval: Duration = ImportSourceDiscoveryService.defaultProgressUpdateInterval,
        onProgress: (@Sendable (ImportSourceDiscoveryProgress) async -> Void)? = nil
    ) async throws -> [URL] {
        let interval = signposter.beginInterval(
            "RecursiveSourceScan",
            id: signposter.makeSignpostID()
        )

        do {
            try Task.checkCancellation()
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw DiscoveryError.couldNotEnumerate(rootURL)
            }

            var files: [URL] = []
            var progress = ImportSourceDiscoveryProgress()
            let clock = ContinuousClock()
            var nextProgressUpdate = clock.now.advanced(by: progressUpdateInterval)
            var lastReportedProgress: ImportSourceDiscoveryProgress?
            while let itemURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    files.append(itemURL)
                    progress.discoveredFileCount += 1
                    if SupportedImageFormats.isSupported(url: itemURL) {
                        progress.supportedImageCount += 1
                    }
                    if itemURL.pathExtension.caseInsensitiveCompare("wav") == .orderedSame {
                        progress.wavFileCount += 1
                    }
                }

                if let onProgress, clock.now >= nextProgressUpdate {
                    await onProgress(progress)
                    lastReportedProgress = progress
                    nextProgressUpdate = clock.now.advanced(by: progressUpdateInterval)
                }
            }
            try Task.checkCancellation()
            if let onProgress, lastReportedProgress != progress {
                await onProgress(progress)
            }
            signposter.endInterval(
                "RecursiveSourceScan",
                interval,
                "result=ready itemCount=\(files.count, privacy: .private)"
            )
            return files
        } catch is CancellationError {
            signposter.endInterval("RecursiveSourceScan", interval, "result=cancelled")
            throw CancellationError()
        } catch {
            signposter.endInterval("RecursiveSourceScan", interval, "result=failed")
            throw error
        }
    }
}
