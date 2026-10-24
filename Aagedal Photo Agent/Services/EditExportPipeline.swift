import Foundation
import os.log
import SwiftMediaMetadata

private let exportPipelineLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "ExportPipeline"
)

/// Accumulates per-file metadata failures that don't abort an export but should be
/// surfaced in the batch result. Shared by every export/publish call site.
actor MetadataFailureTracker: Sendable {
    private(set) var metadataCopyFailures: [String] = []
    private(set) var sidecarOverlayFailures: [String] = []
    /// Files exported from the embedded image (not the `.xmp` sidecar) because the sidecar
    /// looked stale — the image file was modified more recently and the two disagreed.
    /// A warning, not a failure: the file was still published, just from the file's metadata.
    private(set) var staleSidecarWarnings: [String] = []
    /// Files exported without one or more enabled watermark layers because the referenced
    /// library image was deleted or hasn't synced to this Mac. A warning, not a failure: the
    /// file was still exported, just without that watermark.
    private(set) var missingWatermarkWarnings: [String] = []
    func recordCopyFailure(_ filename: String) { metadataCopyFailures.append(filename) }
    func recordOverlayFailure(_ filename: String) { sidecarOverlayFailures.append(filename) }
    func recordStaleSidecar(_ filename: String) { staleSidecarWarnings.append(filename) }
    func recordMissingWatermark(_ filename: String) { missingWatermarkWarnings.append(filename) }
}

/// Immutable input for one export Camera Raw resolution pass. Live workspace settings are
/// captured on MainActor before this value crosses to the filesystem actor; only RAW files that
/// lack a live value need an XMP sidecar read.
nonisolated struct ExportCameraRawResolutionRequest: Equatable, Sendable {
    let requestID: UUID
    let imageURLs: [URL]
    let liveSettingsByImageURL: [URL: CameraRawSettings]
}

/// A complete result contains both the captured live values and every usable sidecar fallback.
/// `inspectedImageURLs` is always an exact prefix of `requestedSidecarImageURLs`, including a read
/// that finished immediately before cancellation was observed.
nonisolated struct ExportCameraRawResolutionSnapshot: Equatable, Sendable {
    let requestID: UUID
    let requestedSidecarImageURLs: [URL]
    let inspectedImageURLs: [URL]
    let settingsByImageURL: [URL: CameraRawSettings]

    var isComplete: Bool {
        inspectedImageURLs.count == requestedSidecarImageURLs.count
    }
}

nonisolated enum ExportCameraRawResolutionResult: Equatable, Sendable {
    case complete(ExportCameraRawResolutionSnapshot)
    case cancelledBeforeRead(requestID: UUID, requestedSidecarImageURLs: [URL])
    case cancelledAfterPartialRead(ExportCameraRawResolutionSnapshot)
    case cancelledAfterCompleteRead(ExportCameraRawResolutionSnapshot)
}

/// Immutable input for the filesystem work that must finish after rendered pixels and metadata
/// have been committed. RAW archives additionally carry the source XMP sidecar unchanged.
nonisolated struct ExportArtifactFinalizationRequest: Equatable, Sendable {
    let requestID: UUID
    let sourceURL: URL
    let renderedURL: URL
    let copiesRAWArchiveSidecar: Bool
}

/// Durable evidence returned after the rendered artifact is safe to publish to the UI. Finalization
/// is deliberately non-preemptible once submitted: cancellation must not leave a RAW archive without
/// its authoritative edit sidecar or skip the user-visible-file postcondition.
nonisolated struct ExportArtifactFinalizationEvidence: Equatable, Sendable {
    let requestID: UUID
    let renderedURL: URL
    let finalizedRAWArchiveSidecar: Bool
    let madeArtifactVisible: Bool
    let cancellationObservedBeforeFinalization: Bool
    let cancellationObservedAfterFinalization: Bool
}

nonisolated struct ExportArtifactFinalizationIO: Sendable {
    let copyRAWArchiveSidecar: @Sendable (URL, URL) throws -> Void
    let removeRenderedArtifact: @Sendable (URL) throws -> Void
    let isHidden: @Sendable (URL) throws -> Bool
    let makeVisible: @Sendable (URL) throws -> Void

    static let system = ExportArtifactFinalizationIO(
        copyRAWArchiveSidecar: { sourceURL, renderedURL in
            try RAWArchiveService.copySidecarIfPresent(from: sourceURL, to: renderedURL)
        },
        removeRenderedArtifact: { try FileManager.default.removeItem(at: $0) },
        isHidden: {
            try $0.resourceValues(forKeys: [.isHiddenKey]).isHidden == true
        },
        makeVisible: { url in
            var values = URLResourceValues()
            values.isHidden = false
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        }
    )
}

/// Serializes post-render filesystem work away from MainActor. There is no suspension point inside
/// `finalize`, so one artifact reaches a truthful durable outcome before the next begins.
actor ExportArtifactFinalizationService {
    /// Keep synchronous volume access on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and serialized durable-operation boundaries.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = ExportArtifactFinalizationService()

    private let io: ExportArtifactFinalizationIO
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "ExportArtifactFinalization"
    )

    init(
        io: ExportArtifactFinalizationIO = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.export-artifact-finalization", qos: .utility
        )
    ) {
        self.filesystemQueue = filesystemQueue
        self.io = io
    }

    func finalize(
        _ request: ExportArtifactFinalizationRequest
    ) throws -> ExportArtifactFinalizationEvidence {
        let cancellationObservedBeforeFinalization = Task.isCancelled
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Finalize", id: signpostID)
        var finalizedRAWArchiveSidecar = false

        if request.copiesRAWArchiveSidecar {
            do {
                try io.copyRAWArchiveSidecar(request.sourceURL, request.renderedURL)
                finalizedRAWArchiveSidecar = true
            } catch {
                // Preserve the existing fail-closed archive contract: pixels without their
                // authoritative sidecar are not a completed archive. The cleanup remains
                // best effort so the original sidecar error is what the caller receives.
                try? io.removeRenderedArtifact(request.renderedURL)
                signposter.endInterval(
                    "Finalize",
                    interval,
                    "result=sidecar-failed archive=true"
                )
                throw error
            }
        }

        let madeArtifactVisible: Bool
        do {
            if try io.isHidden(request.renderedURL) {
                try io.makeVisible(request.renderedURL)
                madeArtifactVisible = true
            } else {
                madeArtifactVisible = false
            }
        } catch {
            signposter.endInterval(
                "Finalize",
                interval,
                "result=visibility-failed archive=\(request.copiesRAWArchiveSidecar)"
            )
            throw error
        }

        signposter.endInterval(
            "Finalize",
            interval,
            "result=complete archive=\(request.copiesRAWArchiveSidecar) visible=\(madeArtifactVisible)"
        )
        return ExportArtifactFinalizationEvidence(
            requestID: request.requestID,
            renderedURL: request.renderedURL,
            finalizedRAWArchiveSidecar: finalizedRAWArchiveSidecar,
            madeArtifactVisible: madeArtifactVisible,
            cancellationObservedBeforeFinalization: cancellationObservedBeforeFinalization,
            cancellationObservedAfterFinalization: Task.isCancelled
        )
    }
}

nonisolated struct ExportCameraRawSidecarAccess: Sendable {
    let load: @Sendable (URL) -> CameraRawSettings?

    static let system = ExportCameraRawSidecarAccess { imageURL in
        guard let settings = XMPSidecarService().loadDevelopSettings(for: imageURL),
              !settings.isEmpty else {
            return nil
        }
        return settings
    }
}

/// Serializes export-side XMP fallback reads away from MainActor. This boundary is shared by
/// local Save/Export/Archive and FTP preview/render preparation, so queued work can be cancelled
/// before it touches a slow card, network volume, or iCloud placeholder.
actor ExportCameraRawResolutionService {
    /// Keep synchronous volume access on a retained Dispatch worker while preserving the
    /// caller's task locals, cancellation, and serialized durable-operation boundaries.
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = ExportCameraRawResolutionService()

    private let access: ExportCameraRawSidecarAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "ExportCameraRawResolution"
    )

    init(
        access: ExportCameraRawSidecarAccess = .system,
        filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.export-camera-raw-resolution", qos: .utility
        )
    ) {
        self.filesystemQueue = filesystemQueue
        self.access = access
    }

    func resolve(_ request: ExportCameraRawResolutionRequest) -> ExportCameraRawResolutionResult {
        let sidecarURLs = request.imageURLs.filter {
            request.liveSettingsByImageURL[$0] == nil && SupportedImageFormats.isRaw(url: $0)
        }
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Resolve", id: signpostID)

        guard !Task.isCancelled else {
            signposter.endInterval("Resolve", interval, "result=cancelled inspected=0")
            return .cancelledBeforeRead(
                requestID: request.requestID,
                requestedSidecarImageURLs: sidecarURLs
            )
        }

        var inspectedURLs: [URL] = []
        inspectedURLs.reserveCapacity(sidecarURLs.count)
        var settingsByURL = request.liveSettingsByImageURL

        for imageURL in sidecarURLs {
            guard !Task.isCancelled else {
                return cancelledResult(
                    request: request,
                    requestedSidecarImageURLs: sidecarURLs,
                    inspectedImageURLs: inspectedURLs,
                    settingsByImageURL: settingsByURL,
                    interval: interval
                )
            }

            let settings = access.load(imageURL)
            inspectedURLs.append(imageURL)
            if let settings {
                settingsByURL[imageURL] = settings
            }

            guard !Task.isCancelled else {
                return cancelledResult(
                    request: request,
                    requestedSidecarImageURLs: sidecarURLs,
                    inspectedImageURLs: inspectedURLs,
                    settingsByImageURL: settingsByURL,
                    interval: interval
                )
            }
        }

        let snapshot = ExportCameraRawResolutionSnapshot(
            requestID: request.requestID,
            requestedSidecarImageURLs: sidecarURLs,
            inspectedImageURLs: inspectedURLs,
            settingsByImageURL: settingsByURL
        )
        signposter.endInterval(
            "Resolve",
            interval,
            "result=complete inspected=\(inspectedURLs.count)"
        )
        return .complete(snapshot)
    }

    private func cancelledResult(
        request: ExportCameraRawResolutionRequest,
        requestedSidecarImageURLs: [URL],
        inspectedImageURLs: [URL],
        settingsByImageURL: [URL: CameraRawSettings],
        interval: OSSignpostIntervalState
    ) -> ExportCameraRawResolutionResult {
        let snapshot = ExportCameraRawResolutionSnapshot(
            requestID: request.requestID,
            requestedSidecarImageURLs: requestedSidecarImageURLs,
            inspectedImageURLs: inspectedImageURLs,
            settingsByImageURL: settingsByImageURL
        )
        signposter.endInterval(
            "Resolve",
            interval,
            "result=cancelled inspected=\(inspectedImageURLs.count)"
        )
        return snapshot.isComplete
            ? .cancelledAfterCompleteRead(snapshot)
            : .cancelledAfterPartialRead(snapshot)
    }
}

/// Selects which `EditedImageRenderer` entry point a `renderItem` call uses.
enum RenderKind: Sendable {
    /// Honors the configured export format + HDR settings (`EditedImageRenderer.render`).
    case format
    /// "Save As" to a specific SDR format (`EditedImageRenderer.saveAs`).
    case saveAs(EditedImageRenderer.SaveAsFormat)
    /// Dedicated unedited RAW decodes. The decode profile is scoped to this archive,
    /// and the current develop stack and global RAW decoding preference are ignored.
    case rawJXL16(RAWDecodeProfile)
    case rawTIFF16(RAWDecodeProfile)
    /// DNG conversion through the separately installed Adobe converter. The app's
    /// current develop settings are not applied to the converted image data.
    case rawDNG(AdobeDNGCompression, executableURL: URL)
    /// Fixed JPEG into a temp folder, used by the FTP publish path
    /// (`EditedImageRenderer.renderJPEG`).
    case jpeg
}

nonisolated enum ExportMetadataFailurePolicy: Sendable {
    /// Retain useful local pixels and report metadata failures through the batch tracker.
    case keepLocalCopy
    /// A known metadata failure must not authorize signing or remote delivery.
    case rejectForDelivery
}

nonisolated struct ExportMetadataIncompleteError: LocalizedError, Sendable {
    let renderedURL: URL
    let copyFailed: Bool
    let overlayFailed: Bool

    var errorDescription: String? {
        "Metadata could not be completed for \(renderedURL.lastPathComponent). The rendered file was kept locally and was not signed or uploaded."
    }
}

/// The shared "render one edited photo" pipeline used by every export/publish call site
/// (C2PA sign, Save As, export folder, FTP publish). Centralizing the steps — CameraRaw
/// resolution, render, source-metadata copy, and pending-IPTC sidecar overlay — keeps the
/// four call sites from drifting apart (which previously left the FTP path missing the
/// in-memory CameraRaw read and the IPTC overlay entirely).
enum EditExportPipeline {

    /// Delivery and signing must not consume pixels whose metadata stage reported failure.
    /// Local Save/Export retains its existing useful-file-plus-warning behavior.
    static func renderForDelivery(sourceURL: URL,
                                  cameraRaw: CameraRawSettings?,
                                  kind: RenderKind,
                                  outputFolder: URL,
                                  folderURL: URL?,
                                  writeEngine: any MetadataWriteEngine,
                                  failureTracker: MetadataFailureTracker,
                                  configuration: AdvancedExportConfiguration? = nil,
                                  collisionPolicy: EditedImageRenderer.OutputCollisionPolicy = .appendNumber) async throws -> URL {
        try await renderItem(sourceURL: sourceURL, cameraRaw: cameraRaw, kind: kind,
            outputFolder: outputFolder, folderURL: folderURL, writeEngine: writeEngine,
            failureTracker: failureTracker, configuration: configuration,
            collisionPolicy: collisionPolicy, metadataFailurePolicy: .rejectForDelivery)
    }

    /// Populates `cameraRaw` on each entry in `map`, preferring the live in-memory edit
    /// settings (kept in sync by the edit workspace) and falling back to the XMP sidecar
    /// for RAW files edited in a previous session. The in-memory lookup is injected so this
    /// stays decoupled from `BrowserViewModel`.
    @MainActor
    static func resolveCameraRaw(
        into map: inout [URL: IPTCMetadata],
        urls: [URL],
        inMemory: @MainActor (URL) -> CameraRawSettings?,
        service: ExportCameraRawResolutionService = .shared
    ) async throws {
        var liveSettingsByURL: [URL: CameraRawSettings] = [:]
        liveSettingsByURL.reserveCapacity(urls.count)
        for url in urls {
            if let crs = inMemory(url) {
                liveSettingsByURL[url] = crs
            }
        }

        let requestID = UUID()
        let result = await service.resolve(ExportCameraRawResolutionRequest(
            requestID: requestID,
            imageURLs: urls,
            liveSettingsByImageURL: liveSettingsByURL
        ))
        guard case .complete(let snapshot) = result,
              snapshot.requestID == requestID else {
            throw CancellationError()
        }

        // A file whose metadata read failed is missing from `map`; its live or sidecar
        // Develop settings must still apply, or the photo would render/upload unedited.
        let requested = Set(urls)
        for (url, settings) in snapshot.settingsByImageURL where requested.contains(url) {
            map[url, default: IPTCMetadata()].cameraRaw = settings
        }
    }

    /// Renders one source file to `outputFolder` using `kind`, copies the source's
    /// EXIF/IPTC/XMP onto the result, and overlays any pending IPTC sidecar edits. Copy and
    /// overlay failures are recorded in `failureTracker`. Delivery rejects known metadata
    /// failures after finalizing the local artifact; ordinary local exports return it with warnings.
    static func renderItem(sourceURL: URL,
                           cameraRaw: CameraRawSettings?,
                           kind: RenderKind,
                           outputFolder: URL,
                           folderURL: URL?,
                           writeEngine: any MetadataWriteEngine,
                           failureTracker: MetadataFailureTracker,
                           configuration: AdvancedExportConfiguration? = nil,
                           outputFilenameSuffix: String = "",
                           collisionPolicy: EditedImageRenderer.OutputCollisionPolicy = .replaceExisting,
                           finalizationService: ExportArtifactFinalizationService = .shared,
                           metadataFailurePolicy: ExportMetadataFailurePolicy = .keepLocalCopy) async throws -> URL {
        try await MetadataSidecarService().requireNoPendingOrientation(
            for: sourceURL, in: folderURL ?? sourceURL.deletingLastPathComponent())
        if case .rawDNG(let compression, let executableURL) = kind {
            // A DNG is still a camera RAW, not a rendered output. Do not run the
            // rendered-metadata copier or sidecar overlay; the converter preserves
            // camera metadata and the DNG service carries the source XMP sidecar.
            let renderedURL = try await Task.detached(priority: .userInitiated) {
                try await AdobeDNGConverterService.convert(
                    sourceURL: sourceURL,
                    destinationFolder: outputFolder,
                    compression: compression,
                    executableURL: executableURL
                )
            }.value
            _ = try await finalizationService.finalize(ExportArtifactFinalizationRequest(
                requestID: UUID(),
                sourceURL: sourceURL,
                renderedURL: renderedURL,
                copiesRAWArchiveSidecar: false
            ))
            return renderedURL
        }

        // The renderer owns encoding, but pending IPTC and finalization still mutate the
        // destination afterward. Keep its name claimed until the complete artifact finishes.
        let reservationOwner = ExportOutputReservationOwner()
        defer { withExtendedLifetime(reservationOwner) {} }
        // Until the renderer returns, a thrown error means the encode itself failed or was
        // cancelled: whatever sits under the reserved name is partial and must not survive.
        var renderReturned = false

        do {
            let bakedCameraRaw: CameraRawSettings?
            switch kind {
            case .rawJXL16, .rawTIFF16:
                // RAW archives intentionally ignore the live develop stack. The renderer
                // performs only the selected decode, so do not document any Camera Raw
                // settings as baked into the output metadata.
                bakedCameraRaw = nil
            case .format, .saveAs, .jpeg, .rawDNG:
                bakedCameraRaw = cameraRaw
            }
            let metadataCameraRaw = bakedCameraRaw
            let isHDR = (metadataCameraRaw?.hdrEditMode == 1)
            // Keep the decision per item. A shared batch tracker may already contain failures
            // from another image (including one with the same basename in a different folder).
            let itemFailures = MetadataFailureTracker()
            let copier: EditedImageRenderer.MetadataCopier = { src, dst in
                do {
                    try await writeEngine.copyMetadataToRenderedFile(
                        from: src, to: dst, bakedCameraRaw: metadataCameraRaw)
                } catch {
                    await failureTracker.recordCopyFailure(src.lastPathComponent)
                    await itemFailures.recordCopyFailure(src.lastPathComponent)
                }
            }

            let renderedURL = try await Task.detached(priority: .userInitiated) {
                switch kind {
                case .format:
                    return try await EditedImageRenderer.render(
                        from: sourceURL, cameraRaw: cameraRaw, isHDR: isHDR,
                        outputFolder: outputFolder,
                        configuration: configuration,
                        outputFilenameSuffix: outputFilenameSuffix,
                        collisionPolicy: collisionPolicy,
                        metadataCopier: copier, reservationOwner: reservationOwner)
                case .saveAs(let format):
                    return try await EditedImageRenderer.saveAs(
                        from: sourceURL, cameraRaw: cameraRaw, format: format,
                        destinationFolder: outputFolder, metadataCopier: copier,
                        reservationOwner: reservationOwner)
                case .rawJXL16(let decodeProfile):
                    return try await EditedImageRenderer.convertRAWTo16BitJXL(
                        from: sourceURL, decodeProfile: decodeProfile,
                        destinationFolder: outputFolder, metadataCopier: copier,
                        reservationOwner: reservationOwner)
                case .rawTIFF16(let decodeProfile):
                    return try await EditedImageRenderer.convertRAWTo16BitTIFF(
                        from: sourceURL, decodeProfile: decodeProfile,
                        destinationFolder: outputFolder, metadataCopier: copier,
                        reservationOwner: reservationOwner)
                case .rawDNG:
                    // Handled before constructing the rendered metadata copier above.
                    preconditionFailure("RAW DNG archives must use the converter path")
                case .jpeg:
                    return try await EditedImageRenderer.renderJPEG(
                        from: sourceURL, cameraRaw: cameraRaw,
                        outputFolder: outputFolder, metadataCopier: copier,
                        collisionPolicy: collisionPolicy, reservationOwner: reservationOwner)
                }
            }.value
            renderReturned = true

            var overlayFailed = false
            switch await SidecarIPTCOverlay.apply(
                sourceURL: sourceURL, renderedURL: renderedURL,
                folderURL: folderURL, writeEngine: writeEngine) {
            case .failed:
                overlayFailed = true
                await failureTracker.recordOverlayFailure(sourceURL.lastPathComponent)
            case .staleSidecarSkipped:
                await failureTracker.recordStaleSidecar(sourceURL.lastPathComponent)
            case .applied, .noPendingEdits:
                break
            }
            // The renderer silently skips a watermark whose library PNG can't be read; tell
            // the user rather than delivering an unbranded file without notice.
            if !missingWatermarkAssetIDs(in: bakedCameraRaw).isEmpty {
                await failureTracker.recordMissingWatermark(sourceURL.lastPathComponent)
            }

            let copiesRAWArchiveSidecar: Bool
            switch kind {
            case .rawJXL16, .rawTIFF16:
                copiesRAWArchiveSidecar = true
            case .format, .saveAs, .rawDNG, .jpeg:
                copiesRAWArchiveSidecar = false
            }
            _ = try await finalizationService.finalize(ExportArtifactFinalizationRequest(
                requestID: UUID(),
                sourceURL: sourceURL,
                renderedURL: renderedURL,
                copiesRAWArchiveSidecar: copiesRAWArchiveSidecar
            ))
            if case .rejectForDelivery = metadataFailurePolicy {
                let copyFailures = await itemFailures.metadataCopyFailures
                let copyFailed = !copyFailures.isEmpty
                if copyFailed || overlayFailed {
                    throw ExportMetadataIncompleteError(renderedURL: renderedURL,
                        copyFailed: copyFailed, overlayFailed: overlayFailed)
                }
            }
            await reservationOwner.release()
            return renderedURL
        } catch {
            if renderReturned {
                await reservationOwner.release()
            } else {
                await reservationOwner.discardOnFailure()
            }
            throw error
        }
    }

    /// Library asset IDs referenced by enabled watermark layers whose PNG isn't readable at the
    /// path the Metal texture loader uses (deleted from the library, or not yet downloaded
    /// from iCloud), or whose latest texture load failed even though the file exists (a
    /// coordinated read or decode failure, e.g. mid-sync). Those layers render as no-ops.
    nonisolated static func missingWatermarkAssetIDs(in cameraRaw: CameraRawSettings?) -> [UUID] {
        var seen = Set<UUID>()
        return (cameraRaw?.watermarkLayers ?? []).filter(\.enabled).compactMap { layer in
            let id = layer.libraryAssetID
            guard seen.insert(id).inserted else { return nil }
            let path = WatermarkStore.resolvedImageURL(forAssetID: id).path
            let readable = FileManager.default.isReadableFile(atPath: path)
            return readable && !WatermarkTextureLoadFailures.lastLoadFailed(id) ? nil : id
        }
    }

    /// Export artifacts are user-facing files and must remain discoverable in Finder.
    /// Metadata writers normally preserve the destination's visibility, but this final
    /// postcondition also protects formats handled by external encoders and filesystem
    /// providers that retain a hidden staging-file flag during an atomic replacement.
    static func ensureExportArtifactIsVisible(
        at url: URL,
        service: ExportArtifactFinalizationService = .shared
    ) async throws {
        _ = try await service.finalize(ExportArtifactFinalizationRequest(
            requestID: UUID(),
            sourceURL: url,
            renderedURL: url,
            copiesRAWArchiveSidecar: false
        ))
    }
}

/// One captured source selection. A pending draft remains authoritative even if it has
/// no writable fields; callers must not fall through to an older physical XMP record.
nonisolated enum ExportIPTCSelection: Equatable, Sendable {
    case pendingDraft(IPTCMetadata)
    case xmp(IPTCMetadata)
    case staleSidecarSkipped
    case noPendingEdits
}

nonisolated struct ExportIPTCSelectionAccess: Sendable {
    let loadDraft: @Sendable (URL, URL) -> MetadataSidecar?
    let loadXMP: @Sendable (URL) -> IPTCMetadata?
    let readEmbedded: @Sendable (URL) -> IPTCMetadata?
    let reconcile: @Sendable (URL, IPTCMetadata?, IPTCMetadata) -> SidecarReconciliation.Verdict

    static let system = ExportIPTCSelectionAccess(
        loadDraft: { MetadataSidecarService().loadSidecar(for: $0, in: $1) },
        loadXMP: { XMPSidecarService().loadSidecar(for: $0) },
        readEmbedded: { url in
            guard let metadata = try? ImageMetadata.read(from: url) else { return nil }
            return iptcMetadataFromDict(metadata.asMetadataDict(fileURL: url))
        },
        reconcile: { url, embedded, sidecar in
            SidecarReconciliation.verdict(imageURL: url,
                sidecarURL: XMPSidecarService().sidecarURL(for: url),
                embedded: embedded, sidecar: sidecar)
        }
    )
}

/// Retains slow/provider-backed reads on a Dispatch worker. Source JSON, XMP, embedded
/// metadata and reconciliation dates are inspected within one per-photo lease, so app
/// writers cannot interleave their carrier updates with this selection.
actor ExportIPTCSelectionService {
    nonisolated let filesystemQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        filesystemQueue.asUnownedSerialExecutor()
    }

    static let shared = ExportIPTCSelectionService()
    private let access: ExportIPTCSelectionAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent", category: "ExportIPTCSelection"
    )

    init(access: ExportIPTCSelectionAccess = .system,
         filesystemQueue: DispatchSerialQueue = DispatchSerialQueue(
            label: "com.aagedal.photo-agent.export-iptc-selection", qos: .utility
         )) {
        self.access = access
        self.filesystemQueue = filesystemQueue
    }

    func select(sourceURL: URL, folderURL: URL?) async -> ExportIPTCSelection {
        let interval = signposter.beginInterval("Select", id: signposter.makeSignpostID())
        // This is post-render finalization. Preserve selection despite caller cancellation;
        // the existing writer/overlay outcome decides whether metadata was actually applied.
        let selection = await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: sourceURL)) {
            await self.capture(sourceURL: sourceURL, folderURL: folderURL)
        }
        signposter.endInterval("Select", interval)
        return selection
    }

    /// Explicit actor hop from the coordinator's admitted task keeps all synchronous I/O
    /// on this retained worker. Do not reacquire the source lock inside this method.
    private func capture(sourceURL: URL, folderURL: URL?) -> ExportIPTCSelection {
        if let folderURL, let draft = access.loadDraft(sourceURL, folderURL), draft.pendingChanges {
            return .pendingDraft(draft.metadata)
        }
        // GPS counts as content: a geotagged RAW sidecar with no caption must still carry
        // its coordinates onto the export (applied additively — see authoritativeFields).
        guard let sidecar = access.loadXMP(sourceURL),
              sidecar.hasDescriptiveContent || sidecar.rating != nil || sidecar.label != nil
                || SidecarIPTCOverlay.hasGPS(sidecar) else {
            return .noPendingEdits
        }
        // The staleness policy only compares descriptive metadata. Rating/label-only
        // records need no source-container read or modification-date probes.
        if sidecar.hasDescriptiveContent {
            let embedded = access.readEmbedded(sourceURL)
            if access.reconcile(sourceURL, embedded, sidecar) == .fileNewerConflict {
                return .staleSidecarSkipped
            }
        }
        return .xmp(sidecar)
    }
}

/// Applies pending sidecar IPTC edits to a rendered output file. Checks both XMP sidecars
/// (default for C2PA) and JSON sidecars (history-only mode). Called after render so the
/// output includes edited metadata (keywords, caption, rating, label, …) that hasn't yet
/// been written back into the source file.
enum SidecarIPTCOverlay {
    enum Outcome: Sendable {
        /// Sidecar values were written onto the rendered file.
        case applied
        /// No sidecar (or no pending edits) to apply — the rendered file keeps its
        /// copied-from-source metadata.
        case noPendingEdits
        /// The `.xmp` sidecar looked stale (image file newer and descriptive metadata
        /// differs), so it was skipped and the embedded file values kept. Caller warns.
        case staleSidecarSkipped
        /// Writing the sidecar values onto the rendered file threw.
        case failed
    }

    /// Shared by rendered export and FTP's explicit sidecar-to-file sync. A partial
    /// record leaves descriptive fields alone; an empty Label is an explicit clear,
    /// whereas a missing Label leaves the destination's embedded value unchanged.
    nonisolated static func authoritativeFields(from metadata: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields = metadata.hasDescriptiveContent ? metadata.toOverwriteFields() : [:]
        if let rating = metadata.rating { fields[.rating] = String(rating) }
        if let label = metadata.label { fields[.label] = label }
        // GPS is additive and independent of descriptive authority: present coordinates are
        // written; absent ones never clear the destination's embedded GPS.
        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        return fields
    }

    nonisolated static func hasGPS(_ metadata: IPTCMetadata) -> Bool {
        metadata.latitude != nil && metadata.longitude != nil
    }

    /// Carry list item boundaries separately from the legacy comma-delimited field map.
    /// Partial rating/label records must not acquire authority over descriptive metadata.
    nonisolated static func authoritativeStructuredData(from metadata: IPTCMetadata) -> StructuredWriteData {
        guard metadata.hasDescriptiveContent else { return .empty }
        return StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: metadata),
                                   listValues: EditorialListWriteData(metadata: metadata))
    }

    static func apply(sourceURL: URL, renderedURL: URL, folderURL: URL?,
                      writeEngine: any MetadataWriteEngine,
                      service: ExportIPTCSelectionService = .shared) async -> Outcome {
        let metadata: IPTCMetadata
        let carrier: String
        switch await service.select(sourceURL: sourceURL, folderURL: folderURL) {
        case .pendingDraft(let draft):
            metadata = draft
            carrier = "JSON"
        case .xmp(let sidecar):
            metadata = sidecar
            carrier = "XMP"
        case .staleSidecarSkipped:
            exportPipelineLog.warning(
                "overlaySidecarIPTC: .xmp sidecar for \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) looks stale (image file newer and differs); exported embedded values instead"
            )
            return .staleSidecarSkipped
        case .noPendingEdits:
            return .noPendingEdits
        }

        // Release the source lease before the output writer takes its destination lease.
        // Keep partial-record safeguards and lossless list transport shared by both carriers.
        let fields = authoritativeFields(from: metadata)
        guard !fields.isEmpty else { return .noPendingEdits }

        do {
            try await writeEngine.writeFieldsToRenderedFiles(
                fields,
                to: [renderedURL],
                structuredData: authoritativeStructuredData(from: metadata)
            )
            return .applied
        } catch {
            exportPipelineLog.error(
                "overlaySidecarIPTC \(carrier, privacy: .private) writeFields failed for \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) → \(renderedURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
            )
            return .failed
        }
    }

}
