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

struct MetadataWriteDestinations: Equatable, Sendable {
    let iptc: MetadataDestination
    let develop: MetadataDestination
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
    var showMetadataSourceChoice = false
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

    private var prefersXMPSidecar: Bool {
        let stored = UserDefaults.standard.object(forKey: UserDefaultsKeys.metadataPreferXMPSidecar) as? Bool
        return stored ?? true
    }

    private var shouldAskOnMultipleSources: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.metadataAskOnMultipleSources)
    }

    private func defaultReferenceSource(hasXmp: Bool) -> MetadataReferenceSource {
        if prefersXMPSidecar, hasXmp { return .xmp }
        return .embedded
    }

    private func referenceMetadata(
        for source: MetadataReferenceSource,
        embedded: IPTCMetadata?,
        xmp: IPTCMetadata?,
        imageURL: URL? = nil
    ) -> IPTCMetadata? {
        switch source {
        case .embedded:
            // For RAW files, CRS edits live exclusively in the XMP sidecar
            // (the image file is never modified for C2PA). Override embedded
            // CRS with XMP CRS even when the user prefers embedded IPTC.
            if let embedded, let url = imageURL,
               SupportedImageFormats.isRaw(url: url),
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
                var merged = embedded.merged(preferring: xmp)
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

    /// Where the next IPTC and Develop write will land for the current selection.
    /// Returns nil when nothing is selected.
    var nextWriteDestination: MetadataWriteDestinations? {
        guard !selectedURLs.isEmpty else { return nil }
        let perFile = selectedURLs.map(Self.writeDestinations(for:))
        let iptc = Self.reduceDestinations(perFile.map(\.iptc))
        let develop = Self.reduceDestinations(perFile.map(\.develop))
        return MetadataWriteDestinations(iptc: iptc, develop: develop)
    }

    private static func writeDestinations(for url: URL) -> MetadataWriteDestinations {
        let isRaw = SupportedImageFormats.isRaw(url: url)
        let developDest: MetadataDestination = isRaw ? .sidecar : .embedded
        if isRaw {
            return MetadataWriteDestinations(iptc: .embedded, develop: developDest)
        }
        guard PMXMPPolicy.mode == .strictPhotoMechanic else {
            return MetadataWriteDestinations(iptc: .embedded, develop: developDest)
        }
        let iptc: MetadataDestination
        switch PMXMPPolicy.nonRawBehavior {
        case .historyOnly:
            iptc = .sidecar
        case .embeddedWrite, .syncRawJpegPair:
            iptc = .embedded
        case .alwaysAsk:
            iptc = remembered(from: PMXMPPolicy.rememberedChoice) ?? .askedAtSave
        }
        return MetadataWriteDestinations(iptc: iptc, develop: developDest)
    }

    private static func remembered(from choice: PMNonRAWXMPSidecarChoice?) -> MetadataDestination? {
        switch choice {
        case .historyOnly: return .sidecar
        case .embeddedWrite, .syncRawJpegPair: return .embedded
        case nil: return nil
        }
    }

    private static func reduceDestinations(_ values: [MetadataDestination]) -> MetadataDestination {
        guard let first = values.first else { return .embedded }
        return values.allSatisfy { $0 == first } ? first : .mixed
    }

    private func loadXMPMetadataIfAllowed(for imageURL: URL) -> IPTCMetadata? {
        guard PMXMPPolicy.shouldUseXMPReference(for: imageURL) else { return nil }
        return xmpSidecarService.loadSidecar(for: imageURL)
    }

    func loadMetadata(for images: [ImageFile], folderURL: URL? = nil) {
        metadataLoadTask?.cancel()
        metadataLoadTask = nil

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
        batchCommonMetadata = nil
        batchDifferingFields = []
        batchPartialKeywords = []
        batchPartialPersonShown = []

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
            let isReloadingSameImage = selectedURLs.count == 1 && selectedURLs.first == imageURL && metadata != nil
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
                    let xmpMeta = self.loadXMPMetadataIfAllowed(for: imageURL)
                    // Preserve the user's manual reference source selection when
                    // reloading the same image (e.g. auto-refresh, post-save).
                    // Only fall back to the default on first load or if the
                    // previously selected source is no longer available.
                    let referenceSource: MetadataReferenceSource
                    if isReloadingSameImage,
                       !(self.metadataReferenceSource == .xmp && xmpMeta == nil) {
                        referenceSource = self.metadataReferenceSource
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

                    // Show source choice prompt when both sources exist with
                    // different IPTC content and the "ask" setting is enabled.
                    if self.shouldAskOnMultipleSources,
                       let xmp = xmpMeta,
                       embedded.hasIPTCDifferences(from: xmp) {
                        self.showMetadataSourceChoice = true
                    }

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
                    if self.metadataReferenceSource == .xmp, self.xmpMetadata == nil {
                        self.metadataReferenceSource = .embedded
                    }
                } catch {
                    self.metadata = nil
                    self.editingMetadata = IPTCMetadata()
                    self.previousEditingMetadata = nil
                    self.saveError = "Failed to load metadata: \(error.localizedDescription)"
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
            let selectionSnapshot = Set(images.map(\.url))
            let isReloadingSameBatch = selectedCount > 1
                && selectionSnapshot == Set(selectedURLs)
                && batchCommonMetadata != nil

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
                if prefersXMPSidecar,
                   let xmpMeta = loadXMPMetadataIfAllowed(for: image.url) {
                    meta = meta.merged(preferring: xmpMeta)
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
        compareOptionalField(allMetadata, keyPath: \.jobId, fieldName: "jobId", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.creator, fieldName: "creator", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.credit, fieldName: "credit", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.city, fieldName: "city", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.country, fieldName: "country", common: &common, differing: &differing)
        compareOptionalField(allMetadata, keyPath: \.event, fieldName: "event", common: &common, differing: &differing)
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

    func resolveDescriptionConflict(keepXMP: Bool) {
        guard let conflict = descriptionConflict else { return }
        editingMetadata.description = keepXMP ? conflict.xmpDescription : conflict.iptcCaptionAbstract
        descriptionConflict = nil
        markChanged()
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

    func commitEdits(
        mode: MetadataWriteMode,
        hasC2PA: Bool,
        allowC2PAOverwrite: Bool = false,
        onComplete: (() -> Void)? = nil
    ) {
        switch mode {
        case .historyOnly:
            saveToSidecar()
            onComplete?()
        case .writeToXMPSidecar:
            if PMXMPPolicy.mode == .strictPhotoMechanic {
                writeStrictPhotoMechanicXMP(onComplete: onComplete)
                return
            }
            writeXMPSidecarAndPreserveHistory(onComplete: onComplete)
        case .writeToFile:
            if hasC2PA && !allowC2PAOverwrite {
                saveToSidecar()
                saveError = "C2PA-protected image. Changes were saved to history only."
                onComplete?()
                return
            }
            writeMetadataAndPreserveHistory(onComplete: onComplete)
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

                    if let v = edited.digitalSourceType { fields[.digitalSourceType] = v.rawValue }
                    if let lat = edited.latitude, let lon = edited.longitude {
                        fields[.gpsLatitude] = String(abs(lat))
                        fields[.gpsLatitudeRef] = lat >= 0 ? "N" : "S"
                        fields[.gpsLongitude] = String(abs(lon))
                        fields[.gpsLongitudeRef] = lon >= 0 ? "E" : "W"
                    }
                    if let v = edited.creator, !v.isEmpty { fields[.creator] = v }
                    if let v = edited.credit, !v.isEmpty { fields[.credit] = v }
                    if let v = edited.copyright, !v.isEmpty { fields[.rights] = v }
                    if let v = edited.jobId, !v.isEmpty { fields[.transmissionReference] = v }
                    if let v = edited.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
                    if let v = edited.city, !v.isEmpty { fields[.city] = v }
                    if let v = edited.country, !v.isEmpty { fields[.country] = v }
                    if let v = edited.event, !v.isEmpty { fields[.event] = v }
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
                    if edited.digitalSourceType != original?.digitalSourceType {
                        fields[.digitalSourceType] = edited.digitalSourceType?.rawValue ?? ""
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
                    if edited.credit != original?.credit { fields[.credit] = edited.credit ?? "" }
                    if edited.copyright != original?.copyright { fields[.rights] = edited.copyright ?? "" }
                    if edited.jobId != original?.jobId {
                        fields[.transmissionReference] = edited.jobId ?? ""
                    }
                    if edited.dateCreated != original?.dateCreated { fields[.dateCreated] = edited.dateCreated ?? "" }
                    if edited.city != original?.city { fields[.city] = edited.city ?? "" }
                    if edited.country != original?.country { fields[.country] = edited.country ?? "" }
                    if edited.event != original?.event { fields[.event] = edited.event ?? "" }
                }

                if !fields.isEmpty {
                    try await writeEngine.writeFields(fields, to: urls)
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

    private func resolveStrictNonRawChoice(for urls: [URL]) async throws -> PMNonRAWXMPSidecarChoice? {
        let hasNonRaw = urls.contains { !SupportedImageFormats.isRaw(url: $0) }
        guard hasNonRaw else { return nil }
        let choice = await MainActor.run {
            PMXMPPolicy.resolveNonRawChoiceWithPromptIfNeeded()
        }
        guard let choice else { throw CancellationError() }
        return choice
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
        if let v = metadata.digitalSourceType { fields[.digitalSourceType] = v.rawValue }
        if let v = metadata.creator, !v.isEmpty { fields[.creator] = v }
        if let v = metadata.credit, !v.isEmpty { fields[.credit] = v }
        if let v = metadata.copyright, !v.isEmpty { fields[.rights] = v }
        if let v = metadata.jobId, !v.isEmpty { fields[.transmissionReference] = v }
        if let v = metadata.dateCreated, !v.isEmpty { fields[.dateCreated] = v }
        if let v = metadata.city, !v.isEmpty { fields[.city] = v }
        if let v = metadata.country, !v.isEmpty { fields[.country] = v }
        if let v = metadata.event, !v.isEmpty { fields[.event] = v }
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

        return (addTags, removeTags)
    }

    private func writeStrictPhotoMechanicXMP(onComplete: (() -> Void)? = nil) {
        guard let folderURL = currentFolderURL else {
            writeXMPSidecar()
            onComplete?()
            return
        }
        guard !selectedURLs.isEmpty else {
            onComplete?()
            return
        }

        if selectedCount == 1, let imageURL = selectedURLs.first {
            if SupportedImageFormats.isRaw(url: imageURL) {
                writeXMPSidecarAndPreserveHistory(onComplete: onComplete)
                return
            }

            writeTask?.cancel()
            writeTask = Task {
                do {
                    guard let choice = try await resolveStrictNonRawChoice(for: [imageURL]) else {
                        onComplete?()
                        return
                    }

                    switch choice {
                    case .historyOnly:
                        saveToSidecar()
                        onComplete?()
                    case .embeddedWrite:
                        writeMetadataAndClearSidecarForCurrentSelection(onComplete: onComplete)
                    case .syncRawJpegPair:
                        writeMetadataAndClearSidecarForCurrentSelection {
                            self.writeTask?.cancel()
                            self.writeTask = Task {
                                await self.syncRawPairForSingleNonRaw(
                                    nonRawURL: imageURL,
                                    metadata: self.editingMetadata
                                )
                                onComplete?()
                            }
                        }
                    }
                } catch is CancellationError {
                    saveError = PMXMPPolicy.cancelMessage
                    onComplete?()
                } catch {
                    saveError = error.localizedDescription
                    onComplete?()
                }
            }
            return
        }

        isSaving = true
        saveError = nil

        let urls = selectedURLs
        let edited = editingMetadata

        writeTask?.cancel()
        writeTask = Task {
            do {
                let nonRawChoice = try await resolveStrictNonRawChoice(for: urls)
                var rawXmpTargets = Set<URL>()
                var nonRawHistoryTargets = Set<URL>()
                var nonRawEmbeddedTargets = Set<URL>()
                var pairRawTargets = Set<URL>()
                var missingPairCount = 0
                var multiplePairCount = 0

                for url in urls {
                    if SupportedImageFormats.isRaw(url: url) {
                        rawXmpTargets.insert(url)
                        continue
                    }

                    guard let nonRawChoice else {
                        continue
                    }
                    switch nonRawChoice {
                    case .historyOnly:
                        nonRawHistoryTargets.insert(url)
                    case .embeddedWrite:
                        nonRawEmbeddedTargets.insert(url)
                    case .syncRawJpegPair:
                        nonRawEmbeddedTargets.insert(url)
                        if let pair = SupportedImageFormats.preferredRawSibling(for: url) {
                            pairRawTargets.insert(pair.url)
                            if pair.hadMultipleMatches {
                                multiplePairCount += 1
                            }
                        } else {
                            missingPairCount += 1
                        }
                    }
                }

                let allRawXmpTargets = rawXmpTargets.union(pairRawTargets)
                let prevCommon = self.previousEditingMetadata
                for rawURL in allRawXmpTargets {
                    var existing = xmpSidecarService.loadSidecar(for: rawURL) ?? IPTCMetadata()
                    applyBatchEdits(edited, to: &existing, previousCommon: prevCommon)
                    try xmpSidecarService.saveSidecar(metadata: existing, for: rawURL)
                }

                let fields = batchWriteFields(from: edited)
                if !nonRawEmbeddedTargets.isEmpty, !fields.isEmpty {
                    let structuredData = StructuredWriteData(
                        toneCurve: edited.cameraRaw?.toneCurve,
                        masks: edited.cameraRaw?.localAdjustments
                    )
                    try await writeEngine.writeFields(fields, to: Array(nonRawEmbeddedTargets), structuredData: structuredData)
                }

                // Handle additive list fields for non-RAW embedded targets
                if !nonRawEmbeddedTargets.isEmpty, let prev = prevCommon {
                    let diffs = additiveListDiffs(from: edited, previous: prev)
                    if !diffs.add.isEmpty || !diffs.remove.isEmpty {
                        try await writeEngine.addRemoveListValues(
                            add: diffs.add,
                            remove: diffs.remove,
                            to: Array(nonRawEmbeddedTargets)
                        )
                    }
                }

                if !allRawXmpTargets.isEmpty {
                    saveBatchSidecars(
                        folderURL: folderURL,
                        pendingChanges: false,
                        targetURLs: Array(allRawXmpTargets),
                        updateState: false
                    )
                }
                if !nonRawHistoryTargets.isEmpty {
                    saveBatchSidecars(
                        folderURL: folderURL,
                        pendingChanges: true,
                        targetURLs: Array(nonRawHistoryTargets),
                        updateState: false
                    )
                }
                if !nonRawEmbeddedTargets.isEmpty {
                    removeSidecars(for: nonRawEmbeddedTargets, in: folderURL)
                }

                hasChanges = !nonRawHistoryTargets.isEmpty
                selectedHavePendingSidecars = !nonRawHistoryTargets.isEmpty
                if !nonRawHistoryTargets.isEmpty {
                    saveError = "Saved \(nonRawHistoryTargets.count) non-RAW file(s) to history only."
                } else if missingPairCount > 0 || multiplePairCount > 0 {
                    var notes: [String] = []
                    if missingPairCount > 0 {
                        notes.append("\(missingPairCount) file(s) had no RAW sibling (embedded write only).")
                    }
                    if multiplePairCount > 0 {
                        notes.append("\(multiplePairCount) file(s) matched multiple RAW siblings (first preferred extension used).")
                    }
                    saveError = notes.joined(separator: " ")
                }
            } catch is CancellationError {
                saveError = PMXMPPolicy.cancelMessage
            } catch {
                saveError = "Failed to write metadata: \(error.localizedDescription)"
            }

            isSaving = false
            onComplete?()
        }
    }

    private func syncRawPairForSingleNonRaw(nonRawURL: URL, metadata: IPTCMetadata) async {
        guard let pair = SupportedImageFormats.preferredRawSibling(for: nonRawURL) else {
            saveError = "No RAW sibling found for \(nonRawURL.lastPathComponent). Wrote embedded metadata only."
            return
        }

        do {
            var existing = xmpSidecarService.loadSidecar(for: pair.url) ?? IPTCMetadata()
            existing = existing.merged(preferring: metadata)
            try xmpSidecarService.saveSidecar(metadata: existing, for: pair.url)

            if pair.hadMultipleMatches {
                saveError = "Multiple RAW siblings matched for \(nonRawURL.lastPathComponent). Used \(pair.url.lastPathComponent)."
            }
        } catch {
            saveError = "Failed to sync RAW sidecar for \(pair.url.lastPathComponent): \(error.localizedDescription)"
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

    private func overwriteFields(from metadata: IPTCMetadata) -> [MetadataFieldKey: String] {
        var fields: [MetadataFieldKey: String] = [:]
        fields[.headline] = metadata.title ?? ""
        fields[.description] = metadata.description ?? ""
        fields[.extendedDescription] = metadata.extendedDescription ?? ""
        fields[.subject] = metadata.keywords.uniqued().joined(separator: ", ")
        fields[.personInImage] = metadata.personShown.uniqued().joined(separator: ", ")
        fields[.digitalSourceType] = metadata.digitalSourceType?.rawValue ?? ""
        fields[.creator] = metadata.creator ?? ""
        fields[.credit] = metadata.credit ?? ""
        fields[.rights] = metadata.copyright ?? ""
        fields[.transmissionReference] = metadata.jobId ?? ""
        fields[.dateCreated] = metadata.dateCreated ?? ""
        fields[.city] = metadata.city ?? ""
        fields[.country] = metadata.country ?? ""
        fields[.event] = metadata.event ?? ""

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

        appendCameraRawFields(from: metadata, into: &fields)
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

    private func appendCameraRawFields(from metadata: IPTCMetadata, into fields: inout [MetadataFieldKey: String]) {
        // When cameraRaw is nil (edits fully reset), check if the original image had CRS
        // fields and clear them. Writing "" removes the field.
        guard let cameraRaw = metadata.cameraRaw else {
            if originalImageMetadata?.cameraRaw != nil {
                clearAllCameraRawFields(into: &fields)
            }
            return
        }

        // ACR requires Version and ProcessVersion to recognize settings.
        // ProcessVersion 15.4 corresponds to the 2012-era tags we write.
        fields[.crsVersion] = cameraRaw.version ?? "15.4"
        fields[.crsProcessVersion] = cameraRaw.processVersion ?? "15.4"

        // Write values when set, clear (empty string) when nil so old values
        // don't persist in the image after a partial reset.
        fields[.crsWhiteBalance] = cameraRaw.whiteBalance ?? ""
        fields[.crsTemperature] = cameraRaw.temperature.map(String.init) ?? ""
        fields[.crsTint] = cameraRaw.tint.map(formatSignedInt) ?? ""
        fields[.crsIncrementalTemperature] = cameraRaw.incrementalTemperature.map(formatSignedInt) ?? ""
        fields[.crsIncrementalTint] = cameraRaw.incrementalTint.map(formatSignedInt) ?? ""
        fields[.crsExposure2012] = cameraRaw.exposure2012.map { formatSignedDouble($0, precision: 2) } ?? ""
        fields[.crsContrast2012] = cameraRaw.contrast2012.map(formatSignedInt) ?? ""
        fields[.crsHighlights2012] = cameraRaw.highlights2012.map(formatSignedInt) ?? ""
        fields[.crsShadows2012] = cameraRaw.shadows2012.map(formatSignedInt) ?? ""
        fields[.crsWhites2012] = cameraRaw.whites2012.map(formatSignedInt) ?? ""
        fields[.crsBlacks2012] = cameraRaw.blacks2012.map(formatSignedInt) ?? ""
        fields[.crsSaturation] = cameraRaw.saturation.map(formatSignedInt) ?? ""
        fields[.crsVibrance] = cameraRaw.vibrance.map(formatSignedInt) ?? ""

        let hasSettings = cameraRaw.hasSettings ?? !cameraRaw.isEmpty
        fields[.crsHasSettings] = hasSettings ? "True" : "False"

        if let crop = cameraRaw.crop {
            fields[.crsCropTop] = crop.top.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropLeft] = crop.left.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropBottom] = crop.bottom.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropRight] = crop.right.map { String(format: "%.6f", $0) } ?? ""
            fields[.crsCropAngle] = crop.angle.map { String(format: "%.6f", $0) } ?? ""
            let hasCrop = crop.hasCrop ?? !crop.isEmpty
            fields[.crsHasCrop] = hasCrop ? "True" : "False"
            fields[.crsCropConstrainToWarp] = "0"
            fields[.crsCropConstrainToUnitSquare] = "1"
        } else {
            fields[.crsCropTop] = ""
            fields[.crsCropLeft] = ""
            fields[.crsCropBottom] = ""
            fields[.crsCropRight] = ""
            fields[.crsCropAngle] = ""
            fields[.crsHasCrop] = "False"
            fields[.crsCropConstrainToWarp] = ""
            fields[.crsCropConstrainToUnitSquare] = ""
        }

        fields[.crsHDREditMode] = cameraRaw.hdrEditMode.map(String.init) ?? ""
        fields[.crsHDRMaxValue] = cameraRaw.hdrMaxValue ?? ""
        fields[.crsSDRBrightness] = cameraRaw.sdrBrightness.map(formatSignedInt) ?? ""
        fields[.crsSDRContrast] = cameraRaw.sdrContrast.map(formatSignedInt) ?? ""
        fields[.crsSDRClarity] = cameraRaw.sdrClarity.map(formatSignedInt) ?? ""
        fields[.crsSDRHighlights] = cameraRaw.sdrHighlights.map(formatSignedInt) ?? ""
        fields[.crsSDRShadows] = cameraRaw.sdrShadows.map(formatSignedInt) ?? ""
        fields[.crsSDRWhites] = cameraRaw.sdrWhites.map(formatSignedInt) ?? ""
        fields[.crsSDRBlend] = cameraRaw.sdrBlend.map(formatSignedInt) ?? ""
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

    private func formatSignedInt(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func formatSignedDouble(_ value: Double, precision: Int) -> String {
        let format = "%.\(precision)f"
        let absValue = String(format: format, abs(value))
        if value > 0 { return "+\(absValue)" }
        if value < 0 { return "-\(absValue)" }
        return absValue
    }

    private func writeMetadataAndPreserveHistory(onComplete: (() -> Void)? = nil) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
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
                let fields = overwriteFields(from: edited)
                let structuredData = StructuredWriteData(
                    toneCurve: edited.cameraRaw?.toneCurve,
                    masks: edited.cameraRaw?.localAdjustments
                )
                try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                self.syncCameraRawToXMPSidecar(for: imageURL, metadata: edited)

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
                    self.hasChanges = false
                }
            } catch {
                self.saveError = error.localizedDescription
            }
            self.isSaving = false
            onComplete?()
        }
    }

    private func writeMetadataAndClearSidecarForCurrentSelection(onComplete: (() -> Void)? = nil) {
        guard selectedCount == 1,
              let imageURL = selectedURLs.first,
              let folderURL = currentFolderURL else {
            writeMetadata()
            onComplete?()
            return
        }

        let edited = editingMetadata

        isSaving = true
        saveError = nil

        writeTask?.cancel()
        writeTask = Task {
            do {
                let fields = overwriteFields(from: edited)
                let structuredData = StructuredWriteData(
                    toneCurve: edited.cameraRaw?.toneCurve,
                    masks: edited.cameraRaw?.localAdjustments
                )
                try await writeEngine.writeFields(fields, to: [imageURL], structuredData: structuredData)
                self.syncCameraRawToXMPSidecar(for: imageURL, metadata: edited)

                try? sidecarService.deleteSidecar(for: imageURL, in: folderURL)

                let isStillSelected = self.selectedCount == 1 && self.selectedURLs.first == imageURL
                if isStillSelected {
                    self.metadata = edited
                    self.originalImageMetadata = edited
                    self.embeddedMetadata = edited
                    self.sidecarHistory = []
                    self.previousEditingMetadata = edited
                    self.hasChanges = false
                    self.selectedHavePendingSidecars = false
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
                let validated = ApprovedListService.shared.validateBulk(parsed, in: .keywords, source: .template)
                if append {
                    let existing = Set(editingMetadata.keywords)
                    editingMetadata.keywords += validated.accepted.filter { !existing.contains($0) }
                } else {
                    var seen = Set<String>()
                    editingMetadata.keywords = validated.accepted.filter { seen.insert($0).inserted }
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
            case "digitalSourceType":
                editingMetadata.digitalSourceType = DigitalSourceType(rawValue: value)
            case "creator":
                editingMetadata.creator = append ? appendString(editingMetadata.creator, value) : value
            case "credit":
                editingMetadata.credit = append ? appendString(editingMetadata.credit, value) : value
            case "copyright":
                editingMetadata.copyright = append ? appendString(editingMetadata.copyright, value) : value
            case "jobId":
                editingMetadata.jobId = append ? appendString(editingMetadata.jobId, value) : value
            case "dateCreated":
                editingMetadata.dateCreated = append ? appendString(editingMetadata.dateCreated, value) : value
            case "city":
                editingMetadata.city = append ? appendString(editingMetadata.city, value) : value
            case "country":
                editingMetadata.country = append ? appendString(editingMetadata.country, value) : value
            case "event":
                editingMetadata.event = append ? appendString(editingMetadata.event, value) : value
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

    private static let variablePattern = /\{(date|date:[^}]+|dateCreated|dateCreated:[^}]+|dateCaptured|dateCaptured:[^}]+|filename|initials|persons|keywords|field:[^}]+|seq|seq:\d+)\}/

    /// Checks whether any text field, keyword, or person in editingMetadata contains variable placeholders.
    var hasVariables: Bool {
        let fields: [String?] = [
            editingMetadata.title,
            editingMetadata.description,
            editingMetadata.extendedDescription,
            editingMetadata.creator,
            editingMetadata.credit,
            editingMetadata.copyright,
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
        return listValues.contains { $0.contains(Self.variablePattern) }
    }

    /// Resolves all variable placeholders in editingMetadata text fields in-place.
    func processVariables(filename: String = "", sequenceIndex: Int = 1) {
        let interpolator = PresetVariableInterpolator()
        let initials = UserDefaults.standard.string(forKey: UserDefaultsKeys.creatorInitials) ?? ""
        // Use a snapshot of current editing state for field references
        let snapshot = editingMetadata

        editingMetadata.title = resolveIfPresent(editingMetadata.title, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.description = resolveIfPresent(editingMetadata.description, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.extendedDescription = resolveIfPresent(editingMetadata.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.creator = resolveIfPresent(editingMetadata.creator, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.credit = resolveIfPresent(editingMetadata.credit, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.copyright = resolveIfPresent(editingMetadata.copyright, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.jobId = resolveIfPresent(editingMetadata.jobId, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.dateCreated = resolveIfPresent(editingMetadata.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.city = resolveIfPresent(editingMetadata.city, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.country = resolveIfPresent(editingMetadata.country, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.event = resolveIfPresent(editingMetadata.event, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)

        editingMetadata.keywords = resolveListField(editingMetadata.keywords, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)
        editingMetadata.personShown = resolveListField(editingMetadata.personShown, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceIndex, initials: initials)

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
        let mode = MetadataWriteMode.current(forC2PA: image.hasC2PA)
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
        if resolved.credit != original.credit { fields[.credit] = resolved.credit ?? "" }
        if resolved.copyright != original.copyright { fields[.rights] = resolved.copyright ?? "" }
        if resolved.jobId != original.jobId {
            fields[.transmissionReference] = resolved.jobId ?? ""
        }
        if resolved.dateCreated != original.dateCreated { fields[.dateCreated] = resolved.dateCreated ?? "" }
        if resolved.city != original.city { fields[.city] = resolved.city ?? "" }
        if resolved.country != original.country { fields[.country] = resolved.country ?? "" }
        if resolved.event != original.event { fields[.event] = resolved.event ?? "" }
        if resolved.keywords != original.keywords {
            fields[.subject] = resolved.keywords.joined(separator: ", ")
        }
        if resolved.personShown != original.personShown {
            fields[.personInImage] = resolved.personShown.joined(separator: ", ")
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
            if PMXMPPolicy.mode == .strictPhotoMechanic {
                // In strict PM mode, RAW files get XMP sidecar normally
                if SupportedImageFormats.isRaw(url: url) {
                    try xmpSidecarService.saveSidecar(metadata: resolved, for: url)
                    let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to XMP sidecar")
                    try sidecarService.saveSidecar(sidecar, for: url, in: folder)
                    return .writtenToXMPSidecar
                }

                // Non-RAW in PM strict mode: check nonRawBehavior setting.
                // In batch context, we can't show dialogs, so .alwaysAsk falls back to history only.
                switch PMXMPPolicy.nonRawBehavior {
                case .historyOnly, .alwaysAsk:
                    let sidecar = buildSidecar(pendingChanges: true, historyNote: "Saved to sidecar (PM strict non-RAW)")
                    try sidecarService.saveSidecar(sidecar, for: url, in: folder)
                    return .savedToHistory
                case .embeddedWrite:
                    if !fields.isEmpty {
                        try await writeEngine.writeFields(fields, to: [url])
                    }
                    let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to image file (PM strict embedded)")
                    try sidecarService.saveSidecar(sidecar, for: url, in: folder)
                    return .writtenToFile
                case .syncRawJpegPair:
                    if !fields.isEmpty {
                        try await writeEngine.writeFields(fields, to: [url])
                    }
                    // Write XMP sidecar for RAW sibling if found
                    if let pair = SupportedImageFormats.preferredRawSibling(for: url) {
                        var existing = xmpSidecarService.loadSidecar(for: pair.url) ?? IPTCMetadata()
                        existing = existing.merged(preferring: resolved)
                        try xmpSidecarService.saveSidecar(metadata: existing, for: pair.url)
                    }
                    let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to file + RAW sibling XMP (PM strict sync)")
                    try sidecarService.saveSidecar(sidecar, for: url, in: folder)
                    return .writtenToFile
                }
            }

            // Normal XMP sidecar mode
            try xmpSidecarService.saveSidecar(metadata: resolved, for: url)
            let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to XMP sidecar")
            try sidecarService.saveSidecar(sidecar, for: url, in: folder)
            return .writtenToXMPSidecar

        case .writeToFile:
            if image.hasC2PA {
                // C2PA-protected: save to sidecar only (same safety guard as commitEdits)
                let sidecar = buildSidecar(pendingChanges: true, historyNote: "Saved to sidecar (C2PA protected)")
                try sidecarService.saveSidecar(sidecar, for: url, in: folder)
                return .savedToHistory
            }

            if !fields.isEmpty {
                try await writeEngine.writeFields(fields, to: [url])
            }
            let sidecar = buildSidecar(pendingChanges: false, historyNote: "Written to image file")
            try sidecarService.saveSidecar(sidecar, for: url, in: folder)
            return .writtenToFile
        }
    }

    /// Process variables for specific images: reads each image's metadata,
    /// resolves any variable placeholders, and writes back.
    func processVariablesForImages(_ images: [ImageFile]) {
        guard !images.isEmpty else { return }
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
        isProcessingFolder = true
        folderProcessProgress = "0/\(images.count)"
        saveError = nil
        variableProcessingStatus = nil
        batchProcessTask?.cancel()
        batchProcessTask = Task { await processVariablesBatch(images) }
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
        var resolved = 0
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
                self.processVariables(filename: filename, sequenceIndex: sequenceNumber)
                if self.editingMetadata != before {
                    self.saveToSidecar()
                    resolved += 1
                } else {
                    unchanged += 1
                }
                processed += 1
                self.folderProcessProgress = "\(processed)/\(images.count)"
                continue
            }

            guard let embedded = batchMetadata[url] else {
                // Already counted as failed during batch read
                processed += 1
                self.folderProcessProgress = "\(processed)/\(images.count)"
                continue
            }

            do {
                // Load XMP sidecar if policy allows, matching the normal
                // metadata loading path that merges embedded + XMP
                let xmpMeta = self.loadXMPMetadataIfAllowed(for: url)
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
                let meta: IPTCMetadata
                if let sidecar = existingSidecar, sidecar.pendingChanges {
                    meta = sidecar.metadata
                } else {
                    meta = baseMeta
                }
                let snapshot = meta

                var changed = false
                var resolvedMeta = meta

                resolvedMeta.title = resolveIfChanged(meta.title, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.description = resolveIfChanged(meta.description, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.extendedDescription = resolveIfChanged(meta.extendedDescription, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.creator = resolveIfChanged(meta.creator, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.credit = resolveIfChanged(meta.credit, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.copyright = resolveIfChanged(meta.copyright, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.jobId = resolveIfChanged(meta.jobId, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.dateCreated = resolveIfChanged(meta.dateCreated, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.city = resolveIfChanged(meta.city, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.country = resolveIfChanged(meta.country, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)
                resolvedMeta.event = resolveIfChanged(meta.event, interpolator: interpolator, filename: filename, ref: snapshot, changed: &changed, sequenceIndex: sequenceNumber, initials: initials)

                let newKeywords = resolveListField(meta.keywords, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials)
                if newKeywords != meta.keywords { resolvedMeta.keywords = newKeywords; changed = true }
                let newPersons = resolveListField(meta.personShown, interpolator: interpolator, filename: filename, ref: snapshot, sequenceIndex: sequenceNumber, initials: initials)
                if newPersons != meta.personShown { resolvedMeta.personShown = newPersons; changed = true }

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
            await self.refreshMetadataAfterProcessing(updatedURLs: updatedURLs)
        }

        self.isProcessingFolder = false
        self.folderProcessProgress = ""
        var statusParts: [String] = []
        if writtenToFile > 0 { statusParts.append("written to file: \(writtenToFile)") }
        if writtenToXMP > 0 { statusParts.append("written to XMP: \(writtenToXMP)") }
        if savedToHistory > 0 { statusParts.append("saved to sidecar: \(savedToHistory)") }
        if resolved > 0 { statusParts.append("resolved: \(resolved)") }
        if unchanged > 0 { statusParts.append("unchanged: \(unchanged)") }
        if failed > 0 { statusParts.append("failed: \(failed)") }
        if !statusParts.isEmpty {
            self.variableProcessingHadFailures = failed > 0
            self.variableProcessingStatus = "Variable processing completed: \(statusParts.joined(separator: ", "))."
        }
    }

    /// Re-read metadata from file for the currently displayed image after variable processing,
    /// so the UI reflects the resolved values instead of stale template strings.
    private func refreshMetadataAfterProcessing(updatedURLs: Set<URL>) async {
        guard selectedCount == 1,
              let url = selectedURLs.first,
              updatedURLs.contains(url) else { return }

        do {
            let (embedded, conflict) = try await readService.readFullMetadataWithConflictCheck(url: url)
            let xmpMeta = loadXMPMetadataIfAllowed(for: url)
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
    private func resolveListField(_ values: [String], interpolator: PresetVariableInterpolator, filename: String, ref: IPTCMetadata, sequenceIndex: Int, initials: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            let resolved = interpolator.resolve(value, filename: filename, existingMetadata: ref, sequenceIndex: sequenceIndex, initials: initials)
            for part in resolved.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                result.append(trimmed)
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

                    // Rate limit: ~0.5s delay between requests
                    try await Task.sleep(for: .milliseconds(500))

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
        recordChange("Copyright", old: previous.copyright, new: edited.copyright)
        recordChange("Job ID", old: previous.jobId, new: edited.jobId)
        recordChange("Creator", old: previous.creator, new: edited.creator)
        recordChange("Credit", old: previous.credit, new: edited.credit)
        recordChange("Date Created", old: previous.dateCreated, new: edited.dateCreated)
        recordChange("City", old: previous.city, new: edited.city)
        recordChange("Country", old: previous.country, new: edited.country)
        recordChange("Event", old: previous.event, new: edited.event)
        recordChange(
            "Digital Source Type",
            old: previous.digitalSourceType?.rawValue,
            new: edited.digitalSourceType?.rawValue
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
                    // C2PA: save full metadata to XMP sidecar for render+sign overlay
                    try xmpSidecarService.saveSidecar(metadata: existingMeta, for: imageURL)
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

        if let copyright = batchMeta.copyright, !copyright.isEmpty {
            metadata.copyright = copyright
        }
        if let jobId = batchMeta.jobId, !jobId.isEmpty {
            metadata.jobId = jobId
        }
        if let creator = batchMeta.creator, !creator.isEmpty {
            metadata.creator = creator
        }
        if let credit = batchMeta.credit, !credit.isEmpty {
            metadata.credit = credit
        }
        if let city = batchMeta.city, !city.isEmpty {
            metadata.city = city
        }
        if let country = batchMeta.country, !country.isEmpty {
            metadata.country = country
        }
        if let event = batchMeta.event, !event.isEmpty {
            metadata.event = event
        }
        if batchMeta.digitalSourceType != nil {
            metadata.digitalSourceType = batchMeta.digitalSourceType
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
                let fields = overwriteFields(from: edited)
                let structuredData = StructuredWriteData(
                    toneCurve: edited.cameraRaw?.toneCurve,
                    masks: edited.cameraRaw?.localAdjustments
                )
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
                let fields = overwriteFields(from: edited)
                let structuredData = StructuredWriteData(
                    toneCurve: edited.cameraRaw?.toneCurve,
                    masks: edited.cameraRaw?.localAdjustments
                )

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
        if editingMetadata.copyright != original.copyright { names.append("Copyright") }
        if editingMetadata.jobId != original.jobId { names.append("Job ID") }
        if editingMetadata.creator != original.creator { names.append("Creator") }
        if editingMetadata.credit != original.credit { names.append("Credit") }
        if editingMetadata.city != original.city { names.append("City") }
        if editingMetadata.country != original.country { names.append("Country") }
        if editingMetadata.event != original.event { names.append("Event") }
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
        case "Copyright":
            metadata.copyright = entry.newValue
        case "Job ID", "Job-ID":
            metadata.jobId = entry.newValue
        case "Creator":
            metadata.creator = entry.newValue
        case "Credit":
            metadata.credit = entry.newValue
        case "City":
            metadata.city = entry.newValue
        case "Country":
            metadata.country = entry.newValue
        case "Event":
            metadata.event = entry.newValue
        case "Digital Source Type":
            metadata.digitalSourceType = entry.newValue.flatMap { DigitalSourceType(rawValue: $0) }
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
