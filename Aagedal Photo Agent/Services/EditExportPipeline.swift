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
    func recordCopyFailure(_ filename: String) { metadataCopyFailures.append(filename) }
    func recordOverlayFailure(_ filename: String) { sidecarOverlayFailures.append(filename) }
    func recordStaleSidecar(_ filename: String) { staleSidecarWarnings.append(filename) }
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
    static let shared = ExportArtifactFinalizationService()

    private let io: ExportArtifactFinalizationIO
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "ExportArtifactFinalization"
    )

    init(io: ExportArtifactFinalizationIO = .system) {
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
        guard let settings = XMPSidecarService().loadSidecar(for: imageURL)?.cameraRaw,
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
    static let shared = ExportCameraRawResolutionService()

    private let access: ExportCameraRawSidecarAccess
    private let signposter = OSSignposter(
        subsystem: "com.aagedal.photo-agent",
        category: "ExportCameraRawResolution"
    )

    init(access: ExportCameraRawSidecarAccess = .system) {
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

/// The shared "render one edited photo" pipeline used by every export/publish call site
/// (C2PA sign, Save As, export folder, FTP publish). Centralizing the steps — CameraRaw
/// resolution, render, source-metadata copy, and pending-IPTC sidecar overlay — keeps the
/// four call sites from drifting apart (which previously left the FTP path missing the
/// in-memory CameraRaw read and the IPTC overlay entirely).
enum EditExportPipeline {

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

        for (url, settings) in snapshot.settingsByImageURL where map[url] != nil {
            map[url]?.cameraRaw = settings
        }
    }

    /// Renders one source file to `outputFolder` using `kind`, copies the source's
    /// EXIF/IPTC/XMP onto the result, and overlays any pending IPTC sidecar edits. Copy and
    /// overlay failures are recorded in `failureTracker` (they don't abort the file).
    /// Returns the rendered file URL.
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
                           finalizationService: ExportArtifactFinalizationService = .shared) async throws -> URL {
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
        let copier: EditedImageRenderer.MetadataCopier = { src, dst in
            do {
                try await writeEngine.copyMetadataToRenderedFile(
                    from: src, to: dst, bakedCameraRaw: metadataCameraRaw)
            } catch {
                await failureTracker.recordCopyFailure(src.lastPathComponent)
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
                    metadataCopier: copier)
            case .saveAs(let format):
                return try await EditedImageRenderer.saveAs(
                    from: sourceURL, cameraRaw: cameraRaw, format: format,
                    destinationFolder: outputFolder, metadataCopier: copier)
            case .rawJXL16(let decodeProfile):
                return try await EditedImageRenderer.convertRAWTo16BitJXL(
                    from: sourceURL, decodeProfile: decodeProfile,
                    destinationFolder: outputFolder, metadataCopier: copier)
            case .rawTIFF16(let decodeProfile):
                return try await EditedImageRenderer.convertRAWTo16BitTIFF(
                    from: sourceURL, decodeProfile: decodeProfile,
                    destinationFolder: outputFolder, metadataCopier: copier)
            case .rawDNG:
                // Handled before constructing the rendered metadata copier above.
                preconditionFailure("RAW DNG archives must use the converter path")
            case .jpeg:
                try await EditedImageRenderer.renderJPEG(
                    from: sourceURL, cameraRaw: cameraRaw,
                    outputFolder: outputFolder, metadataCopier: copier)
                return EditedImageRenderer.outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
            }
        }.value

        switch await SidecarIPTCOverlay.apply(
            sourceURL: sourceURL, renderedURL: renderedURL,
            folderURL: folderURL, writeEngine: writeEngine) {
        case .failed:
            await failureTracker.recordOverlayFailure(sourceURL.lastPathComponent)
        case .staleSidecarSkipped:
            await failureTracker.recordStaleSidecar(sourceURL.lastPathComponent)
        case .applied, .noPendingEdits:
            break
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
        return renderedURL
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

    static func apply(sourceURL: URL, renderedURL: URL, folderURL: URL?,
                      writeEngine: any MetadataWriteEngine) async -> Outcome {
        // Prefer XMP sidecar IPTC (default write mode for RAW and C2PA files). A sidecar
        // without descriptive content (develop-settings-only, written by saveCameraRawOnly
        // or stripped by Remove IPTC) is not an IPTC record: running toOverwriteFields on
        // it would wipe every descriptive field from the render. Skip it and fall through
        // to the JSON sidecar, which may still hold pending history-only edits.
        let xmpService = XMPSidecarService()
        if let xmpMeta = xmpService.loadSidecar(for: sourceURL),
           xmpMeta.hasDescriptiveContent || xmpMeta.rating != nil || xmpMeta.label != nil {
            // Staleness guard: if the image file was modified more recently than the .xmp
            // and their descriptive metadata differs, an external tool (e.g. Adobe Bridge,
            // which writes into the file rather than a sidecar) likely edited the embedded
            // metadata after the sidecar was written. Treat the file as master — the
            // rendered output already carries the embedded values copied during render — so
            // skip the sidecar overwrite and let the caller surface a warning.
            let embedded = await readEmbeddedMetadata(from: sourceURL)
            if SidecarReconciliation.verdict(
                imageURL: sourceURL, sidecarURL: xmpService.sidecarURL(for: sourceURL),
                embedded: embedded, sidecar: xmpMeta) == .fileNewerConflict {
                exportPipelineLog.warning(
                    "overlaySidecarIPTC: .xmp sidecar for \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) looks stale (image file newer and differs); exported embedded values instead"
                )
                return .staleSidecarSkipped
            }

            // Overwrite (not overlay): the sidecar is the authoritative edited state, so a
            // descriptive field the user cleared is emitted empty here to strip the source's
            // stale embedded value from the rendered output. GPS stays additive (see
            // toOverwriteFields). Guarded again here: a rating/label-only sidecar must not
            // wipe the descriptive fields it never carried.
            var fields = xmpMeta.hasDescriptiveContent ? xmpMeta.toOverwriteFields() : [:]
            // Rating and label are excluded from toOverwriteFields() (managed separately
            // in normal flow). For rendered output we must include them because the source
            // file may be C2PA-protected and hold stale values.
            if let rating = xmpMeta.rating {
                fields[.rating] = String(rating)
            }
            if let label = xmpMeta.label, !label.isEmpty {
                fields[.label] = label
            }
            guard !fields.isEmpty else { return .noPendingEdits }
            do {
                try await writeEngine.writeFieldsToRenderedFiles(
                    fields,
                    to: [renderedURL],
                    structuredData: StructuredWriteData(
                        editorial: xmpMeta.hasDescriptiveContent
                            ? EditorialStructuredWriteData(metadata: xmpMeta)
                            : nil
                    )
                )
                return .applied
            } catch {
                exportPipelineLog.error(
                    "overlaySidecarIPTC XMP writeFields failed for \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) → \(renderedURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
                )
                return .failed
            }
        }

        // Fall back to JSON sidecar (history-only mode). This sidecar is app-private and
        // only overlaid when `pendingChanges` is set (edits not yet written to the file),
        // so external-tool staleness doesn't apply here.
        guard let folderURL else { return .noPendingEdits }
        let sidecarService = MetadataSidecarService()
        guard let sidecar = sidecarService.loadSidecar(for: sourceURL, in: folderURL),
              sidecar.pendingChanges else { return .noPendingEdits }

        // Same partial-record guard as the .xmp branch: a record with no descriptive
        // content (e.g. a failed-seed fallback) must not wipe fields it never carried.
        var fields = sidecar.metadata.hasDescriptiveContent ? sidecar.metadata.toOverwriteFields() : [:]
        if let rating = sidecar.metadata.rating {
            fields[.rating] = String(rating)
        }
        if let label = sidecar.metadata.label, !label.isEmpty {
            fields[.label] = label
        }
        guard !fields.isEmpty else { return .noPendingEdits }

        do {
            try await writeEngine.writeFieldsToRenderedFiles(
                fields,
                to: [renderedURL],
                structuredData: StructuredWriteData(
                    editorial: sidecar.metadata.hasDescriptiveContent
                        ? EditorialStructuredWriteData(metadata: sidecar.metadata)
                        : nil
                )
            )
            return .applied
        } catch {
            exportPipelineLog.error(
                "overlaySidecarIPTC JSON writeFields failed for \(sourceURL.lastPathComponent, privacy: .private(mask: .hash)) → \(renderedURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)"
            )
            return .failed
        }
    }

    /// Reads the source file's embedded descriptive metadata (no sidecar), serialized
    /// against concurrent writes via `MetadataIOCoordinator`, for the staleness comparison.
    /// Returns nil on read failure (the reconciler then defaults to trusting the sidecar).
    private static func readEmbeddedMetadata(from url: URL) async -> IPTCMetadata? {
        await MetadataIOCoordinator.shared.withLock(MetadataIOKey.key(for: url)) {
            guard let md = try? ImageMetadata.read(from: url) else { return nil }
            return iptcMetadataFromDict(md.asMetadataDict(fileURL: url))
        }
    }
}
