import Foundation

/// Immutable evidence for one Browser metadata batch. `processedURLs` is always an exact prefix
/// of `requestedURLs`, so a cancelled read never disguises partial filesystem work as a complete
/// snapshot. Sidecars that do not exist are still represented by their processed URL.
nonisolated struct BrowserXMPSidecarBatchSnapshot: Equatable, Sendable {
    let requestID: UUID
    let requestedURLs: [URL]
    let processedURLs: [URL]
    let dataByImageURL: [URL: Data]

    var isComplete: Bool {
        processedURLs.count == requestedURLs.count
    }
}

/// Synchronous Foundation reads cannot be interrupted once started. These cases preserve whether
/// cancellation prevented all work, stopped after an exact partial prefix, or arrived only after
/// the complete snapshot had already been read.
nonisolated enum BrowserXMPSidecarBatchLoadResult: Equatable, Sendable {
    case complete(BrowserXMPSidecarBatchSnapshot)
    case cancelledBeforeRead(requestID: UUID, requestedURLs: [URL])
    case cancelledAfterPartialRead(BrowserXMPSidecarBatchSnapshot)
    case cancelledAfterCompleteRead(BrowserXMPSidecarBatchSnapshot)
}

nonisolated struct BrowserXMPSidecarAccess: Sendable {
    let read: @Sendable (URL) -> Data?

    static let system = BrowserXMPSidecarAccess { imageURL in
        XMPSidecarService().sidecarDataIfExists(for: imageURL)
    }
}

/// Serializes Browser XMP sidecar reads away from MainActor. A single batch no longer launches an
/// unbounded task per file, and queued Browser requests can be cancelled before touching a slow
/// card, network volume, or iCloud placeholder.
actor BrowserXMPSidecarLoadService {
    private let access: BrowserXMPSidecarAccess

    init(access: BrowserXMPSidecarAccess = .system) {
        self.access = access
    }

    func load(
        imageURLs: [URL],
        requestID: UUID
    ) -> BrowserXMPSidecarBatchLoadResult {
        guard !Task.isCancelled else {
            return .cancelledBeforeRead(requestID: requestID, requestedURLs: imageURLs)
        }

        var processedURLs: [URL] = []
        processedURLs.reserveCapacity(imageURLs.count)
        var dataByImageURL: [URL: Data] = [:]

        for imageURL in imageURLs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: imageURLs,
                    processedURLs: processedURLs,
                    dataByImageURL: dataByImageURL
                )
            }

            let data = access.read(imageURL)
            processedURLs.append(imageURL)
            if let data {
                dataByImageURL[imageURL] = data
            }

            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: imageURLs,
                    processedURLs: processedURLs,
                    dataByImageURL: dataByImageURL
                )
            }
        }

        return .complete(BrowserXMPSidecarBatchSnapshot(
            requestID: requestID,
            requestedURLs: imageURLs,
            processedURLs: processedURLs,
            dataByImageURL: dataByImageURL
        ))
    }

    private func cancelledResult(
        requestID: UUID,
        requestedURLs: [URL],
        processedURLs: [URL],
        dataByImageURL: [URL: Data]
    ) -> BrowserXMPSidecarBatchLoadResult {
        let snapshot = BrowserXMPSidecarBatchSnapshot(
            requestID: requestID,
            requestedURLs: requestedURLs,
            processedURLs: processedURLs,
            dataByImageURL: dataByImageURL
        )
        if snapshot.isComplete {
            return .cancelledAfterCompleteRead(snapshot)
        }
        return .cancelledAfterPartialRead(snapshot)
    }
}
