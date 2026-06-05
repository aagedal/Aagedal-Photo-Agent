import Foundation
import os.log

private let exportPipelineLog = Logger(
    subsystem: "com.aagedal.photo-agent",
    category: "ExportPipeline"
)

/// Accumulates per-file metadata failures that don't abort an export but should be
/// surfaced in the batch result. Shared by every export/publish call site.
actor MetadataFailureTracker: Sendable {
    private(set) var metadataCopyFailures: [String] = []
    private(set) var sidecarOverlayFailures: [String] = []
    func recordCopyFailure(_ filename: String) { metadataCopyFailures.append(filename) }
    func recordOverlayFailure(_ filename: String) { sidecarOverlayFailures.append(filename) }
}

/// Selects which `EditedImageRenderer` entry point a `renderItem` call uses.
enum RenderKind: Sendable {
    /// Honors the configured export format + HDR settings (`EditedImageRenderer.render`).
    case format
    /// "Save As" to a specific SDR format (`EditedImageRenderer.saveAs`).
    case saveAs(EditedImageRenderer.SaveAsFormat)
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
                           failureTracker: MetadataFailureTracker) async throws -> URL {
        let isHDR = (cameraRaw?.hdrEditMode == 1)
        let copier: EditedImageRenderer.MetadataCopier = { src, dst in
            do {
                try await writeEngine.copyMetadataToRenderedFile(from: src, to: dst)
            } catch {
                await failureTracker.recordCopyFailure(src.lastPathComponent)
            }
        }

        let renderedURL = try await Task.detached(priority: .userInitiated) {
            switch kind {
            case .format:
                return try await EditedImageRenderer.render(
                    from: sourceURL, cameraRaw: cameraRaw, isHDR: isHDR,
                    outputFolder: outputFolder, metadataCopier: copier)
            case .saveAs(let format):
                return try await EditedImageRenderer.saveAs(
                    from: sourceURL, cameraRaw: cameraRaw, format: format,
                    destinationFolder: outputFolder, metadataCopier: copier)
            case .jpeg:
                try await EditedImageRenderer.renderJPEG(
                    from: sourceURL, cameraRaw: cameraRaw,
                    outputFolder: outputFolder, metadataCopier: copier)
                return EditedImageRenderer.outputURL(for: sourceURL, in: outputFolder, extension: "jpg")
            }
        }.value

        let overlayOk = await SidecarIPTCOverlay.apply(
            sourceURL: sourceURL, renderedURL: renderedURL,
            folderURL: folderURL, writeEngine: writeEngine)
        if !overlayOk {
            await failureTracker.recordOverlayFailure(sourceURL.lastPathComponent)
        }
        return renderedURL
    }
}

/// Applies pending sidecar IPTC edits to a rendered output file. Checks both XMP sidecars
/// (default for C2PA) and JSON sidecars (history-only mode). Called after render so the
/// output includes edited metadata (keywords, caption, rating, label, …) that hasn't yet
/// been written back into the source file.
enum SidecarIPTCOverlay {
    @discardableResult
    static func apply(sourceURL: URL, renderedURL: URL, folderURL: URL?,
                      writeEngine: any MetadataWriteEngine) async -> Bool {
        // Prefer XMP sidecar IPTC (default write mode for C2PA files)
        let xmpService = XMPSidecarService()
        if let xmpMeta = xmpService.loadSidecar(for: sourceURL) {
            var fields = xmpMeta.toWriteFields()
            // Rating and label are excluded from toWriteFields() (managed separately
            // in normal flow). For rendered output we must include them because the source
            // file may be C2PA-protected and hold stale values.
            if let rating = xmpMeta.rating {
                fields[.rating] = String(rating)
            }
            if let label = xmpMeta.label, !label.isEmpty {
                fields[.label] = label
            }
            if !fields.isEmpty {
                do {
                    try await writeEngine.writeFields(fields, to: [renderedURL])
                    return true
                } catch {
                    exportPipelineLog.error(
                        "overlaySidecarIPTC XMP writeFields failed for \(sourceURL.lastPathComponent, privacy: .public) → \(renderedURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }
        }

        // Fall back to JSON sidecar (history-only mode)
        guard let folderURL else { return true }
        let sidecarService = MetadataSidecarService()
        guard let sidecar = sidecarService.loadSidecar(for: sourceURL, in: folderURL),
              sidecar.pendingChanges else { return true }

        var fields = sidecar.metadata.toWriteFields()
        if let rating = sidecar.metadata.rating {
            fields[.rating] = String(rating)
        }
        if let label = sidecar.metadata.label, !label.isEmpty {
            fields[.label] = label
        }
        guard !fields.isEmpty else { return true }

        do {
            try await writeEngine.writeFields(fields, to: [renderedURL])
            return true
        } catch {
            exportPipelineLog.error(
                "overlaySidecarIPTC JSON writeFields failed for \(sourceURL.lastPathComponent, privacy: .public) → \(renderedURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
