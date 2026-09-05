import Foundation
import os

/// Immutable XMP, app-sidecar, and reconciliation evidence for one image in the Metadata editor.
/// The synchronous reads used to produce this value have completed before it crosses back to the
/// main actor.
nonisolated struct MetadataEditorSourceFacts: Sendable {
    let imageURL: URL
    let xmpMetadata: IPTCMetadata?
    let appSidecar: MetadataSidecar?
    let reconciliationVerdict: SidecarReconciliation.Verdict?
}

/// One ordered Metadata-editor read request. Embedded metadata is already produced by the
/// serialized SwiftExif reader; carrying it here lets timestamp reconciliation stay in the same
/// off-main operation as the sidecar reads.
nonisolated struct MetadataEditorReadRequest: Sendable {
    let id: UUID
    let imageURLs: [URL]
    let folderURL: URL?
    let embeddedMetadataByImageURL: [URL: IPTCMetadata]
    let reconcilesSidecarTimestamps: Bool

    init(
        id: UUID,
        imageURLs: [URL],
        folderURL: URL?,
        embeddedMetadataByImageURL: [URL: IPTCMetadata],
        reconcilesSidecarTimestamps: Bool = true
    ) {
        self.id = id
        self.imageURLs = imageURLs
        self.folderURL = folderURL
        self.embeddedMetadataByImageURL = embeddedMetadataByImageURL
        self.reconcilesSidecarTimestamps = reconcilesSidecarTimestamps
    }
}

/// Every URL in `inspectedImageURLs` has complete facts, including an explicit absence of either
/// sidecar. It is always an exact prefix of the request so partial work cannot be published as a
/// complete selection.
nonisolated struct MetadataEditorReadSnapshot: Sendable {
    let request: MetadataEditorReadRequest
    let inspectedImageURLs: [URL]
    let factsByImageURL: [URL: MetadataEditorSourceFacts]

    var isComplete: Bool {
        inspectedImageURLs.count == request.imageURLs.count
    }
}

/// Foundation reads cannot be interrupted after they enter the filesystem. Cancellation retains
/// the exact complete prefix and distinguishes a request cancelled after its final facts were read.
nonisolated enum MetadataEditorReadResult: Sendable {
    case complete(MetadataEditorReadSnapshot)
    case cancelledBeforeRead(MetadataEditorReadRequest)
    case cancelledAfterPartialRead(MetadataEditorReadSnapshot)
    case cancelledAfterCompleteRead(MetadataEditorReadSnapshot)
}

nonisolated struct MetadataEditorReadAccess: Sendable {
    let read: @Sendable (URL, URL?, IPTCMetadata?, Bool) -> MetadataEditorSourceFacts

    static let system = MetadataEditorReadAccess { imageURL, folderURL, embedded, reconciles in
        let xmpService = XMPSidecarService()
        let xmpMetadata = xmpService.loadSidecar(for: imageURL)
        let appSidecar = folderURL.flatMap {
            MetadataSidecarService().loadSidecar(for: imageURL, in: $0)
        }
        let verdict: SidecarReconciliation.Verdict?
        if reconciles, let embedded, let xmpMetadata {
            verdict = SidecarReconciliation.verdict(
                imageURL: imageURL,
                sidecarURL: xmpService.sidecarURL(for: imageURL),
                embedded: embedded,
                sidecar: xmpMetadata
            )
        } else {
            verdict = nil
        }
        return MetadataEditorSourceFacts(
            imageURL: imageURL,
            xmpMetadata: xmpMetadata,
            appSidecar: appSidecar,
            reconciliationVerdict: verdict
        )
    }
}

/// Serializes Metadata-editor XMP, JSON-history, conditional image-aspect, and modification-time
/// reads away from MainActor. Queued requests can be cancelled before they touch a slow card,
/// network volume, or iCloud placeholder.
actor MetadataEditorReadService {
    static let shared = MetadataEditorReadService()

    private let access: MetadataEditorReadAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "MetadataEditorRead"
    )

    init(access: MetadataEditorReadAccess = .system) {
        self.access = access
    }

    func load(_ request: MetadataEditorReadRequest) -> MetadataEditorReadResult {
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Load", id: signpostID)

        guard !Task.isCancelled else {
            signposter.endInterval("Load", interval, "result=cancelled inspected=0")
            return .cancelledBeforeRead(request)
        }

        var inspectedImageURLs: [URL] = []
        inspectedImageURLs.reserveCapacity(request.imageURLs.count)
        var factsByImageURL: [URL: MetadataEditorSourceFacts] = [:]
        factsByImageURL.reserveCapacity(request.imageURLs.count)

        for imageURL in request.imageURLs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    request: request,
                    inspectedImageURLs: inspectedImageURLs,
                    factsByImageURL: factsByImageURL,
                    interval: interval
                )
            }

            let facts = access.read(
                imageURL,
                request.folderURL,
                request.embeddedMetadataByImageURL[imageURL],
                request.reconcilesSidecarTimestamps
            )
            factsByImageURL[imageURL] = facts
            inspectedImageURLs.append(imageURL)

            guard !Task.isCancelled else {
                return cancelledResult(
                    request: request,
                    inspectedImageURLs: inspectedImageURLs,
                    factsByImageURL: factsByImageURL,
                    interval: interval
                )
            }
        }

        let snapshot = MetadataEditorReadSnapshot(
            request: request,
            inspectedImageURLs: inspectedImageURLs,
            factsByImageURL: factsByImageURL
        )
        signposter.endInterval(
            "Load",
            interval,
            "result=complete inspected=\(inspectedImageURLs.count) xmp=\(factsByImageURL.values.count(where: { $0.xmpMetadata != nil })) app=\(factsByImageURL.values.count(where: { $0.appSidecar != nil }))"
        )
        return .complete(snapshot)
    }

    private func cancelledResult(
        request: MetadataEditorReadRequest,
        inspectedImageURLs: [URL],
        factsByImageURL: [URL: MetadataEditorSourceFacts],
        interval: OSSignpostIntervalState
    ) -> MetadataEditorReadResult {
        let snapshot = MetadataEditorReadSnapshot(
            request: request,
            inspectedImageURLs: inspectedImageURLs,
            factsByImageURL: factsByImageURL
        )
        signposter.endInterval(
            "Load",
            interval,
            "result=cancelled inspected=\(inspectedImageURLs.count)"
        )
        if snapshot.isComplete {
            return .cancelledAfterCompleteRead(snapshot)
        }
        return .cancelledAfterPartialRead(snapshot)
    }
}
