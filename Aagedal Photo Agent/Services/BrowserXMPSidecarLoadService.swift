import Foundation
import os.log

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

/// Immutable native-HDR classification evidence for one Browser metadata batch. Every inspected
/// URL has an explicit Boolean result, and `inspectedURLs` is always an exact prefix of the
/// request so cancellation cannot turn partial container reads into publishable state.
nonisolated struct BrowserHDRClassificationSnapshot: Equatable, Sendable {
    let requestID: UUID
    let requestedURLs: [URL]
    let inspectedURLs: [URL]
    let isHDRByImageURL: [URL: Bool]

    var isComplete: Bool {
        inspectedURLs.count == requestedURLs.count
    }
}

/// ImageIO and mapped container reads are synchronous once entered. These cases preserve whether
/// cancellation prevented all work, stopped after an exact prefix, or arrived after the final
/// classification completed.
nonisolated enum BrowserHDRClassificationResult: Equatable, Sendable {
    case complete(BrowserHDRClassificationSnapshot)
    case cancelledBeforeRead(requestID: UUID, requestedURLs: [URL])
    case cancelledAfterPartialRead(BrowserHDRClassificationSnapshot)
    case cancelledAfterCompleteRead(BrowserHDRClassificationSnapshot)
}

nonisolated struct BrowserHDRClassificationAccess: Sendable {
    let isHDR: @Sendable (URL) -> Bool

    static let system = BrowserHDRClassificationAccess { imageURL in
        SupportedImageFormats.isHDR(url: imageURL)
    }
}

/// Serializes Browser native-HDR container inspection away from MainActor. Browser metadata
/// publication receives only immutable complete evidence, while queued work can be cancelled
/// before touching a slow card, network volume, or iCloud placeholder.
actor BrowserHDRClassificationService {
    static let shared = BrowserHDRClassificationService()

    private let access: BrowserHDRClassificationAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "BrowserHDRClassification"
    )

    init(access: BrowserHDRClassificationAccess = .system) {
        self.access = access
    }

    func classify(
        imageURLs: [URL],
        requestID: UUID
    ) -> BrowserHDRClassificationResult {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Classify", id: signpostID)

        guard !Task.isCancelled else {
            signposter.endInterval("Classify", interval, "result=cancelled inspected=0")
            return .cancelledBeforeRead(requestID: requestID, requestedURLs: imageURLs)
        }

        var inspectedURLs: [URL] = []
        inspectedURLs.reserveCapacity(imageURLs.count)
        var isHDRByImageURL: [URL: Bool] = [:]
        isHDRByImageURL.reserveCapacity(imageURLs.count)

        for imageURL in imageURLs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: imageURLs,
                    inspectedURLs: inspectedURLs,
                    isHDRByImageURL: isHDRByImageURL,
                    interval: interval
                )
            }

            isHDRByImageURL[imageURL] = access.isHDR(imageURL)
            inspectedURLs.append(imageURL)

            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedURLs: imageURLs,
                    inspectedURLs: inspectedURLs,
                    isHDRByImageURL: isHDRByImageURL,
                    interval: interval
                )
            }
        }

        let snapshot = BrowserHDRClassificationSnapshot(
            requestID: requestID,
            requestedURLs: imageURLs,
            inspectedURLs: inspectedURLs,
            isHDRByImageURL: isHDRByImageURL
        )
        signposter.endInterval(
            "Classify",
            interval,
            "result=complete inspected=\(inspectedURLs.count)"
        )
        return .complete(snapshot)
    }

    private func cancelledResult(
        requestID: UUID,
        requestedURLs: [URL],
        inspectedURLs: [URL],
        isHDRByImageURL: [URL: Bool],
        interval: OSSignpostIntervalState
    ) -> BrowserHDRClassificationResult {
        let snapshot = BrowserHDRClassificationSnapshot(
            requestID: requestID,
            requestedURLs: requestedURLs,
            inspectedURLs: inspectedURLs,
            isHDRByImageURL: isHDRByImageURL
        )
        signposter.endInterval(
            "Classify",
            interval,
            "result=cancelled inspected=\(inspectedURLs.count)"
        )
        return snapshot.isComplete
            ? .cancelledAfterCompleteRead(snapshot)
            : .cancelledAfterPartialRead(snapshot)
    }
}
