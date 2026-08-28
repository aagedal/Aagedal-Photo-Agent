import Foundation
import os

/// Serializes recursive import-source scans away from the main actor.
///
/// Directory enumeration is synchronous Foundation I/O, so callers cross this actor boundary
/// instead of walking a card or network volume from UI-isolated code. Results are immutable and
/// cancellation is observed throughout the walk, before any result can be published.
actor ImportSourceDiscoveryService {
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

    func discoverFiles(at rootURL: URL) async throws -> [URL] {
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
            while let itemURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try itemURL.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    files.append(itemURL)
                }
            }
            try Task.checkCancellation()
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
