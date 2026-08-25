import Foundation
import os.log
import SwiftExif

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
    static func resolveCameraRaw(into map: inout [URL: IPTCMetadata], urls: [URL],
                                 inMemory: @MainActor (URL) -> CameraRawSettings?) {
        let xmp = XMPSidecarService()
        for url in urls {
            // Prefer in-memory CRS (kept in sync by edit workspace via syncCameraRawToImageFile)
            if let crs = inMemory(url) {
                map[url]?.cameraRaw = crs
            }
            // For RAW files without in-memory CRS, read XMP sidecar (handles previous-session edits)
            else if SupportedImageFormats.isRaw(url: url),
                    let meta = xmp.loadSidecar(for: url),
                    let crs = meta.cameraRaw, !crs.isEmpty {
                map[url]?.cameraRaw = crs
            }
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
                           collisionPolicy: EditedImageRenderer.OutputCollisionPolicy = .replaceExisting) async throws -> URL {
        if case .rawDNG(let compression, let executableURL) = kind {
            // A DNG is still a camera RAW, not a rendered output. Do not run the
            // rendered-metadata copier or sidecar overlay; the converter preserves
            // camera metadata and the DNG service carries the source XMP sidecar.
            return try await Task.detached(priority: .userInitiated) {
                try await AdobeDNGConverterService.convert(
                    sourceURL: sourceURL,
                    destinationFolder: outputFolder,
                    compression: compression,
                    executableURL: executableURL
                )
            }.value
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

        switch kind {
        case .rawJXL16, .rawTIFF16:
            do {
                try RAWArchiveService.copySidecarIfPresent(
                    from: sourceURL,
                    to: renderedURL
                )
            } catch {
                // The pixels were written without edits, but the archive contract also
                // carries the authoritative edit sidecar. Remove this newly created,
                // incomplete rendered file and report the archive as failed. Do not
                // remove a destination sidecar here: a concurrent writer may own it.
                try? FileManager.default.removeItem(at: renderedURL)
                throw error
            }
        case .format, .saveAs, .rawDNG, .jpeg:
            break
        }
        return renderedURL
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
                    "overlaySidecarIPTC: .xmp sidecar for \(sourceURL.lastPathComponent, privacy: .public) looks stale (image file newer and differs); exported embedded values instead"
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
                    "overlaySidecarIPTC XMP writeFields failed for \(sourceURL.lastPathComponent, privacy: .public) → \(renderedURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
                "overlaySidecarIPTC JSON writeFields failed for \(sourceURL.lastPathComponent, privacy: .public) → \(renderedURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
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
