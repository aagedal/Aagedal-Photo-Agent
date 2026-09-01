import Foundation
import os

enum MetadataReferenceSource: String, CaseIterable, Identifiable, Sendable {
    case embedded
    case xmp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .embedded:
            return "Embedded"
        case .xmp:
            return "XMP Sidecar"
        }
    }
}

/// Common/partial projection for an unordered repeatable metadata property across a selection.
/// Values retain first-seen order for stable presentation even though equality is set-based.
nonisolated struct BatchListSelection<Value: Hashable & Sendable>: Sendable, Equatable {
    var common: [Value]
    var partial: [Value]

    nonisolated static var empty: Self { Self(common: [], partial: []) }
}

/// Typed projection of every repeatable field supported by the batch metadata editor.
/// Keeping partial values outside the editing buffer prevents a mixed-state placeholder from ever
/// becoming data that is propagated to the selected files.
nonisolated struct BatchMetadataListSelectionSummary: Sendable, Equatable {
    var repeatable: [MetadataFieldID: BatchListSelection<String>]
    var locationsShown: BatchListSelection<EditorialLocation>
    var imageSuppliers: BatchListSelection<EditorialImageSupplier>

    nonisolated static let empty = Self(
        repeatable: [:], locationsShown: .empty, imageSuppliers: .empty
    )

    nonisolated func selection(for field: MetadataFieldID) -> BatchListSelection<String> {
        repeatable[field] ?? .empty
    }
}

/// Structured locations are not part of `MetadataFieldID`, so they use the same explicit intent
/// vocabulary through a strongly typed companion operation.
nonisolated enum BatchLocationsShownMutation: Sendable, Equatable {
    case untouched
    case append([EditorialLocation])
    case replace([EditorialLocation])
    case clear
}

nonisolated enum BatchListSelectionError: Error, Sendable, Equatable {
    case batchSelectionRequired
    case repeatableFieldRequired(MetadataFieldID)
    case emptyLocationAppend
    case emptyLocationReplace
    case emptyImageSupplierAppend
    case emptyImageSupplierReplace
}

/// Typed completion from a metadata/history commit. This is separate from presentation state so
/// an owner awaiting an older request never has to infer its result from a mutable error string.
nonisolated enum MetadataCommitResult: Sendable, Equatable {
    case succeeded
    case cancelled(message: String)
    case failed(message: String)
}

@Observable
final class MetadataViewModel {
    var metadata: IPTCMetadata?
    var editingMetadata = IPTCMetadata()
    var isLoading = false
    var isSaving = false
    var isProcessingFolder = false
    var folderProcessProgress = ""
    var selectedCount = 0
    var selectedURLs: [URL] = []
    var hasChanges = false
    var isInEditView = false
    var saveError: String?
    var variableProcessingStatus: String?
    var variableProcessingHadFailures = false
    var selectedHasC2PA = false
    var descriptionConflict: DescriptionConflict?
    /// Non-blocking notice rendered as a dismissible banner in the metadata panel.
    /// Set by bulk-add paths (template apply, partial promotion, Quick List pick)
    /// when entries are rejected or canonicalised against the approved list.
    var notice: MetadataPanelNotice?

    var originalImageMetadata: IPTCMetadata?
    var embeddedMetadata: IPTCMetadata?
    var xmpMetadata: IPTCMetadata?
    var sidecarHistory: [MetadataHistoryEntry] = []
    var currentFolderURL: URL?
    var metadataReferenceSource: MetadataReferenceSource = .embedded
    /// Incremented after every metadata load completes. Observed by EditWorkspaceView
    /// to force re-render even when editingMetadata.cameraRaw hasn't changed.
    var metadataLoadGeneration: Int = 0

    var hasXmpMetadata: Bool { xmpMetadata != nil }
    var hasEmbeddedCropNotLoaded: Bool {
        guard let embeddedCrop = embeddedMetadata?.cameraRaw?.crop,
              embeddedCrop.hasCrop == true else { return false }
        return editingMetadata.cameraRaw?.crop?.hasCrop != true
    }
    var referenceMetadata: IPTCMetadata? {
        referenceMetadata(
            for: metadataReferenceSource,
            embedded: embeddedMetadata,
            xmp: xmpMetadata,
            imageURL: selectedURLs.count == 1 ? selectedURLs.first : nil
        )
    }
    var canWriteMetadataToImage: Bool {
        if isSaving { return false }
        if hasChanges { return true }
        if selectedCount == 1, let embedded = embeddedMetadata {
            return editingMetadata != embedded
        }
        return selectedHavePendingSidecars
    }

    // Batch metadata state - stores common values across selected images
    var batchCommonMetadata: IPTCMetadata?
    var batchDifferingFields: Set<String> = []
    var batchPartialKeywords: [String] = []
    var batchPartialPersonShown: [String] = []
    var batchListSelectionSummary = BatchMetadataListSelectionSummary.empty
    private(set) var batchFieldMutations: [MetadataFieldID: MetadataFieldMutation] = [:]
    private(set) var batchLocationsShownMutation: BatchLocationsShownMutation = .untouched
    private(set) var batchImageSupplierMutation: EditorialImageSupplierMutation = .untouched
    var isLoadingBatchMetadata = false

    // Geocoding state
    var isReverseGeocoding = false
    var geocodingError: String?
    var geocodingProgress = ""

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let descriptiveWriteBoundary: DescriptiveMetadataWriteBoundary
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let sidecarPersistenceService = MetadataSidecarPersistenceService()
    private let geocodingService = GeocodingService()
    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataViewModel")
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")
    private var previousEditingMetadata: IPTCMetadata?
    @ObservationIgnored private var metadataLoadTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var batchProcessTask: Task<Void, Never>?
    @ObservationIgnored private var geocodingTask: Task<Void, Never>?
    @ObservationIgnored private var batchMetadataByURL: [URL: IPTCMetadata] = [:]

    init(readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine) {
        self.readService = readService
        self.writeEngine = writeEngine
        self.descriptiveWriteBoundary = DescriptiveMetadataWriteBoundary(writeEngine: writeEngine)
    }

    deinit {
        metadataLoadTask?.cancel()
        writeTask?.cancel()
        batchProcessTask?.cancel()
        geocodingTask?.cancel()
    }

    var isBatchEdit: Bool { selectedCount > 1 }

    private func multiSelectMode(for field: String) -> MultiSelectFieldMode {
        switch field {
        case "keywords":
            let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectKeywordsMode)
                ?? MultiSelectFieldMode.add.rawValue
            return MultiSelectFieldMode(rawValue: raw) ?? .add
        case "personShown":
            let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.multiSelectPersonShownMode)
                ?? MultiSelectFieldMode.add.rawValue
            return MultiSelectFieldMode(rawValue: raw) ?? .add
        default:
            return .overwrite
        }
    }

    /// PM record semantics: when a sidecar exists it is the metadata record, so it is
    /// always the default reference (the per-image reading chip lets the user inspect
    /// embedded values; a stale verdict overrides this to .embedded at load).
    private func defaultReferenceSource(hasXmp: Bool) -> MetadataReferenceSource {
        hasXmp ? .xmp : .embedded
    }

    private func referenceMetadata(
        for source: MetadataReferenceSource,
        embedded: IPTCMetadata?,
        xmp: IPTCMetadata?,
        imageURL: URL? = nil
    ) -> IPTCMetadata? {
        switch source {
        case .embedded:
            // Develop (CRS) edits made in this app always persist to the XMP
            // sidecar — the image file itself is never rewritten by the editor
            // (mandatory for RAW/C2PA, and the default for non-RAW too). So even
            // when the user prefers embedded IPTC, the sidecar is authoritative
            // for develop settings: override embedded CRS with non-empty XMP CRS
            // for ALL file types. This mirrors the grid loader
            // (BrowserViewModel.applyBatchMetadataResults); previously this was
            // gated to RAW only, which dropped develop edits for JPEG/JXL on
            // reload and left the develop view showing the unedited original.
            if let embedded,
               let xmpCRS = xmp?.cameraRaw, !xmpCRS.isEmpty {
                var result = embedded
                var finalCRS = xmpCRS
                if (xmpCRS.localAdjustments?.isEmpty ?? true),
                   let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                    finalCRS.localAdjustments = masks
                }
                result.cameraRaw = finalCRS
                return result
            }
            return embedded
        case .xmp:
            if let embedded, let xmp {
                // Photo Mechanic semantics: a sidecar with descriptive content IS the
                // IPTC record — take its descriptive fields wholesale so clears stick
                // instead of resurrecting embedded values through empty fields. A
                // develop-only sidecar (no descriptive content) is not a record;
                // overlay it additively so embedded descriptive values show through.
                var merged = xmp.hasDescriptiveContent
                    ? embedded.replacingDescriptiveFields(from: xmp)
                    : embedded.merged(preferring: xmp)
                // RAW: XMP sidecar is authoritative for CRS — replace, don't merge,
                // to avoid stale embedded values leaking through nil sidecar fields
                // (e.g. Adobe omitting Temperature even with WhiteBalance="Custom").
                if let url = imageURL, SupportedImageFormats.isRaw(url: url),
                   let xmpCRS = xmp.cameraRaw {
                    var finalCRS = xmpCRS
                    // Preserve localAdjustments from embedded (written to image directly, not to XMP sidecar)
                    if (xmpCRS.localAdjustments?.isEmpty ?? true),
                       let masks = embedded.cameraRaw?.localAdjustments, !masks.isEmpty {
                        finalCRS.localAdjustments = masks
                    }
                    merged.cameraRaw = finalCRS
                }
                return merged
            }
            return xmp ?? embedded
        }
    }

    private(set) var selectedHavePendingSidecars = false

    private func loadXMPMetadata(for imageURL: URL) -> IPTCMetadata? {
        xmpSidecarService.loadSidecar(for: imageURL)
    }

    /// Reads a Copy Previous source without changing the current selection or editing buffer.
    /// Pending app sidecars win, followed by a current descriptive XMP record, then embedded
    /// metadata. This mirrors the normal single-image read path while remaining read-only.
    func loadCaptionCopyPreviousMetadata(for imageURL: URL) async throws -> IPTCMetadata {
        let embedded = try await readService.readFullMetadata(url: imageURL)
        let xmp = loadXMPMetadata(for: imageURL)

        var resolved = embedded
        if let xmp {
            let sidecarIsStale = SidecarReconciliation.verdict(
                imageURL: imageURL,
                sidecarURL: xmpSidecarService.sidecarURL(for: imageURL),
                embedded: embedded,
                sidecar: xmp
            ) == .fileNewerConflict
            if !sidecarIsStale {
                resolved = xmp.hasDescriptiveContent
                    ? embedded.replacingDescriptiveFields(from: xmp)
                    : embedded.merged(preferring: xmp)
            }
        }

        let folderURL = currentFolderURL ?? imageURL.deletingLastPathComponent()
        if let sidecar = sidecarService.loadSidecar(for: imageURL, in: folderURL),
           sidecar.pendingChanges {
            let bestCameraRaw = resolved.cameraRaw ?? sidecar.metadata.cameraRaw
            let bestOrientation = resolved.exifOrientation
            resolved = sidecar.metadata
            resolved.cameraRaw = bestCameraRaw
            resolved.exifOrientation = bestOrientation
        }
        return resolved
    }

    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil) {
        metadataLoadTask?.cancel()
        metadataLoadTask = nil

        // Snapshot BEFORE overwriting: the "reloading the same image/batch" checks below
        // must compare the new selection against what was previously loaded. Comparing
        // against the just-assigned selectedURLs is always true, which made every
        // navigation count as a same-image reload — carrying the previous file's
        // metadataReferenceSource to the next file. A file without a sidecar legitimately
        // lands on .embedded; the next (sidecar-backed) RAW then kept .embedded and showed
        // empty fields even though its .xmp was intact.
        let previousSelectedURLs = selectedURLs
        let selectionSnapshot = Set(images.map(\.url))
        let isReloadingSameBatch = images.count > 1
            && selectionSnapshot == Set(previousSelectedURLs)
            && batchCommonMetadata != nil

        selectedCount = images.count
        selectedURLs = images.map(\.url)
        hasChanges = false
        selectedHavePendingSidecars = false
        saveError = nil
        variableProcessingStatus = nil
        selectedHasC2PA = images.contains { $0.hasC2PA }
        descriptionConflict = nil
        sidecarHistory = []
        originalImageMetadata = nil
        embeddedMetadata = nil
        xmpMetadata = nil
        // Keep the displayed batch state intact across a redundant reload. Clearing it here
        // made `isReloadingSameBatch` impossible to detect and blanked/replaced fields while
        // the user was typing whenever a folder refresh reloaded the same selection.
        if !isReloadingSameBatch {
            batchCommonMetadata = nil
            batchDifferingFields = []
            batchPartialKeywords = []
            batchPartialPersonShown = []
            batchListSelectionSummary = .empty
            batchFieldMutations = [:]
            batchLocationsShownMutation = .untouched
            batchImageSupplierMutation = .untouched
            batchMetadataByURL = [:]
        }

        if let folderURL {
            currentFolderURL = folderURL
        }

        guard !images.isEmpty else {
            metadata = nil
            editingMetadata = IPTCMetadata()
            previousEditingMetadata = nil
            embeddedMetadata = nil
            xmpMetadata = nil
            isLoading = false
            isLoadingBatchMetadata = false
            batchMetadataByURL = [:]
            return
        }

        if images.count == 1 {
            batchMetadataByURL = [:]
            let imageURL = images[0].url

            // When reloading the same image (e.g. auto-refresh after external edit),
            // skip the synchronous reset to avoid flashing the preview to unedited state.
            let isReloadingSameImage = previousSelectedURLs.count == 1 && previousSelectedURLs.first == imageURL && metadata != nil
            if !isReloadingSameImage {
                metadata = nil
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
            }
            isLoading = true

            metadataLoadTask = Task {
                let loadStart = ContinuousClock.now
                self.perfLog.info("[MetadataVM] loadMetadata START — \(imageURL.lastPathComponent, privacy: .private(mask: .hash))")
                do {
                    let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: imageURL)
                    let exifMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] metadata read returned — \(exifMs)ms for \(imageURL.lastPathComponent, privacy: .private(mask: .hash))")
                    guard !Task.isCancelled else { return }
                    let xmpMeta = self.loadXMPMetadata(for: imageURL)
                    // Reconcile embedded vs sidecar: the sidecar is master unless the image
                    // file was modified more recently and they disagree (e.g. Adobe Bridge
                    // wrote into the file after the sidecar), in which case the file is the
                    // trustworthy source. See SidecarReconciliation.
                    let sidecarIsStale: Bool = {
                        guard let xmp = xmpMeta else { return false }
                        return SidecarReconciliation.verdict(
                            imageURL: imageURL,
                            sidecarURL: XMPSidecarService().sidecarURL(for: imageURL),
                            embedded: embedded, sidecar: xmp) == .fileNewerConflict
                    }()
                    // Preserve the user's manual reference source selection when
                    // reloading the same image (e.g. auto-refresh, post-save).
                    // Only fall back to the default on first load or if the
                    // previously selected source is no longer available.
                    let referenceSource: MetadataReferenceSource
                    if isReloadingSameImage,
                       !(self.metadataReferenceSource == .xmp && xmpMeta == nil) {
                        referenceSource = self.metadataReferenceSource
                    } else if sidecarIsStale {
                        // Stale sidecar → trust the embedded file by default; the comparison
                        // sheet lets the user merge per field.
                        referenceSource = .embedded
                    } else {
                        referenceSource = self.defaultReferenceSource(hasXmp: xmpMeta != nil)
                    }
                    let baseMeta = self.referenceMetadata(
                        for: referenceSource,
                        embedded: embedded,
                        xmp: xmpMeta,
                        imageURL: imageURL
                    ) ?? embedded
                    guard !Task.isCancelled else { return }
                    guard self.selectedURLs.count == 1,
                          self.selectedURLs.first == imageURL else { return }
                    self.embeddedMetadata = embedded
                    self.descriptionConflict = conflict
                    self.xmpMetadata = xmpMeta
                    self.metadataReferenceSource = referenceSource
                    self.metadata = baseMeta
                    self.originalImageMetadata = baseMeta

                    var newEditingMetadata = baseMeta
                    if let folder = self.currentFolderURL,
                       let sidecar = sidecarService.loadSidecar(for: imageURL, in: folder) {
                        self.sidecarHistory = sidecar.history
                        self.sidecarHistory.trimToHistoryLimit()
                        if sidecar.pendingChanges {
                            // Best CRS source: XMP/embedded (baseMeta) > JSON sidecar (fallback)
                            let bestCameraRaw = newEditingMetadata.cameraRaw
                                ?? sidecar.metadata.cameraRaw
                            let bestOrientation = newEditingMetadata.exifOrientation
                            newEditingMetadata = sidecar.metadata
                            newEditingMetadata.cameraRaw = bestCameraRaw
                            newEditingMetadata.exifOrientation = bestOrientation
                            self.hasChanges = true
                        }
                    }
                    // Always update on first load; optimize on reloads only.
                    if !isReloadingSameImage || self.editingMetadata != newEditingMetadata {
                        self.editingMetadata = newEditingMetadata
                    }
                    self.previousEditingMetadata = self.editingMetadata
                    self.metadataLoadGeneration += 1
                    let totalMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] loadMetadata DONE — \(imageURL.lastPathComponent, privacy: .private(mask: .hash)) total \(totalMs)ms")
                    self.logger.info("[\(imageURL.lastPathComponent, privacy: .private(mask: .hash))] loadMetadata result: xmp=\(xmpMeta != nil), stale=\(sidecarIsStale), ref=\(String(describing: referenceSource), privacy: .public), reloadSame=\(isReloadingSameImage), title=\(self.editingMetadata.title ?? "nil", privacy: .private(mask: .hash))")
                    if self.metadataReferenceSource == .xmp, self.xmpMetadata == nil {
                        self.metadataReferenceSource = .embedded
                    }
                } catch {
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                    self.saveError = "Failed to load metadata: \(error.localizedDescription)"
                    self.logger.error("[\(imageURL.lastPathComponent, privacy: .private(mask: .hash))] loadMetadata FAILED: \(error.localizedDescription, privacy: .private)")
                }
                guard !Task.isCancelled else { return }
                self.isLoading = false
            }
        } else {
            // Batch mode: load metadata for all selected images and find common values
            //
            // When reloading the same batch (e.g. auto-refresh after external edit),
            // skip the synchronous editingMetadata reset to avoid blanking the fields
            // while the user is editing.  The async load will update only if values
            // actually changed — mirroring the single-image isReloadingSameImage
            // optimisation.
            if !isReloadingSameBatch {
                metadata = nil
                editingMetadata = IPTCMetadata()
                previousEditingMetadata = nil
                embeddedMetadata = nil
                xmpMetadata = nil
                metadataReferenceSource = .embedded
            }
            isLoadingBatchMetadata = true

            metadataLoadTask = Task {
                await loadBatchMetadata(
                    for: images,
                    selectionSnapshot: selectionSnapshot,
                    isReload: isReloadingSameBatch
                )
                guard !Task.isCancelled else { return }
                self.isLoadingBatchMetadata = false
                self.refreshPendingSidecarsFlag(for: selectionSnapshot)
            }
        }
    }

    func applyReferenceSource(_ source: MetadataReferenceSource) {
        if source == .xmp, xmpMetadata == nil {
            metadataReferenceSource = .embedded
            return
        }
        metadataReferenceSource = source
        guard let reference = referenceMetadata(
            for: source,
            embedded: embeddedMetadata,
            xmp: xmpMetadata,
            imageURL: selectedURLs.count == 1 ? selectedURLs.first : nil
        ) else { return }

        originalImageMetadata = reference
        metadata = reference

        if !hasChanges {
            editingMetadata = reference
            previousEditingMetadata = reference
        }
    }

    /// Load metadata for all selected images and compute common values
    private func loadBatchMetadata(for images: [ImageFile], selectionSnapshot: Set<URL>, isReload: Bool = false) async {
        let urls = images.map(\.url)
        var allMetadata: [IPTCMetadata] = []
        var metadataByURL: [URL: IPTCMetadata] = [:]

        do {
            let batchResults = try await readService.readBatchFullMetadata(urls: urls)
            if Task.isCancelled { return }

            for image in images {
                guard var meta = batchResults[image.url] else { continue }
                if let xmpMeta = loadXMPMetadata(for: image.url) {
                    // Same record semantics as the single-image reference read: a
                    // descriptive sidecar IS the IPTC record (clears stick); a
                    // develop-only sidecar is overlaid additively.
                    meta = xmpMeta.hasDescriptiveContent
                        ? meta.replacingDescriptiveFields(from: xmpMeta)
                        : meta.merged(preferring: xmpMeta)
                }
                if let folder = currentFolderURL,
                   let sidecar = sidecarService.loadSidecar(for: image.url, in: folder),
                   sidecar.pendingChanges {
                    let bestCameraRaw = meta.cameraRaw ?? sidecar.metadata.cameraRaw
                    let bestOrientation = meta.exifOrientation
                    meta = sidecar.metadata
                    meta.cameraRaw = bestCameraRaw
                    meta.exifOrientation = bestOrientation
                }
                allMetadata.append(meta)
                metadataByURL[image.url] = meta
            }
        } catch {
            logger.error("Failed to load batch metadata: \(error.localizedDescription)")
        }

        guard !allMetadata.isEmpty else { return }
        guard !Task.isCancelled else { return }
        guard Set(selectedURLs) == selectionSnapshot else { return }

        // Compute common values and differing fields
        var common = IPTCMetadata()
        var differing = Set<String>()

        // Optional fields
        compareOptionalField(allMetadata, keyPath: \.title, fieldName: "title", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.description, fieldName: "description", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.extendedDescription, fieldName: "extendedDescription", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.copyright, fieldName: "copyright", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.rightsUsageTerms, fieldName: "rightsUsageTerms", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.webStatementOfRights, fieldName: "webStatementOfRights", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.digitalImageGUID, fieldName: "digitalImageGUID", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.imageSupplierImageID, fieldName: "imageSupplierImageID", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.jobId, fieldName: "jobId", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.creatorJobTitle, fieldName: "creatorJobTitle", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.descriptionWriter, fieldName: "descriptionWriter", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.credit, fieldName: "credit", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.city, fieldName: "city", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.sublocation, fieldName: "sublocation", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.provinceState, fieldName: "provinceState", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.country, fieldName: "country", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.countryCode, fieldName: "countryCode", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.event, fieldName: "event", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.instructions, fieldName: "instructions", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.source, fieldName: "source", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.digitalSourceType, fieldName: "digitalSourceType", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.urgency, fieldName: "urgency", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.dateCreated, fieldName: "dateCreated", common: &common, differing: &differing)

        // Repeatable IPTC Bags use normalized membership. Creator is the ordered Seq exception:
        // only an identical sequence is common, so mixed order can never be propagated silently.
        let listSummary = Self.batchListSelectionSummary(for: allMetadata)
        common.keywords = listSummary.selection(for: .keywords).common
        common.personShown = listSummary.selection(for: .personShown).common
        common.organisationsShownNames = listSummary.selection(for: .organisationShownName).common
        common.organisationsShownCodes = listSummary.selection(for: .organisationShownCode).common
        common.sceneCodes = listSummary.selection(for: .sceneCode).common
        common.subjectCodes = listSummary.selection(for: .subjectCode).common
        let commonMediaTopicIDs = Set(listSummary.selection(for: .mediaTopic).common)
        common.mediaTopics = allMetadata[0].mediaTopics.filter { commonMediaTopicIDs.contains($0.termIdentifier) }
        let commonGenreIDs = Set(listSummary.selection(for: .genre).common)
        common.genres = allMetadata[0].genres.filter { commonGenreIDs.contains($0.termIdentifier) }
        common.creators = listSummary.selection(for: .creator).common
        common.locationsShown = listSummary.locationsShown.common

        for (field, differingName) in [
            (MetadataFieldID.keywords, "keywords"),
            (.personShown, "personShown"),
            (.organisationShownName, "organisationShownName"),
            (.organisationShownCode, "organisationShownCode"),
            (.sceneCode, "sceneCode"),
            (.subjectCode, "subjectCode"),
            (.mediaTopic, "mediaTopic"),
            (.genre, "genre"),
            (.creator, "creator"),
        ] where !listSummary.selection(for: field).partial.isEmpty {
            differing.insert(differingName)
        }
        if !listSummary.locationsShown.partial.isEmpty {
            differing.insert("locationsShown")
        }
        self.batchPartialKeywords = listSummary.selection(for: .keywords).partial
        self.batchPartialPersonShown = listSummary.selection(for: .personShown).partial
        self.batchListSelectionSummary = listSummary
        self.batchMetadataByURL = metadataByURL

        // GPS - check if all have the same coordinates
        let latitudes = allMetadata.compactMap(\.latitude)
        let longitudes = allMetadata.compactMap(\.longitude)
        if latitudes.count == allMetadata.count,
           longitudes.count == allMetadata.count,
           let firstLat = latitudes.first,
           let firstLon = longitudes.first,
           latitudes.allSatisfy({ abs($0 - firstLat) < 0.000001 }),
           longitudes.allSatisfy({ abs($0 - firstLon) < 0.000001 }) {
            common.latitude = firstLat
            common.longitude = firstLon
        } else if !latitudes.isEmpty || !longitudes.isEmpty {
            differing.insert("gps")
        }

        self.batchCommonMetadata = common
        self.batchDifferingFields = differing
        // Pre-populate editing metadata with common values.
        // On redundant reloads (same batch, e.g. auto-refresh), skip the
        // update when the loaded values match what's already displayed to
        // avoid overwriting the user's in-progress edits.
        if !isReload || self.editingMetadata != common {
            self.editingMetadata = common
            self.previousEditingMetadata = common
        }
    }

    private func compareOptionalField<T: Equatable>(
        _ allMetadata: [IPTCMetadata],
        keyPath: WritableKeyPath<IPTCMetadata, T?>,
        fieldName: String,
        common: inout IPTCMetadata,
        differing: inout Set<String>
    ) {
        let values = allMetadata.compactMap { $0[keyPath: keyPath] }
        if values.count == allMetadata.count,
           let first = values.first,
           values.allSatisfy({ $0 == first }) {
            common[keyPath: keyPath] = first
        } else if !values.isEmpty {
            differing.insert(fieldName)
        }
    }

    nonisolated static func batchListSelectionSummary(
        for allMetadata: [IPTCMetadata]
    ) -> BatchMetadataListSelectionSummary {
        guard !allMetadata.isEmpty else { return .empty }

        var repeatable: [MetadataFieldID: BatchListSelection<String>] = [:]
        for field in MetadataFieldID.allCases where field.isRepeatable {
            let lists = allMetadata.map {
                normalizedRepeatableValues(values(for: field, in: $0), field: field)
            }
            repeatable[field] = field == .creator
                ? summarizeOrderedLists(lists)
                : summarizeUnorderedLists(lists)
        }

        return BatchMetadataListSelectionSummary(
            repeatable: repeatable,
            locationsShown: summarizeUnorderedLists(
                allMetadata.map { normalizedLocations($0.locationsShown) }
            ),
            imageSuppliers: summarizeUnorderedLists(
                allMetadata.map { EditorialImageSupplier.normalizedValues($0.imageSuppliers) }
            )
        )
    }

    private nonisolated static func summarizeOrderedLists<Value: Hashable & Sendable>(
        _ lists: [[Value]]
    ) -> BatchListSelection<Value> {
        guard let first = lists.first else { return .empty }
        if lists.dropFirst().allSatisfy({ $0 == first }) {
            return BatchListSelection(common: first, partial: [])
        }
        var union: [Value] = []
        var seen = Set<Value>()
        for list in lists {
            union.append(contentsOf: list.filter { seen.insert($0).inserted })
        }
        return BatchListSelection(common: [], partial: union)
    }

    private nonisolated static func summarizeUnorderedLists<Value: Hashable & Sendable>(
        _ lists: [[Value]]
    ) -> BatchListSelection<Value> {
        guard let first = lists.first else { return .empty }
        let commonSet = lists.dropFirst().reduce(Set(first)) { result, values in
            result.intersection(values)
        }

        var unionOrder: [Value] = []
        var seen = Set<Value>()
        for values in lists {
            for value in values where seen.insert(value).inserted {
                unionOrder.append(value)
            }
        }
        return BatchListSelection(
            common: first.filter { commonSet.contains($0) },
            partial: unionOrder.filter { !commonSet.contains($0) }
        )
    }

    private nonisolated static func values(
        for field: MetadataFieldID,
        in metadata: IPTCMetadata
    ) -> [String] {
        switch field {
        case .creator: metadata.creators
        case .keywords: metadata.keywords
        case .personShown: metadata.personShown
        case .organisationShownName: metadata.organisationsShownNames
        case .organisationShownCode: metadata.organisationsShownCodes
        case .sceneCode: metadata.sceneCodes
        case .subjectCode: metadata.subjectCodes
        case .mediaTopic: metadata.mediaTopics.map(\.termIdentifier)
        case .genre: metadata.genres.map(\.termIdentifier)
        default: []
        }
    }

    private nonisolated static func normalizedRepeatableValues(
        _ values: [String],
        field: MetadataFieldID
    ) -> [String] {
        let trimmed = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        if field == .sceneCode {
            return IPTCSceneCode.normalizedValues(trimmed.map(IPTCSceneCode.normalizedEditorValue))
        }
        if field == .subjectCode {
            return IPTCSubjectCode.normalizedValues(trimmed)
        }
        if field == .mediaTopic {
            return IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
            ).map(\.termIdentifier)
        }
        if field == .genre {
            return IPTCControlledVocabularyTerm.normalizedValues(
                trimmed.compactMap { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
            ).map(\.termIdentifier)
        }
        return trimmed
    }

    private nonisolated static func normalizedLocations(
        _ locations: [EditorialLocation]
    ) -> [EditorialLocation] {
        locations.compactMap { location in
            var normalized = location
            normalized.identifiers = location.identifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .uniqued()
                .sorted()
            normalized.name = normalizedText(location.name)
            normalized.sublocation = normalizedText(location.sublocation)
            normalized.city = normalizedText(location.city)
            normalized.provinceState = normalizedText(location.provinceState)
            normalized.countryName = normalizedText(location.countryName)
            normalized.countryCode = ISO3166Country.normalizedAlpha3(normalizedText(location.countryCode))
            normalized.worldRegion = normalizedText(location.worldRegion)
            return normalized.isEmpty ? nil : normalized
        }.uniqued()
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Records explicit append/replace/clear intent for one repeatable field. The common-value
    /// projection is only a preview; persistence applies the operation independently to each
    /// selected record, so partial values cannot be mistaken for absent values.
    func setBatchMutation(
        _ mutation: MetadataFieldMutation,
        for field: MetadataFieldID
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        guard field.isRepeatable else { throw BatchListSelectionError.repeatableFieldRequired(field) }

        var proposed = batchFieldMutations
        if mutation == .untouched {
            proposed.removeValue(forKey: field)
        } else {
            proposed[field] = mutation
        }
        let preview = try Self.applyingBatchListMutations(
            proposed,
            locationsShown: batchLocationsShownMutation,
            imageSuppliers: batchImageSupplierMutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchFieldMutations = proposed
        copyBatchLists(from: preview, into: &editingMetadata)
        // This API owns only the explicit list intent. Never clear dirty state here: scalar
        // fields may already have pending edits that are intentionally independent of it.
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched
            || batchImageSupplierMutation != .untouched {
            hasChanges = true
        }
    }

    func setBatchLocationsShownMutation(
        _ mutation: BatchLocationsShownMutation
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        let preview = try Self.applyingBatchListMutations(
            batchFieldMutations,
            locationsShown: mutation,
            imageSuppliers: batchImageSupplierMutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchLocationsShownMutation = mutation
        copyBatchLists(from: preview, into: &editingMetadata)
        if !batchFieldMutations.isEmpty || mutation != .untouched
            || batchImageSupplierMutation != .untouched {
            hasChanges = true
        }
    }

    func setBatchImageSupplierMutation(
        _ mutation: EditorialImageSupplierMutation
    ) throws {
        guard isBatchEdit else { throw BatchListSelectionError.batchSelectionRequired }
        switch mutation {
        case let .append(values) where EditorialImageSupplier.normalizedValues(values).isEmpty:
            throw BatchListSelectionError.emptyImageSupplierAppend
        case let .replace(values) where EditorialImageSupplier.normalizedValues(values).isEmpty:
            throw BatchListSelectionError.emptyImageSupplierReplace
        default:
            break
        }
        let preview = try Self.applyingBatchListMutations(
            batchFieldMutations,
            locationsShown: batchLocationsShownMutation,
            imageSuppliers: mutation,
            to: batchCommonMetadata ?? IPTCMetadata()
        )
        batchImageSupplierMutation = mutation
        copyBatchLists(from: preview, into: &editingMetadata)
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched
            || mutation != .untouched {
            hasChanges = true
        }
    }

    nonisolated static func applyingBatchListMutations(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        locationsShown: BatchLocationsShownMutation = .untouched,
        imageSuppliers: EditorialImageSupplierMutation = .untouched,
        to metadata: IPTCMetadata
    ) throws -> IPTCMetadata {
        var result = metadata
        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            try result.apply(mutation, to: field)
        }

        switch locationsShown {
        case .untouched:
            break
        case .clear:
            result.locationsShown = []
        case .append(let locations):
            let normalized = normalizedLocations(locations)
            guard !normalized.isEmpty else { throw BatchListSelectionError.emptyLocationAppend }
            result.locationsShown = normalizedLocations(result.locationsShown + normalized)
        case .replace(let locations):
            let normalized = normalizedLocations(locations)
            guard !normalized.isEmpty else { throw BatchListSelectionError.emptyLocationReplace }
            result.locationsShown = normalized
        }
        result.imageSuppliers = imageSuppliers.apply(to: result.imageSuppliers)
        return result
    }

    private func copyBatchLists(from source: IPTCMetadata, into target: inout IPTCMetadata) {
        target.keywords = source.keywords
        target.personShown = source.personShown
        target.organisationsShownNames = source.organisationsShownNames
        target.organisationsShownCodes = source.organisationsShownCodes
        target.sceneCodes = source.sceneCodes
        target.subjectCodes = source.subjectCodes
        target.mediaTopics = source.mediaTopics
        target.genres = source.genres
        target.creators = source.creators
        target.locationsShown = source.locationsShown
        target.imageSuppliers = source.imageSuppliers
    }

    func promotePartialKeyword(_ keyword: String) {
        switch ApprovedListService.shared.validate(keyword, in: .keywords) {
        case .reject(let reason):
            notice = MetadataPanelNotice(
                title: "Keyword not added — \(reason)",
                detail: [keyword],
                severity: .warning
            )
            return
        case .accept:
            if !editingMetadata.keywords.contains(keyword) {
                editingMetadata.keywords.append(keyword)
            }
        case .acceptCanonical(let canonical):
            if !editingMetadata.keywords.contains(canonical) {
                editingMetadata.keywords.append(canonical)
            }
        }
        batchPartialKeywords.removeAll { $0 == keyword }
        hasChanges = true
    }

    func promotePartialPerson(_ person: String) {
        if !editingMetadata.personShown.contains(person) {
            editingMetadata.personShown.append(person)
        }
        batchPartialPersonShown.removeAll { $0 == person }
        hasChanges = true
    }

    /// Check for pending sidecars once after batch loading, instead of on every UI access.
    private func refreshPendingSidecarsFlag(for selectionSnapshot: Set<URL>) {
        guard let folderURL = currentFolderURL else { return }
        guard Set(selectedURLs) == selectionSnapshot else { return }
        for url in selectedURLs {
            if let sidecar = sidecarService.loadSidecar(for: url, in: folderURL),
               sidecar.pendingChanges {
                selectedHavePendingSidecars = true
                return
            }
        }
    }

    /// Returns the placeholder text for a batch field that has differing values
    func batchPlaceholder(for field: String) -> String {
        if batchDifferingFields.contains(field) {
            return "Multiple values"
        }
        return "Leave empty to skip"
    }

    /// Returns true if a field has differing values across the batch selection
    func fieldHasMultipleValues(_ field: String) -> Bool {
        batchDifferingFields.contains(field)
    }

    func markChanged() {
        hasChanges = true
    }

    /// Append `incoming` to `editingMetadata.keywords`, skipping empties and entries
    /// already present (case-sensitive). Returns the count actually added.
    /// Calls `markChanged()` when at least one keyword was added.
    @discardableResult
    func appendKeywords(_ incoming: [String]) -> Int {
        var current = editingMetadata.keywords
        var seen = Set(current)
        var addedCount = 0
        for keyword in incoming {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(trimmed) {
                seen.insert(trimmed)
                current.append(trimmed)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return 0 }
        editingMetadata.keywords = current
        markChanged()
        return addedCount
    }

    /// Appends trimmed, de-duplicated names to `personShown`, preserving order.
    /// Returns the number actually added; calls `markChanged()` when non-zero.
    @discardableResult
    func appendPersonShown(_ incoming: [String]) -> Int {
        var current = editingMetadata.personShown
        var seen = Set(current)
        var addedCount = 0
        for name in incoming {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                current.append(trimmed)
                addedCount += 1
            }
        }
        guard addedCount > 0 else { return 0 }
        editingMetadata.personShown = current
        markChanged()
        return addedCount
    }

    func resolveDescriptionConflict(keepXMP: Bool) {
        guard let conflict = descriptionConflict else { return }
        editingMetadata.description = keepXMP ? conflict.xmpDescription : conflict.iptcCaptionAbstract
        descriptionConflict = nil
        markChanged()
    }

    /// Clears Camera Raw develop + crop edits from the live editing session in memory.
    /// Call right after `BrowserViewModel.resetAllEditsOnSelected` so the develop editor
    /// reflects the reset immediately — without this, reopening the editor reads the
    /// not-yet-rewritten file/sidecar and resurrects the just-removed edits (the async
    /// XMP rewrite can land seconds later). Mirrors the clear across the reference copies
    /// so it isn't seen as a pending change, and bumps the generation to force a re-render.
    func resetCameraRawEdits() {
        editingMetadata.cameraRaw = nil
        originalImageMetadata?.cameraRaw = nil
        metadata?.cameraRaw = nil
        previousEditingMetadata?.cameraRaw = nil
        metadataLoadGeneration += 1
    }

    func importEmbeddedCrop() {
        guard let embeddedCrop = embeddedMetadata?.cameraRaw?.crop,
              embeddedCrop.hasCrop == true else { return }
        if editingMetadata.cameraRaw == nil {
            editingMetadata.cameraRaw = CameraRawSettings()
        }
        editingMetadata.cameraRaw?.crop = embeddedCrop
        markChanged()
    }

    /// Writes the editing buffer to the destination the mode dictates. A file-writing
    /// mode writes into C2PA files without ceremony — only the Simple preset resolves
    /// C2PA to `.writeToFile`, and Simple deliberately ignores content credentials
    /// (Professional and Custom route C2PA to sidecar-only modes upstream).
    func commitEdits(
        mode: MetadataWriteMode,
        onComplete: (() -> Void)? = nil
    ) {
        commitEditsReportingResult(mode: mode) { _ in
            onComplete?()
        }
    }

    /// Reports the result of the exact commit request to an external lifecycle owner.
    /// `historyOnly` retains its established fire-and-forget contract; Develop uses the two
    /// durable modes whose completions occur only after their metadata/history work finishes.
    func commitEditsReportingResult(
        mode: MetadataWriteMode,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        switch mode {
        case .historyOnly:
            saveToSidecar()
            onComplete(.succeeded)
        case .writeToXMPSidecar:
            writeXMPSidecarAndPreserveHistory(onComplete: onComplete)
        case .writeToFile, .writeToFileAndXMPSidecar:
            writeMetadataAndPreserveHistory(alsoWriteXMPSidecar: mode.writesXMPSidecar, onComplete: onComplete)
        }
    }

    func writeMetadata() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let selectionSnapshot = Set(urls)
        let edited = editingMetadata
        let original = metadata
        let isBatch = isBatchEdit
        let prevEditing = previousEditingMetadata
        let explicitBatchMutations = batchFieldMutations
        let explicitLocationsShownMutation = batchLocationsShownMutation
        let resolvedBatchSnapshot = batchMetadataByURL
        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            do {
                var fields: [MetadataFieldKey: String] = [:]

                if isBatch {
                    // Batch: only write non-empty fields
                    if let v = edited.title, !v.isEmpty { fields[.headline] = v }
                    if let v = edited.description, !v.isEmpty { fields[.description] = v }
                    if let v = edited.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }

                    // Keywords — check add vs overwrite mode
                    let keywordsMode = self.multiSelectMode(for: "keywords")
                    if keywordsMode == .overwrite {
                        if !edited.keywords.isEmpty {
                            fields[.subject] = edited.keywords.joined(separator: ", ")
                        }
                    }
                    // Add mode keywords handled below via addRemoveListValues

                    // Person Shown — check add vs overwrite mode
                    let personMode = self.multiSelectMode(for: "personShown")
                    if personMode == .overwrite {
                        if !edited.personShown.isEmpty {
                            fields[.personInImage] = edited.personShown.joined(separator: ", ")
                        }
                    }
                    // Add mode personShown handled below via addRemoveListValues

                    if let v = edited.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
                    if let v = edited.urgency { fields[.urgency] = String(v) }
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields[.gpsLatitude] = String(abs(lat))
                        fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                        fields[.gpsLongitude] = String(abs(lon))
                        fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                    }
                    if let v = edited.creatorTransportValue { fields[.creator] = v }
                    if let v = edited.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
                    if let v = edited.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
                    if let v = edited.credit, !v.isEmpty { fields[.credit] = v }
                    if let v = edited.copyright, !v.isEmpty { fields[.rights] = v }
                    if let v = edited.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
                    if let v = edited.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
                    if let v = edited.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
                    if let v = edited.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
                    if let v = edited.jobId, !v.isEmpty { fields[.transmissionReference] = v }
                    if let v = edited.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
                    if let v = edited.city, !v.isEmpty { fields[.city] = v }
                    if let v = edited.sublocation, !v.isEmpty { fields[.sublocation] = v }
                    if let v = edited.provinceState, !v.isEmpty { fields[.provinceState] = v }
                    if let v = edited.country, !v.isEmpty { fields[.country] = v }
                    if let v = edited.countryCode, !v.isEmpty { fields[.countryCode] = v }
                    if let v = edited.event, !v.isEmpty { fields[.event] = v }
                    if let v = edited.instructions, !v.isEmpty { fields[.instructions] = v }
                    if let v = edited.source, !v.isEmpty { fields[.source] = v }
                } else {
                    // Single: write all changed fields
                    if edited.title != original?.title { fields[.headline] = edited.title ?? "" }
                    if edited.description != original?.description { fields[.description] = edited.description ?? "" }
                    if edited.extendedDescription != original?.extendedDescription {
                        fields[.extendedDescription] = edited.extendedDescription ?? ""
                    }
                    if edited.keywords != original?.keywords {
                        // Clear then set keywords
                        fields[.subject] = edited.keywords.uniqued().joined(separator: ", ")
                    }
                    if edited.personShown != original?.personShown {
                        fields[.personInImage] = edited.personShown.uniqued().joined(separator: ", ")
                    }
                    if edited.organisationsShownNames != original?.organisationsShownNames {
                        fields[.organisationInImageName] = edited.organisationsShownNames.uniqued().joined(separator: ", ")
                    }
                    if edited.organisationsShownCodes != original?.organisationsShownCodes {
                        fields[.organisationInImageCode] = edited.organisationsShownCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.sceneCodes != original?.sceneCodes {
                        fields[.scene] = edited.sceneCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.subjectCodes != original?.subjectCodes {
                        fields[.subjectCode] = edited.subjectCodes.uniqued().joined(separator: ", ")
                    }
                    if edited.mediaTopics != original?.mediaTopics {
                        fields[.mediaTopic] = edited.mediaTopics.map(\.termIdentifier).joined(separator: ", ")
                    }
                    if edited.genres != original?.genres {
                        fields[.genre] = edited.genres.map(\.termIdentifier).joined(separator: ", ")
                    }
                    if edited.digitalSourceType != original?.digitalSourceType {
                        fields[.digitalSourceType] = edited.digitalSourceType?.newsCodeURI ?? ""
                    }
                    if edited.urgency != original?.urgency {
                        fields[.urgency] = edited.urgency.map(String.init) ?? ""
                    }
                    if edited.latitude != original?.latitude || edited.longitude != original?.longitude {
                        if let lat = edited.latitude, let lon = edited.longitude {
                            fields[.gpsLatitude] = String(abs(lat))
                            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                            fields[.gpsLongitude] = String(abs(lon))
                            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                        } else {
                            fields[.gpsLatitude] = ""
                            fields[.gpsLatitudeRef] = ""
                            fields[.gpsLongitude] = ""
                            fields[.gpsLongitudeRef] = ""
                        }
                    }
                    if edited.creators != original?.creators {
                        fields[.creator] = edited.creatorTransportValue ?? ""
                    }
                    if edited.creatorJobTitle != original?.creatorJobTitle { fields[.creatorJobTitle] = edited.creatorJobTitle ?? "" }
                    if edited.descriptionWriter != original?.descriptionWriter { fields[.descriptionWriter] = edited.descriptionWriter ?? "" }
                    if edited.credit != original?.credit { fields[.credit] = edited.credit ?? "" }
                    if edited.copyright != original?.copyright { fields[.rights] = edited.copyright ?? "" }
                    if edited.rightsUsageTerms != original?.rightsUsageTerms { fields[.rightsUsageTerms] = edited.rightsUsageTerms ?? "" }
                    if edited.webStatementOfRights != original?.webStatementOfRights { fields[.webStatementOfRights] = edited.webStatementOfRights ?? "" }
                    if edited.digitalImageGUID != original?.digitalImageGUID { fields[.digitalImageGUID] = edited.digitalImageGUID ?? "" }
                    if edited.imageSupplierImageID != original?.imageSupplierImageID { fields[.imageSupplierImageID] = edited.imageSupplierImageID ?? "" }
                    if edited.jobId != original?.jobId {
                        fields[.transmissionReference] = edited.jobId ?? ""
                    }
                    if edited.dateCreated != original?.dateCreated { fields[.dateCreated] = edited.dateCreated ?? "" }
                    if edited.city != original?.city { fields[.city] = edited.city ?? "" }
                    if edited.sublocation != original?.sublocation { fields[.sublocation] = edited.sublocation ?? "" }
                    if edited.provinceState != original?.provinceState { fields[.provinceState] = edited.provinceState ?? "" }
                    if edited.country != original?.country { fields[.country] = edited.country ?? "" }
                    if edited.countryCode != original?.countryCode { fields[.countryCode] = edited.countryCode ?? "" }
                    if edited.event != original?.event { fields[.event] = edited.event ?? "" }
                    if edited.instructions != original?.instructions { fields[.instructions] = edited.instructions ?? "" }
                    if edited.source != original?.source { fields[.source] = edited.source ?? "" }
                }

                if isBatch {
                    Self.applyExplicitBatchWriteFields(explicitBatchMutations, into: &fields)
                }

                let structuredEditorialChanged = !isBatch && (
                    edited.creatorContactInfo != original?.creatorContactInfo
                        || Set(edited.locationsCreated) != Set(original?.locationsCreated ?? [])
                        || Set(edited.locationsShown) != Set(original?.locationsShown ?? [])
                        || Set(edited.mediaTopics) != Set(original?.mediaTopics ?? [])
                        || Set(edited.genres) != Set(original?.genres ?? [])
                )
                if !fields.isEmpty || structuredEditorialChanged {
                    let structuredData = StructuredWriteData(
                        editorial: structuredEditorialChanged
                            ? EditorialStructuredWriteData(metadata: edited)
                            : nil
                    )
                    try await writeEngine.writeFields(fields, to: urls, structuredData: structuredData)
                }

                // Handle additive list fields via += / -=
                if isBatch, let prev = prevEditing {
                    let diffs = additiveListDiffs(
                        from: edited,
                        previous: prev,
                        explicitMutations: explicitBatchMutations
                    )
                    if !diffs.add.isEmpty || !diffs.remove.isEmpty {
                        try await writeEngine.addRemoveListValues(
                            add: diffs.add,
                            remove: diffs.remove,
                            to: urls
                        )
                    }
                }

                if isBatch, explicitLocationsShownMutation != .untouched {
                    for url in urls {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let updated = try Self.applyingBatchListMutations(
                            [:],
                            locationsShown: explicitLocationsShownMutation,
                            to: base
                        )
                        try await writeEngine.writeFields(
                            [:],
                            to: [url],
                            structuredData: StructuredWriteData(
                                editorial: EditorialStructuredWriteData(metadata: updated)
                            )
                        )
                    }
                }

                let controlledStructuredMutations = explicitBatchMutations.filter {
                    $0.key == .mediaTopic || $0.key == .genre
                }
                if isBatch, !controlledStructuredMutations.isEmpty {
                    for url in urls {
                        let base: IPTCMetadata
                        if let resolved = resolvedBatchSnapshot[url] {
                            base = resolved
                        } else {
                            base = try await self.readService.readFullMetadata(url: url)
                        }
                        let updated = try MetadataFieldMutationSet(controlledStructuredMutations)
                            .applying(to: base)
                        try await writeEngine.writeFields(
                            [:],
                            to: [url],
                            structuredData: StructuredWriteData(
                                editorial: EditorialStructuredWriteData(metadata: updated)
                            )
                        )
                    }
                }

                await self.mirrorEmbeddedStateToExistingSidecars(for: urls)

                if Set(self.selectedURLs) == selectionSnapshot {
                    self.metadata = edited
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    private func batchWriteFields(from metadata: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        if let v = metadata.title, !v.isEmpty { fields[.headline] = v }
        if let v = metadata.description, !v.isEmpty { fields[.description] = v }
        if let v = metadata.extendedDescription, !v.isEmpty { fields[.extendedDescription] = v }
        if multiSelectMode(for: "keywords") == .overwrite, !metadata.keywords.isEmpty {
            fields[.subject] = metadata.keywords.joined(separator: ", ")
        }
        if multiSelectMode(for: "personShown") == .overwrite, !metadata.personShown.isEmpty {
            fields[.personInImage] = metadata.personShown.joined(separator: ", ")
        }
        if let v = metadata.digitalSourceType { fields[.digitalSourceType] = v.newsCodeURI }
        if let v = metadata.urgency { fields[.urgency] = String(v) }
        if let v = metadata.creatorTransportValue { fields[.creator] = v }
        if let v = metadata.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
        if let v = metadata.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
        if let v = metadata.credit, !v.isEmpty { fields[.credit] = v }
        if let v = metadata.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = metadata.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
        if let v = metadata.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
        if let v = metadata.digitalImageGUID, !v.isEmpty { fields[.digitalImageGUID] = v }
        if let v = metadata.imageSupplierImageID, !v.isEmpty { fields[.imageSupplierImageID] = v }
        if let v = metadata.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = metadata.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = metadata.city, !v.isEmpty { fields[.city] = v }
        if let v = metadata.sublocation, !v.isEmpty { fields[.sublocation] = v }
        if let v = metadata.provinceState, !v.isEmpty { fields[.provinceState] = v }
        if let v = metadata.country, !v.isEmpty { fields[.country] = v }
        if let v = metadata.countryCode, !v.isEmpty { fields[.countryCode] = v }
        if let v = metadata.event, !v.isEmpty { fields[.event] = v }
        if let v = metadata.instructions, !v.isEmpty { fields[.instructions] = v }
        if let v = metadata.source, !v.isEmpty { fields[.source] = v }
        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        }
        appendCameraRawFields(from: metadata, into: &fields)
        return fields
    }

    private nonisolated static func applyExplicitBatchWriteFields(
        _ mutations: [MetadataFieldID: MetadataFieldMutation],
        into fields: inout [MetadataFieldKey: String]
    ) {
        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard let mutation = mutations[field] else { continue }
            switch mutation {
            case .untouched:
                fields.removeValue(forKey: field.metadataWriteKey)
            case .append:
                // Appends use the typed add/remove writer path below; never also overwrite the
                // field with the common-value preview.
                fields.removeValue(forKey: field.metadataWriteKey)
            case .clear:
                fields[field.metadataWriteKey] = ""
            case .overwrite:
                guard let updated = try? applyingBatchListMutations(
                    [field: mutation],
                    to: IPTCMetadata()
                ) else { continue }
                if field == .creator {
                    fields[field.metadataWriteKey] = updated.creatorTransportValue ?? ""
                } else {
                    fields[field.metadataWriteKey] = values(for: field, in: updated)
                        .joined(separator: ", ")
                }
            }
        }
    }

    /// Compute add/remove diffs for list fields in add mode, relative to previousEditingMetadata.
    private func additiveListDiffs(
        from edited: IPTCMetadata,
        previous: IPTCMetadata,
        explicitMutations: [MetadataFieldID: MetadataFieldMutation]
    ) -> (add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]]) {
        var addTags: [MetadataFieldKey: [String]] = [:]
        var removeTags: [MetadataFieldKey: [String]] = [:]

        for field in MetadataFieldID.allCases where field.isRepeatable {
            guard case .append(let values)? = explicitMutations[field] else { continue }
            let normalized = Self.normalizedRepeatableValues(values, field: field)
            if !normalized.isEmpty {
                addTags[field.metadataWriteKey] = normalized
            }
        }

        if explicitMutations[.keywords] == nil, multiSelectMode(for: "keywords") == .add {
            let added = Array(Set(edited.keywords).subtracting(previous.keywords))
            let removed = Array(Set(previous.keywords).subtracting(edited.keywords))
            if !added.isEmpty { addTags[.subject] = added }
            if !removed.isEmpty { removeTags[.subject] = removed }
        }

        if explicitMutations[.personShown] == nil, multiSelectMode(for: "personShown") == .add {
            let added = Array(Set(edited.personShown).subtracting(previous.personShown))
            let removed = Array(Set(previous.personShown).subtracting(edited.personShown))
            if !added.isEmpty { addTags[.personInImage] = added }
            if !removed.isEmpty { removeTags[.personInImage] = removed }
        }

        if explicitMutations[.organisationShownName] == nil {
            let previousOrganisationNames = Set(previous.organisationsShownNames)
            let editedOrganisationNames = Set(edited.organisationsShownNames)
            let addedOrganisationNames = edited.organisationsShownNames.filter { !previousOrganisationNames.contains($0) }
            let removedOrganisationNames = previous.organisationsShownNames.filter { !editedOrganisationNames.contains($0) }
            if !addedOrganisationNames.isEmpty { addTags[.organisationInImageName] = addedOrganisationNames }
            if !removedOrganisationNames.isEmpty { removeTags[.organisationInImageName] = removedOrganisationNames }
        }

        if explicitMutations[.organisationShownCode] == nil {
            let previousOrganisationCodes = Set(previous.organisationsShownCodes)
            let editedOrganisationCodes = Set(edited.organisationsShownCodes)
            let addedOrganisationCodes = edited.organisationsShownCodes.filter { !previousOrganisationCodes.contains($0) }
            let removedOrganisationCodes = previous.organisationsShownCodes.filter { !editedOrganisationCodes.contains($0) }
            if !addedOrganisationCodes.isEmpty { addTags[.organisationInImageCode] = addedOrganisationCodes }
            if !removedOrganisationCodes.isEmpty { removeTags[.organisationInImageCode] = removedOrganisationCodes }
        }

        if explicitMutations[.sceneCode] == nil {
            let previousSceneCodes = Set(previous.sceneCodes)
            let editedSceneCodes = Set(edited.sceneCodes)
            let addedSceneCodes = edited.sceneCodes.filter { !previousSceneCodes.contains($0) }
            let removedSceneCodes = previous.sceneCodes.filter { !editedSceneCodes.contains($0) }
            if !addedSceneCodes.isEmpty { addTags[.scene] = addedSceneCodes }
            if !removedSceneCodes.isEmpty { removeTags[.scene] = removedSceneCodes }
        }


        if explicitMutations[.subjectCode] == nil {
            let previousCodes = Set(previous.subjectCodes)
            let editedCodes = Set(edited.subjectCodes)
            let addedCodes = edited.subjectCodes.filter { !previousCodes.contains($0) }
            let removedCodes = previous.subjectCodes.filter { !editedCodes.contains($0) }
            if !addedCodes.isEmpty { addTags[.subjectCode] = addedCodes }
            if !removedCodes.isEmpty { removeTags[.subjectCode] = removedCodes }
        }

        return (addTags, removeTags)
    }

    /// PM-style writeToFile invariant: an `.xmp` already on disk must mirror the file,
    /// or its stale descriptive values shadow the freshly embedded ones on read and
    /// export (the sidecar is the record once it has descriptive content). Batch writes
    /// don't track per-file post-state, so read it back from each file that has a
    /// sidecar. The sidecar's Camera Raw settings and orientation are preserved —
    /// develop edits (RAW especially) live in the sidecar, not the embedded read-back.
    private func mirrorEmbeddedStateToExistingSidecars(for urls: [URL]) async {
        let sidecarURLs = urls.filter { xmpSidecarService.sidecarExists(for: $0) }
        guard !sidecarURLs.isEmpty else { return }
        guard let postWrite = try? await readService.readBatchFullMetadata(urls: sidecarURLs) else {
            logger.error("Sidecar mirror: post-write metadata read-back failed; existing .xmp sidecars left untouched")
            return
        }
        for url in sidecarURLs {
            guard var record = postWrite[url] else { continue }
            if let existingSidecar = xmpSidecarService.loadSidecar(for: url) {
                if let crs = existingSidecar.cameraRaw, !crs.isEmpty {
                    record.cameraRaw = crs
                }
                if record.exifOrientation == nil {
                    record.exifOrientation = existingSidecar.exifOrientation
                }
            }
            do {
                try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                    metadata: record,
                    for: url
                )
            } catch {
                logger.error("Sidecar mirror failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func writeXMPSidecar() async {
        guard !selectedURLs.isEmpty else { return }

        if selectedCount == 1, let imageURL = selectedURLs.first {
            do {
                try await xmpSidecarService.saveSidecarSerialized(
                    metadata: editingMetadata,
                    for: imageURL
                )
                if selectedCount == 1, selectedURLs.first == imageURL {
                    xmpMetadata = editingMetadata
                }
            } catch {
                saveError = "Failed to write XMP sidecar: \(error.localizedDescription)"
            }
            return
        }

        let batchMeta = editingMetadata
        let prevCommon = previousEditingMetadata
        for imageURL in selectedURLs {
            var existing = xmpSidecarService.loadSidecar(for: imageURL)
                ?? batchMetadataByURL[imageURL]
                ?? IPTCMetadata()
            applyBatchEdits(batchMeta, to: &existing, previousCommon: prevCommon)
            do {
                try await xmpSidecarService.saveSidecarSerialized(
                    metadata: existing,
                    for: imageURL
                )
                batchMetadataByURL[imageURL] = existing
            } catch {
                saveError = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func writeXMPSidecarAndPreserveHistory(
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard let folderURL = currentFolderURL else {
            writeTask?.cancel()
            writeTask = Task {
                await writeXMPSidecar()
                if let saveError {
                    onComplete(.failed(message: saveError))
                } else {
                    onComplete(.succeeded)
                }
            }
            return
        }

        if selectedCount > 1 {
            writeTask?.cancel()
            writeTask = Task {
                await writeXMPSidecar()
                await saveBatchSidecars(folderURL: folderURL, pendingChanges: false)
                hasChanges = false
                if let saveError {
                    onComplete(.failed(message: saveError))
                } else {
                    onComplete(.succeeded)
                }
            }
            return
        }

        guard let imageURL = selectedURLs.first else {
            onComplete(.succeeded)
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let existingHistory = sidecarHistory

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            let now = Date()
            let history = buildHistory(
                previous: previous,
                edited: edited,
                timestamp: now,
                existing: existingHistory
            )
            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: now,
                pendingChanges: false,
                metadata: edited,
                imageMetadataSnapshot: edited,
                history: history
            )
            let result = await sidecarPersistenceService.persistHistoryAndMirrorXMP(
                MetadataSidecarPersistenceRequest(
                    sidecar: sidecar,
                    imageURL: imageURL,
                    folderURL: folderURL
                )
            )

            let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
            if isStillSelected, let installed = result.installedSidecar {
                // JSON may already be durable when cancellation or an XMP failure occurs. Advance
                // the history baseline so Retry mirrors the existing record instead of appending
                // duplicate deltas, while leaving `hasChanges` set until both artifacts commit.
                self.sidecarHistory = installed.history
                self.previousEditingMetadata = installed.metadata
            }

            if result.completed {
                if isStillSelected, let installed = result.installedSidecar {
                    self.sidecarHistory = installed.history
                    self.previousEditingMetadata = installed.metadata
                    self.xmpMetadata = installed.metadata
                    if self.metadataReferenceSource == .xmp {
                        let reference = self.referenceMetadata(
                            for: .xmp,
                            embedded: self.embeddedMetadata,
                            xmp: edited,
                            imageURL: imageURL
                        ) ?? edited
                        self.metadata = reference
                        self.originalImageMetadata = reference
                    }
                    self.hasChanges = false
                }
                onComplete(.succeeded)
            } else if let failure = result.failure {
                let artifact = failure.stage == .metadataSidecar ? "metadata history" : "XMP sidecar"
                let message = "Failed to save \(artifact): \(failure.message)"
                self.saveError = message
                onComplete(.failed(message: message))
            } else if result.wasCancelled, result.installedSidecar != nil {
                let message = "Save cancelled after metadata history was written; the XMP sidecar was not changed."
                self.saveError = message
                onComplete(.cancelled(message: message))
            } else if result.wasCancelled {
                let message = "Save cancelled before metadata history was written."
                self.saveError = message
                onComplete(.cancelled(message: message))
            } else {
                let message = "The metadata history and XMP sidecar save did not complete."
                self.saveError = message
                onComplete(.failed(message: message))
            }

            self.isSaving = false
        }
    }

    /// True when the develop (Camera Raw) state differs between two snapshots,
    /// ignoring render-time-only fields the edit pipeline stamps on local copies
    /// (as-shot white balance, HDR-headroom flag). Gates whether a metadata save
    /// touches the file's crs block at all: a caption-only save on an ACR-edited
    /// file must not rewrite (and with replaceCameraRawBlock, wipe) Adobe's
    /// develop settings.
    nonisolated static func developSettingsChanged(_ a: CameraRawSettings?, _ b: CameraRawSettings?) -> Bool {
        func normalized(_ s: CameraRawSettings?) -> CameraRawSettings? {
            guard var s else { return nil }
            s.asShotNeutralTemperature = nil
            s.asShotNeutralTint = nil
            s.sourceHasHDRHeadroom = nil
            return s
        }
        return normalized(a) != normalized(b)
    }

    private func overwriteFields(
        from metadata: IPTCMetadata,
        includeCameraRaw: Bool = true,
        imageAspect: () -> Double? = { nil }
    ) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        fields[.headline] = metadata.title ?? ""
        fields[.description] = metadata.description ?? ""
        fields[.extendedDescription] = metadata.extendedDescription ?? ""
        fields[.subject] = metadata.keywords.uniqued().joined(separator: ", ")
        fields[.personInImage] = metadata.personShown.uniqued().joined(separator: ", ")
        fields[.organisationInImageName] = metadata.organisationsShownNames.uniqued().joined(separator: ", ")
        fields[.organisationInImageCode] = metadata.organisationsShownCodes.uniqued().joined(separator: ", ")
        fields[.scene] = metadata.sceneCodes.uniqued().joined(separator: ", ")
        fields[.subjectCode] = metadata.subjectCodes.uniqued().joined(separator: ", ")
        fields[.mediaTopic] = metadata.mediaTopics.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.genre] = metadata.genres.map(\.termIdentifier).uniqued().joined(separator: ", ")
        fields[.digitalSourceType] = metadata.digitalSourceType?.newsCodeURI ?? ""
        fields[.urgency] = metadata.urgency.map(String.init) ?? ""
        fields[.creator] = metadata.creatorTransportValue ?? ""
        fields[.creatorJobTitle] = metadata.creatorJobTitle ?? ""
        fields[.descriptionWriter] = metadata.descriptionWriter ?? ""
        fields[.credit] = metadata.credit ?? ""
        fields[.rights] = metadata.copyright ?? ""
        fields[.rightsUsageTerms] = metadata.rightsUsageTerms ?? ""
        fields[.webStatementOfRights] = metadata.webStatementOfRights ?? ""
        fields[.digitalImageGUID] = metadata.digitalImageGUID ?? ""
        fields[.imageSupplierImageID] = metadata.imageSupplierImageID ?? ""
        fields[.transmissionReference] = metadata.jobId ?? ""
        fields[.dateCreated] = metadata.dateCreated ?? ""
        fields[.city] = metadata.city ?? ""
        fields[.sublocation] = metadata.sublocation ?? ""
        fields[.provinceState] = metadata.provinceState ?? ""
        fields[.country] = metadata.country ?? ""
        fields[.countryCode] = metadata.countryCode ?? ""
        fields[.event] = metadata.event ?? ""
        fields[.instructions] = metadata.instructions ?? ""
        fields[.source] = metadata.source ?? ""

        if let lat = metadata.latitude, let lon = metadata.longitude {
            fields[.gpsLatitude] = String(abs(lat))
            fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
            fields[.gpsLongitude] = String(abs(lon))
            fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
        } else {
            fields[.gpsLatitude] = ""
            fields[.gpsLatitudeRef] = ""
            fields[.gpsLongitude] = ""
            fields[.gpsLongitudeRef] = ""
        }

        // Caption-only saves must not touch the crs block at all — rewriting it
        // (even merge-style) churns Adobe's develop settings for no reason.
        if includeCameraRaw {
            appendCameraRawFields(from: metadata, into: &fields, imageAspect: imageAspect)
        }
        return fields
    }

    private func syncCameraRawToXMPSidecar(for imageURL: URL, metadata: IPTCMetadata) async {
        guard metadata.cameraRaw != nil || originalImageMetadata?.cameraRaw != nil else { return }
        try? await xmpSidecarService.saveCameraRawOnlySerialized(
            metadata.cameraRaw,
            orientation: metadata.exifOrientation,
            for: imageURL
        )
    }

    private func appendCameraRawFields(
        from metadata: IPTCMetadata,
        into fields: inout [MetadataFieldKey: String],
        imageAspect: () -> Double? = { nil }
    ) {
        // When cameraRaw is nil (edits fully reset), check if the original image had CRS
        // fields and clear them. Writing "" removes the field.
        guard let cameraRaw = metadata.cameraRaw else {
            if originalImageMetadata?.cameraRaw != nil {
                clearAllCameraRawFields(into: &fields)
            }
            return
        }

        // Canonical serialization of the simple crs fields (signed ints, +exposure,
        // 6-decimal ACR-encoded crop). Shared with the export engine via
        // CameraRawSettings.developWriteFields to keep the two write paths from drifting.
        fields.merge(cameraRaw.developWriteFields(imageAspect: imageAspect)) { _, new in new }
    }

    private func clearAllCameraRawFields(into fields: inout [MetadataFieldKey: String]) {
        fields[.crsVersion] = ""
        fields[.crsProcessVersion] = ""
        fields[.crsWhiteBalance] = ""
        fields[.crsTemperature] = ""
        fields[.crsTint] = ""
        fields[.crsIncrementalTemperature] = ""
        fields[.crsIncrementalTint] = ""
        fields[.crsExposure2012] = ""
        fields[.crsContrast2012] = ""
        fields[.crsHighlights2012] = ""
        fields[.crsShadows2012] = ""
        fields[.crsWhites2012] = ""
        fields[.crsBlacks2012] = ""
        fields[.crsSaturation] = ""
        fields[.crsVibrance] = ""
        fields[.aaphotoGlobalDensity] = ""
        fields[.crsSharpness] = ""
        fields[.crsClarity2012] = ""
        fields[.crsDehaze] = ""
        fields[.crsHasSettings] = "False"
        fields[.crsCropTop] = ""
        fields[.crsCropLeft] = ""
        fields[.crsCropBottom] = ""
        fields[.crsCropRight] = ""
        fields[.crsCropAngle] = ""
        fields[.crsHasCrop] = ""
        fields[.crsCropConstrainToWarp] = ""
        fields[.crsCropConstrainToUnitSquare] = ""
        fields[.crsHDREditMode] = ""
        fields[.crsHDRMaxValue] = ""
        fields[.crsSDRBrightness] = ""
        fields[.crsSDRContrast] = ""
        fields[.crsSDRClarity] = ""
        fields[.crsSDRHighlights] = ""
        fields[.crsSDRShadows] = ""
        fields[.crsSDRWhites] = ""
        fields[.crsSDRBlend] = ""
        fields[.crsToneCurveName2012] = ""
    }

    private func writeMetadataAndPreserveHistory(
        alsoWriteXMPSidecar: Bool = false,
        onComplete: @escaping (MetadataCommitResult) -> Void
    ) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            if alsoWriteXMPSidecar {
                Task { await writeXMPSidecar() }
            }
            onComplete(.succeeded)
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata
        let existingHistory = sidecarHistory

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            let commitResult: MetadataCommitResult
            do {
                // Touch the crs block only when develop settings actually changed:
                // a caption-only save on an ACR-edited file must not rewrite (and,
                // with replaceCameraRawBlock, wipe) Adobe's develop settings.
                let developChanged = Self.developSettingsChanged(
                    edited.cameraRaw, self.originalImageMetadata?.cameraRaw
                )
                let fields = overwriteFields(
                    from: edited,
                    includeCameraRaw: developChanged,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
                let structuredData = developChanged
                    ? StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments,
                        watermarkLayers: edited.cameraRaw?.watermarkLayers,
                        hslAdjustments: edited.cameraRaw?.hslAdjustments,
                        layerOrder: edited.cameraRaw?.layerOrder,
                        anonymizer: edited.cameraRaw?.anonymizer,
                        unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
                        editorial: EditorialStructuredWriteData(metadata: edited),
                        replaceCameraRawBlock: true
                    )
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited))
                try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                var sidecarMirrored = false
                if alsoWriteXMPSidecar || xmpSidecarService.sidecarExists(for: imageURL) {
                    // Dual-write keeps a matching full .xmp record. In PM-style
                    // writeToFile mode the file is the record, but any .xmp already on
                    // disk must mirror it — otherwise its stale descriptive values (or a
                    // develop-sync mtime bump) shadow the file on read and export.
                    try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                        metadata: edited,
                        for: imageURL
                    )
                    if developChanged {
                        try await xmpSidecarService.saveCameraRawOnlySerialized(
                            edited.cameraRaw,
                            orientation: edited.exifOrientation,
                            for: imageURL
                        )
                    }
                    sidecarMirrored = true
                } else {
                    // No sidecar yet: keep develop settings ACR-readable without
                    // creating a descriptive IPTC record next to an embedded-mode file.
                    await self.syncCameraRawToXMPSidecar(for: imageURL, metadata: edited)
                }

                let now = Date()
                let history = buildHistory(
                    previous: previous ?? IPTCMetadata(),
                    edited: edited,
                    timestamp: now,
                    existing: existingHistory
                )
                let sidecar = MetadataSidecar(
                    sourceFile: imageURL.lastPathComponent,
                    lastModified: now,
                    pendingChanges: false,
                    metadata: edited,
                    imageMetadataSnapshot: edited,
                    history: history
                )
                let installed = try await sidecarService.saveSidecarMergingHistorySerialized(
                    sidecar,
                    for: imageURL,
                    in: folderURL
                )

                let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
                if isStillSelected {
                    self.sidecarHistory = installed.history
                    self.previousEditingMetadata = installed.metadata
                    self.metadata = edited
                    self.originalImageMetadata = edited
                    self.embeddedMetadata = edited
                    if sidecarMirrored {
                        self.xmpMetadata = edited
                    }
                    self.hasChanges = false
                }
                commitResult = .succeeded
            } catch {
                let message = error.localizedDescription
                self.saveError = message
                commitResult = error is CancellationError
                    ? .cancelled(message: message)
                    : .failed(message: message)
            }
            self.isSaving = false
            onComplete(commitResult)
        }
    }

    private func removeSidecars(for urls: Set<URL>, in folderURL: URL) {
        for url in urls {
            try? sidecarService.deleteSidecar(for: url, in: folderURL)
        }
    }

    func applyTemplateFields(_ template: [String: String], append: Bool = false) {
        for (key, value) in template {
            switch key {
            case "title":
                editingMetadata.title = append ? appendString(editingMetadata.title, value) : value
            case "description":
                editingMetadata.description = append ? appendString(editingMetadata.description, value) : value
            case "extendedDescription":
                editingMetadata.extendedDescription = append ? appendString(editingMetadata.extendedDescription, value) : value
            case "keywords":
                let parsed = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // Tokens containing a variable ({...}) can't be validated against
                // the approved list until they're resolved, so pass them through
                // verbatim — validation happens after variable processing (see
                // resolveListField). Validate only literal keywords here.
                let variableTokens = parsed.filter { $0.contains("{") }
                let literalTokens = parsed.filter { !$0.contains("{") }
                let validated = ApprovedListService.shared.validateBulk(literalTokens, in: .keywords, source: .template)
                let toAdd = variableTokens + validated.accepted
                if append {
                    let existing = Set(editingMetadata.keywords)
                    editingMetadata.keywords += toAdd.filter { !existing.contains($0) }
                } else {
                    var seen = Set<String>()
                    editingMetadata.keywords = toAdd.filter { seen.insert($0).inserted }
                }
                if !validated.rejected.isEmpty {
                    let acceptedCount = validated.accepted.count
                    let rejCount = validated.rejected.count
                    let acceptedWord = acceptedCount == 1 ? "keyword" : "keywords"
                    notice = MetadataPanelNotice(
                        title: "Template: \(acceptedCount) \(acceptedWord) added, \(rejCount) rejected",
                        detail: validated.rejected,
                        severity: .warning
                    )
                }
            case "personShown":
                let newPersons = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if append {
                    let existing = Set(editingMetadata.personShown)
                    editingMetadata.personShown += newPersons.filter { !existing.contains($0) }
                } else {
                    editingMetadata.personShown = newPersons
                }
            case "organisationShownName":
                let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if append {
                    let existing = Set(editingMetadata.organisationsShownNames)
                    editingMetadata.organisationsShownNames += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.organisationsShownNames = values
                }
            case "organisationShownCode":
                let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if append {
                    let existing = Set(editingMetadata.organisationsShownCodes)
                    editingMetadata.organisationsShownCodes += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.organisationsShownCodes = values
                }
            case "sceneCode":
                let values = IPTCSceneCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
                if append {
                    let existing = Set(editingMetadata.sceneCodes)
                    editingMetadata.sceneCodes += values.filter { !existing.contains($0) }
                } else {
                    editingMetadata.sceneCodes = values
                }
            case "subjectCode":
                let values = IPTCSubjectCode.normalizedValues(
                    value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                )
                editingMetadata.subjectCodes = append
                    ? IPTCSubjectCode.normalizedValues(editingMetadata.subjectCodes + values)
                    : values
            case "mediaTopic":
                let values = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.mediaTopic(metadataValue: $0) }
                )
                editingMetadata.mediaTopics = append
                    ? IPTCControlledVocabularyTerm.normalizedValues(editingMetadata.mediaTopics + values)
                    : values
            case "genre":
                let values = IPTCControlledVocabularyTerm.terms(
                    fromTemplateValue: value,
                    fallback: { IPTCControlledVocabularyTerm.genre(metadataValue: $0) }
                )
                editingMetadata.genres = append
                    ? IPTCControlledVocabularyTerm.normalizedValues(editingMetadata.genres + values)
                    : values
            case "digitalSourceType":
                editingMetadata.digitalSourceType = DigitalSourceType(metadataValue: value)
            case "urgency":
                editingMetadata.urgency = Int(value)
            case "creator":
                let values = IPTCMetadata.creators(fromTransportValue: value)
                editingMetadata.creators = append
                    ? IPTCMetadata.normalizedCreators(editingMetadata.creators + values)
                    : values
            case "creatorJobTitle":
                editingMetadata.creatorJobTitle = append ? appendString(editingMetadata.creatorJobTitle, value) : value
            case "descriptionWriter":
                editingMetadata.descriptionWriter = append ? appendString(editingMetadata.descriptionWriter, value) : value
            case "credit":
                editingMetadata.credit = append ? appendString(editingMetadata.credit, value) : value
            case "copyright":
                editingMetadata.copyright = append ? appendString(editingMetadata.copyright, value) : value
            case "rightsUsageTerms":
                editingMetadata.rightsUsageTerms = append ? appendString(editingMetadata.rightsUsageTerms, value) : value
            case "webStatementOfRights":
                editingMetadata.webStatementOfRights = append ? appendString(editingMetadata.webStatementOfRights, value) : value
            case "digitalImageGUID":
                // Identifiers are atomic. Template append mode still replaces this field rather
                // than concatenating two identifiers into an invalid third value.
                editingMetadata.digitalImageGUID = value
            case "imageSupplierImageID":
                editingMetadata.imageSupplierImageID = value
            case "imageSupplier":
                guard let values = EditorialImageSupplier.values(fromCanonicalJSONString: value) else {
                    continue
                }
                editingMetadata.imageSuppliers = append
                    ? EditorialImageSupplier.normalizedValues(editingMetadata.imageSuppliers + values)
                    : values
            case "jobId":
                editingMetadata.jobId = append ? appendString(editingMetadata.jobId, value) : value
            case "dateCreated":
                if MetadataTemplatePlaceholderDetector.containsPlaceholder(value)
                    || (try? EditorialDateCreated(parsing: value)) != nil {
                    editingMetadata.dateCreated = value
                }
            case "city":
                editingMetadata.city = append ? appendString(editingMetadata.city, value) : value
            case "sublocation":
                editingMetadata.sublocation = append ? appendString(editingMetadata.sublocation, value) : value
            case "provinceState":
                editingMetadata.provinceState = append ? appendString(editingMetadata.provinceState, value) : value
            case "country":
                editingMetadata.country = append ? appendString(editingMetadata.country, value) : value
            case "countryCode":
                editingMetadata.countryCode = ISO3166Country.normalizedAlpha3(value)
            case "event":
                editingMetadata.event = append ? appendString(editingMetadata.event, value) : value
            case "instructions":
                editingMetadata.instructions = append ? appendString(editingMetadata.instructions, value) : value
            case "source":
                editingMetadata.source = append ? appendString(editingMetadata.source, value) : value
            default: break
            }
        }
        hasChanges = true
    }

    private func appendString(_ existing: String?, _ new: String) -> String {
        guard let existing, !existing.isEmpty else { return new }
        guard !new.isEmpty else { return existing }
        return existing + " " + new
    }

    /// Applies template fields to the editing buffer and then immediately resolves
    /// metadata variables for exactly the supplied images. Used by templates that
    /// have "process instantly" enabled.
    ///
    /// `images` is captured by the caller at apply time so a selection change during
    /// the async resolution doesn't redirect the writes to other images.
    ///
    /// Per-image variables ({filename}, {seq}, …) can only be resolved against each
    /// image individually. For a multi-image selection the shared editing buffer
    /// can't express that, so the just-applied template literals are flushed to each
    /// image's sidecar first, then the batch resolver reads them back and resolves
    /// per image. For a single displayed image the batch resolver works directly off
    /// the editing buffer, so no pre-save is needed there.
    func applyTemplateFieldsAndProcessVariables(_ template: [String: String], to images: [ImageFile], append: Bool = false) {
        applyTemplateFields(template, append: append)
        guard !images.isEmpty else { return }
        if selectedCount > 1 {
            saveToSidecar()
        }
        processVariablesForImages(images)
    }

    private static let variablePattern = /(?:\{(date|date:[^}]+|dateCreated|dateCreated:[^}]+|dateCaptured|dateCaptured:[^}]+|filename|initials|persons|keywords|number|gps|gps:city|gps:country|latitude|longitude|field:[^}]+|seq|seq:\d+)\}|\(number\))/

    /// Checks whether any text field, keyword, or person in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        let fields: [String?] = [
            editingMetadata.title,
            editingMetadata.description,
            editingMetadata.extendedDescription,
            editingMetadata.creatorJobTitle,
            editingMetadata.descriptionWriter,
            editingMetadata.credit,
            editingMetadata.copyright,
            editingMetadata.rightsUsageTerms,
            editingMetadata.webStatementOfRights,
            editingMetadata.digitalImageGUID,
            editingMetadata.imageSupplierImageID,
            editingMetadata.jobId,
            editingMetadata.dateCreated,
            editingMetadata.city,
            editingMetadata.country,
            editingMetadata.event,
        ]
        if fields.contains(where: { field in
            guard let field else { return false }
            return field.contains(Self.variablePattern)
        }) {
            return true
        }
        let listValues = editingMetadata.keywords + editingMetadata.personShown
            + editingMetadata.creators
            + editingMetadata.organisationsShownNames + editingMetadata.organisationsShownCodes
            + editingMetadata.sceneCodes
            + editingMetadata.subjectCodes
            + editingMetadata.mediaTopics.map(\.termIdentifier)
            + editingMetadata.genres.map(\.termIdentifier)
        return listValues.contains { $0.contains(Self.variablePattern) }
    }

    /// Resolves all variable placeholders in editingMetadata text fields in-place.
    func processVariables(filename: String = "", sequenceIndex: Int = 1) {
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            await processVariablesInEditingBuffer(filename: filename, sequenceIndex: sequenceIndex)
        }
    }

    private func sportsCaptionNumber(for imageURL: URL?) async -> String {
        guard let imageURL else { return "" }
        let folderURL = imageURL.deletingLastPathComponent()
        let rosterResult = await MatchRosterService.shared.load(
            for: folderURL,
            requestID: UUID()
        )
        guard !Task.isCancelled,
              case .loaded(let rosterSnapshot) = rosterResult else { return "" }
        return SportsCaptionNumberResolver.value(
            for: imageURL,
            faceData: FaceDataStorageService().loadFaceData(for: folderURL),
            match: rosterSnapshot.roster
        )
    }

    private func processVariablesInEditingBuffer(filename: String, sequenceIndex: Int) async {
        let interpolator = PresetVariableInterpolator()
        let initials = UserDefaults.standard.string(forKey: UserDefaultsKeys.creatorInitials) ?? ""
        editingMetadata = await interpolator.resolvingGPSPlaceVariables(in: editingMetadata)
        editingMetadata = interpolator.resolvingSportsNumberVariables(
            in: editingMetadata,
            number: await sportsCaptionNumber(for: selectedURLs.first)
        )
        // Use a snapshot of current editing state for field references
        let snapshot = editingMetadata

        editingMetadata.title = resolveIfPresent(editingMetadata.title, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.description = resolveIfPresent(editingMetadata.description, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.extendedDescription = resolveIfPresent(editingMetadata.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.creators = IPTCMetadata.normalizedCreators(editingMetadata.creators.compactMap {
            resolveIfPresent($0, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        })
        editingMetadata.creatorJobTitle = resolveIfPresent(editingMetadata.creatorJobTitle, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.descriptionWriter = resolveIfPresent(editingMetadata.descriptionWriter, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.credit = resolveIfPresent(editingMetadata.credit, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.copyright = resolveIfPresent(editingMetadata.copyright, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.rightsUsageTerms = resolveIfPresent(editingMetadata.rightsUsageTerms, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.webStatementOfRights = resolveIfPresent(editingMetadata.webStatementOfRights, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.digitalImageGUID = resolveIfPresent(editingMetadata.digitalImageGUID, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.imageSupplierImageID = resolveIfPresent(editingMetadata.imageSupplierImageID, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.jobId = resolveIfPresent(editingMetadata.jobId, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.dateCreated = resolveIfPresent(editingMetadata.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.city = resolveIfPresent(editingMetadata.city, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.sublocation = resolveIfPresent(editingMetadata.sublocation, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.provinceState = resolveIfPresent(editingMetadata.provinceState, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.country = resolveIfPresent(editingMetadata.country, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.event = resolveIfPresent(editingMetadata.event, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.instructions = resolveIfPresent(editingMetadata.instructions, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.source = resolveIfPresent(editingMetadata.source, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)

        editingMetadata.keywords = resolveListField(editingMetadata.keywords, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials, validateField: .keywords)
        editingMetadata.personShown = resolveListField(editingMetadata.personShown, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.organisationsShownNames = resolveListField(editingMetadata.organisationsShownNames, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.organisationsShownCodes = resolveListField(editingMetadata.organisationsShownCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.sceneCodes = IPTCSceneCode.normalizedValues(resolveListField(editingMetadata.sceneCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials))
        editingMetadata.subjectCodes = IPTCSubjectCode.normalizedValues(resolveListField(editingMetadata.subjectCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials))

        // Add resolved Job ID to keywords if enabled (after all variables are resolved)
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.addJobIdToKeywords),
           let jobId = editingMetadata.jobId, !jobId.isEmpty,
           !editingMetadata.keywords.contains(jobId) {
            editingMetadata.keywords.append(jobId)
        }

        hasChanges = true
    }

    private func resolveIfPresent(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, sequenceIndex: Int = 1, initials: String = "") -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
        return resolved.isEmpty ? nil : resolved
    }

    private enum VariableWriteResult {
        case writtenToFile
        case writtenToXMPSidecar
        case savedToHistory
    }

    /// Write resolved variable metadata for a single image, respecting the user's write mode settings.
    private func writeResolvedVariables(
        resolved: IPTCMetadata,
        original: IPTCMetadata,
        embedded: IPTCMetadata,
        existingSidecar: MetadataSidecar?,
        image: ImageFile,
        url: URL
    ) async throws -> VariableWriteResult {
        let mode = MetadataWriteMode.current(forC2PA: image.hasC2PA, isRaw: SupportedImageFormats.isRaw(url: url))
        guard let folder = self.currentFolderURL else {
            throw NSError(domain: "MetadataViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "No folder URL"])
        }

        // Build changed-fields dictionary for file write paths
        var fields: [MetadataFieldKey: String] = [:]
        if resolved.title != original.title { fields[.headline] = resolved.title ?? "" }
        if resolved.description != original.description { fields[.description] = resolved.description ?? "" }
        if resolved.extendedDescription != original.extendedDescription {
            fields[.extendedDescription] = resolved.extendedDescription ?? ""
        }
        if resolved.creators != original.creators {
            fields[.creator] = resolved.creatorTransportValue ?? ""
        }
        if resolved.creatorJobTitle != original.creatorJobTitle { fields[.creatorJobTitle] = resolved.creatorJobTitle ?? "" }
        if resolved.descriptionWriter != original.descriptionWriter { fields[.descriptionWriter] = resolved.descriptionWriter ?? "" }
        if resolved.credit != original.credit { fields[.credit] = resolved.credit ?? "" }
        if resolved.copyright != original.copyright { fields[.rights] = resolved.copyright ?? "" }
        if resolved.rightsUsageTerms != original.rightsUsageTerms { fields[.rightsUsageTerms] = resolved.rightsUsageTerms ?? "" }
        if resolved.webStatementOfRights != original.webStatementOfRights { fields[.webStatementOfRights] = resolved.webStatementOfRights ?? "" }
        if resolved.digitalImageGUID != original.digitalImageGUID { fields[.digitalImageGUID] = resolved.digitalImageGUID ?? "" }
        if resolved.imageSupplierImageID != original.imageSupplierImageID { fields[.imageSupplierImageID] = resolved.imageSupplierImageID ?? "" }
        if resolved.jobId != original.jobId {
            fields[.transmissionReference] = resolved.jobId ?? ""
        }
        if resolved.dateCreated != original.dateCreated { fields[.dateCreated] = resolved.dateCreated ?? "" }
        if resolved.city != original.city { fields[.city] = resolved.city ?? "" }
        if resolved.sublocation != original.sublocation { fields[.sublocation] = resolved.sublocation ?? "" }
        if resolved.provinceState != original.provinceState { fields[.provinceState] = resolved.provinceState ?? "" }
        if resolved.country != original.country { fields[.country] = resolved.country ?? "" }
        if resolved.countryCode != original.countryCode { fields[.countryCode] = resolved.countryCode ?? "" }
        if resolved.event != original.event { fields[.event] = resolved.event ?? "" }
        if resolved.instructions != original.instructions { fields[.instructions] = resolved.instructions ?? "" }
        if resolved.source != original.source { fields[.source] = resolved.source ?? "" }
        if resolved.keywords != original.keywords {
            fields[.subject] = resolved.keywords.joined(separator: ", ")
        }
        if resolved.personShown != original.personShown {
            fields[.personInImage] = resolved.personShown.joined(separator: ", ")
        }
        if resolved.organisationsShownNames != original.organisationsShownNames {
            fields[.organisationInImageName] = resolved.organisationsShownNames.joined(separator: ", ")
        }
        if resolved.organisationsShownCodes != original.organisationsShownCodes {
            fields[.organisationInImageCode] = resolved.organisationsShownCodes.joined(separator: ", ")
        }
        if resolved.sceneCodes != original.sceneCodes {
            fields[.scene] = resolved.sceneCodes.joined(separator: ", ")
        }
        if resolved.subjectCodes != original.subjectCodes {
            fields[.subjectCode] = resolved.subjectCodes.joined(separator: ", ")
        }
        if resolved.mediaTopics != original.mediaTopics {
            fields[.mediaTopic] = resolved.mediaTopics.map(\.termIdentifier).joined(separator: ", ")
        }
        if resolved.genres != original.genres {
            fields[.genre] = resolved.genres.map(\.termIdentifier).joined(separator: ", ")
        }

        // Build JSON sidecar with history entry
        func buildSidecar(pendingChanges: Bool, historyNote: String) -> MetadataSidecar {
            let timestamp = Date()
            var sidecar = MetadataSidecar(
                sourceFile: url.lastPathComponent,
                pendingChanges: pendingChanges,
                metadata: resolved,
                imageMetadataSnapshot: embedded
            )
            sidecar.history = existingSidecar?.history ?? []
            // The serialized sidecar boundary replays new history entries onto the latest
            // on-disk record. Record the actual variable substitutions as field deltas; the
            // audit-only entry below deliberately carries no replayable metadata value.
            sidecar.history.append(contentsOf: MetadataHistoryEntry.changes(
                from: existingSidecar?.metadata ?? original,
                to: resolved,
                timestamp: timestamp
            ))
            sidecar.history.append(MetadataHistoryEntry(
                timestamp: timestamp,
                fieldName: "Variables processed",
                oldValue: nil,
                newValue: historyNote
            ))
            sidecar.history.trimToHistoryLimit()
            return sidecar
        }

        switch mode {
        case .historyOnly:
            let sidecar = buildSidecar(pendingChanges: true, historyNote: "Saved to sidecar (history only)")
            _ = try await sidecarService.saveSidecarMergingHistorySerialized(
                sidecar,
                for: url,
                in: folder
            )
            return .savedToHistory

        case .writeToXMPSidecar:
            try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                metadata: resolved,
                for: url
            )
            let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to XMP sidecar")
            _ = try await sidecarService.saveSidecarMergingHistorySerialized(
                sidecar,
                for: url,
                in: folder
            )
            return .writtenToXMPSidecar

        case .writeToFile, .writeToFileAndXMPSidecar:
            if !fields.isEmpty || resolved.hasDescriptiveContent {
                try await writeEngine.writeFields(
                    fields,
                    to: [url],
                    structuredData: StructuredWriteData(
                        editorial: EditorialStructuredWriteData(metadata: resolved)
                    )
                )
            }
            // Dual-write keeps a matching full .xmp record. In PM-style writeToFile
            // mode any existing .xmp must mirror the file (full resolved record), or
            // its stale values shadow the freshly embedded ones on read and export.
            if mode.writesXMPSidecar || xmpSidecarService.sidecarExists(for: url) {
                try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                    metadata: resolved,
                    for: url
                )
            }
            let note = mode.writesXMPSidecar ? "Written to image file + XMP sidecar" : "Written to image file"
            let sidecar = buildSidecar(pendingChanges: false, historyNote: note)
            _ = try await sidecarService.saveSidecarMergingHistorySerialized(
                sidecar,
                for: url,
                in: folder
            )
            return .writtenToFile
        }
    }

    /// Process variables for specific images: reads each image's metadata,
    /// resolves any variable placeholders, and writes back.
    func processVariablesForImages(_ images: [ImageFile]) {
        guard !images.isEmpty else { return }
        flushPendingBatchEditsForVariableProcessing(targetURLs: Set(images.map(\.url)))
        isProcessingFolder = true
        folderProcessProgress = "0/\(images.count)"
        saveError = nil
        variableProcessingStatus = nil
        batchProcessTask?.cancel()
        batchProcessTask = Task { await processVariablesBatch(images) }
    }

    /// Process variables for all images in a folder: reads each image's metadata,
    /// resolves any variable placeholders, and writes back.
    func processVariablesInFolder(images: [ImageFile]) {
        guard !images.isEmpty else { return }
        flushPendingBatchEditsForVariableProcessing(targetURLs: Set(images.map(\.url)))
        isProcessingFolder = true
        folderProcessProgress = "0/\(images.count)"
        saveError = nil
        variableProcessingStatus = nil
        batchProcessTask?.cancel()
        batchProcessTask = Task { await processVariablesBatch(images) }
    }

    /// Batch template edits live only in the shared editing buffer until saved.
    /// If variables are processed immediately after applying a template, flush
    /// those literals first so the async per-file resolver reads the same values
    /// the panel is showing.
    private func flushPendingBatchEditsForVariableProcessing(targetURLs: Set<URL>) {
        guard selectedCount > 1,
              hasChanges,
              hasVariables,
              !targetURLs.isDisjoint(with: Set(selectedURLs)) else { return }
        saveToSidecar()
    }

    /// Shared implementation for batch variable processing.
    /// Reads metadata in batches via readBatchFullMetadata (single batch read)
    /// instead of one readFullMetadata call per image.
    private func processVariablesBatch(_ images: [ImageFile]) async {
        let interpolator = PresetVariableInterpolator()
        let initials = UserDefaults.standard.string(forKey: UserDefaultsKeys.creatorInitials) ?? ""
        var processed = 0
        var writtenToFile = 0
        var writtenToXMP = 0
        var savedToHistory = 0
        var unchanged = 0
        var failed = 0
        var updatedURLs: Set<URL> = []

        // Identify which images need a disk metadata read (skip the currently-displayed image
        // with pending edits — that one is resolved in-memory)
        let currentlyDisplayedURL: URL? = (selectedCount == 1 && hasChanges) ? selectedURLs.first : nil
        let urlsToRead = images
            .filter { $0.url != currentlyDisplayedURL }
            .map(\.url)

        // Batch-read embedded metadata in chunks of 50 to avoid memory pressure
        var batchMetadata: [URL: IPTCMetadata] = [:]
        batchMetadata.reserveCapacity(urlsToRead.count)
        let chunkSize = 50
        for chunkStart in stride(from: 0, to: urlsToRead.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, urlsToRead.count)
            let chunk = Array(urlsToRead[chunkStart..<chunkEnd])
            do {
                let batch = try await readService.readBatchFullMetadata(urls: chunk)
                batchMetadata.merge(batch) { _, new in new }
            } catch {
                // Count all images in this chunk as failed
                failed += chunk.count
            }
            self.folderProcessProgress = "Reading metadata: \(min(chunkEnd, urlsToRead.count))/\(urlsToRead.count)"
        }

        var sequenceNumber = 1
        for image in images {
            let url = image.url
            let filename = image.filename

            // If this is the currently displayed image with pending edits,
            // resolve variables directly in the editing buffer
            if url == currentlyDisplayedURL {
                let before = self.editingMetadata
                await self.processVariablesInEditingBuffer(filename: filename, sequenceIndex: sequenceNumber)
                if self.editingMetadata != before {
                    // Honor the Simple/Professional/Custom write-mode toggle for the
                    // displayed image too, rather than forcing a history-only sidecar.
                    // commitEdits writes the full editing buffer (all fields, incl.
                    // digitalSourceType/GPS/cameraRaw) to the destination the mode
                    // dictates and reconciles editing state itself, so this URL is
                    // not added to updatedURLs / refreshed again below.
                    let mode = MetadataWriteMode.current(forC2PA: image.hasC2PA, isRaw: SupportedImageFormats.isRaw(url: url))
                    self.commitEdits(mode: mode)
                    switch mode {
                    case .writeToXMPSidecar:
                        writtenToXMP += 1
                    case .writeToFile, .writeToFileAndXMPSidecar:
                        writtenToFile += 1
                    case .historyOnly:
                        savedToHistory += 1
                    }
                } else {
                    unchanged += 1
                }
                processed += 1
                sequenceNumber += 1
                self.folderProcessProgress = "\(processed)/\(images.count)"
                continue
            }

            guard let embedded = batchMetadata[url] else {
                // Already counted as failed during batch read
                processed += 1
                sequenceNumber += 1
                self.folderProcessProgress = "\(processed)/\(images.count)"
                continue
            }

            do {
                // Load XMP sidecar if policy allows, matching the normal
                // metadata loading path that merges embedded + XMP
                let xmpMeta = self.loadXMPMetadata(for: url)
                let refSource = defaultReferenceSource(hasXmp: xmpMeta != nil)
                let baseMeta = referenceMetadata(for: refSource, embedded: embedded, xmp: xmpMeta, imageURL: url) ?? embedded

                // For images with sidecar pending changes (C2PA or historyOnly mode),
                // resolve variables from the sidecar metadata instead of embedded
                let existingSidecar: MetadataSidecar?
                if let folder = self.currentFolderURL {
                    existingSidecar = sidecarService.loadSidecar(for: url, in: folder)
                } else {
                    existingSidecar = nil
                }
                let unresolvedMeta: IPTCMetadata
                if let sidecar = existingSidecar, sidecar.pendingChanges {
                    unresolvedMeta = sidecar.metadata
                } else {
                    unresolvedMeta = baseMeta
                }
                let gpsResolved = await interpolator.resolvingGPSPlaceVariables(in: unresolvedMeta)
                let meta = interpolator.resolvingSportsNumberVariables(
                    in: gpsResolved,
                    number: await self.sportsCaptionNumber(for: url)
                )
                let snapshot = meta

                var changed = meta != unresolvedMeta
                var resolvedMeta = meta

                resolvedMeta.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.extendedDescription = resolveIfChanged(meta.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.creators = IPTCMetadata.normalizedCreators(meta.creators.map { value in
                    resolveIfChanged(value, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials) ?? ""
                })
                resolvedMeta.creatorJobTitle = resolveIfChanged(meta.creatorJobTitle, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.descriptionWriter = resolveIfChanged(meta.descriptionWriter, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.rightsUsageTerms = resolveIfChanged(meta.rightsUsageTerms, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.webStatementOfRights = resolveIfChanged(meta.webStatementOfRights, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.digitalImageGUID = resolveIfChanged(meta.digitalImageGUID, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.imageSupplierImageID = resolveIfChanged(meta.imageSupplierImageID, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.jobId = resolveIfChanged(meta.jobId, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.sublocation = resolveIfChanged(meta.sublocation, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.provinceState = resolveIfChanged(meta.provinceState, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.instructions = resolveIfChanged(meta.instructions, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.source = resolveIfChanged(meta.source, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)

                let newKeywords = resolveListField(meta.keywords, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials, validateField: .keywords)
                if newKeywords != meta.keywords { resolvedMeta.keywords = newKeywords; changed = true }
                let newPersons = resolveListField(meta.personShown, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials)
                if newPersons != meta.personShown { resolvedMeta.personShown = newPersons; changed = true }
                let newOrganisationNames = resolveListField(meta.organisationsShownNames, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials)
                if newOrganisationNames != meta.organisationsShownNames { resolvedMeta.organisationsShownNames = newOrganisationNames; changed = true }
                let newOrganisationCodes = resolveListField(meta.organisationsShownCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials)
                if newOrganisationCodes != meta.organisationsShownCodes { resolvedMeta.organisationsShownCodes = newOrganisationCodes; changed = true }
                let newSceneCodes = IPTCSceneCode.normalizedValues(resolveListField(meta.sceneCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials))
                if newSceneCodes != meta.sceneCodes { resolvedMeta.sceneCodes = newSceneCodes; changed = true }
                let newSubjectCodes = IPTCSubjectCode.normalizedValues(resolveListField(meta.subjectCodes, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials))
                if newSubjectCodes != meta.subjectCodes { resolvedMeta.subjectCodes = newSubjectCodes; changed = true }

                // Add resolved Job ID to keywords if enabled (after all variables are resolved)
                if UserDefaults.standard.bool(forKey: UserDefaultsKeys.addJobIdToKeywords),
                   let jobId = resolvedMeta.jobId, !jobId.isEmpty,
                   !resolvedMeta.keywords.contains(jobId) {
                    resolvedMeta.keywords.append(jobId)
                    changed = true
                }

                if changed {
                    let result = try await writeResolvedVariables(
                        resolved: resolvedMeta,
                        original: meta,
                        embedded: embedded,
                        existingSidecar: existingSidecar,
                        image: image,
                        url: url
                    )
                    switch result {
                    case .writtenToFile: writtenToFile += 1
                    case .writtenToXMPSidecar: writtenToXMP += 1
                    case .savedToHistory: savedToHistory += 1
                    }
                    updatedURLs.insert(url)
                } else {
                    unchanged += 1
                }
            } catch {
                failed += 1
            }

            processed += 1
            sequenceNumber += 1
            self.folderProcessProgress = "\(processed)/\(images.count)"
        }

        // Refresh the metadata panel if the currently displayed image was processed
        if !updatedURLs.isEmpty {
            await self.refreshMetadataAfterProcessing(updatedURLs: updatedURLs, processedImages: images)
        }

        self.isProcessingFolder = false
        self.folderProcessProgress = ""
        var statusParts: [String] = []
        if writtenToFile > 0 { statusParts.append("written to file: \(writtenToFile)") }
        if writtenToXMP > 0 { statusParts.append("written to XMP: \(writtenToXMP)") }
        if savedToHistory > 0 { statusParts.append("saved to sidecar: \(savedToHistory)") }
        if unchanged > 0 { statusParts.append("unchanged: \(unchanged)") }
        if failed > 0 { statusParts.append("failed: \(failed)") }
        if !statusParts.isEmpty {
            self.variableProcessingHadFailures = failed > 0
            self.variableProcessingStatus = "Variable processing completed: \(statusParts.joined(separator: ", "))."
        }
    }

    /// Re-read metadata from file for the currently displayed image after variable processing,
    /// so the UI reflects the resolved values instead of stale template strings.
    private func refreshMetadataAfterProcessing(updatedURLs: Set<URL>, processedImages: [ImageFile]) async {
        if selectedCount > 1 {
            let selectionSnapshot = Set(selectedURLs)
            guard !selectionSnapshot.isDisjoint(with: updatedURLs) else { return }
            let selectedProcessedImages = processedImages.filter { selectionSnapshot.contains($0.url) }
            guard Set(selectedProcessedImages.map(\.url)) == selectionSnapshot else { return }

            await loadBatchMetadata(
                for: selectedProcessedImages,
                selectionSnapshot: selectionSnapshot,
                isReload: false
            )
            selectedHavePendingSidecars = false
            refreshPendingSidecarsFlag(for: selectionSnapshot)
            hasChanges = false
            return
        }

        guard selectedCount == 1,
              let url = selectedURLs.first,
              updatedURLs.contains(url) else { return }

        do {
            let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: url)
            let xmpMeta = loadXMPMetadata(for: url)
            // Preserve the user's current reference source selection after processing
            let refSource: MetadataReferenceSource
            if metadataReferenceSource == .xmp, xmpMeta == nil {
                refSource = .embedded
            } else {
                refSource = metadataReferenceSource
            }
            let baseMeta = referenceMetadata(for: refSource, embedded: embedded, xmp: xmpMeta, imageURL: url) ?? embedded

            self.embeddedMetadata = embedded
            self.descriptionConflict = conflict
            self.xmpMetadata = xmpMeta
            self.metadataReferenceSource = refSource
            self.metadata = baseMeta
            self.originalImageMetadata = baseMeta

            // Load sidecar for images with pending changes (C2PA, historyOnly, etc.)
            if let folder = currentFolderURL,
               let sidecar = sidecarService.loadSidecar(for: url, in: folder),
               sidecar.pendingChanges {
                self.editingMetadata = sidecar.metadata
                self.previousEditingMetadata = sidecar.metadata
                self.hasChanges = true
            } else {
                self.editingMetadata = baseMeta
                self.previousEditingMetadata = baseMeta
                self.hasChanges = false
                // Only delete sidecar if it has no history entries worth preserving
                if let folder = currentFolderURL,
                   let sidecar = sidecarService.loadSidecar(for: url, in: folder),
                   sidecar.history.isEmpty {
                    try? sidecarService.deleteSidecar(for: url, in: folder)
                }
            }
        } catch {
            logger.warning("Failed to refresh metadata after processing: \(error.localizedDescription)")
        }
    }

    private func resolveIfChanged(_ value: String?, interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, changed: inout Bool, sequenceIndex: Int = 1, initials: String = "") -> String? {
        guard let value, !value.isEmpty else { return value }
        let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
        if resolved != value { changed = true }
        return resolved.isEmpty ? nil : resolved
    }

    /// Resolves variables in each entry of a keyword/person array.
    /// After interpolation, splits on commas so a single token can expand into
    /// multiple values, trims, drops empties, and dedups in order.
    /// When `validateField` is set, each resolved value is checked against the
    /// approved list — this is where variable tokens that bypassed validation at
    /// apply time finally get validated/canonicalised (rejected values dropped).
    private func resolveListField(_ values: [String], interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, sequenceIndex: Int, initials: String, validateField: ApprovedListField? = nil) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
            for part in resolved.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let finalValue: String
                if let field = validateField {
                    switch ApprovedListService.shared.validate(trimmed, in: field, source: .template) {
                    case .accept: finalValue = trimmed
                    case .acceptCanonical(let canonical): finalValue = canonical
                    case .reject: continue
                    }
                } else {
                    finalValue = trimmed
                }
                guard seen.insert(finalValue).inserted else { continue }
                result.append(finalValue)
            }
        }
        return result
    }

    // MARK: - Reverse Geocoding

    /// Reverse geocodes the current image's GPS coordinates to fill City and Country fields.
    func reverseGeocodeCurrentLocation() {
        guard let lat = editingMetadata.latitude,
              let lon = editingMetadata.longitude else {
            geocodingError = "No GPS coordinates available"
            return
        }

        isReverseGeocoding = true
        geocodingError = nil

        geocodingTask?.cancel()
        geocodingTask = Task { @MainActor in
            do {
                let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)
                if let city = result.city { editingMetadata.city = city }
                if let country = result.country { editingMetadata.country = country }
                hasChanges = true
            } catch {
                geocodingError = error.localizedDescription
            }
            isReverseGeocoding = false
        }
    }

    /// Reverse geocodes GPS coordinates for all selected images and writes City/Country directly to each file.
    func reverseGeocodeSelectedImages() {
        guard !selectedURLs.isEmpty else { return }

        isReverseGeocoding = true
        geocodingError = nil
        geocodingProgress = "0/\(selectedURLs.count)"

        geocodingTask?.cancel()
        geocodingTask = Task { @MainActor in
            var processed = 0
            var skipped = 0
            var geocoded = 0
            var failed = 0

            for url in selectedURLs {
                if Task.isCancelled { break }
                do {
                    let meta = try await readService.readFullMetadata(url: url)
                    guard let lat = meta.latitude, let lon = meta.longitude else {
                        skipped += 1
                        processed += 1
                        geocodingProgress = "\(processed)/\(selectedURLs.count)"
                        continue
                    }

                    let result = try await geocodingService.reverseGeocode(latitude: lat, longitude: lon)

                    var fields: [MetadataFieldKey: String] = [:]
                    if let city = result.city { fields[.city] = city }
                    if let country = result.country { fields[.country] = country }

                    if !fields.isEmpty {
                        if SupportedImageFormats.isRaw(url: url) {
                            var update = IPTCMetadata()
                            update.city = result.city
                            update.country = result.country
                            _ = try await descriptiveWriteBoundary.write(
                                metadata: update,
                                for: url,
                                requestedMode: .writeToFile,
                                semantics: .merge
                            )
                        } else {
                            try await writeEngine.writeFields(fields, to: [url])
                        }
                        geocoded += 1
                    }

                    // Throttle only the online geocoder; the offline lookup needs no rate limit.
                    if geocodingService.usesNetwork {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch {
                    failed += 1
                    logger.warning("Reverse geocoding failed for \(url.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }

                processed += 1
                geocodingProgress = "\(processed)/\(selectedURLs.count)"
            }

            var notes: [String] = []
            if geocoded > 0 { notes.append("\(geocoded) geocoded") }
            if skipped > 0 { notes.append("\(skipped) skipped (no GPS)") }
            if failed > 0 { notes.append("\(failed) failed") }
            geocodingError = notes.isEmpty ? nil : notes.joined(separator: ", ")

            isReverseGeocoding = false
            geocodingProgress = ""
        }
    }

    // MARK: - Sidecar Management

    func saveToSidecar() {
        guard let folderURL = currentFolderURL else { return }

        isSaving = true
        writeTask?.cancel()
        writeTask = Task {
            if selectedCount == 1, let imageURL = selectedURLs.first {
                // Single image mode - save with full history tracking
                await saveSingleImageSidecar(
                    imageURL: imageURL,
                    folderURL: folderURL,
                    pendingChanges: true,
                    snapshot: originalImageMetadata
                )
            } else if selectedCount > 1 {
                // Batch mode - merge edits into each image's sidecar
                await saveBatchSidecars(folderURL: folderURL)
            }
            isSaving = false
        }
    }

    /// Captures the current single-image Caption draft for serialized off-main persistence.
    ///
    /// The selection can change as soon as this returns: every value needed by the write is owned
    /// by the returned request. History state advances optimistically so rapid navigation back to
    /// the same image cannot manufacture duplicate edits; the queue retains and retries a failed
    /// request at the next durable barrier.
    func captureCaptionDraftPersistence() throws -> CaptionDraftPersistence? {
        guard let folderURL = currentFolderURL else {
            throw CaptionWorkspaceFlushError.sidecarUnavailable
        }
        guard hasChanges else { return nil }
        guard selectedCount == 1, let imageURL = selectedURLs.first else {
            throw CaptionWorkspaceFlushError.persistenceFailed(
                "Caption persistence requires exactly one selected photo."
            )
        }

        let now = Date()
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let history = buildHistory(
            previous: previous,
            edited: editingMetadata,
            timestamp: now,
            existing: sidecarHistory
        )
        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: now,
            pendingChanges: true,
            metadata: editingMetadata,
            imageMetadataSnapshot: originalImageMetadata,
            history: history
        )

        sidecarHistory = history
        previousEditingMetadata = editingMetadata
        saveError = nil
        return CaptionDraftPersistence(
            imageURL: imageURL,
            folderURL: folderURL,
            sidecar: sidecar
        )
    }

    private func saveSingleImageSidecar(
        imageURL: URL,
        folderURL: URL,
        pendingChanges: Bool,
        snapshot: IPTCMetadata?
    ) async {
        let now = Date()
        let prev = previousEditingMetadata ?? IPTCMetadata()
        let newHistory = buildHistory(
            previous: prev,
            edited: editingMetadata,
            timestamp: now,
            existing: sidecarHistory
        )

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: now,
            pendingChanges: pendingChanges,
            metadata: editingMetadata,
            imageMetadataSnapshot: snapshot,
            history: newHistory
        )

        do {
            let installed = try await sidecarService.saveSidecarMergingHistorySerialized(
                sidecar,
                for: imageURL,
                in: folderURL
            )
            if pendingChanges {
                // C2PA: save full metadata to XMP sidecar for render+sign overlay
                try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                    metadata: installed.metadata,
                    for: imageURL,
                    mergeWithExisting: true
                )
            } else {
                await syncCameraRawToXMPSidecar(for: imageURL, metadata: installed.metadata)
            }
            sidecarHistory = installed.history
            previousEditingMetadata = installed.metadata
            hasChanges = pendingChanges
        } catch {
            saveError = "Failed to save sidecar: \(error.localizedDescription)"
        }
    }

    private func buildHistory(
        previous: IPTCMetadata,
        edited: IPTCMetadata,
        timestamp: Date,
        existing: [MetadataHistoryEntry]
    ) -> [MetadataHistoryEntry] {
        var history = existing
        history.append(contentsOf: MetadataHistoryEntry.changes(
            from: previous,
            to: edited,
            timestamp: timestamp
        ))

        history.trimToHistoryLimit()
        return history
    }

    private func saveBatchSidecars(
        folderURL: URL,
        pendingChanges: Bool = true,
        targetURLs: [URL]? = nil,
        updateState: Bool = true
    ) async {
        let now = Date()
        let batchMeta = editingMetadata
        let prevCommon = previousEditingMetadata
        let urls = targetURLs ?? selectedURLs

        for imageURL in urls {
            // Load existing sidecar or create base metadata
            var existingMeta: IPTCMetadata
            var existingHistory: [MetadataHistoryEntry] = []
            var snapshot: IPTCMetadata? = nil

            if let existing = sidecarService.loadSidecar(for: imageURL, in: folderURL) {
                existingMeta = existing.metadata
                existingHistory = existing.history
                snapshot = existing.imageMetadataSnapshot
            } else {
                // Start from the resolved per-image record captured during batch loading. Starting
                // from an empty record loses values that are partial across the selection.
                existingMeta = batchMetadataByURL[imageURL] ?? IPTCMetadata()
                snapshot = batchMetadataByURL[imageURL]
            }

            let previousMeta = existingMeta
            applyBatchEdits(batchMeta, to: &existingMeta, previousCommon: prevCommon)
            let history = buildHistory(
                previous: previousMeta,
                edited: existingMeta,
                timestamp: now,
                existing: existingHistory
            )

            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: now,
                pendingChanges: pendingChanges,
                metadata: existingMeta,
                imageMetadataSnapshot: pendingChanges ? snapshot : existingMeta,
                history: history
            )

            do {
                let installed = try await sidecarService.saveSidecarMergingHistorySerialized(
                    sidecar,
                    for: imageURL,
                    in: folderURL
                )
                batchMetadataByURL[imageURL] = installed.metadata
                if pendingChanges {
                    // C2PA: save full metadata to XMP sidecar for render+sign overlay.
                    // `existingMeta` is JSON-sourced (no crs) — preserve any develop
                    // edits already in the .xmp so a batch rating/keyword edit on a
                    // C2PA RAW doesn't wipe them.
                    try await xmpSidecarService.saveSidecarPreservingDevelopSettingsSerialized(
                        metadata: installed.metadata,
                        for: imageURL,
                        mergeWithExisting: true
                    )
                }
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }

        if updateState {
            hasChanges = pendingChanges
            if !pendingChanges {
                selectedHavePendingSidecars = false
            }
        }
    }

    private func applyBatchEdits(
        _ batchMeta: IPTCMetadata,
        to metadata: inout IPTCMetadata,
        previousCommon: IPTCMetadata? = nil
    ) {
        // Explicit intent wins over every legacy inference path below. These operations were
        // validated when recorded, so a failure here can only mean an internal contract drift;
        // fail closed by leaving the per-image record unchanged.
        if !batchFieldMutations.isEmpty || batchLocationsShownMutation != .untouched {
            guard let explicitlyMutated = try? Self.applyingBatchListMutations(
                batchFieldMutations,
                locationsShown: batchLocationsShownMutation,
                to: metadata
            ) else { return }
            metadata = explicitlyMutated
        }

        if let title = batchMeta.title, !title.isEmpty {
            metadata.title = title
        }
        if let desc = batchMeta.description, !desc.isEmpty {
            metadata.description = desc
        }
        if let extDesc = batchMeta.extendedDescription, !extDesc.isEmpty {
            metadata.extendedDescription = extDesc
        }

        // Keywords — add vs overwrite
        if batchFieldMutations[.keywords] == nil {
            if multiSelectMode(for: "keywords") == .add, let prev = previousCommon {
                let previous = Set(Self.normalizedRepeatableValues(prev.keywords, field: .keywords))
                let edited = Self.normalizedRepeatableValues(batchMeta.keywords, field: .keywords)
                let editedSet = Set(edited)
                let added = edited.filter { !previous.contains($0) }
                let removed = previous.subtracting(editedSet)
                if !added.isEmpty || !removed.isEmpty {
                    metadata.keywords = metadata.keywords.filter { !removed.contains($0) }
                    metadata.keywords = Self.normalizedRepeatableValues(
                        metadata.keywords + added,
                        field: .keywords
                    )
                }
            } else if !batchMeta.keywords.isEmpty {
                metadata.keywords = Self.normalizedRepeatableValues(batchMeta.keywords, field: .keywords)
            }
        }

        // Person Shown — add vs overwrite
        if batchFieldMutations[.personShown] == nil {
            if multiSelectMode(for: "personShown") == .add, let prev = previousCommon {
                let previous = Set(Self.normalizedRepeatableValues(prev.personShown, field: .personShown))
                let edited = Self.normalizedRepeatableValues(batchMeta.personShown, field: .personShown)
                let editedSet = Set(edited)
                let added = edited.filter { !previous.contains($0) }
                let removed = previous.subtracting(editedSet)
                if !added.isEmpty || !removed.isEmpty {
                    metadata.personShown = metadata.personShown.filter { !removed.contains($0) }
                    metadata.personShown = Self.normalizedRepeatableValues(
                        metadata.personShown + added,
                        field: .personShown
                    )
                }
            } else if !batchMeta.personShown.isEmpty {
                metadata.personShown = Self.normalizedRepeatableValues(batchMeta.personShown, field: .personShown)
            }
        }

        if let prev = previousCommon {
            if batchFieldMutations[.organisationShownName] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.organisationsShownNames,
                    edited: batchMeta.organisationsShownNames,
                    field: .organisationShownName,
                    to: &metadata.organisationsShownNames
                )
            }
            if batchFieldMutations[.organisationShownCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.organisationsShownCodes,
                    edited: batchMeta.organisationsShownCodes,
                    field: .organisationShownCode,
                    to: &metadata.organisationsShownCodes
                )
            }
            if batchFieldMutations[.sceneCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.sceneCodes,
                    edited: batchMeta.sceneCodes,
                    field: .sceneCode,
                    to: &metadata.sceneCodes
                )
            }
            if batchFieldMutations[.subjectCode] == nil {
                applyImplicitAdditiveEdit(
                    previous: prev.subjectCodes,
                    edited: batchMeta.subjectCodes,
                    field: .subjectCode,
                    to: &metadata.subjectCodes
                )
            }
        }

        if let copyright = batchMeta.copyright, !copyright.isEmpty {
            metadata.copyright = copyright
        }
        if let rightsUsageTerms = batchMeta.rightsUsageTerms, !rightsUsageTerms.isEmpty {
            metadata.rightsUsageTerms = rightsUsageTerms
        }
        if let webStatementOfRights = batchMeta.webStatementOfRights, !webStatementOfRights.isEmpty {
            metadata.webStatementOfRights = webStatementOfRights
        }
        if let digitalImageGUID = batchMeta.digitalImageGUID, !digitalImageGUID.isEmpty {
            metadata.digitalImageGUID = digitalImageGUID
        }
        if let imageSupplierImageID = batchMeta.imageSupplierImageID, !imageSupplierImageID.isEmpty {
            metadata.imageSupplierImageID = imageSupplierImageID
        }
        if let jobId = batchMeta.jobId, !jobId.isEmpty {
            metadata.jobId = jobId
        }
        if let dateCreated = batchMeta.dateCreated,
           (try? EditorialDateCreated(parsing: dateCreated)) != nil {
            metadata.dateCreated = dateCreated
        }
        if batchFieldMutations[.creator] == nil, !batchMeta.creators.isEmpty {
            metadata.creators = batchMeta.creators
        }
        if let creatorJobTitle = batchMeta.creatorJobTitle, !creatorJobTitle.isEmpty {
            metadata.creatorJobTitle = creatorJobTitle
        }
        if let descriptionWriter = batchMeta.descriptionWriter, !descriptionWriter.isEmpty {
            metadata.descriptionWriter = descriptionWriter
        }
        if let credit = batchMeta.credit, !credit.isEmpty {
            metadata.credit = credit
        }
        if let city = batchMeta.city, !city.isEmpty {
            metadata.city = city
        }
        if let sublocation = batchMeta.sublocation, !sublocation.isEmpty {
            metadata.sublocation = sublocation
        }
        if let provinceState = batchMeta.provinceState, !provinceState.isEmpty {
            metadata.provinceState = provinceState
        }
        if let country = batchMeta.country, !country.isEmpty {
            metadata.country = country
        }
        if let countryCode = batchMeta.countryCode, !countryCode.isEmpty {
            metadata.countryCode = countryCode
        }
        if let event = batchMeta.event, !event.isEmpty {
            metadata.event = event
        }
        if let instructions = batchMeta.instructions, !instructions.isEmpty {
            metadata.instructions = instructions
        }
        if let source = batchMeta.source, !source.isEmpty {
            metadata.source = source
        }
        if batchMeta.digitalSourceType != nil {
            metadata.digitalSourceType = batchMeta.digitalSourceType
        }
        if batchMeta.urgency != nil {
            metadata.urgency = batchMeta.urgency
        }

        // GPS — apply only when both coordinates are set, mirroring the batch
        // file-write path in writeMetadata(). When GPS differs across the
        // selection and the user hasn't picked a location, the common
        // coordinates are nil, so each image's existing GPS is preserved.
        if let lat = batchMeta.latitude, let lon = batchMeta.longitude {
            metadata.latitude = lat
            metadata.longitude = lon
        }
    }

    private func applyImplicitAdditiveEdit(
        previous: [String],
        edited: [String],
        field: MetadataFieldID,
        to target: inout [String]
    ) {
        let normalizedPrevious = Set(Self.normalizedRepeatableValues(previous, field: field))
        let normalizedEdited = Self.normalizedRepeatableValues(edited, field: field)
        let normalizedEditedSet = Set(normalizedEdited)
        let added = normalizedEdited.filter { !normalizedPrevious.contains($0) }
        let removed = normalizedPrevious.subtracting(normalizedEditedSet)
        target.removeAll { removed.contains($0) }
        target = Self.normalizedRepeatableValues(target + added, field: field)
    }

    func writeMetadataAndClearSidecar() {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            return
        }

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            do {
                let edited = editingMetadata
                // See writeMetadataAndPreserveHistory — leave the crs block alone
                // unless develop settings actually changed.
                let developChanged = Self.developSettingsChanged(
                    edited.cameraRaw, self.originalImageMetadata?.cameraRaw
                )
                let fields = overwriteFields(
                    from: edited,
                    includeCameraRaw: developChanged,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
                let structuredData = developChanged
                    ? StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments,
                        watermarkLayers: edited.cameraRaw?.watermarkLayers,
                        hslAdjustments: edited.cameraRaw?.hslAdjustments,
                        layerOrder: edited.cameraRaw?.layerOrder,
                        anonymizer: edited.cameraRaw?.anonymizer,
                        unparsedMaskCorrections: edited.cameraRaw?.unparsedMaskCorrections,
                        editorial: EditorialStructuredWriteData(metadata: edited),
                        replaceCameraRawBlock: true
                    )
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited))
                let wroteToRawSidecar = SupportedImageFormats.isRaw(url: imageURL)
                if wroteToRawSidecar {
                    _ = try await descriptiveWriteBoundary.write(
                        metadata: edited,
                        for: imageURL,
                        requestedMode: .writeToFile,
                        semantics: .replace
                    )
                } else {
                    try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                }

                do {
                    try sidecarService.deleteSidecar(for: imageURL, in: folderURL)
                } catch {
                    logger.warning("Failed to delete sidecar for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }
                self.metadata = edited
                self.originalImageMetadata = edited
                if wroteToRawSidecar {
                    self.xmpMetadata = edited
                } else {
                    self.embeddedMetadata = edited
                }
                self.sidecarHistory = []
                self.hasChanges = false
                self.previousEditingMetadata = edited
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
        }
    }

    func writeAllPendingChanges(in folderURL: URL?, images: [ImageFile], skipC2PA: Bool = true) {
        guard let folderURL else { return }

        isProcessingFolder = true
        folderProcessProgress = "0/?"
        saveError = nil

        batchProcessTask?.cancel()
        batchProcessTask = Task {
            defer {
                self.isProcessingFolder = false
                self.folderProcessProgress = ""
            }

            let sidecars = await sidecarService.loadAllSidecars(in: folderURL)
            let pendingSidecars = sidecars.filter { $0.value.pendingChanges }

            var processed = 0
            let total = pendingSidecars.count
            self.folderProcessProgress = "0/\(total)"
            var writtenCount = 0
            var skippedCount = 0
            var failedCount = 0

            let imagesByURL = Dictionary(images.map { ($0.url, $0) }, uniquingKeysWith: { _, last in last })

            for (imageURL, sidecar) in pendingSidecars {
                if skipC2PA {
                    if let image = imagesByURL[imageURL], image.hasC2PA {
                        skippedCount += 1
                        processed += 1
                        self.folderProcessProgress = "\(processed)/\(total)"
                        continue
                    }
                }

                let edited = sidecar.metadata
                // Batch pending writes have no per-file baseline to diff against
                // (originalImageMetadata tracks only the selected image), so gate on
                // whether the sidecar recorded develop edits at all: cameraRaw == nil
                // means a metadata-only pending change, and the file's crs block
                // (possibly Adobe-authored) must be left untouched.
                let developChanged = edited.cameraRaw != nil
                let fields = overwriteFields(
                    from: edited,
                    includeCameraRaw: developChanged,
                    imageAspect: { ImagePixelAspect.aspect(at: imageURL) }
                )
                let structuredData = developChanged
                    ? StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments,
                        watermarkLayers: edited.cameraRaw?.watermarkLayers,
                        hslAdjustments: edited.cameraRaw?.hslAdjustments,
                        layerOrder: edited.cameraRaw?.layerOrder,
                        anonymizer: edited.cameraRaw?.anonymizer,
                        editorial: EditorialStructuredWriteData(metadata: edited),
                        replaceCameraRawBlock: true
                    )
                    : StructuredWriteData(editorial: EditorialStructuredWriteData(metadata: edited))

                do {
                    try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                    do {
                        try sidecarService.deleteSidecar(for: imageURL, in: folderURL)
                    } catch {
                        logger.warning("Failed to delete sidecar for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                    }
                    writtenCount += 1
                } catch {
                    failedCount += 1
                    logger.warning("Failed to write metadata for \(imageURL.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                }

                processed += 1
                self.folderProcessProgress = "\(processed)/\(total)"
            }

            let remainingPending = await sidecarService.imagesWithPendingChanges(in: folderURL)
            self.selectedHavePendingSidecars = !remainingPending.isEmpty
            if failedCount > 0 || skippedCount > 0 {
                self.saveError = "Wrote \(writtenCount), skipped \(skippedCount), failed \(failedCount)."
            }
        }
    }

    // MARK: - Diff Helpers

    func fieldDiffers(_ keyPath: KeyPath<IPTCMetadata, String?>) -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata[keyPath: keyPath] != original[keyPath: keyPath]
    }

    func keywordsDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.keywords != original.keywords
    }

    func personShownDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.personShown != original.personShown
    }

    func organisationShownNamesDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.organisationsShownNames != original.organisationsShownNames
    }

    func organisationShownCodesDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.organisationsShownCodes != original.organisationsShownCodes
    }

    func sceneCodesDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.sceneCodes != original.sceneCodes
    }

    func subjectCodesDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.subjectCodes != original.subjectCodes
    }

    func mediaTopicsDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.mediaTopics != original.mediaTopics
    }

    func genresDiffer() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.genres != original.genres
    }

    func digitalSourceTypeDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.digitalSourceType != original.digitalSourceType
    }

    func urgencyDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.urgency != original.urgency
    }

    func gpsDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.latitude != original.latitude || editingMetadata.longitude != original.longitude
    }

    var pendingFieldNames: [String] {
        guard let original = originalImageMetadata else { return [] }
        var names: [String] = []
        if editingMetadata.title != original.title { names.append("Headline") }
        if editingMetadata.description != original.description { names.append("Description") }
        if editingMetadata.extendedDescription != original.extendedDescription { names.append("Extended Description") }
        if editingMetadata.keywords != original.keywords { names.append("Keywords") }
        if editingMetadata.personShown != original.personShown { names.append("Person Shown") }
        if editingMetadata.organisationsShownNames != original.organisationsShownNames { names.append("Organisation Shown Name") }
        if editingMetadata.organisationsShownCodes != original.organisationsShownCodes { names.append("Organisation Shown Code") }
        if editingMetadata.sceneCodes != original.sceneCodes { names.append("Scene Code") }
        if editingMetadata.subjectCodes != original.subjectCodes { names.append("Subject Code") }
        if editingMetadata.mediaTopics != original.mediaTopics { names.append("Media Topic") }
        if editingMetadata.genres != original.genres { names.append("Genre") }
        if editingMetadata.copyright != original.copyright { names.append("Copyright") }
        if editingMetadata.rightsUsageTerms != original.rightsUsageTerms { names.append("Rights Usage Terms") }
        if editingMetadata.webStatementOfRights != original.webStatementOfRights { names.append("Web Statement of Rights") }
        if editingMetadata.digitalImageGUID != original.digitalImageGUID { names.append("Digital Image GUID") }
        if editingMetadata.imageSupplierImageID != original.imageSupplierImageID { names.append("Image Supplier Image ID") }
        if editingMetadata.jobId != original.jobId { names.append("Job ID") }
        if editingMetadata.creators != original.creators { names.append("Creator") }
        if editingMetadata.creatorJobTitle != original.creatorJobTitle { names.append("Creator Job Title") }
        if editingMetadata.descriptionWriter != original.descriptionWriter { names.append("Description Writer") }
        if editingMetadata.credit != original.credit { names.append("Credit") }
        if editingMetadata.city != original.city { names.append("City") }
        if editingMetadata.sublocation != original.sublocation { names.append("Sublocation") }
        if editingMetadata.provinceState != original.provinceState { names.append("State / Province") }
        if editingMetadata.country != original.country { names.append("Country") }
        if editingMetadata.countryCode != original.countryCode { names.append("Country Code") }
        if editingMetadata.event != original.event { names.append("Event") }
        if editingMetadata.instructions != original.instructions { names.append("Instructions") }
        if editingMetadata.source != original.source { names.append("Source") }
        if editingMetadata.digitalSourceType != original.digitalSourceType { names.append("Digital Source Type") }
        if editingMetadata.urgency != original.urgency { names.append("Urgency") }
        if editingMetadata.rating != original.rating { names.append("Rating") }
        if editingMetadata.label != original.label { names.append("Label") }
        if editingMetadata.latitude != original.latitude || editingMetadata.longitude != original.longitude { names.append("GPS Coordinates") }
        if editingMetadata.captureDate != original.captureDate { names.append("Capture Date") }
        return names
    }

    var showDiscardConfirmation = false
    var showDiscardAllConfirmation = false

    /// Call this instead of discardPendingChanges() directly.
    /// Sets showDiscardConfirmation = true so a view can present an alert.
    func confirmDiscardPendingChanges() {
        showDiscardConfirmation = true
    }

    /// Call this instead of discardAllPendingInFolder() directly.
    /// Sets showDiscardAllConfirmation = true so a view can present an alert.
    func confirmDiscardAllPendingInFolder() {
        showDiscardAllConfirmation = true
    }

    func discardPendingChanges() {
        guard let folderURL = currentFolderURL else { return }

        // Single image: restore from original and delete sidecar
        if selectedURLs.count == 1, let original = originalImageMetadata {
            editingMetadata = original
            hasChanges = false
            sidecarHistory = []
            previousEditingMetadata = original
            try? sidecarService.deleteSidecar(for: selectedURLs[0], in: folderURL)
        } else {
            // Multiple images: delete sidecars for all selected
            for imageURL in selectedURLs {
                try? sidecarService.deleteSidecar(for: imageURL, in: folderURL)
            }
            // Reset state since we're in batch mode
            hasChanges = false
            selectedHavePendingSidecars = false
            editingMetadata = IPTCMetadata()
        }
    }

    func discardAllPendingInFolder() {
        guard let folderURL = currentFolderURL else { return }

        try? sidecarService.deleteAllSidecars(in: folderURL)

        // Reset current editing state
        if let original = originalImageMetadata {
            editingMetadata = original
            previousEditingMetadata = original
        } else {
            editingMetadata = IPTCMetadata()
        }
        hasChanges = false
        selectedHavePendingSidecars = false
        sidecarHistory = []
    }

    func clearHistory() {
        guard let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else { return }

        sidecarHistory = []

        let sidecar = MetadataSidecar(
            sourceFile: imageURL.lastPathComponent,
            lastModified: Date(),
            pendingChanges: hasChanges,
            metadata: editingMetadata,
            imageMetadataSnapshot: originalImageMetadata,
            history: []
        )
        writeTask?.cancel()
        writeTask = Task {
            do {
                _ = try await sidecarService.saveSidecarReplacingHistorySerialized(
                    sidecar,
                    for: imageURL,
                    in: folderURL
                )
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }
    }

    func restoreToOriginal() {
        guard let original = originalImageMetadata else { return }

        editingMetadata = original
        previousEditingMetadata = original
        hasChanges = false

        if let imageURL = selectedURLs.first,
           let folderURL = currentFolderURL {
            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: Date(),
                pendingChanges: false,
                metadata: editingMetadata,
                imageMetadataSnapshot: originalImageMetadata,
                history: sidecarHistory
            )
            writeTask?.cancel()
            writeTask = Task {
                do {
                    let installed = try await sidecarService.saveSidecarMergingHistorySerialized(
                        sidecar,
                        for: imageURL,
                        in: folderURL
                    )
                    sidecarHistory = installed.history
                } catch {
                    saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
                }
            }
        }
    }

    func restoreToHistoryPoint(at index: Int) {
        guard let original = originalImageMetadata else { return }

        // Start from original and replay history up to (and including) the given index
        var restored = original
        let historyToApply = Array(sidecarHistory.prefix(index + 1))

        guard historyToApply.allSatisfy(\.isRestorable) else {
            saveError = "This history point includes summarized or hidden metadata and cannot be restored safely."
            return
        }

        for entry in historyToApply {
            guard entry.apply(to: &restored) else {
                saveError = "This history point contains metadata that cannot be restored safely."
                return
            }
        }

        editingMetadata = restored
        previousEditingMetadata = restored

        hasChanges = editingMetadata != original

        // Save the updated sidecar
        if let imageURL = selectedURLs.first,
           let folderURL = currentFolderURL {
            let sidecar = MetadataSidecar(
                sourceFile: imageURL.lastPathComponent,
                lastModified: Date(),
                pendingChanges: hasChanges,
                metadata: editingMetadata,
                imageMetadataSnapshot: originalImageMetadata,
                history: sidecarHistory
            )
            writeTask?.cancel()
            writeTask = Task {
                do {
                    let installed = try await sidecarService.saveSidecarMergingHistorySerialized(
                        sidecar,
                        for: imageURL,
                        in: folderURL
                    )
                    sidecarHistory = installed.history
                } catch {
                    saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
                }
            }
        }
    }

    func clear() {
        metadata = nil
        editingMetadata = IPTCMetadata()
        selectedCount = 0
        selectedURLs = []
        hasChanges = false
        sidecarHistory = []
        originalImageMetadata = nil
        previousEditingMetadata = nil
        metadataReferenceSource = .embedded
    }
}
