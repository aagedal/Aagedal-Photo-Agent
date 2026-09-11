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
    /// nil means unavailable evidence; a wrapper containing nil data proves absence at load.
    let xmpWriteSnapshot: XMPSidecarWriteSnapshot?
    let xmpReadFailure: String?

    init(imageURL: URL, xmpMetadata: IPTCMetadata?, appSidecar: MetadataSidecar?,
         reconciliationVerdict: SidecarReconciliation.Verdict?,
         xmpWriteSnapshot: XMPSidecarWriteSnapshot? = nil, xmpReadFailure: String? = nil) {
        self.imageURL = imageURL; self.xmpMetadata = xmpMetadata; self.appSidecar = appSidecar
        self.reconciliationVerdict = reconciliationVerdict
        self.xmpWriteSnapshot = xmpWriteSnapshot; self.xmpReadFailure = xmpReadFailure
    }
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
        systemRead(imageURL: imageURL, folderURL: folderURL, embedded: embedded, reconciles: reconciles)
    }

    /// Used only on the read service's filesystem executor. Parsing and publication share the
    /// same bytes; the second read refuses an external replacement during reconciliation.
    static func systemRead(imageURL: URL, folderURL: URL?, embedded: IPTCMetadata?,
                           reconciles: Bool, beforeValidation: () throws -> Void = {}) -> MetadataEditorSourceFacts {
        let xmpService = XMPSidecarService()
        let appSidecar = folderURL.flatMap {
            MetadataSidecarService().loadSidecar(for: imageURL, in: $0)
        }
        do {
            let url = xmpService.sidecarURL(for: imageURL)
            let data = try regularXMPBytes(at: url)
            let metadata: IPTCMetadata?
            if let data {
                guard let parsed = xmpService.loadSidecar(fromData: data,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                metadata = parsed
            } else { metadata = nil }
            let verdict: SidecarReconciliation.Verdict?
            if reconciles, let embedded, let metadata {
                verdict = SidecarReconciliation.verdict(imageURL: imageURL, sidecarURL: url,
                    embedded: embedded, sidecar: metadata)
            } else { verdict = nil }
            try beforeValidation()
            guard try regularXMPBytes(at: url) == data else {
                throw DescriptiveMetadataWriteError.staleXMPSidecar(url)
            }
            return .init(imageURL: imageURL, xmpMetadata: metadata, appSidecar: appSidecar,
                reconciliationVerdict: verdict, xmpWriteSnapshot: .init(data: data))
        } catch {
            return .init(imageURL: imageURL, xmpMetadata: nil, appSidecar: appSidecar,
                reconciliationVerdict: nil, xmpReadFailure:
                    "The XMP sidecar could not be read consistently. Reload before saving. " + error.localizedDescription)
        }
    }

    private static func regularXMPBytes(at url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
        return try Data(contentsOf: url)
    }

}

/// Serializes Metadata-editor XMP, JSON-history, conditional image-aspect, and modification-time
/// reads away from MainActor. Queued requests can be cancelled before they touch a slow card,
/// network volume, or iCloud placeholder.
actor MetadataEditorReadService {
    static let shared = MetadataEditorReadService()

    /// Keep blocking provider reads off the cooperative pool while executing the caller's
    /// original task, including its cancellation state and task-local context.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    private let access: MetadataEditorReadAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "MetadataEditorRead"
    )

    init(access: MetadataEditorReadAccess = .system,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.metadata-editor.read", qos: .utility
         )) {
        self.access = access
        self.filesystemQueue = filesystemQueue
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
