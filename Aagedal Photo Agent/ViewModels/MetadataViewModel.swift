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
    var isLoadingBatchMetadata = false

    // Geocoding state
    var isReverseGeocoding = false
    var geocodingError: String?
    var geocodingProgress = ""

    private let readService: SwiftExifReadService
    private let writeEngine: any MetadataWriteEngine
    private let sidecarService = MetadataSidecarService()
    private let xmpSidecarService = XMPSidecarService()
    private let geocodingService = GeocodingService()
    private let logger = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataViewModel")
    private let perfLog = Logger(subsystem: "com.aagedal.photo-agent", category: "MetadataPerf")
    private var previousEditingMetadata: IPTCMetadata?
    @ObservationIgnored private var metadataLoadTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var batchProcessTask: Task<Void, Never>?
    @ObservationIgnored private var geocodingTask: Task<Void, Never>?

    init(readService: SwiftExifReadService, writeEngine: any MetadataWriteEngine) {
        self.readService = readService
        self.writeEngine = writeEngine
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
            return
        }

        if images.count == 1 {
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
                self.perfLog.info("[MetadataVM] loadMetadata START — \(imageURL.lastPathComponent, privacy: .public)")
                do {
                    let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: imageURL)
                    let exifMs = loadStart.elapsedMilliseconds()
                    self.perfLog.info("[MetadataVM] metadata read returned — \(exifMs)ms for \(imageURL.lastPathComponent, privacy: .public)")
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
                    self.perfLog.info("[MetadataVM] loadMetadata DONE — \(imageURL.lastPathComponent, privacy: .public) total \(totalMs)ms")
                    self.logger.info("[\(imageURL.lastPathComponent, privacy: .public)] loadMetadata result: xmp=\(xmpMeta != nil), stale=\(sidecarIsStale), ref=\(String(describing: referenceSource), privacy: .public), reloadSame=\(isReloadingSameImage), title=\(self.editingMetadata.title ?? "nil", privacy: .public)")
                    if self.metadataReferenceSource == .xmp, self.xmpMetadata == nil {
                        self.metadataReferenceSource = .embedded
                    }
                } catch {
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                    self.saveError = "Failed to load metadata: \(error.localizedDescription)"
                    self.logger.error("[\(imageURL.lastPathComponent, privacy: .public)] loadMetadata FAILED: \(error.localizedDescription, privacy: .public)")
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
        compareOptionalField(allMetadata, keyPath: \.jobId, fieldName: "jobId", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.creator, fieldName: "creator", common: &common, differing: &differing)
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

        // Array fields — compute intersection (common to all) and partial (some but not all)
        let (commonKW, partialKW) = computeArrayFieldPartials(allMetadata, keyPath: \.keywords)
        common.keywords = commonKW
        if !partialKW.isEmpty { differing.insert("keywords") }
        self.batchPartialKeywords = partialKW

        let (commonPS, partialPS) = computeArrayFieldPartials(allMetadata, keyPath: \.personShown)
        common.personShown = commonPS
        if !partialPS.isEmpty { differing.insert("personShown") }
        self.batchPartialPersonShown = partialPS

        let (commonOrganisationNames, partialOrganisationNames) = computeArrayFieldPartials(
            allMetadata,
            keyPath: \.organisationsShownNames
        )
        common.organisationsShownNames = commonOrganisationNames
        if !partialOrganisationNames.isEmpty { differing.insert("organisationShownName") }

        let (commonOrganisationCodes, partialOrganisationCodes) = computeArrayFieldPartials(
            allMetadata,
            keyPath: \.organisationsShownCodes
        )
        common.organisationsShownCodes = commonOrganisationCodes
        if !partialOrganisationCodes.isEmpty { differing.insert("organisationShownCode") }

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

    /// Compute intersection (common to all images) and partial (in some but not all) for an array field.
    private func computeArrayFieldPartials(
        _ allMetadata: [IPTCMetadata],
        keyPath: KeyPath<IPTCMetadata, [String]>
    ) -> (common: [String], partial: [String]) {
        let sets = allMetadata.map { Set($0[keyPath: keyPath]) }
        guard let first = sets.first else { return ([], []) }
        let intersection = sets.dropFirst().reduce(first) { $0.intersection($1) }
        let union = sets.dropFirst().reduce(first) { $0.union($1) }
        let common = (allMetadata.first?[keyPath: keyPath] ?? []).filter { intersection.contains($0) }
        let partial = union.subtracting(intersection).sorted()
        return (common, partial)
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
        switch mode {
        case .historyOnly:
            saveToSidecar()
            onComplete?()
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
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields[.gpsLatitude] = String(abs(lat))
                        fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                        fields[.gpsLongitude] = String(abs(lon))
                        fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                    }
                    if let v = edited.creator, !v.isEmpty { fields[.creator] = v }
                    if let v = edited.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
                    if let v = edited.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
                    if let v = edited.credit, !v.isEmpty { fields[.credit] = v }
                    if let v = edited.copyright, !v.isEmpty { fields[.rights] = v }
                    if let v = edited.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
                    if let v = edited.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
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
                    if edited.digitalSourceType != original?.digitalSourceType {
                        fields[.digitalSourceType] = edited.digitalSourceType?.newsCodeURI ?? ""
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
                    if edited.creator != original?.creator { fields[.creator] = edited.creator ?? "" }
                    if edited.creatorJobTitle != original?.creatorJobTitle { fields[.creatorJobTitle] = edited.creatorJobTitle ?? "" }
                    if edited.descriptionWriter != original?.descriptionWriter { fields[.descriptionWriter] = edited.descriptionWriter ?? "" }
                    if edited.credit != original?.credit { fields[.credit] = edited.credit ?? "" }
                    if edited.copyright != original?.copyright { fields[.rights] = edited.copyright ?? "" }
                    if edited.rightsUsageTerms != original?.rightsUsageTerms { fields[.rightsUsageTerms] = edited.rightsUsageTerms ?? "" }
                    if edited.webStatementOfRights != original?.webStatementOfRights { fields[.webStatementOfRights] = edited.webStatementOfRights ?? "" }
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

                let structuredEditorialChanged = !isBatch && (
                    edited.creatorContactInfo != original?.creatorContactInfo
                        || Set(edited.locationsCreated) != Set(original?.locationsCreated ?? [])
                        || Set(edited.locationsShown) != Set(original?.locationsShown ?? [])
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
                    let diffs = additiveListDiffs(from: edited, previous: prev)
                    if !diffs.add.isEmpty || !diffs.remove.isEmpty {
                        try await writeEngine.addRemoveListValues(
                            add: diffs.add,
                            remove: diffs.remove,
                            to: urls
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
        if let v = metadata.creator, !v.isEmpty { fields[.creator] = v }
        if let v = metadata.creatorJobTitle, !v.isEmpty { fields[.creatorJobTitle] = v }
        if let v = metadata.descriptionWriter, !v.isEmpty { fields[.descriptionWriter] = v }
        if let v = metadata.credit, !v.isEmpty { fields[.credit] = v }
        if let v = metadata.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = metadata.rightsUsageTerms, !v.isEmpty { fields[.rightsUsageTerms] = v }
        if let v = metadata.webStatementOfRights, !v.isEmpty { fields[.webStatementOfRights] = v }
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

    /// Compute add/remove diffs for list fields in add mode, relative to previousEditingMetadata.
    private func additiveListDiffs(
        from edited: IPTCMetadata,
        previous: IPTCMetadata
    ) -> (add: [MetadataFieldKey: [String]], remove: [MetadataFieldKey: [String]]) {
        var addTags: [MetadataFieldKey: [String]] = [:]
        var removeTags: [MetadataFieldKey: [String]] = [:]

        if multiSelectMode(for: "keywords") == .add {
            let added = Array(Set(edited.keywords).subtracting(previous.keywords))
            let removed = Array(Set(previous.keywords).subtracting(edited.keywords))
            if !added.isEmpty { addTags[.subject] = added }
            if !removed.isEmpty { removeTags[.subject] = removed }
        }

        if multiSelectMode(for: "personShown") == .add {
            let added = Array(Set(edited.personShown).subtracting(previous.personShown))
            let removed = Array(Set(previous.personShown).subtracting(edited.personShown))
            if !added.isEmpty { addTags[.personInImage] = added }
            if !removed.isEmpty { removeTags[.personInImage] = removed }
        }

        let previousOrganisationNames = Set(previous.organisationsShownNames)
        let editedOrganisationNames = Set(edited.organisationsShownNames)
        let addedOrganisationNames = edited.organisationsShownNames.filter { !previousOrganisationNames.contains($0) }
        let removedOrganisationNames = previous.organisationsShownNames.filter { !editedOrganisationNames.contains($0) }
        if !addedOrganisationNames.isEmpty { addTags[.organisationInImageName] = addedOrganisationNames }
        if !removedOrganisationNames.isEmpty { removeTags[.organisationInImageName] = removedOrganisationNames }

        let previousOrganisationCodes = Set(previous.organisationsShownCodes)
        let editedOrganisationCodes = Set(edited.organisationsShownCodes)
        let addedOrganisationCodes = edited.organisationsShownCodes.filter { !previousOrganisationCodes.contains($0) }
        let removedOrganisationCodes = previous.organisationsShownCodes.filter { !editedOrganisationCodes.contains($0) }
        if !addedOrganisationCodes.isEmpty { addTags[.organisationInImageCode] = addedOrganisationCodes }
        if !removedOrganisationCodes.isEmpty { removeTags[.organisationInImageCode] = removedOrganisationCodes }

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
                try xmpSidecarService.saveSidecar(metadata: record, for: url)
            } catch {
                logger.error("Sidecar mirror failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func writeXMPSidecar() {
        guard !selectedURLs.isEmpty else { return }

        if selectedCount == 1, let imageURL = selectedURLs.first {
            do {
                try xmpSidecarService.saveSidecar(metadata: editingMetadata, for: imageURL)
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
            var existing = xmpSidecarService.loadSidecar(for: imageURL) ?? IPTCMetadata()
            applyBatchEdits(batchMeta, to: &existing, previousCommon: prevCommon)
            do {
                try xmpSidecarService.saveSidecar(metadata: existing, for: imageURL)
            } catch {
                saveError = "Failed to save XMP sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func writeXMPSidecarAndPreserveHistory(onComplete: (() -> Void)? = nil) {
        guard let folderURL = currentFolderURL else {
            writeXMPSidecar()
            onComplete?()
            return
        }

        if selectedCount > 1 {
            writeXMPSidecar()
            saveBatchSidecars(folderURL: folderURL, pendingChanges: false)
            hasChanges = false
            onComplete?()
            return
        }

        guard let imageURL = selectedURLs.first else {
            onComplete?()
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata ?? IPTCMetadata()
        let existingHistory = sidecarHistory

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            do {
                try xmpSidecarService.saveSidecar(metadata: edited, for: imageURL)

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
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)

                let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
                if isStillSelected {
                    self.sidecarHistory = history
                    self.previousEditingMetadata = edited
                    self.xmpMetadata = edited
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
            } catch {
                self.saveError = "Failed to write XMP sidecar: \(error.localizedDescription)"
            }

            self.isSaving = false
            onComplete?()
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
        fields[.digitalSourceType] = metadata.digitalSourceType?.newsCodeURI ?? ""
        fields[.creator] = metadata.creator ?? ""
        fields[.creatorJobTitle] = metadata.creatorJobTitle ?? ""
        fields[.descriptionWriter] = metadata.descriptionWriter ?? ""
        fields[.credit] = metadata.credit ?? ""
        fields[.rights] = metadata.copyright ?? ""
        fields[.rightsUsageTerms] = metadata.rightsUsageTerms ?? ""
        fields[.webStatementOfRights] = metadata.webStatementOfRights ?? ""
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

    private func syncCameraRawToXMPSidecar(for imageURL: URL, metadata: IPTCMetadata) {
        guard metadata.cameraRaw != nil || originalImageMetadata?.cameraRaw != nil else { return }
        try? xmpSidecarService.saveCameraRawOnly(
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

    private func writeMetadataAndPreserveHistory(alsoWriteXMPSidecar: Bool = false, onComplete: (() -> Void)? = nil) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            if alsoWriteXMPSidecar { writeXMPSidecar() }
            onComplete?()
            return
        }

        let edited = editingMetadata
        let previous = previousEditingMetadata
        let existingHistory = sidecarHistory

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
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
                    try xmpSidecarService.saveSidecar(metadata: edited, for: imageURL)
                    sidecarMirrored = true
                } else {
                    // No sidecar yet: keep develop settings ACR-readable without
                    // creating a descriptive IPTC record next to an embedded-mode file.
                    self.syncCameraRawToXMPSidecar(for: imageURL, metadata: edited)
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
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)

                let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
                if isStillSelected {
                    self.sidecarHistory = history
                    self.previousEditingMetadata = edited
                    self.metadata = edited
                    self.originalImageMetadata = edited
                    self.embeddedMetadata = edited
                    if sidecarMirrored {
                        self.xmpMetadata = edited
                    }
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
            onComplete?()
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
            case "digitalSourceType":
                editingMetadata.digitalSourceType = DigitalSourceType(metadataValue: value)
            case "creator":
                editingMetadata.creator = append ? appendString(editingMetadata.creator, value) : value
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
            case "jobId":
                editingMetadata.jobId = append ? appendString(editingMetadata.jobId, value) : value
            case "dateCreated":
                editingMetadata.dateCreated = append ? appendString(editingMetadata.dateCreated, value) : value
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

    private static let variablePattern = /\{(date|date:[^}]+|dateCreated|dateCreated:[^}]+|dateCaptured|dateCaptured:[^}]+|filename|initials|persons|keywords|gps|gps:city|gps:country|latitude|longitude|field:[^}]+|seq|seq:\d+)\}/

    /// Checks whether any text field, keyword, or person in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        let fields: [String?] = [
            editingMetadata.title,
            editingMetadata.description,
            editingMetadata.extendedDescription,
            editingMetadata.creator,
            editingMetadata.creatorJobTitle,
            editingMetadata.descriptionWriter,
            editingMetadata.credit,
            editingMetadata.copyright,
            editingMetadata.rightsUsageTerms,
            editingMetadata.webStatementOfRights,
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
            + editingMetadata.organisationsShownNames + editingMetadata.organisationsShownCodes
        return listValues.contains { $0.contains(Self.variablePattern) }
    }

    /// Resolves all variable placeholders in editingMetadata text fields in-place.
    func processVariables(filename: String = "", sequenceIndex: Int = 1) {
        batchProcessTask?.cancel()
        batchProcessTask = Task {
            await processVariablesInEditingBuffer(filename: filename, sequenceIndex: sequenceIndex)
        }
    }

    private func processVariablesInEditingBuffer(filename: String, sequenceIndex: Int) async {
        let interpolator = PresetVariableInterpolator()
        let initials = UserDefaults.standard.string(forKey: UserDefaultsKeys.creatorInitials) ?? ""
        editingMetadata = await interpolator.resolvingGPSPlaceVariables(in: editingMetadata)
        // Use a snapshot of current editing state for field references
        let snapshot = editingMetadata

        editingMetadata.title = resolveIfPresent(editingMetadata.title, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.description = resolveIfPresent(editingMetadata.description, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.extendedDescription = resolveIfPresent(editingMetadata.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.creator = resolveIfPresent(editingMetadata.creator, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.creatorJobTitle = resolveIfPresent(editingMetadata.creatorJobTitle, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.descriptionWriter = resolveIfPresent(editingMetadata.descriptionWriter, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.credit = resolveIfPresent(editingMetadata.credit, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.copyright = resolveIfPresent(editingMetadata.copyright, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.rightsUsageTerms = resolveIfPresent(editingMetadata.rightsUsageTerms, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.webStatementOfRights = resolveIfPresent(editingMetadata.webStatementOfRights, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
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
        if resolved.creator != original.creator { fields[.creator] = resolved.creator ?? "" }
        if resolved.creatorJobTitle != original.creatorJobTitle { fields[.creatorJobTitle] = resolved.creatorJobTitle ?? "" }
        if resolved.descriptionWriter != original.descriptionWriter { fields[.descriptionWriter] = resolved.descriptionWriter ?? "" }
        if resolved.credit != original.credit { fields[.credit] = resolved.credit ?? "" }
        if resolved.copyright != original.copyright { fields[.rights] = resolved.copyright ?? "" }
        if resolved.rightsUsageTerms != original.rightsUsageTerms { fields[.rightsUsageTerms] = resolved.rightsUsageTerms ?? "" }
        if resolved.webStatementOfRights != original.webStatementOfRights { fields[.webStatementOfRights] = resolved.webStatementOfRights ?? "" }
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

        // Build JSON sidecar with history entry
        func buildSidecar(pendingChanges: Bool, historyNote: String) -> MetadataSidecar {
            var sidecar = MetadataSidecar(
                sourceFile: url.lastPathComponent,
                pendingChanges: pendingChanges,
                metadata: resolved,
                imageMetadataSnapshot: embedded
            )
            sidecar.history = existingSidecar?.history ?? []
            sidecar.history.append(MetadataHistoryEntry(
                timestamp: Date(),
                fieldName: "Variables processed",
                oldValue: nil,
                newValue: historyNote
            ))
            return sidecar
        }

        switch mode {
        case .historyOnly:
            let sidecar = buildSidecar(pendingChanges: true, historyNote: "Saved to sidecar (history only)")
            try sidecarService.saveSidecar(sidecar, for: url, in: folder)
            return .savedToHistory

        case .writeToXMPSidecar:
            try xmpSidecarService.saveSidecar(metadata: resolved, for: url)
            let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to XMP sidecar")
            try sidecarService.saveSidecar(sidecar, for: url, in: folder)
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
                try xmpSidecarService.saveSidecar(metadata: resolved, for: url)
            }
            let note = mode.writesXMPSidecar ? "Written to image file + XMP sidecar" : "Written to image file"
            let sidecar = buildSidecar(pendingChanges: false, historyNote: note)
            try sidecarService.saveSidecar(sidecar, for: url, in: folder)
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
                let meta = await interpolator.resolvingGPSPlaceVariables(in: unresolvedMeta)
                let snapshot = meta

                var changed = meta != unresolvedMeta
                var resolvedMeta = meta

                resolvedMeta.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.extendedDescription = resolveIfChanged(meta.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.creatorJobTitle = resolveIfChanged(meta.creatorJobTitle, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.descriptionWriter = resolveIfChanged(meta.descriptionWriter, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.rightsUsageTerms = resolveIfChanged(meta.rightsUsageTerms, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.webStatementOfRights = resolveIfChanged(meta.webStatementOfRights, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
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
                        try await writeEngine.writeFields(fields, to: [url])
                        geocoded += 1
                    }

                    // Throttle only the online geocoder; the offline lookup needs no rate limit.
                    if geocodingService.usesNetwork {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch {
                    failed += 1
                    logger.warning("Reverse geocoding failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        if selectedCount == 1, let imageURL = selectedURLs.first {
            // Single image mode - save with full history tracking
            saveSingleImageSidecar(imageURL: imageURL, folderURL: folderURL, pendingChanges: true, snapshot: originalImageMetadata)
        } else if selectedCount > 1 {
            // Batch mode - merge edits into each image's sidecar
            saveBatchSidecars(folderURL: folderURL)
        }
    }

    private func saveSingleImageSidecar(
        imageURL: URL,
        folderURL: URL,
        pendingChanges: Bool,
        snapshot: IPTCMetadata?
    ) {
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
            try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
            if pendingChanges {
                // C2PA: save full metadata to XMP sidecar for render+sign overlay
                try xmpSidecarService.saveSidecar(metadata: editingMetadata, for: imageURL)
            } else {
                syncCameraRawToXMPSidecar(for: imageURL, metadata: editingMetadata)
            }
            sidecarHistory = newHistory
            previousEditingMetadata = editingMetadata
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

        func recordChange(_ fieldName: String, old: String?, new: String?) {
            if old != new {
                history.append(MetadataHistoryEntry(
                    timestamp: timestamp,
                    fieldName: fieldName,
                    oldValue: old,
                    newValue: new
                ))
            }
        }

        func recordArrayChange(_ fieldName: String, old: [String], new: [String]) {
            let oldVal = old.isEmpty ? nil : old.joined(separator: ", ")
            let newVal = new.isEmpty ? nil : new.joined(separator: ", ")
            if oldVal != newVal {
                history.append(MetadataHistoryEntry(
                    timestamp: timestamp,
                    fieldName: fieldName,
                    oldValue: oldVal,
                    newValue: newVal
                ))
            }
        }

        recordChange("Headline", old: previous.title, new: edited.title)
        recordChange("Description", old: previous.description, new: edited.description)
        recordChange("Extended Description", old: previous.extendedDescription, new: edited.extendedDescription)
        recordArrayChange("Keywords", old: previous.keywords, new: edited.keywords)
        recordArrayChange("Person Shown", old: previous.personShown, new: edited.personShown)
        recordArrayChange("Organisation Shown Name", old: previous.organisationsShownNames, new: edited.organisationsShownNames)
        recordArrayChange("Organisation Shown Code", old: previous.organisationsShownCodes, new: edited.organisationsShownCodes)
        recordChange("Copyright", old: previous.copyright, new: edited.copyright)
        recordChange("Rights Usage Terms", old: previous.rightsUsageTerms, new: edited.rightsUsageTerms)
        recordChange("Web Statement of Rights", old: previous.webStatementOfRights, new: edited.webStatementOfRights)
        recordChange("Job ID", old: previous.jobId, new: edited.jobId)
        recordChange("Creator", old: previous.creator, new: edited.creator)
        recordChange("Creator Job Title", old: previous.creatorJobTitle, new: edited.creatorJobTitle)
        recordChange("Description Writer", old: previous.descriptionWriter, new: edited.descriptionWriter)
        recordChange("Credit", old: previous.credit, new: edited.credit)
        recordChange("Date Created", old: previous.dateCreated, new: edited.dateCreated)
        recordChange("City", old: previous.city, new: edited.city)
        recordChange("Country", old: previous.country, new: edited.country)
        recordChange("Country Code", old: previous.countryCode, new: edited.countryCode)
        recordChange("Event", old: previous.event, new: edited.event)
        recordChange(
            "Digital Source Type",
            old: previous.digitalSourceType?.rawValue,
            new: edited.digitalSourceType?.rawValue
        )

        func formatGPS(_ lat: Double?, _ lon: Double?) -> String? {
            guard let lat, let lon else { return nil }
            return "\(lat), \(lon)"
        }
        recordChange(
            "GPS",
            old: formatGPS(previous.latitude, previous.longitude),
            new: formatGPS(edited.latitude, edited.longitude)
        )

        history.trimToHistoryLimit()
        return history
    }

    private func saveBatchSidecars(
        folderURL: URL,
        pendingChanges: Bool = true,
        targetURLs: [URL]? = nil,
        updateState: Bool = true
    ) {
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
                existingMeta = IPTCMetadata()
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
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
                if pendingChanges {
                    // C2PA: save full metadata to XMP sidecar for render+sign overlay.
                    // `existingMeta` is JSON-sourced (no crs) — preserve any develop
                    // edits already in the .xmp so a batch rating/keyword edit on a
                    // C2PA RAW doesn't wipe them.
                    try xmpSidecarService.saveSidecarPreservingDevelopSettings(metadata: existingMeta, for: imageURL)
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
        if multiSelectMode(for: "keywords") == .add, let prev = previousCommon {
            let added = Set(batchMeta.keywords).subtracting(prev.keywords)
            let removed = Set(prev.keywords).subtracting(batchMeta.keywords)
            if !added.isEmpty || !removed.isEmpty {
                metadata.keywords = metadata.keywords.filter { !removed.contains($0) }
                let existingSet = Set(metadata.keywords)
                metadata.keywords += added.filter { !existingSet.contains($0) }
            }
        } else if !batchMeta.keywords.isEmpty {
            let existing = Set(metadata.keywords)
            metadata.keywords += batchMeta.keywords.filter { !existing.contains($0) }
        }

        // Person Shown — add vs overwrite
        if multiSelectMode(for: "personShown") == .add, let prev = previousCommon {
            let added = Set(batchMeta.personShown).subtracting(prev.personShown)
            let removed = Set(prev.personShown).subtracting(batchMeta.personShown)
            if !added.isEmpty || !removed.isEmpty {
                metadata.personShown = metadata.personShown.filter { !removed.contains($0) }
                let existingSet = Set(metadata.personShown)
                metadata.personShown += added.filter { !existingSet.contains($0) }
            }
        } else if !batchMeta.personShown.isEmpty {
            let existing = Set(metadata.personShown)
            metadata.personShown += batchMeta.personShown.filter { !existing.contains($0) }
        }

        if let prev = previousCommon {
            let previousNames = Set(prev.organisationsShownNames)
            let added = batchMeta.organisationsShownNames.filter { !previousNames.contains($0) }
            let removed = Set(prev.organisationsShownNames).subtracting(batchMeta.organisationsShownNames)
            metadata.organisationsShownNames.removeAll { removed.contains($0) }
            let existing = Set(metadata.organisationsShownNames)
            metadata.organisationsShownNames += added.filter { !existing.contains($0) }

            let previousCodes = Set(prev.organisationsShownCodes)
            let addedCodes = batchMeta.organisationsShownCodes.filter { !previousCodes.contains($0) }
            let removedCodes = Set(prev.organisationsShownCodes).subtracting(batchMeta.organisationsShownCodes)
            metadata.organisationsShownCodes.removeAll { removedCodes.contains($0) }
            let existingCodes = Set(metadata.organisationsShownCodes)
            metadata.organisationsShownCodes += addedCodes.filter { !existingCodes.contains($0) }
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
        if let jobId = batchMeta.jobId, !jobId.isEmpty {
            metadata.jobId = jobId
        }
        if let creator = batchMeta.creator, !creator.isEmpty {
            metadata.creator = creator
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

        // GPS — apply only when both coordinates are set, mirroring the batch
        // file-write path in writeMetadata(). When GPS differs across the
        // selection and the user hasn't picked a location, the common
        // coordinates are nil, so each image's existing GPS is preserved.
        if let lat = batchMeta.latitude, let lon = batchMeta.longitude {
            metadata.latitude = lat
            metadata.longitude = lon
        }
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
                try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)

                do {
                    try sidecarService.deleteSidecar(for: imageURL, in: folderURL)
                } catch {
                    logger.warning("Failed to delete sidecar for \(imageURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                self.metadata = edited
                self.originalImageMetadata = edited
                self.embeddedMetadata = edited
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
                        logger.warning("Failed to delete sidecar for \(imageURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    writtenCount += 1
                } catch {
                    failedCount += 1
                    logger.warning("Failed to write metadata for \(imageURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    func digitalSourceTypeDiffers() -> Bool {
        guard let original = originalImageMetadata else { return false }
        return editingMetadata.digitalSourceType != original.digitalSourceType
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
        if editingMetadata.copyright != original.copyright { names.append("Copyright") }
        if editingMetadata.rightsUsageTerms != original.rightsUsageTerms { names.append("Rights Usage Terms") }
        if editingMetadata.webStatementOfRights != original.webStatementOfRights { names.append("Web Statement of Rights") }
        if editingMetadata.jobId != original.jobId { names.append("Job ID") }
        if editingMetadata.creator != original.creator { names.append("Creator") }
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
        do {
            try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
        } catch {
            saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
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
            do {
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }
    }

    func restoreToHistoryPoint(at index: Int) {
        guard let original = originalImageMetadata else { return }

        // Start from original and replay history up to (and including) the given index
        var restored = original
        let historyToApply = Array(sidecarHistory.prefix(index + 1))

        for entry in historyToApply {
            applyHistoryEntry(entry, to: &restored)
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
            do {
                try sidecarService.saveSidecar(sidecar, for: imageURL, in: folderURL)
            } catch {
                saveError = "Failed to save metadata sidecar: \(error.localizedDescription)"
            }
        }
    }

    private func applyHistoryEntry(_ entry: MetadataHistoryEntry, to metadata: inout IPTCMetadata) {
        switch entry.fieldName {
        case "Headline", "Title":
            metadata.title = entry.newValue
        case "Description":
            metadata.description = entry.newValue
        case "Extended Description":
            metadata.extendedDescription = entry.newValue
        case "Keywords":
            metadata.keywords = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Person Shown":
            metadata.personShown = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Organisation Shown Name":
            metadata.organisationsShownNames = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Organisation Shown Code":
            metadata.organisationsShownCodes = entry.newValue?.components(separatedBy: ", ") ?? []
        case "Copyright":
            metadata.copyright = entry.newValue
        case "Rights Usage Terms":
            metadata.rightsUsageTerms = entry.newValue
        case "Web Statement of Rights":
            metadata.webStatementOfRights = entry.newValue
        case "Job ID", "Job-ID":
            metadata.jobId = entry.newValue
        case "Creator":
            metadata.creator = entry.newValue
        case "Creator Job Title":
            metadata.creatorJobTitle = entry.newValue
        case "Description Writer":
            metadata.descriptionWriter = entry.newValue
        case "Credit":
            metadata.credit = entry.newValue
        case "City":
            metadata.city = entry.newValue
        case "Sublocation":
            metadata.sublocation = entry.newValue
        case "State / Province":
            metadata.provinceState = entry.newValue
        case "Country":
            metadata.country = entry.newValue
        case "Country Code":
            metadata.countryCode = ISO3166Country.normalizedAlpha3(entry.newValue)
        case "Event":
            metadata.event = entry.newValue
        case "Instructions":
            metadata.instructions = entry.newValue
        case "Source":
            metadata.source = entry.newValue
        case "Digital Source Type":
            metadata.digitalSourceType = entry.newValue.flatMap { DigitalSourceType(metadataValue: $0) }
        default:
            break
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
