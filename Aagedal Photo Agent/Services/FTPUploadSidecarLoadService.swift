import Foundation
import os

/// Immutable XMP metadata evidence for one FTP upload inspection. Every inspected URL is
/// represented in `inspectedImageURLs`, including files with no readable sidecar, so callers can
/// distinguish a complete absence result from a cancelled prefix.
nonisolated struct FTPUploadSidecarSnapshot: Equatable, Sendable {
    let requestID: UUID
    let requestedImageURLs: [URL]
    let inspectedImageURLs: [URL]
    let metadataByImageURL: [URL: IPTCMetadata]

    var isComplete: Bool {
        inspectedImageURLs.count == requestedImageURLs.count
    }
}

/// A sidecar or angled-crop image-aspect read cannot be interrupted after Foundation enters it.
/// These cases retain the exact completed prefix and distinguish cancellation after the final read
/// from an ordinary complete request.
nonisolated enum FTPUploadSidecarLoadResult: Equatable, Sendable {
    case complete(FTPUploadSidecarSnapshot)
    case cancelledBeforeRead(requestID: UUID, requestedImageURLs: [URL])
    case cancelledAfterPartialRead(FTPUploadSidecarSnapshot)
    case cancelledAfterCompleteRead(FTPUploadSidecarSnapshot)
}

nonisolated struct FTPUploadSidecarAccess: Sendable {
    let load: @Sendable (URL) -> IPTCMetadata?

    static let system = FTPUploadSidecarAccess { imageURL in
        XMPSidecarService().loadSidecar(for: imageURL)
    }
}

/// Serializes FTP preflight and sidecar-to-file action reads away from MainActor. Keeping the
/// complete `XMPSidecarService.loadSidecar` call here also keeps its conditional image-aspect probe
/// off the UI executor when an angled crop needs conversion.
actor FTPUploadSidecarLoadService {
    static let shared = FTPUploadSidecarLoadService()

    private let access: FTPUploadSidecarAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "FTPUploadSidecarLoad"
    )

    init(access: FTPUploadSidecarAccess = .system) {
        self.access = access
    }

    func load(
        imageURLs: [URL],
        requestID: UUID
    ) -> FTPUploadSidecarLoadResult {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Load", id: signpostID)

        guard !Task.isCancelled else {
            signposter.endInterval("Load", interval, "result=cancelled inspected=0")
            return .cancelledBeforeRead(
                requestID: requestID,
                requestedImageURLs: imageURLs
            )
        }

        var inspectedImageURLs: [URL] = []
        inspectedImageURLs.reserveCapacity(imageURLs.count)
        var metadataByImageURL: [URL: IPTCMetadata] = [:]
        metadataByImageURL.reserveCapacity(imageURLs.count)

        for imageURL in imageURLs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedImageURLs: imageURLs,
                    inspectedImageURLs: inspectedImageURLs,
                    metadataByImageURL: metadataByImageURL,
                    interval: interval
                )
            }

            let metadata = access.load(imageURL)
            inspectedImageURLs.append(imageURL)
            if let metadata {
                metadataByImageURL[imageURL] = metadata
            }

            guard !Task.isCancelled else {
                return cancelledResult(
                    requestID: requestID,
                    requestedImageURLs: imageURLs,
                    inspectedImageURLs: inspectedImageURLs,
                    metadataByImageURL: metadataByImageURL,
                    interval: interval
                )
            }
        }

        let snapshot = FTPUploadSidecarSnapshot(
            requestID: requestID,
            requestedImageURLs: imageURLs,
            inspectedImageURLs: inspectedImageURLs,
            metadataByImageURL: metadataByImageURL
        )
        signposter.endInterval(
            "Load",
            interval,
            "result=complete inspected=\(inspectedImageURLs.count) found=\(metadataByImageURL.count)"
        )
        return .complete(snapshot)
    }

    private func cancelledResult(
        requestID: UUID,
        requestedImageURLs: [URL],
        inspectedImageURLs: [URL],
        metadataByImageURL: [URL: IPTCMetadata],
        interval: OSSignpostIntervalState
    ) -> FTPUploadSidecarLoadResult {
        let snapshot = FTPUploadSidecarSnapshot(
            requestID: requestID,
            requestedImageURLs: requestedImageURLs,
            inspectedImageURLs: inspectedImageURLs,
            metadataByImageURL: metadataByImageURL
        )
        signposter.endInterval(
            "Load",
            interval,
            "result=cancelled inspected=\(inspectedImageURLs.count) found=\(metadataByImageURL.count)"
        )
        if snapshot.isComplete {
            return .cancelledAfterCompleteRead(snapshot)
        }
        return .cancelledAfterPartialRead(snapshot)
    }
}
